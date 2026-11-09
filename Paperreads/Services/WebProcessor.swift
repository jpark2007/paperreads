import Foundation
import WebKit

// Module C — runs the bundled ingest page (Web/ingest.html, module A) in one offscreen
// WKWebView to turn untrusted arXiv HTML / Claude Markdown into sanitized, block-tagged HTML.
//
// Security:
//   • non-persistent website data store, no window opening, no navigation except the
//     bundled ingest page (every other navigation is cancelled)
//   • a content rule list blocks every non-file load (ingest never needs the network)
//   • content is passed to JS only as `callAsyncJavaScript` arguments — never interpolated

enum WebProcessorError: LocalizedError {
    case missingIngestPage
    case loadFailed(String)
    case loadTimedOut
    case timedOut
    case scriptFailed(String)
    case ingestUnavailable
    case badResult
    case inputTooLarge

    var errorDescription: String? {
        switch self {
        case .missingIngestPage: return "The text processor is missing from the app bundle."
        case .loadFailed(let why): return "The text processor failed to start: \(why)"
        case .loadTimedOut: return "The text processor took too long to start."
        case .timedOut: return "Processing the document took too long."
        case .scriptFailed(let why): return "The text processor failed: \(why)"
        case .ingestUnavailable: return "The text processor did not initialise correctly."
        case .badResult: return "The text processor returned an unreadable result."
        case .inputTooLarge: return "The document is too large to process."
        }
    }
}

@MainActor
final class WebProcessor: NSObject {
    static let shared = WebProcessor()

    /// Max characters handed to the ingest page (matches the 25MB HTML download cap).
    private let maxInputLength = 26 * 1024 * 1024
    private let loadTimeout: Duration = .seconds(20)
    private let callTimeout: Duration = .seconds(120)

    private var webView: WKWebView?
    private var isLoaded = false
    private var loadError: Error?
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var ingestPageURL: URL?
    private var blockRules: WKContentRuleList?
    private var didAttemptRules = false

    private override init() { super.init() }

    // MARK: Public API

    func ingestArxivHTML(_ html: String, baseURL: URL) async throws -> IngestResult {
        guard html.utf16.count <= maxInputLength else { throw WebProcessorError.inputTooLarge }
        return try await call(
            "return await Ingest.fromArxivHTML(html, baseURL);",
            arguments: ["html": html, "baseURL": baseURL.absoluteString])
    }

    func ingestMarkdown(_ markdown: String) async throws -> IngestResult {
        guard markdown.utf16.count <= maxInputLength else { throw WebProcessorError.inputTooLarge }
        return try await call(
            "return await Ingest.fromMarkdown(md);",
            arguments: ["md": markdown])
    }

    // MARK: Calling

