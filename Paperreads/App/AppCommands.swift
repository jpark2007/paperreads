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

    // Reading position: recorded on every (throttled) report, written to the Paper at most
    // once per `positionSaveDelay`, and flushed on switch / mode toggle / close / quit.
    private static let positionSaveDelay: UInt64 = 1_000_000_000
    private var pendingTextPosition: ReaderPosition?
    private var pendingPDFPage: Int?
    private var positionSaveTask: Task<Void, Never>?
    private var isClosed = false

    init(paper: Paper, context: ModelContext) {
        self.paper = paper
        self.paperID = paper.id
        self.context = context
        self.chat = ChatEngine(paper: paper, context: context)
        self.engineBuiltBeforeReady = paper.importState != .ready
    }

    func close() {
        chat.cancel()
        flushPosition()
        isClosed = true
        reader.detach()
        try? context.save()
    }

    // MARK: Reading position

    /// Where the text reader should open: the latest unsaved report, else the stored one.
    func savedTextPosition() -> ReaderPosition? {
        if let pending = pendingTextPosition { return pending }
        guard isPaperAlive, let b = paper.readingBlock, b >= 0 else { return nil }
        let frac = paper.readingBlockFraction ?? 0
        return ReaderPosition(block: b, fraction: frac.isFinite ? min(max(frac, 0), 1) : 0)
    }

    /// Where the PDF view should open (0-based page; the view clamps it to the page count).
    func savedPDFPage() -> Int? {
        if let pending = pendingPDFPage { return pending }
        guard isPaperAlive, let page = paper.pdfPageIndex, page >= 0 else { return nil }
        return page
    }

    func recordTextPosition(_ position: ReaderPosition) {
        pendingTextPosition = position
        schedulePositionSave()
    }

    func recordPDFPage(_ index: Int) {
        guard index >= 0 else { return }
        pendingPDFPage = index
        schedulePositionSave()
    }

    /// Remembers the mode the user chose for this paper and saves the position right away.
    func recordViewMode(_ mode: ReaderMode) {
        guard !isClosed, isPaperAlive else { return }
        if paper.lastViewModeRaw != mode.rawValue { paper.lastViewModeRaw = mode.rawValue }
        if mode == .pdf {
            // Leaving the text view: take its exact live position first (it stays loaded, hidden).
            Task { [weak self] in
                guard let self else { return }
                if let live = await self.reader.currentPosition(), !self.isClosed {
                    self.pendingTextPosition = live
                }
                self.flushPosition(force: true)
            }
        } else {
            flushPosition(force: true)
        }
    }

    /// Writes any pending position to the Paper and saves (no-op when nothing changed).
    func flushPosition(force: Bool = false) {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        guard isPaperAlive else {
            pendingTextPosition = nil
            pendingPDFPage = nil
            return
        }
        var changed = false
        if let p = pendingTextPosition {
            if paper.readingBlock != p.block { paper.readingBlock = p.block; changed = true }
            if paper.readingBlockFraction != p.fraction { paper.readingBlockFraction = p.fraction; changed = true }
            pendingTextPosition = nil
        }
        if let page = pendingPDFPage {
            if paper.pdfPageIndex != page { paper.pdfPageIndex = page; changed = true }
            pendingPDFPage = nil
        }
        if changed || (force && context.hasChanges) { try? context.save() }
    }

    private func schedulePositionSave() {
        if isClosed {
            // A late report from the page after the switch: write it straight through.
            flushPosition()
            return
        }
        // Trailing throttle: at most one save per interval, even while scrolling continuously.
        guard positionSaveTask == nil else { return }
        positionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.positionSaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.positionSaveTask = nil
            self.flushPosition()
        }
    }

    private var isPaperAlive: Bool { !paper.isDeleted && paper.modelContext != nil }

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
        syncNotesFile()
    }

    func deleteHighlight(_ h: Highlight) {
        if focusedHighlightID == h.id { focusedHighlightID = nil }
        context.delete(h)
        try? context.save()
        syncNotesFile()
    }

    /// Keeps the paper's Markdown notes file current when highlights change outside the Notes panel.
    private func syncNotesFile() {
        let snap = NotesFiles.snapshot(of: paper, in: context)
        Task { _ = await NotesFiles.sync(snap, allowPull: false) }
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
    @Published var readerMode: ReaderMode = .text {
        didSet {
            guard readerMode != oldValue, !isRestoringMode else { return }
            session?.recordViewMode(readerMode)
        }
    }
    @Published var selectedPaperID: UUID?
    @Published private(set) var session: PaperSession?
    /// Transient, non-modal message (e.g. a dropped file that isn't a PDF).
    @Published var notice: String?

    private var didLaunch = false
    /// Set while `syncSession` picks the mode for a newly opened paper (not a user choice).
    private var isRestoringMode = false
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
        let fallback: ReaderMode = (!hasText && paper.hasPDF && !paper.importState.isBusy) ? .pdf : .text
        // Reopen in the mode last chosen for this paper, when that view is available.
        let mode: ReaderMode
        switch paper.lastViewModeRaw.flatMap(ReaderMode.init(rawValue:)) {
        case .pdf? where paper.hasPDF: mode = .pdf
        case .text? where hasText: mode = .text
        default: mode = fallback
        }
        isRestoringMode = true
        readerMode = mode
        isRestoringMode = false
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

    /// Saves the open paper's reading position now (window close, app termination).
    func flushReadingPosition() {
        session?.flushPosition(force: true)
    }

    /// Saves the open paper's exact live text position (app deactivation): asks the reader
    /// for it first, since the last throttled report may be up to 250 ms old.
    func flushReadingPositionFetchingLatest() {
        guard let session else { return }
        guard readerMode == .text else { session.flushPosition(force: true); return }
        Task { [weak session] in
            guard let session else { return }
            if let live = await session.reader.currentPosition() {
                session.recordTextPosition(live)
            }
            session.flushPosition(force: true)
        }
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

    /// Text-size commands only make sense while the clean-text reader is showing.
    var canResizeReaderText: Bool { session != nil && readerMode == .text }

    var canUseSelectionCommands: Bool {
        guard let session else { return false }
        return readerMode == .text && session.paper.importState == .ready
    }
}

// MARK: - Menu commands

struct PaperreadsCommands: Commands {
    @ObservedObject var app: AppCommands
    @ObservedObject var prefs: ReaderPreferences

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
            // ⌘= is also handled (PaperreadsAppDelegate), since ⌘+ needs Shift on most layouts.
            Button("Larger Text") { prefs.increase() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!app.canResizeReaderText || !prefs.canIncrease)
            Button("Smaller Text") { prefs.decrease() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!app.canResizeReaderText || !prefs.canDecrease)
            Button("Actual Size") { prefs.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!app.canResizeReaderText || prefs.isDefaultSize)
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
