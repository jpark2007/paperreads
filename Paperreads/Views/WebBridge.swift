import Foundation
import WebKit
import AppKit

// Shared plumbing for the bundled reader/chat web views (docs/ARCHITECTURE.md §5 bridge rules):
// non-persistent store, no auto-opened windows, file-URL-only navigation, https links handed
// to the default browser, validated script messages, JSON-argument JS calls.

/// Forwards script messages to a weakly-held target so WKUserContentController (which retains
/// its handlers strongly) never keeps a Coordinator — and through it the web view — alive.
final class WebScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

enum WebBridge {
    static let quoteLimit = 4000
    static let contextLimit = 8000

    /// `Web/<name>.html` inside the app bundle.
    static func pageURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "Web")
    }

    @MainActor
    static func makeWebView(handlerName: String,
                            handler: WKScriptMessageHandler,
                            delegate: WKNavigationDelegate & WKUIDelegate) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true

        let controller = WKUserContentController()
        controller.add(WebScriptMessageProxy(target: handler), name: handlerName)
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = Theme.nsBg
        // File drops belong to the window (PDF import), never to the page.
        webView.unregisterDraggedTypes()
        // Fade in once the page reports ready, so there's no white flash.
        webView.alphaValue = 0
        return webView
    }

    @MainActor
    static func tearDown(_ webView: WKWebView, handlerName: String) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    static func load(_ webView: WKWebView, page: URL) {
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    @MainActor
    static func reveal(_ webView: WKWebView) {
        guard webView.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            webView.animator().alphaValue = 1
        }
    }

    // MARK: Navigation policy

    /// Only the bundled page itself may load in the main frame. User-clicked https links open in
    /// the default browser; everything else is cancelled.
    @MainActor
    static func policy(for action: WKNavigationAction, page: URL) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.navigationType == .linkActivated {
            if isSameDocument(url, page) { return .allow }      // in-page #anchors
            openExternally(url)
            return .cancel
        }
        guard action.targetFrame?.isMainFrame == true else { return .cancel }
        return isSameDocument(url, page) ? .allow : .cancel
    }

    /// Opens https URLs in the default browser; ignores anything else.
    @MainActor
    static func openExternally(_ url: URL) {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return }
        NSWorkspace.shared.open(url)
    }

    static func isSameDocument(_ url: URL, _ page: URL) -> Bool {
        guard url.isFileURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
            == page.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Message validation

    /// Accept messages only from our web view's main frame on the bundled file page.
    @MainActor
    static func isTrusted(_ message: WKScriptMessage, from webView: WKWebView?, page: URL) -> Bool {
        guard let webView, message.webView === webView, message.frameInfo.isMainFrame else { return false }
        guard message.frameInfo.securityOrigin.protocol == "file" else { return false }
        if let url = message.frameInfo.request.url, !isSameDocument(url, page) { return false }
        return true
    }

    static func type(of body: Any) -> (String, [String: Any])? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String,
              type.count <= 64 else { return nil }
        return (type, dict)
    }

    /// A JS number that is a finite integer in range (rejects booleans and fractions).
    static func int(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, d >= Double(range.lowerBound), d <= Double(range.upperBound) else {
            return nil
        }
        return Int(d)
    }

    static func string(_ value: Any?, maxLength: Int, allowEmpty: Bool = false) -> String? {
        guard let s = value as? String, s.count <= maxLength else { return nil }
        if !allowEmpty && s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return s
    }

    /// Validates a reader selection object (§5 size caps). Accepts an object or its JSON string.
    static func selection(_ value: Any?) -> ReaderSelection? {
        var obj = value
        if let json = value as? String {
            guard json.utf8.count <= 64_000, let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
            obj = parsed
        }
        guard let dict = obj as? [String: Any],
              let quote = string(dict["quote"], maxLength: quoteLimit),
              let block = int(dict["blockIndex"], in: 0...10_000_000),
              let offset = int(dict["startOffset"], in: 0...100_000_000) else { return nil }
        let context: String
        if dict["contextText"] == nil || dict["contextText"] is NSNull {
            context = ""
        } else {
            guard let c = string(dict["contextText"], maxLength: contextLimit, allowEmpty: true) else { return nil }
            context = c
        }
        return ReaderSelection(quote: quote, blockIndex: block, startOffset: offset, contextText: context)
    }

    // MARK: JS calls

    /// `callAsyncJavaScript` with JSON-encoded arguments (never string-interpolated JS).
    @MainActor
    @discardableResult
    static func call(_ webView: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async -> Result<Any?, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Any?, Error>, Never>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: .success(value))
                case .failure(let error): continuation.resume(returning: .failure(error))
                }
            }
        }
    }
}

/// Limits reloads after the WebContent process terminates. Content that kills the process
/// deterministically (memory limit, WebKit bug) would otherwise reload forever, spawning one
/// process after another. Reloads back off exponentially; after `maxCrashes` terminations
/// within `window` the caller stops and shows a native fallback instead.
struct WebCrashGuard {
    static let maxCrashes = 3
    static let window: TimeInterval = 60

    enum Decision {
        case reload(after: Duration)
        case giveUp
    }

    private var key: String?
    private var crashes: [Date] = []

    /// Records a termination for `key` (crash history resets when the key changes).
    mutating func recordCrash(key: String, now: Date = Date()) -> Decision {
        if self.key != key {
            self.key = key
            crashes = []
        }
        crashes = crashes.filter { now.timeIntervalSince($0) < Self.window }
        crashes.append(now)
        if crashes.count >= Self.maxCrashes { return .giveUp }
        // 0.5 s, 1 s, … before each reload.
        let ms = 500 << (crashes.count - 1)
        return .reload(after: .milliseconds(ms))
    }

    mutating func reset() {
        key = nil
        crashes = []
    }
}
