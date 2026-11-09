import SwiftUI
import WebKit

/// A highlight as sent to `Reader.load` / `Reader.addHighlight`.
struct ReaderHighlightPayload: Equatable {
    let id: UUID
    let blockIndex: Int
    let startOffset: Int
    let quote: String

    init(_ h: Highlight) {
        id = h.id
        blockIndex = h.blockIndex
        startOffset = h.startOffset
        quote = h.quote
    }

    var jsObject: [String: Any] {
        ["id": id.uuidString, "blockIndex": blockIndex, "startOffset": startOffset, "quote": quote]
    }
}

/// Handle the rest of the app uses to drive the reader web view (scroll, flash, read selection).
/// Owned by a `PaperSession`; the live `WebReader.Coordinator` attaches itself weakly.
@MainActor
final class ReaderBridge {
    fileprivate weak var coordinator: WebReader.Coordinator?
    private var pendingReveal: (block: Int, highlightID: UUID?)?

    /// Scroll to a block (and flash a highlight). Deferred until the content has loaded.
    func reveal(block: Int, highlightID: UUID?) {
        if let c = coordinator, c.isContentLoaded {
            c.reveal(block: block, highlightID: highlightID)
        } else {
            pendingReveal = (block, highlightID)
        }
    }

    func currentSelection() async -> ReaderSelection? {
        guard let c = coordinator, c.isContentLoaded else { return nil }
        return await c.fetchSelection()
    }

    func detach() {
        coordinator = nil
        pendingReveal = nil
    }

    fileprivate func attach(_ c: WebReader.Coordinator) {
        coordinator = c
    }

    fileprivate func contentDidLoad() {
        guard let p = pendingReveal, let c = coordinator else { return }
        pendingReveal = nil
        c.reveal(block: p.block, highlightID: p.highlightID)
    }
}

/// The clean-text reader: `Web/reader.html` in a WKWebView.
struct WebReader: NSViewRepresentable {
    static let handlerName = "reader"

