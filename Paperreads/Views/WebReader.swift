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

/// A reading position in the clean-text view: the top-most visible block (`data-b`) and how far
/// through that block the top of the viewport is (0–1), so it survives font-size changes.
struct ReaderPosition: Equatable {
    var block: Int
    var fraction: Double

    var jsObject: [String: Any] { ["b": block, "frac": fraction] }
}

// MARK: - Reader typography

enum ReaderMeasure: String, CaseIterable {
    case narrow, normal, wide
    var label: String {
        switch self { case .narrow: "Narrow"; case .normal: "Normal"; case .wide: "Wide" }
    }
}

enum ReaderFontChoice: String, CaseIterable {
    case serif, sans
    var label: String {
        switch self { case .serif: "Serif"; case .sans: "Sans" }
    }
}

enum ReaderLineSpacing: String, CaseIterable {
    case compact, normal, relaxed
    var label: String {
        switch self { case .compact: "Compact"; case .normal: "Normal"; case .relaxed: "Relaxed" }
    }
}

/// The value sent to `Reader.setPrefs` / `Reader.load(prefs)`.
struct ReaderTypography: Equatable {
    var fontSize: Int
    var measure: ReaderMeasure
    var font: ReaderFontChoice
    var lineHeight: ReaderLineSpacing

    var jsObject: [String: Any] {
        ["fontSize": fontSize, "measure": measure.rawValue, "font": font.rawValue, "lineHeight": lineHeight.rawValue]
    }
}

/// Global reader typography preferences, persisted in UserDefaults (not secret, so not in
/// config.json). Shared by the header popover, the View menu commands and the web reader.
@MainActor
final class ReaderPreferences: ObservableObject {
    static let shared = ReaderPreferences()

    static let fontSizeRange = 14...26
    static let defaultFontSize = 19

    private enum Key {
        static let fontSize = "reader.fontSize"
        static let measure = "reader.measure"
        static let font = "reader.font"
        static let lineHeight = "reader.lineHeight"
    }

    private let defaults: UserDefaults

    @Published var fontSize: Int {
        didSet {
            let clamped = Self.clamp(fontSize)
            if clamped != fontSize { fontSize = clamped }
            defaults.set(fontSize, forKey: Key.fontSize)
        }
    }
    @Published var measure: ReaderMeasure {
        didSet { defaults.set(measure.rawValue, forKey: Key.measure) }
    }
    @Published var font: ReaderFontChoice {
        didSet { defaults.set(font.rawValue, forKey: Key.font) }
    }
    @Published var lineHeight: ReaderLineSpacing {
        didSet { defaults.set(lineHeight.rawValue, forKey: Key.lineHeight) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSize = defaults.object(forKey: Key.fontSize) as? Int
        fontSize = Self.clamp(storedSize ?? Self.defaultFontSize)
        measure = defaults.string(forKey: Key.measure).flatMap(ReaderMeasure.init) ?? .normal
        font = defaults.string(forKey: Key.font).flatMap(ReaderFontChoice.init) ?? .serif
        lineHeight = defaults.string(forKey: Key.lineHeight).flatMap(ReaderLineSpacing.init) ?? .normal
    }

    var typography: ReaderTypography {
        ReaderTypography(fontSize: fontSize, measure: measure, font: font, lineHeight: lineHeight)
    }

    var canIncrease: Bool { fontSize < Self.fontSizeRange.upperBound }
    var canDecrease: Bool { fontSize > Self.fontSizeRange.lowerBound }
    var isDefaultSize: Bool { fontSize == Self.defaultFontSize }
    var isDefault: Bool {
        isDefaultSize && measure == .normal && font == .serif && lineHeight == .normal
    }

    func increase() { if canIncrease { fontSize += 1 } }
    func decrease() { if canDecrease { fontSize -= 1 } }
    func actualSize() { if !isDefaultSize { fontSize = Self.defaultFontSize } }

    func reset() {
        actualSize()
        if measure != .normal { measure = .normal }
        if font != .serif { font = .serif }
        if lineHeight != .normal { lineHeight = .normal }
    }

    private static func clamp(_ size: Int) -> Int {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}

// MARK: - Bridge

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

    /// The reader's live position (`Reader.getPosition()`), or nil when no text is loaded.
    func currentPosition() async -> ReaderPosition? {
        guard let c = coordinator, c.isContentLoaded else { return nil }
        return await c.fetchPosition()
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
    /// Typography applied on every load and whenever it changes.
    var prefs: ReaderTypography
    /// Read when content (re)loads: where to put the reader (latest unsaved position first).
    var savedPosition: () -> ReaderPosition? = { nil }
    var onSelection: (SelectionAction, ReaderSelection) -> Void
    var onHighlightClicked: (UUID) -> Void
    /// Validated, throttled position reports from the page (the receiver debounces saving).
    var onPosition: (ReaderPosition) -> Void = { _ in }
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
        private var appliedPrefs: ReaderTypography?
        /// Highest data-b in the loaded content (-1 when there are no blocks).
        private var maxBlock = -1
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
            if parent.prefs != appliedPrefs {
                let prefs = parent.prefs
                appliedPrefs = prefs
                enqueue { webView in
                    await WebBridge.call(webView, "return Reader.setPrefs(p);", ["p": prefs.jsObject])
                }
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
            maxBlock = -1
            let paperID = parent.paperID
            let highlights = parent.highlights
            applied = Dictionary(highlights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let prefs = parent.prefs
            appliedPrefs = prefs

            enqueue { [weak self] webView in
                let html = await Task.detached(priority: .userInitiated) {
                    PaperStore.readHTML(paperID)
                }.value
                guard let self, gen == self.generation else { return }
                let content = html ?? "<p>This paper's text file is missing. Retry the import from the library.</p>"
                var payload: [String: Any] = [
                    "html": content,
                    "highlights": highlights.map(\.jsObject),
                    "prefs": prefs.jsObject,
                ]
                // Read the position now (not at enqueue time) so the latest unsaved one wins.
                if html != nil, let position = self.parent.savedPosition() {
                    payload["position"] = position.jsObject
                }
                let result = await WebBridge.call(webView, "return Reader.load(payload);", ["payload": payload])
                guard gen == self.generation else { return }
                if case .success(let value) = result, let dict = value as? [String: Any],
                   let maxB = WebBridge.int(dict["maxBlock"], in: -1...10_000_000) {
                    self.maxBlock = maxB
                }
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

        func fetchPosition() async -> ReaderPosition? {
            guard let webView, isContentLoaded else { return nil }
            let gen = generation
            let result = await WebBridge.call(webView, "return Reader.getPosition();")
            guard gen == generation, isContentLoaded,
                  case .success(let value) = result, let value, !(value is NSNull) else { return nil }
            return WebBridge.readerPosition(value, maxBlock: maxBlock)
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
                appliedPrefs = nil
                maxBlock = -1
                sync()
            case "selection":
                guard isContentLoaded,
                      let raw = WebBridge.string(body["action"], maxLength: 16),
                      let action = SelectionAction(rawValue: raw),
                      let selection = WebBridge.selection(body["selection"]) else { return }
                parent.onSelection(action, selection)
            case "position":
                guard isContentLoaded,
                      let position = WebBridge.readerPosition(body, maxBlock: maxBlock) else { return }
                parent.onPosition(position)
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
            appliedPrefs = nil
            maxBlock = -1
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
