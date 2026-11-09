import SwiftUI
import SwiftData
import AppKit

/// Library: search, status + tag filters, the paper list, and the Add-paper footer.
struct LibrarySidebar: View {
    @EnvironmentObject private var app: AppCommands
    @Environment(\.modelContext) private var context
    @Query(sort: \Paper.addedAt, order: .reverse) private var papers: [Paper]
    @Query private var highlights: [Highlight]

    @State private var search = ""
    @State private var statusFilter: ReadingStatus?
    @State private var tagFilter: String?
    @State private var tagEditing: Paper?
    @State private var pendingDelete: Paper?
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    // MARK: Filtering

    private var allTags: [String] {
        Array(Set(papers.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [Paper] {
        let tokens = search.split(whereSeparator: \.isWhitespace).map(String.init)
        var highlightText: [UUID: String] = [:]
        if !tokens.isEmpty {
            for h in highlights {
                highlightText[h.paperId, default: ""] += " " + h.quote + " " + h.note
            }
        }
        return papers.filter { p in
            if let s = statusFilter, p.status != s { return false }
            if let t = tagFilter, !p.tags.contains(t) { return false }
            guard !tokens.isEmpty else { return true }
            let haystack = [p.title, p.authors.joined(separator: " "), p.tags.joined(separator: " "),
                            p.paperNotes, p.arxivId ?? "", p.doi ?? "", highlightText[p.id] ?? ""]
                .joined(separator: " ")
            return tokens.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    var body: some View {
        let visible = filtered
        VStack(spacing: 0) {
            header
            searchField
            filterRow
            if !allTags.isEmpty { tagRow }
            Hairline()
            if papers.isEmpty {
                emptyLibrary
            } else if visible.isEmpty {
                noMatches
            } else {
                list(visible)
            }
            Hairline()
            footer
        }
        .background(Theme.bg)
        .sheet(item: $tagEditing) { paper in
            TagEditorSheet(paper: paper, suggestions: allTags)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let target = pendingDelete
                pendingDelete = nil
                if let target { app.delete(target, context: context) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its highlights, notes, chat history and files are removed too.")
        }
        .onChange(of: tagFilter) {
            if let t = tagFilter, !allTags.contains(t) { tagFilter = nil }
        }
    }

    // MARK: Header + filters

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Library").capsLabel()
            Spacer()
            if !papers.isEmpty {
                Text("\(papers.count)").capsLabel(Theme.faint)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }

    private var searchField: some View {
        VStack(spacing: 6) {
            HStack(spacing: Theme.Space.xs) {
                TextField("Search titles, authors, notes…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.rounded(14))
                    .foregroundStyle(Theme.ink)
                    .focused($searchFocused)
                    .onSubmit { listFocused = true }
                    .onExitCommand { search = ""; searchFocused = false }
                if !search.isEmpty {
                    Button("Clear") { search = "" }
                        .buttonStyle(TextButtonStyle(color: Theme.faint, size: 12))
                }
            }
            Rectangle()
                .fill(searchFocused ? Theme.accent : Theme.hairline)
                .frame(height: searchFocused ? 1.5 : 1)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, Theme.Space.m)
    }

    private var filterRow: some View {
        HStack(spacing: Theme.Space.xs) {
            filterButton("All", nil)
            ForEach(ReadingStatus.allCases, id: \.self) { s in
                Text("·").font(.rounded(13)).foregroundStyle(Theme.faint)
                filterButton(s.label, s)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
    }

    private func filterButton(_ title: String, _ value: ReadingStatus?) -> some View {
        let selected = statusFilter == value
        return Button { statusFilter = value } label: {
            Text(title)
                .font(.rounded(13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.faint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(allTags, id: \.self) { tag in
                    let selected = tagFilter == tag
                    Button { tagFilter = selected ? nil : tag } label: {
                        Text("#\(tag)")
                            .font(.rounded(12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.ink : Theme.faint)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
        .padding(.bottom, Theme.Space.s)
    }

    // MARK: List

    private func list(_ visible: [Paper]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { paper in
                        PaperRow(paper: paper, isSelected: app.selectedPaperID == paper.id)
                            .id(paper.id)
                            .onTapGesture {
                                app.selectedPaperID = paper.id
                                listFocused = true
                            }
                            .contextMenu { contextMenu(for: paper) }
                        Hairline().padding(.leading, Theme.Space.l)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, in: visible, proxy: proxy) }
            .onKeyPress(.downArrow) { move(1, in: visible, proxy: proxy) }
            .onDeleteCommand {
                if let id = app.selectedPaperID, let p = visible.first(where: { $0.id == id }) {
                    pendingDelete = p
                }
            }
        }
    }

    private func move(_ delta: Int, in visible: [Paper], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !visible.isEmpty else { return .ignored }
        let current = visible.firstIndex { $0.id == app.selectedPaperID }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), visible.count - 1)
        } else {
            next = delta > 0 ? 0 : visible.count - 1
        }
        let id = visible[next].id
        app.selectedPaperID = id
        proxy.scrollTo(id)
        return .handled
    }

    @ViewBuilder
    private func contextMenu(for paper: Paper) -> some View {
        Menu("Status") {
            ForEach(ReadingStatus.allCases, id: \.self) { s in
                Button {
                    paper.status = s
                    try? context.save()
                } label: {
                    if paper.status == s { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                }
            }
        }
        Button("Edit Tags…") { tagEditing = paper }
        if paper.importState == .failed {
            Button("Retry Import") { Importer.shared.retry(paper, context: context) }
        }
        if Importer.shared.canRetryReferences(paper) {
            Button("Retry References") { Importer.shared.retryReferences(paper, context: context) }
        }
        Divider()
        if paper.hasPDF {
            Button("Show PDF in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([PaperStore.pdfURL(paper.id)])
            }
        }
        if let s = paper.sourceURL, let u = URL(string: s), u.scheme?.lowercased() == "https" {
            Button("Open Source Page") { WebBridge.openExternally(u) }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = paper }
    }

    // MARK: Empty states

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("No papers yet")
                .font(.serif(19, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Add an arXiv link or DOI with ⌘L, open a PDF with ⌘O, or drop a PDF anywhere in this window.")
                .font(.rounded(13))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noMatches: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Nothing matches")
                .font(.rounded(14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Button("Clear filters") {
                search = ""
                statusFilter = nil
                tagFilter = nil
            }
            .buttonStyle(.text)
            Spacer()
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            Button("Add paper") { app.showImportSheet = true }
                .buttonStyle(.pill)
                .help("Import an arXiv link or DOI (⌘L)")
            Button("Open PDF…") { app.showPDFImporter = true }
                .buttonStyle(.text)
                .help("Import a PDF file (⌘O)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 64)
    }
}

// MARK: - Row

private struct PaperRow: View {
    let paper: Paper
    let isSelected: Bool
    @State private var hovering = false

    private var meta: String {
        [paper.authorLine, paper.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(paper.title.isEmpty ? "Untitled paper" : paper.title)
                .font(.serif(15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !meta.isEmpty {
                Text(meta)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 14)
        .background(isSelected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var statusLine: some View {
        if paper.importState.isBusy {
            Text(paper.importStatusDetail?.isEmpty == false ? paper.importStatusDetail! : "Importing…")
                .font(.rounded(12, weight: .medium))
                .foregroundStyle(Theme.accentText)
                .lineLimit(1)
        } else if paper.importState == .failed {
            Text("Import failed")
                .font(.rounded(12, weight: .medium))
                .foregroundStyle(Theme.danger)
        } else {
            HStack(spacing: Theme.Space.xs) {
                Text(paper.status.label)
                    .foregroundStyle(paper.status == .reading ? Theme.ink : Theme.faint)
                ForEach(paper.tags.prefix(3), id: \.self) { tag in
                    Text("#\(tag)").foregroundStyle(Theme.faint)
                }
            }
            .font(.rounded(11, weight: .medium))
            .lineLimit(1)
        }
    }
}

// MARK: - Tag editor

private struct TagEditorSheet: View {
    let paper: Paper
    let suggestions: [String]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty && $0.count <= 40 && seen.insert($0.lowercased()).inserted }
    }

    private var unusedSuggestions: [String] {
        let current = Set(parsed.map { $0.lowercased() })
        return suggestions.filter { !current.contains($0.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Tags").font(.serif(22, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(paper.title).font(.rounded(13)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            VStack(spacing: 6) {
                TextField("comma, separated, tags", text: $text)
                    .textFieldStyle(.plain)
                    .font(.rounded(15))
                    .focused($focused)
                    .onSubmit(save)
                Rectangle().fill(focused ? Theme.accent : Theme.hairline).frame(height: focused ? 1.5 : 1)
            }
            if !unusedSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(unusedSuggestions.prefix(12), id: \.self) { tag in
                            Button("#\(tag)") {
                                let trimmed = text.trimmingCharacters(in: .whitespaces)
                                text = trimmed.isEmpty || trimmed.hasSuffix(",") ? trimmed + " " + tag : trimmed + ", " + tag
                                text = text.trimmingCharacters(in: .whitespaces)
                            }
                            .buttonStyle(TextButtonStyle(color: Theme.faint, size: 12))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.text)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.pill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
        .background(Theme.bg)
        .onAppear {
            text = paper.tags.joined(separator: ", ")
            focused = true
        }
    }

    private func save() {
        paper.tags = parsed
        try? context.save()
        dismiss()
    }
}
