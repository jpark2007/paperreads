import SwiftUI
import AppKit
import SwiftData

/// Paper-level notes plus the list of highlights (click a quote → reader scrolls to it).
struct NotesPanel: View {
    @Bindable var paper: Paper
    @ObservedObject var session: PaperSession
    @EnvironmentObject private var app: AppCommands
    @Environment(\.modelContext) private var context
    @Query private var highlights: [Highlight]

    @State private var saveTask: Task<Void, Never>?
    /// Debounced mirror of notes + highlights to the Markdown file (see NotesFiles).
    @State private var fileTask: Task<Void, Never>?
    @State private var fileURL: URL?
    @State private var fileError: String?
    @State private var fileNotice: String?
    @StateObject private var editor = MarkdownEditorController()

    init(paper: Paper, session: PaperSession) {
        self.paper = paper
        self.session = session
        let pid = paper.id
        _highlights = Query(filter: #Predicate<Highlight> { $0.paperId == pid },
                            sort: [SortDescriptor(\Highlight.blockIndex), SortDescriptor(\Highlight.startOffset)])
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    notesSection
                    highlightsSection
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: session.focusedHighlightID) {
                scrollToFocused(proxy)
            }
            .onAppear { scrollToFocused(proxy) }
        }
        .background(Theme.bg)
        .onChange(of: paper.paperNotes) { scheduleSave() }
        // Highlight notes are edited in child rows; debounce-save them the same way.
        .onChange(of: highlights.map(\.note)) { scheduleSave() }
        // Anything that changes the Markdown file (notes, highlights, title → rename, tags…).
        .onChange(of: fileSnapshot) { scheduleFileWrite() }
        .onAppear {
            NotesFiles.register(context)
            syncFile(allowPull: true)
        }
        .onDisappear {
            saveNow()
            flushFileAsync()
        }
        // ⌘Q inside the debounce window: flush synchronously before the process exits.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveNow()
            flushFileSync()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesFiles.folderDidChange)) { _ in
            fileURL = nil
            syncFile(allowPull: true)
        }
    }

    // MARK: Notes file mirror

    private var fileSnapshot: NotesFiles.Snapshot {
        NotesFiles.snapshot(of: paper, highlights: highlights)
    }

    private func scheduleFileWrite() {
        fileTask?.cancel()
        fileTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            fileTask = nil
            syncFile(allowPull: true)
        }
    }

    /// Reconcile with the file off the main actor; apply the outcome back here.
    private func syncFile(allowPull: Bool, then: ((URL?) -> Void)? = nil) {
        let snap = fileSnapshot
        Task { @MainActor in
            let outcome = await NotesFiles.sync(snap, allowPull: allowPull)
            apply(outcome, requestedNotes: snap.notes)
            then?(outcome.url)
        }
    }

    private func flushFileAsync() {
        guard fileTask != nil else { return }
        fileTask?.cancel()
        fileTask = nil
        let snap = fileSnapshot
        Task.detached(priority: .utility) { _ = await NotesFiles.sync(snap, allowPull: false) }
    }

    private func flushFileSync() {
        fileTask?.cancel()
        fileTask = nil
        NotesFiles.flushSync(fileSnapshot)
    }

    private func apply(_ outcome: NotesFiles.Outcome, requestedNotes: String) {
        switch outcome {
        case .synced(let url), .deferred(let url):
            fileURL = url
            fileError = nil
        case .pulled(let notes, let url):
            fileURL = url
            fileError = nil
            // Only adopt the file's text if nothing was typed while we were reading it.
            if paper.paperNotes == requestedNotes, paper.paperNotes != notes {
                paper.paperNotes = notes
                fileNotice = "Updated from \(url.lastPathComponent), edited outside Paperreads."
            }
        case .conflict(let url, let backup):
            fileURL = url
            fileError = nil
            fileNotice = "The notes file was also edited elsewhere. That version was kept as “\(backup.lastPathComponent)”."
        case .failed(let message):
            fileError = message
        }
    }

    private func openFile() {
        syncFile(allowPull: true) { url in
            if let url { NSWorkspace.shared.open(url) }
        }
    }

    private func revealFile() {
        syncFile(allowPull: true) { url in
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func scrollToFocused(_ proxy: ScrollViewProxy) {
        guard let id = session.focusedHighlightID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        if context.hasChanges { try? context.save() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            try? context.save()
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text("Paper notes").capsLabel()
                Spacer(minLength: 0)
                Button("Open file", action: openFile)
                    .buttonStyle(TextButtonStyle(size: 12))
                    .help("Open this paper's Markdown notes file in your default editor")
                Button("Reveal", action: revealFile)
                    .buttonStyle(TextButtonStyle(size: 12))
                    .help(fileURL.map { NotesFiles.displayPath($0) } ?? "Show the notes file in Finder")
            }
            MarkdownFormatBar(controller: editor)
            ZStack(alignment: .topLeading) {
                MarkdownEditor(text: $paper.paperNotes, controller: editor)
                if paper.paperNotes.isEmpty {
                    Text("Your thoughts on this paper — questions, takeaways, what to read next. Markdown works: # headings, - lists, **bold**.")
                        .font(.rounded(14))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 320)
            if let fileError {
                Text(fileError)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let fileNotice {
                Text(fileNotice)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
        }
    }

    // MARK: Highlights

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Highlights").capsLabel()
                if !highlights.isEmpty {
                    Text("\(highlights.count)").capsLabel(Theme.faint)
                }
            }
            if highlights.isEmpty {
                Text("Select text in the reader and choose Highlight, or press ⇧⌘H.")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(highlights) { h in
                        HighlightRow(
                            highlight: h,
                            isFocused: session.focusedHighlightID == h.id,
                            onReveal: {
                                session.focusedHighlightID = h.id
                                app.reveal(block: h.blockIndex, highlightID: h.id)
                            },
                            onDelete: { session.deleteHighlight(h) }
                        )
                        .id(h.id)
                        if h.id != highlights.last?.id { Hairline() }
                    }
                }
            }
        }
    }
}

private struct HighlightRow: View {
    @Bindable var highlight: Highlight
    var isFocused: Bool
    var onReveal: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Rectangle()
                .fill(isFocused ? Theme.accent : Theme.highlightFill)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button(action: onReveal) {
                    Text(highlight.quote)
                        .font(.serif(15))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(3)
                        .lineLimit(8)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in reader")

                // NSTextView-backed so "-", "--" and quotes are never auto-substituted.
                ZStack(alignment: .topLeading) {
                    PlainNoteField(text: $highlight.note, fontSize: 13, color: Theme.nsMuted)
                    if highlight.note.isEmpty {
                        Text("Add a note")
                            .font(.rounded(13))
                            .foregroundStyle(Theme.faint)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: Theme.Space.m) {
                    Text("¶\(highlight.blockIndex)")
                        .font(.rounded(11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                    Text(highlight.createdAt, format: .dateTime.month(.abbreviated).day())
                        .font(.rounded(11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                    Button("Remove", action: onDelete)
                        .buttonStyle(TextButtonStyle(color: Theme.faint, hoverColor: Theme.danger, size: 12))
                        .opacity(hovering || isFocused ? 1 : 0)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Theme.Space.m)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Reader", action: onReveal)
            Button("Copy Quote") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(highlight.quote, forType: .string)
            }
            Divider()
            Button("Remove Highlight", role: .destructive, action: onDelete)
        }
    }
}
