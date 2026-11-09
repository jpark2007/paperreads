import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

enum ReaderMode: String {
    case text, pdf
}

enum SidePanelTab: String {
    case ask, notes
}

enum SelectionAction: String {
    case highlight, explain, ask
}

/// Per-open-paper state: the chat engine, the reader bridge, and transient UI hand-offs.
/// Created when a paper is selected; `close()` cancels in-flight work on switch.
@MainActor
final class PaperSession: ObservableObject {
    let paper: Paper
    let paperID: UUID
    let context: ModelContext
    let reader = ReaderBridge()

    @Published private(set) var chat: ChatEngine
    /// A passage the user chose "Ask" on; prefixed to the next question.
    @Published var pendingQuote: ReaderSelection?
    /// Bumped to move keyboard focus into the chat composer.
    @Published var composerFocusToken = 0
    /// Highlight to bring into view in the Notes panel (set when clicked in the reader).
    @Published var focusedHighlightID: UUID?

    private var engineBuiltBeforeReady: Bool

    init(paper: Paper, context: ModelContext) {
        self.paper = paper
        self.paperID = paper.id
        self.context = context
        self.chat = ChatEngine(paper: paper, context: context)
        self.engineBuiltBeforeReady = paper.importState != .ready
    }

    func close() {
        chat.cancel()
        reader.detach()
        try? context.save()
    }

    var isChatBusy: Bool { chat.streamingText != nil || chat.isThinking }

    /// The engine snapshots title/authors at init. If the paper was still importing when the
    /// session opened, rebuild it once content is ready (only when nothing is in flight).
    func importStateChanged() {
        guard paper.importState == .ready, engineBuiltBeforeReady else { return }
        engineBuiltBeforeReady = false
        guard !isChatBusy, chat.messages.isEmpty else { return }
        chat.cancel()
        chat = ChatEngine(paper: paper, context: context)
    }

    func addHighlight(_ selection: ReaderSelection) {
        let quote = selection.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return }
        let pid = paperID
        let b = selection.blockIndex
        let off = selection.startOffset
        let existing = (try? context.fetch(FetchDescriptor<Highlight>(
            predicate: #Predicate { $0.paperId == pid && $0.blockIndex == b && $0.startOffset == off }
        ))) ?? []
        if let dup = existing.first(where: { $0.quote == selection.quote }) {
            focusedHighlightID = dup.id
            return
        }
        let h = Highlight(paperId: pid, quote: selection.quote, blockIndex: b, startOffset: off)
        context.insert(h)
        try? context.save()
        focusedHighlightID = h.id
    }

    func deleteHighlight(_ h: Highlight) {
        if focusedHighlightID == h.id { focusedHighlightID = nil }
        context.delete(h)
        try? context.save()
    }

    /// Sends the composer text, folding in a pending "Ask about this passage" quote.
    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isChatBusy else { return }
        if let q = pendingQuote {
            let quoted = q.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "\n> ")
            chat.ask("Regarding this passage (at [b\(q.blockIndex)]):\n> \(quoted)\n\n\(question)")
            pendingQuote = nil
        } else {
            chat.ask(question)
        }
    }
}

/// App-wide UI state and command routing (menus, shortcuts, sheets, the open paper).
@MainActor
final class AppCommands: ObservableObject {
    static let shared = AppCommands()

    @Published var showImportSheet = false
    @Published var showPDFImporter = false
    @Published var sidePanelVisible = true
    @Published var sidePanelTab: SidePanelTab = .ask
    @Published var readerMode: ReaderMode = .text
    @Published var selectedPaperID: UUID?
    @Published private(set) var session: PaperSession?
    /// Transient, non-modal message (e.g. a dropped file that isn't a PDF).
    @Published var notice: String?

    private var didLaunch = false
    private var noticeTask: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    func launch(context: ModelContext) {
        guard !didLaunch else { return }
        didLaunch = true
        Importer.recoverInterrupted(context: context)
        Importer.shared.resumeReferences(context: context)
    }

