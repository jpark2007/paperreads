import SwiftUI
import AppKit
import SwiftData

/// Center column: header (title, meta, status, Text|PDF) over the clean text or the PDF.
struct ReaderView: View {
    @ObservedObject var session: PaperSession
    @EnvironmentObject private var app: AppCommands

    /// The paper whose PDF layer has been shown at least once. The PDF view then stays alive
    /// (hidden) across Text/PDF toggles, so the document is not re-parsed on the main thread
    /// and the scroll position is kept.
    @State private var pdfLayerPaper: UUID?

    private var paper: Paper { session.paper }

    var body: some View {
        VStack(spacing: 0) {
            ReaderHeader(paper: paper)
            Hairline()
            ZStack {
                textLayer
                    .opacity(app.readerMode == .text ? 1 : 0)
                    .allowsHitTesting(app.readerMode == .text)
                if app.readerMode == .pdf || pdfLayerPaper == paper.id {
                    pdfLayer
                        .opacity(app.readerMode == .pdf ? 1 : 0)
                        .allowsHitTesting(app.readerMode == .pdf)
                        .accessibilityHidden(app.readerMode != .pdf)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onAppear { if app.readerMode == .pdf { pdfLayerPaper = paper.id } }
        .onChange(of: app.readerMode) { if app.readerMode == .pdf { pdfLayerPaper = paper.id } }
        .onChange(of: paper.id) { pdfLayerPaper = app.readerMode == .pdf ? paper.id : nil }
    }

    // MARK: Text

    @ViewBuilder
    private var textLayer: some View {
        switch paper.importState {
        case .queued, .fetching, .converting, .indexing:
            ImportProgressView(paper: paper)
        case .failed:
            ImportFailedView(paper: paper)
        case .ready:
            if paper.contentKind == .none {
                ReaderMessage(
                    label: "No clean text",
                    message: "This paper has no text view yet.",
                    actionTitle: paper.hasPDF ? "View PDF" : nil,
                    action: { app.readerMode = .pdf }
                )
            } else if let page = WebBridge.pageURL("reader") {
                ReaderTextContent(paper: paper, session: session, page: page)
            } else {
                ReaderMessage(label: "Reader unavailable",
                              message: "The reader page is missing from this build.",
                              isError: true)
            }
        }
    }

    // MARK: PDF

    @ViewBuilder
    private var pdfLayer: some View {
        if paper.hasPDF {
            PDFKitView(url: PaperStore.pdfURLForReading(paper.id),
                       initialPage: { [session] in session.savedPDFPage() },
                       onPageChange: { [session] in session.recordPDFPage($0) })
                .background(Theme.bg)
        } else {
            ReaderMessage(
                label: "No PDF",
                message: "No original PDF was saved for this paper.",
                actionTitle: "Show clean text",
                action: { app.readerMode = .text }
            )
            .background(Theme.bg)
        }
    }
}

/// Hosts the WebReader with this paper's live highlight list.
private struct ReaderTextContent: View {
    let paper: Paper
    @ObservedObject var session: PaperSession
    let page: URL
    @EnvironmentObject private var app: AppCommands
    @ObservedObject private var prefs = ReaderPreferences.shared
    @Query private var highlights: [Highlight]
    /// Paper whose text kept crashing the web content process (reloading has stopped).
    @State private var crashedPaper: UUID?

    init(paper: Paper, session: PaperSession, page: URL) {
        self.paper = paper
        self.session = session
        self.page = page
        let pid = paper.id
        _highlights = Query(filter: #Predicate<Highlight> { $0.paperId == pid },
                            sort: [SortDescriptor(\Highlight.createdAt)])
    }

    var body: some View {
        if crashedPaper == paper.id {
            ReaderMessage(
                label: "Text unavailable",
                message: "This paper's text could not be displayed — the text view kept crashing."
                    + (paper.hasPDF ? " View the PDF instead." : ""),
                isError: true,
                actionTitle: paper.hasPDF ? "View PDF" : "Try again",
                action: {
                    if paper.hasPDF { app.readerMode = .pdf } else { crashedPaper = nil }
                }
            )
        } else {
            reader
        }
    }

    private var reader: some View {
        WebReader(
            page: page,
            paperID: paper.id,
            contentToken: "\(paper.contentKindRaw)|\(paper.importStateRaw)",
            highlights: highlights.filter { $0.paperId == paper.id }.map(ReaderHighlightPayload.init),
            bridge: session.reader,
            prefs: prefs.typography,
            savedPosition: { [session] in session.savedTextPosition() },
            onSelection: { action, selection in app.handleReaderSelection(action, selection) },
            onHighlightClicked: { app.highlightClicked($0) },
            onPosition: { [session] in session.recordTextPosition($0) },
            onContentCrashed: { [paperID = paper.id] in crashedPaper = paperID }
        )
    }
}

// MARK: - Header

private struct ReaderHeader: View {
    let paper: Paper
    @EnvironmentObject private var app: AppCommands
    @State private var showAbstract = false

    private var meta: String {
        var parts: [String] = []
        if !paper.authors.isEmpty {
            parts.append(paper.authors.count > 6
                         ? paper.authors.prefix(6).joined(separator: ", ") + " et al."
                         : paper.authors.joined(separator: ", "))
        }
        if let y = paper.year { parts.append(String(y)) }
        if let a = paper.arxivId, !a.isEmpty { parts.append("arXiv \(a)") }
        else if let d = paper.doi, !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    private var abstract: String {
        paper.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(paper.title.isEmpty ? "Untitled paper" : paper.title)
                .font(.serif(28, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !meta.isEmpty {
                Text(meta)
                    .font(.rounded(13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(alignment: .center, spacing: Theme.Space.m) {
                StatusPicker(paper: paper)
                TextSegmented(options: [(ReaderMode.text, "Text"), (ReaderMode.pdf, "PDF")],
                              selection: $app.readerMode)
                    .help("Clean text or original PDF (⇧⌘P)")
                if !abstract.isEmpty {
                    Button(showAbstract ? "Hide abstract" : "Abstract") {
                        withAnimation(.easeInOut(duration: 0.18)) { showAbstract.toggle() }
                    }
                    .buttonStyle(.text)
                }
                Spacer(minLength: 0)
                TypographyButton()
                    .disabled(app.readerMode != .text)
                if let source = sourceURL {
                    Button("Source") { WebBridge.openExternally(source) }
                        .buttonStyle(.text)
                        .help(source.absoluteString)
                }
                Button(app.sidePanelVisible ? "Hide panel" : "Ask · Notes") { app.toggleSidePanel() }
                    .buttonStyle(.text)
                    .help("Toggle the side panel (⌘J)")
            }
            .padding(.top, Theme.Space.xxs)

            if showAbstract && !abstract.isEmpty {
                ScrollView {
                    Text(abstract)
                        .font(.serif(15))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 200)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: paper.id) { showAbstract = false }
    }

    private var sourceURL: URL? {
        if let s = paper.sourceURL, let u = URL(string: s), u.scheme?.lowercased() == "https" { return u }
        if let a = paper.arxivId, !a.isEmpty,
           let enc = a.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: "https://arxiv.org/abs/\(enc)")
        }
        return nil
    }
}

/// Quiet "Aa" text button: text size, width, font and spacing for the clean-text reader.
private struct TypographyButton: View {
    @ObservedObject private var prefs = ReaderPreferences.shared
    @State private var open = false

    var body: some View {
        Button("Aa") { open.toggle() }
            .buttonStyle(.text)
            .help("Text size, width, font and spacing (⌘+ / ⌘− / ⌘0)")
            .accessibilityLabel("Reader typography")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                TypographyPanel(prefs: prefs)
            }
    }
}

private struct TypographyPanel: View {
    @ObservedObject var prefs: ReaderPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            row("Text size") {
                HStack(spacing: Theme.Space.s) {
                    Button("A−") { prefs.decrease() }
                        .buttonStyle(TextButtonStyle(size: 13, weight: .semibold))
                        .disabled(!prefs.canDecrease)
                        .help("Smaller text (⌘−)")
                        .accessibilityLabel("Smaller text")
                    Text("\(prefs.fontSize)")
                        .font(.rounded(14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: 26)
                        .accessibilityLabel("Text size \(prefs.fontSize) points")
                    Button("A+") { prefs.increase() }
                        .buttonStyle(TextButtonStyle(size: 16, weight: .semibold))
                        .disabled(!prefs.canIncrease)
                        .help("Larger text (⌘+)")
                        .accessibilityLabel("Larger text")
                }
                .frame(height: 30)
            }
            row("Width") {
                TextSegmented(options: ReaderMeasure.allCases.map { ($0, $0.label) },
                              selection: $prefs.measure)
            }
            row("Font") {
                TextSegmented(options: ReaderFontChoice.allCases.map { ($0, $0.label) },
                              selection: $prefs.font)
            }
            row("Spacing") {
                TextSegmented(options: ReaderLineSpacing.allCases.map { ($0, $0.label) },
                              selection: $prefs.lineHeight)
            }
            Hairline()
            HStack {
                Spacer(minLength: 0)
                Button("Reset") { prefs.reset() }
                    .buttonStyle(.text)
                    .disabled(prefs.isDefault)
            }
        }
        .padding(Theme.Space.m)
        .frame(minWidth: 280, alignment: .leading)
        .background(Theme.bg)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).capsLabel()
            content()
        }
    }
}

/// Outlined pill showing the reading status; opens a small text-only list.
struct StatusPicker: View {
    let paper: Paper
    @Environment(\.modelContext) private var context
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Text(paper.status.label)
        }
        .buttonStyle(.pill)
        .help("Reading status")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ReadingStatus.allCases, id: \.self) { status in
                    Button {
                        paper.status = status
                        try? context.save()
                        open = false
                    } label: {
                        HStack {
                            Text(status.label)
                                .font(.rounded(14, weight: paper.status == status ? .semibold : .regular))
                                .foregroundStyle(paper.status == status ? Theme.ink : Theme.muted)
                            Spacer(minLength: Theme.Space.l)
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Theme.Space.xs)
            .frame(minWidth: 150)
            .background(Theme.bg)
        }
    }
}

// MARK: - States

private struct ImportProgressView: View {
    let paper: Paper

