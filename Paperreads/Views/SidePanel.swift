import SwiftUI
import AppKit
import SwiftData

/// Right-hand panel: `Ask | Notes`.
struct SidePanel: View {
    @ObservedObject var session: PaperSession
    @EnvironmentObject private var app: AppCommands

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ZStack {
                // Ask stays alive behind Notes so the transcript web view keeps its state.
                AskPanel(session: session, engine: session.chat)
                    .opacity(app.sidePanelTab == .ask ? 1 : 0)
                    .allowsHitTesting(app.sidePanelTab == .ask)
                    .accessibilityHidden(app.sidePanelTab != .ask)
                if app.sidePanelTab == .notes {
                    NotesPanel(paper: session.paper, session: session)
                        .id(session.paperID)
                        .transition(.opacity)
                }
            }
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
            tab("Ask", .ask)
            tab("Notes", .notes)
            Spacer(minLength: 0)
            if app.sidePanelTab == .ask {
                Button("New chat") { app.newChat() }
                    .buttonStyle(.text)
                    .disabled(session.chat.messages.isEmpty && session.chat.streamingText == nil)
                    .help("Start a fresh conversation about this paper")
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 52)
    }

    private func tab(_ title: String, _ value: SidePanelTab) -> some View {
        let selected = app.sidePanelTab == value
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { app.sidePanelTab = value }
        } label: {
            Text(title)
                .font(.rounded(15, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.faint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ask

private struct AskPanel: View {
    @ObservedObject var session: PaperSession
    @ObservedObject var engine: ChatEngine
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var app: AppCommands
    @Query private var references: [ReferenceEntry]

    @State private var draft = ""
    @State private var inputHeight: CGFloat = 36

    init(session: PaperSession, engine: ChatEngine) {
        self.session = session
        self.engine = engine
        let pid = session.paperID
        _references = Query(filter: #Predicate<ReferenceEntry> { $0.paperId == pid },
                            sort: [SortDescriptor(\ReferenceEntry.ordinal)])
    }

    private var isBusy: Bool { engine.streamingText != nil || engine.isThinking }
    private var paperReady: Bool { session.paper.importState == .ready }
    private var hasKey: Bool { settings.effectiveAPIKey != nil }

    private var referenceTitles: [String: String] {
        var map: [String: String] = [:]
        for r in references {
            let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            map[r.label] = r.year.map { "\(title) (\($0))" } ?? title
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let error = engine.errorText {
                errorRow(error)
            }
            if !hasKey {
                keyNotice
            }
            Hairline()
            composer
        }
        .onChange(of: session.paperID) {
            draft = ""
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let page = WebBridge.pageURL("chat") {
            ChatWebView(
                page: page,
                paperTitle: session.paper.title,
                messages: engine.messages,
                streamingText: engine.streamingText,
                isThinking: engine.isThinking,
                references: referenceTitles,
                onJumpToBlock: { app.reveal(block: $0) },
                onOpenReference: { openReference($0) }
            )
        } else {
            VStack {
                Spacer()
                Text("The chat view is missing from this build.")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.danger)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(error)
                .font(.rounded(13))
                .foregroundStyle(Theme.danger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { engine.errorText = nil }
                .buttonStyle(.text)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .top) { Hairline() }
    }

    private var keyNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("Add your Anthropic API key to ask questions.")
                .font(.rounded(13))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            SettingsLink {
                Text("Open Settings")
            }
            .buttonStyle(.text)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .top) { Hairline() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let quote = session.pendingQuote {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                    Text(quote.quote)
                        .font(.serif(13).italic())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Clear") { session.pendingQuote = nil }
                        .buttonStyle(.text)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.rounded(14))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                ChatInputField(text: $draft, height: $inputHeight,
                               focusToken: session.composerFocusToken,
                               onSubmit: send)
                    .frame(height: inputHeight)
            }

            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(Theme.modelDisplayName(settings.model))
                    .font(.rounded(12, weight: .medium))
                    .foregroundStyle(Theme.faint)
                if isBusy {
                    Text(engine.isThinking && (engine.streamingText ?? "").isEmpty ? "Thinking…" : "Writing…")
                        .font(.rounded(12, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                }
                Spacer(minLength: 0)
                if isBusy {
                    Button("Stop") { engine.cancel() }
                        .buttonStyle(PillButtonStyle(height: 28))
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Text("⏎ send · ⇧⏎ newline")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.faint)
                    Button("Send", action: send)
                        .buttonStyle(PillButtonStyle(height: 28))
                        .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.l)
    }

    private var placeholder: String {
        if !paperReady { return "Available once the paper has finished importing" }
        return session.pendingQuote == nil ? "Ask about this paper…" : "Ask about this passage…"
    }

    private var canSend: Bool {
        paperReady && hasKey && !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else {
            if !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { NSSound.beep() }
            return
        }
        session.send(draft)
        draft = ""
    }

    private func openReference(_ label: String) {
        guard let ref = references.first(where: { $0.label == label }),
              let url = Self.url(for: ref) else { return }
        WebBridge.openExternally(url)
    }

    /// Best public https page for a cited work.
    static func url(for ref: ReferenceEntry) -> URL? {
        func https(_ s: String) -> URL? {
            guard let c = URLComponents(string: s), c.scheme?.lowercased() == "https",
                  c.host?.isEmpty == false else { return nil }
            return c.url
        }
        if let id = ref.arxivId?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
           let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let u = https("https://arxiv.org/abs/\(enc)") { return u }
        if let doi = ref.doi?.trimmingCharacters(in: .whitespaces), !doi.isEmpty,
           let enc = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let u = https("https://doi.org/\(enc)") { return u }
        if let pdf = ref.openAccessPDF, let u = https(pdf) { return u }
        if let s2 = ref.s2PaperId?.trimmingCharacters(in: .whitespaces), !s2.isEmpty,
           let enc = s2.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let u = https("https://www.semanticscholar.org/paper/\(enc)") { return u }
        let q = ref.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return q.isEmpty ? nil : https("https://www.semanticscholar.org/search?q=\(q)")
    }
}