    /// Opens a session for `selectedPaperID`, cancelling the previous paper's chat.
    func syncSession(context: ModelContext) {
        if session?.paperID == selectedPaperID { return }
        session?.close()
        session = nil
        guard let id = selectedPaperID else { return }
        let descriptor = FetchDescriptor<Paper>(predicate: #Predicate { $0.id == id })
        guard let paper = try? context.fetch(descriptor).first else {
            selectedPaperID = nil
            return
        }
        paper.lastOpenedAt = Date()
        try? context.save()
        let hasText = paper.importState == .ready && paper.contentKind != .none
        readerMode = (!hasText && paper.hasPDF && !paper.importState.isBusy) ? .pdf : .text
        session = PaperSession(paper: paper, context: context)
    }

    /// Must be called before deleting a paper so nothing touches the deleted model.
    func delete(_ paper: Paper, context: ModelContext) {
        if session?.paperID == paper.id {
            session?.close()
            session = nil
            selectedPaperID = nil
        }
        Importer.shared.cancel(paper.id)   // stop any queued/running pipeline first
        PaperStore.delete(paper, in: context)
    }

    // MARK: Imports

    func importLink(_ input: String, context: ModelContext) throws {
        let paper = try Importer.shared.importLink(input, context: context)
        selectedPaperID = paper.id
    }

    func importPDFs(_ urls: [URL], context: ModelContext) {
        var last: Paper?
        var skipped = 0
        for url in urls {
            guard url.isFileURL, isPDF(url) else { skipped += 1; continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            last = Importer.shared.importPDF(at: url, context: context)
        }
        if let last { selectedPaperID = last.id }
        if skipped > 0 {
            flash(skipped == 1 ? "That file isn't a PDF." : "\(skipped) files weren't PDFs.")
        }
    }

    /// Drag-and-drop: PDFs are imported as files; https links are imported as links.
    func importDropped(_ urls: [URL], context: ModelContext) -> Bool {
        let files = urls.filter(\.isFileURL)
        let links = urls.filter { $0.scheme?.lowercased() == "https" }
        if !files.isEmpty { importPDFs(files, context: context) }
        for link in links {
            do { try importLink(link.absoluteString, context: context) }
            catch { flash(error.localizedDescription) }
        }
        return !files.isEmpty || !links.isEmpty
    }

    private func isPDF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return false
    }

    func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Panel + mode

    func toggleSidePanel() {
        withAnimation(.easeInOut(duration: 0.18)) { sidePanelVisible.toggle() }
    }

    func toggleReaderMode() {
        guard session != nil else { return }
        readerMode = readerMode == .text ? .pdf : .text
    }

    func show(_ tab: SidePanelTab) {
        sidePanelTab = tab
        if !sidePanelVisible { toggleSidePanel() }
    }

    func newChat() {
        session?.chat.newConversation()
        session?.pendingQuote = nil
        show(.ask)
    }

    /// Scrolls the clean-text reader to a block (switching from PDF if needed).
    func reveal(block: Int, highlightID: UUID? = nil) {
        guard let session else { return }
        readerMode = .text
        session.reader.reveal(block: block, highlightID: highlightID)
    }

    // MARK: Reader selection

    func handleReaderSelection(_ action: SelectionAction, _ selection: ReaderSelection) {
        guard let session else { return }
        switch action {
        case .highlight:
            session.addHighlight(selection)
        case .explain:
            show(.ask)
            if session.isChatBusy { NSSound.beep(); return }
            session.chat.explain(selection)
        case .ask:
            show(.ask)
            session.pendingQuote = selection
            session.composerFocusToken += 1
        }
    }

    func highlightClicked(_ id: UUID) {
        guard let session else { return }
        show(.notes)
        session.focusedHighlightID = id
    }

    /// ⌘E / ⌘⇧H: read the current reader selection and act on it.
    func performSelectionCommand(_ action: SelectionAction) {
        guard let session, readerMode == .text else { NSSound.beep(); return }
        Task { [weak self] in
            guard let selection = await session.reader.currentSelection() else { NSSound.beep(); return }
            guard let self, self.session === session else { return }
            self.handleReaderSelection(action, selection)
        }
    }

    var canUseSelectionCommands: Bool {
        guard let session else { return false }
        return readerMode == .text && session.paper.importState == .ready
    }
}

// MARK: - Menu commands

struct PaperreadsCommands: Commands {
    @ObservedObject var app: AppCommands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Link…") { app.showImportSheet = true }
                .keyboardShortcut("l", modifiers: .command)
            Button("Import PDF…") { app.showPDFImporter = true }
                .keyboardShortcut("o", modifiers: .command)
        }
        // ⌘⇧P is ours (Text | PDF); drop Page Setup / Print.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .sidebar) {
            Button(app.sidePanelVisible ? "Hide Side Panel" : "Show Side Panel") { app.toggleSidePanel() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(app.session == nil)
            Button(app.readerMode == .text ? "Show Original PDF" : "Show Clean Text") { app.toggleReaderMode() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(app.session == nil)
            Divider()
        }

        CommandMenu("Paper") {
            Button("Explain Selection") { app.performSelectionCommand(.explain) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!app.canUseSelectionCommands)
            Button("Highlight Selection") { app.performSelectionCommand(.highlight) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!app.canUseSelectionCommands)
            Button("Ask About Selection") { app.performSelectionCommand(.ask) }
                .disabled(!app.canUseSelectionCommands)
            Divider()
            Button("Ask") { app.show(.ask) }
                .disabled(app.session == nil)
            Button("Notes") { app.show(.notes) }
                .disabled(app.session == nil)
            Button("New Chat") { app.newChat() }
                .disabled(app.session == nil)
        }
    }
}