    private var headline: String {
        switch paper.importState {
        case .queued: "Waiting to import"
        case .fetching: "Fetching"
        case .converting: "Converting the PDF to text"
        case .indexing: "Indexing"
        default: "Importing"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text(headline).capsLabel(Theme.accentText)
            }
            Text(paper.importStatusDetail?.isEmpty == false ? paper.importStatusDetail! : "Working…")
                .font(.serif(19))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can keep reading other papers — this one opens as soon as it's ready.")
                .font(.rounded(13))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportFailedView: View {
    let paper: Paper
    @EnvironmentObject private var app: AppCommands
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Import failed").capsLabel(Theme.danger)
            Text(paper.importStatusDetail?.isEmpty == false ? paper.importStatusDetail! : "Something went wrong while importing this paper.")
                .font(.serif(19))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.m) {
                Button("Retry") { Importer.shared.retry(paper, context: context) }
                    .buttonStyle(.pill)
                if paper.hasPDF {
                    Button("View PDF") { app.readerMode = .pdf }
                        .buttonStyle(.text)
                }
            }
            .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReaderMessage: View {
    let label: String
    let message: String
    var isError = false
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(label).capsLabel(isError ? Theme.danger : Theme.muted)
            Text(message)
                .font(.serif(19))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.pill)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
