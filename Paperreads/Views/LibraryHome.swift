import SwiftUI
import SwiftData

/// Opening page (no paper open): the library itself — continue reading, then every paper —
/// with Add paper / Open PDF above. Falls back to the welcome text when the library is empty.
struct LibraryHome: View {
    @EnvironmentObject private var app: AppCommands
    @Query(sort: \Paper.addedAt, order: .reverse) private var papers: [Paper]
    @State private var statusFilter: ReadingStatus?

    /// Recently opened papers that aren't finished, most recent first.
    private var continueReading: [Paper] {
        papers
            .filter { $0.lastOpenedAt != nil && $0.status != .done && $0.importState == .ready }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(3)
            .map { $0 }
    }

    private var listed: [Paper] {
        guard let s = statusFilter else { return papers }
        return papers.filter { $0.status == s }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if !papers.isEmpty {
                    if !continueReading.isEmpty {
                        section("Continue reading", continueReading, showOpened: true)
                    }
                    allPapers
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xxl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Paperreads").capsLabel()
            if papers.isEmpty {
                Text("Add your first paper.")
                    .font(.serif(28, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Read papers as clean text with real equations, highlight what matters, and ask Claude about anything — grounded in the paper and the works it cites.")
                    .font(.serif(17))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(5)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your library")
                    .font(.serif(28, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(papers.count == 1 ? "1 paper" : "\(papers.count) papers")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.faint)
            }
            HStack(spacing: Theme.Space.m) {
                Button("Add paper") { app.showImportSheet = true }
                    .buttonStyle(.pill)
                Button("Open PDF…") { app.showPDFImporter = true }
                    .buttonStyle(.text)
            }
            .padding(.top, Theme.Space.xs)
        }
    }

    // MARK: Sections

    private func section(_ title: String, _ items: [Paper], showOpened: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).capsLabel()
            rows(items, showOpened: showOpened)
        }
    }

    private var allPapers: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text("All papers").capsLabel()
                Spacer(minLength: 0)
                filterButton("All", nil)
                ForEach(ReadingStatus.allCases, id: \.self) { filterButton($0.label, $0) }
            }
            if listed.isEmpty {
                Text("No papers marked “\(statusFilter?.label ?? "")”.")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, Theme.Space.s)
            } else {
                rows(listed, showOpened: false)
            }
        }
    }

    private func filterButton(_ title: String, _ value: ReadingStatus?) -> some View {
        let selected = statusFilter == value
        return Button { statusFilter = value } label: {
            Text(title)
                .font(.rounded(12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.faint)
        }
        .buttonStyle(.plain)
    }

    private func rows(_ items: [Paper], showOpened: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            ForEach(items) { paper in
                HomeRow(paper: paper, showOpened: showOpened) { app.selectedPaperID = paper.id }
                Hairline()
            }
        }
    }
}

private struct HomeRow: View {
    let paper: Paper
    let showOpened: Bool
    let open: () -> Void
    @State private var hovering = false

    private var meta: String {
        [paper.authorLine, paper.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(paper.title.isEmpty ? "Untitled paper" : paper.title)
                        .font(.serif(17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.rounded(12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.m)
                trailing
            }
            .padding(.vertical, 14)
            .padding(.horizontal, Theme.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var trailing: some View {
        Group {
            if paper.importState.isBusy {
                Text("Importing…").foregroundStyle(Theme.accentText)
            } else if paper.importState == .failed {
                Text("Import failed").foregroundStyle(Theme.danger)
            } else if showOpened, let opened = paper.lastOpenedAt {
                Text(opened, format: .relative(presentation: .named)).foregroundStyle(Theme.faint)
            } else {
                Text(paper.status.label)
                    .foregroundStyle(paper.status == .reading ? Theme.ink : Theme.faint)
            }
        }
        .font(.rounded(12, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}