    let page: URL
    let paperID: UUID
    /// Changes whenever the paper's content may have been (re)written.
    let contentToken: String
    let highlights: [ReaderHighlightPayload]
    let bridge: ReaderBridge
    var onSelection: (SelectionAction, ReaderSelection) -> Void
    var onHighlightClicked: (UUID) -> Void
    /// Called when the content process keeps crashing on this paper; reloading has stopped.
    var onContentCrashed: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        let webView = WebBridge.makeWebView(handlerName: Self.handlerName, handler: c, delegate: c)
        c.webView = webView
        c.attach(bridge)
        WebBridge.load(webView, page: page)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.attach(bridge)
        c.sync()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
        WebBridge.tearDown(webView, handlerName: handlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: WebReader
        weak var webView: WKWebView?
        private weak var bridge: ReaderBridge?

        private var isReady = false
        private(set) var isContentLoaded = false
        private var loadedKey: String?
        private var applied: [UUID: ReaderHighlightPayload] = [:]
        private var chain: Task<Void, Never>?
        private var generation = 0
        private var crashGuard = WebCrashGuard()
        private var reloadTask: Task<Void, Never>?

        init(parent: WebReader) {
            self.parent = parent
        }

        func attach(_ b: ReaderBridge) {
            guard bridge !== b else { return }
            bridge = b
            b.attach(self)
        }

        func tearDown() {
            generation += 1
            reloadTask?.cancel()
            reloadTask = nil
            chain?.cancel()
            chain = nil
            isReady = false
            isContentLoaded = false
            if bridge?.coordinator === self { bridge?.detach() }
            bridge = nil
        }

        // MARK: State sync

        func sync() {
            guard isReady, webView != nil else { return }
            let key = "\(parent.paperID.uuidString)|\(parent.contentToken)"
            if key != loadedKey {
                load(key: key)
                return
            }
            let desired = Dictionary(parent.highlights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            guard desired != applied else { return }
            let removed = applied.filter { desired[$0.key] != $0.value }.map(\.key)
            let added = desired.values.filter { applied[$0.id] != $0 }
                .sorted { ($0.blockIndex, $0.startOffset) < ($1.blockIndex, $1.startOffset) }
            applied = desired
            enqueue { webView in
                for id in removed {
                    await WebBridge.call(webView, "Reader.removeHighlight(id);", ["id": id.uuidString])
                }
                for h in added {
                    await WebBridge.call(webView, "Reader.addHighlight(h);", ["h": h.jsObject])
                }
            }
        }

        private func load(key: String) {
            generation += 1
            let gen = generation
            loadedKey = key
            isContentLoaded = false
            let paperID = parent.paperID
            let highlights = parent.highlights
            applied = Dictionary(highlights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            enqueue { [weak self] webView in
                let html = await Task.detached(priority: .userInitiated) {
                    PaperStore.readHTML(paperID)
                }.value
                guard let self, gen == self.generation else { return }
                let content = html ?? "<p>This paper's text file is missing. Retry the import from the library.</p>"
                let payload: [String: Any] = ["html": content, "highlights": highlights.map(\.jsObject)]
                await WebBridge.call(webView, "await Reader.load(payload);", ["payload": payload])
                guard gen == self.generation else { return }
                self.isContentLoaded = true
                WebBridge.reveal(webView)
                self.bridge?.contentDidLoad()
                self.sync()
            }
        }

        /// Serialises JS calls so load → highlight diffs → scrolls run in order.
        private func enqueue(_ op: @escaping @MainActor (WKWebView) async -> Void) {
            let previous = chain
            chain = Task { @MainActor [weak self] in
                await previous?.value
                guard !Task.isCancelled, let webView = self?.webView else { return }
                await op(webView)
            }
        }

        func reveal(block: Int, highlightID: UUID?) {
            enqueue { webView in
                await WebBridge.call(webView, "Reader.scrollToBlock(b);", ["b": block])
                if let id = highlightID {
                    await WebBridge.call(webView, "Reader.flashHighlight(id);", ["id": id.uuidString])
                }
            }
        }

        func fetchSelection() async -> ReaderSelection? {
            guard let webView else { return nil }
            let result = await WebBridge.call(webView, "return Reader.getSelection();")
            guard case .success(let value) = result, let value, !(value is NSNull) else { return nil }
            return WebBridge.selection(value)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == WebReader.handlerName,
                  WebBridge.isTrusted(message, from: webView, page: parent.page),
                  let parsed = WebBridge.type(of: message.body) else { return }
            let (kind, body) = parsed

            switch kind {
            case "ready":
                // Fresh page (first load, reload, or after a content-process crash).
                generation += 1
                isReady = true
                isContentLoaded = false
                loadedKey = nil
                applied = [:]
                sync()
            case "selection":
                guard isContentLoaded,
                      let raw = WebBridge.string(body["action"], maxLength: 16),
                      let action = SelectionAction(rawValue: raw),
                      let selection = WebBridge.selection(body["selection"]) else { return }
                parent.onSelection(action, selection)
            case "highlightClicked":
                guard isContentLoaded,
                      let raw = WebBridge.string(body["id"], maxLength: 64),
                      let id = UUID(uuidString: raw) else { return }
                parent.onHighlightClicked(id)
            default:
                return
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(WebBridge.policy(for: navigationAction, page: parent.page))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            generation += 1
            isReady = false
            isContentLoaded = false
            loadedKey = nil
            applied = [:]
            reloadTask?.cancel()
            switch crashGuard.recordCrash(key: parent.paperID.uuidString) {
            case .giveUp:
                reloadTask = nil
                parent.onContentCrashed()
            case .reload(let delay):
                let gen = generation
                reloadTask = Task { [weak self, weak webView] in
                    try? await Task.sleep(for: delay)
                    guard let self, let webView, !Task.isCancelled, self.generation == gen else { return }
                    self.reloadTask = nil
                    WebBridge.load(webView, page: self.parent.page)
                }
            }
        }

        // MARK: WKUIDelegate

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                WebBridge.openExternally(url)
            }
            return nil
        }
    }
}