    private func call(_ body: String, arguments: [String: Any]) async throws -> IngestResult {
        let view = try await readyWebView()

        let guarded = """
        if (typeof Ingest === "undefined") { throw new Error("Ingest unavailable"); }
        \(body)
        """
        let raw: Any?
        do {
            raw = try await evaluate(guarded, arguments: arguments, in: view)
        } catch let error as WebProcessorError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            if message?.contains("Ingest unavailable") == true { throw WebProcessorError.ingestUnavailable }
            throw WebProcessorError.scriptFailed(message ?? error.localizedDescription)
        }
        if let s = raw as? String {
            // Copying + JSON-decoding a multi-MB result stays off the main actor.
            return try await Task.detached(priority: .userInitiated) {
                try WebProcessor.decodeJSON(Data(s.utf8))
            }.value
        }
        return try decode(raw)
    }

    nonisolated private static func decodeJSON(_ data: Data) throws -> IngestResult {
        do { return try JSONDecoder().decode(IngestResult.self, from: data) }
        catch { throw WebProcessorError.badResult }
    }

    private func decode(_ raw: Any?) throws -> IngestResult {
        let data: Data
        if let s = raw as? String {
            data = Data(s.utf8)
        } else if let obj = raw, JSONSerialization.isValidJSONObject(obj) {
            // Tolerate the page returning a plain object instead of a JSON string.
            data = try JSONSerialization.data(withJSONObject: obj)
        } else {
            throw WebProcessorError.badResult
        }
        do { return try JSONDecoder().decode(IngestResult.self, from: data) }
        catch { throw WebProcessorError.badResult }
    }

    // MARK: Web view lifecycle

    private func readyWebView() async throws -> WKWebView {
        if let view = webView, isLoaded { return view }
        if webView == nil { try await createWebView() }
        guard let view = webView else { throw WebProcessorError.loadFailed("no web view") }
        if isLoaded { return view }
        if let loadError { reset(); throw loadError }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if isLoaded { cont.resume(); return }
            if let e = loadError { cont.resume(throwing: e); return }
            loadWaiters.append(cont)
        }
        guard isLoaded, let ready = webView else {
            let e = loadError ?? WebProcessorError.loadTimedOut
            reset()
            throw e
        }
        return ready
    }

    private func createWebView() async throws {
        guard let page = Bundle.main.url(forResource: "ingest", withExtension: "html", subdirectory: "Web") else {
            throw WebProcessorError.missingIngestPage
        }
        let rules = await networkBlockRules()
        // Another caller may have created the view while we awaited the rule list.
        if webView != nil { return }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        if let rules { config.userContentController.add(rules) }

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        ingestPageURL = page
        isLoaded = false
        loadError = nil
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

        let limit = loadTimeout
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: limit)
            guard let self, let view, view === self.webView, !self.isLoaded, self.loadError == nil else { return }
            self.finishLoad(WebProcessorError.loadTimedOut)
        }
    }

    /// Blocks every load that is not a local file. Compiled once; nil if compilation fails
    /// (navigation policy + the page's CSP still apply).
    private func networkBlockRules() async -> WKContentRuleList? {
        if didAttemptRules { return blockRules }
        didAttemptRules = true
        let json = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
        guard let store = WKContentRuleListStore.default() else { return nil }
        let list: WKContentRuleList? = await withCheckedContinuation { cont in
            store.compileContentRuleList(forIdentifier: "PaperreadsIngestOffline",
                                         encodedContentRuleList: json) { list, _ in
                cont.resume(returning: list)
            }
        }
        blockRules = list
        return list
    }

    private func finishLoad(_ error: Error?) {
        if let error { loadError = error; isLoaded = false } else { isLoaded = true; loadError = nil }
        let waiters = loadWaiters
        loadWaiters = []
        for w in waiters {
            if let error { w.resume(throwing: error) } else { w.resume() }
        }
    }

    /// Drops the web view so the next call starts fresh (after a crash or failed load).
    private func reset() {
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
        isLoaded = false
        loadError = nil
        let waiters = loadWaiters
        loadWaiters = []
        for w in waiters { w.resume(throwing: WebProcessorError.loadFailed("restarted")) }
    }

    // MARK: JS evaluation with timeout

    /// Runs `callAsyncJavaScript` with a deadline. On timeout or Task cancellation the
    /// web view is torn down (stopping runaway work) and the caller gets an error; the
    /// continuation is resumed exactly once.
    private func evaluate(_ js: String, arguments: [String: Any], in view: WKWebView) async throws -> Any? {
        let once = OnceBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                once.set(cont)
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: self?.callTimeout ?? .seconds(120))
                    guard !Task.isCancelled else { return }
                    if once.resume(.failure(WebProcessorError.timedOut)) { self?.reset() }
                }
                view.callAsyncJavaScript(js, arguments: arguments, in: nil, in: .page) { result in
                    timeout.cancel()
                    switch result {
                    case .success(let value): _ = once.resume(.success(value))
                    case .failure(let error): _ = once.resume(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if once.resume(.failure(CancellationError())) { self?.reset() }
            }
        }
    }
}

/// Resume-once wrapper so completion, timeout and cancellation can race safely.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Any?, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<Any?, Error>) {
        lock.lock()
        if done { lock.unlock(); c.resume(throwing: CancellationError()); return }
        cont = c
        lock.unlock()
    }

    /// Returns true if this call performed the resume.
    @discardableResult
    func resume(_ result: Result<Any?, Error>) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: result)
        return true
    }
}

// MARK: - Navigation policy

extension WebProcessor: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let page = ingestPageURL,
              url.isFileURL,
              url.standardizedFileURL.path == page.standardizedFileURL.path,
              navigationAction.targetFrame?.isMainFrame == true
        else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        finishLoad(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        finishLoad(WebProcessorError.loadFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        finishLoad(WebProcessorError.loadFailed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        if !isLoaded { finishLoad(WebProcessorError.loadFailed("web content process terminated")) }
        // Any in-flight callAsyncJavaScript fails on its own; recreate lazily next time.
        self.webView = nil
        isLoaded = false
        loadError = nil
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
