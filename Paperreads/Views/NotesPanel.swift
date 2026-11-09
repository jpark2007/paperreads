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
        .onDisappear {
            saveTask?.cancel()
            try? context.save()
        }
    }

    private func scrollToFocused(_ proxy: ScrollViewProxy) {
        guard let id = session.focusedHighlightID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
        }
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
            Text("Paper notes").capsLabel()
            ZStack(alignment: .topLeading) {
                if paper.paperNotes.isEmpty {
                    Text("Your thoughts on this paper — questions, takeaways, what to read next.")
                        .font(.serif(15))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $paper.paperNotes)
                    .font(.serif(15))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.leading, -5)   // align NSTextView's inset with the labels
            }
            .frame(minHeight: 160, maxHeight: 280)
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

                TextField("Add a note", text: $highlight.note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.rounded(13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1...6)

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
