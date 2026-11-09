import SwiftUI
import WebKit

/// The Ask transcript: `Web/chat.html` (markdown + KaTeX) in a WKWebView.
struct ChatWebView: NSViewRepresentable {
    static let handlerName = "chat"

    let page: URL
    let paperTitle: String
    let messages: [ChatDisplayMessage]
    let streamingText: String?
    let isThinking: Bool
    /// "r3" → "Title (2017)"
    let references: [String: String]
    var onJumpToBlock: (Int) -> Void
    var onOpenReference: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        let webView = WebBridge.makeWebView(handlerName: Self.handlerName, handler: c, delegate: c)
        c.webView = webView
        WebBridge.load(webView, page: page)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
        WebBridge.tearDown(webView, handlerName: handlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: ChatWebView
        weak var webView: WKWebView?

        private var isReady = false
        private var appliedTitle: String?
        private var appliedReferences: [String: String]?
        private var appliedMessages: [ChatDisplayMessage]?
        private var appliedStreaming: (text: String?, thinking: Bool)?
        private var chain: Task<Void, Never>?

        init(parent: ChatWebView) {
            self.parent = parent
        }

        func tearDown() {
            chain?.cancel()
            chain = nil
            isReady = false
        }

        private func resetApplied() {
            appliedTitle = nil
            appliedReferences = nil
            appliedMessages = nil
            appliedStreaming = nil
        }

        /// Pushes only what changed. Order matters: messages land before the streaming state is
        /// cleared, so a finished answer never blinks out.
        func sync() {
            guard isReady, webView != nil else { return }
            let p = parent

            if appliedTitle != p.paperTitle {
                appliedTitle = p.paperTitle
                let title = p.paperTitle
                enqueue { _ = await WebBridge.call($0, "Chat.setPaperTitle(t);", ["t": title]) }
            }
            if appliedReferences != p.references {
                appliedReferences = p.references
                let refs = p.references
                enqueue { _ = await WebBridge.call($0, "Chat.setReferences(r);", ["r": refs]) }
            }
            if appliedMessages != p.messages {
                appliedMessages = p.messages
                let list: [[String: Any]] = p.messages.map {
                    ["id": $0.id.uuidString, "role": $0.role, "kind": $0.kind, "markdown": $0.markdown]
                }
                enqueue { _ = await WebBridge.call($0, "Chat.setMessages(m);", ["m": list]) }
            }
            if appliedStreaming?.text != p.streamingText || appliedStreaming?.thinking != p.isThinking {
                appliedStreaming = (p.streamingText, p.isThinking)
                let text: Any = p.streamingText ?? NSNull()
                let thinking = p.isThinking
                enqueue { _ = await WebBridge.call($0, "Chat.setStreaming(s, t);", ["s": text, "t": thinking]) }
            }
        }

        private func enqueue(_ op: @escaping @MainActor (WKWebView) async -> Void) {
            let previous = chain
            chain = Task { @MainActor [weak self] in
                await previous?.value
                guard !Task.isCancelled, let webView = self?.webView else { return }
                await op(webView)
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == ChatWebView.handlerName,
                  WebBridge.isTrusted(message, from: webView, page: parent.page),
                  let parsed = WebBridge.type(of: message.body) else { return }
            let (kind, body) = parsed

            switch kind {
            case "ready":
                isReady = true
                resetApplied()
                sync()
                if let webView { WebBridge.reveal(webView) }
            case "jumpToBlock":
                guard isReady, let b = WebBridge.int(body["b"], in: 0...10_000_000) else { return }
                parent.onJumpToBlock(b)
            case "openReference":
                guard isReady,
                      let label = WebBridge.string(body["label"], maxLength: 8),
                      label.range(of: #"^r[1-9][0-9]{0,4}$"#, options: .regularExpression) != nil else { return }
                parent.onOpenReference(label)
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
            isReady = false
            resetApplied()
            WebBridge.load(webView, page: parent.page)
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
