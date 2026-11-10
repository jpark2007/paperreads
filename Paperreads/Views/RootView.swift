import SwiftUI
import AppKit
import SwiftData
import UniformTypeIdentifiers

/// Window root: Library sidebar + (Reader | Side panel). Hosts window-wide drop, sheets and
/// the PDF file importer.
struct RootView: View {
    @EnvironmentObject private var app: AppCommands
    @Environment(\.modelContext) private var context
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .background(Theme.bg)
        .toolbarBackground(Theme.bg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .overlay { if dropTargeted { DropOverlay() } }
        .overlay(alignment: .bottom) { noticeBanner }
        .dropDestination(for: URL.self) { urls, _ in
            app.importDropped(urls, context: context)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.12)) { dropTargeted = targeted }
        }
        .sheet(isPresented: $app.showImportSheet) {
            ImportSheet()
                .environmentObject(app)
        }
        .fileImporter(isPresented: $app.showPDFImporter,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): app.importPDFs(urls, context: context)
            case .failure(let error): app.flash(error.localizedDescription)
            }
        }
        .task { app.launch(context: context) }
        .onChange(of: app.selectedPaperID, initial: true) {
            app.syncSession(context: context)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = app.session {
            PaperDetail(session: session)
        } else {
            LibraryHome()
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = app.notice {
            Text(notice)
                .font(.rounded(13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.Space.l)
                .frame(height: 36)
                .background(Theme.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous)
                        .strokeBorder(Theme.ink, lineWidth: Theme.outlineWidth)
                )
                .padding(.bottom, Theme.Space.l)
                .transition(.opacity)
                .onTapGesture { app.notice = nil }
        }
    }
}

/// Reader + side panel for the open paper.
private struct PaperDetail: View {
    @ObservedObject var session: PaperSession
    @EnvironmentObject private var app: AppCommands

    var body: some View {
        HSplitView {
            ReaderView(session: session)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if app.sidePanelVisible {
                SidePanel(session: session)
                    .frame(minWidth: 320, idealWidth: Theme.sidePanelWidth, maxWidth: 600, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.showLibrary()
                } label: {
                    Image(systemName: "books.vertical")
                }
                .help("Library (⇧⌘L)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.toggleSidePanel()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(app.sidePanelVisible ? "Hide side panel (⌘J)" : "Show side panel (⌘J)")
            }
        }
        .onChange(of: session.paper.importStateRaw) {
            session.importStateChanged()
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.bg.opacity(0.92)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(Theme.Space.l)
            VStack(spacing: Theme.Space.xs) {
                Text("Drop to import")
                    .font(.serif(26, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("PDF files, or arXiv / DOI links")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.muted)
            }
        }
        .allowsHitTesting(false)
    }
}
