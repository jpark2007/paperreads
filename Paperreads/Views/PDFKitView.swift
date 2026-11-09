import SwiftUI
import PDFKit

/// The original PDF, on the same paper background. Link clicks only open https URLs.
struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = Theme.nsBg
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = false
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.delegate = context.coordinator
        load(url, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.loadedURL != url {
            load(url, into: view, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        view.delegate = nil
        view.document = nil
    }

    private func load(_ url: URL, into view: PDFView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        view.document = PDFDocument(url: url)
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        var loadedURL: URL?

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            guard url.scheme?.lowercased() == "https" else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
