import SwiftUI
import PDFKit

/// The original PDF, on the same paper background. Link clicks only open https URLs.
/// Restores the last page on load and reports page changes (the receiver debounces saving).
struct PDFKitView: NSViewRepresentable {
    let url: URL
    /// Read once per document load: the 0-based page to open at (clamped to the page count).
    var initialPage: () -> Int? = { nil }
    /// Called with the 0-based index of the current page whenever it changes after the restore.
    var onPageChange: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

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
        context.coordinator.observe(view)
        context.coordinator.load(url, into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.loadedURL != url {
            c.load(url, into: view)
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.delegate = nil
        view.document = nil
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        var parent: PDFKitView
        var loadedURL: URL?
        private weak var view: PDFView?
        /// Page notifications are ignored until the saved page has been restored, so the
        /// layout-time jump to page 1 is never reported (and saved) as a page change.
        private var isRestoring = false
        private var loadGeneration = 0
        private var lastReported: Int?
        private var restoreTask: Task<Void, Never>?

        init(parent: PDFKitView) {
            self.parent = parent
        }

        func observe(_ view: PDFView) {
            stopObserving()
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChangedNotification(_:)),
                                                   name: .PDFViewPageChanged, object: view)
        }

        func stopObserving() {
            restoreTask?.cancel()
            restoreTask = nil
            if let view {
                NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: view)
            }
        }

        func load(_ url: URL, into view: PDFView) {
            loadedURL = url
            loadGeneration += 1
            lastReported = nil
            isRestoring = true
            view.document = PDFDocument(url: url)
            guard let document = view.document, document.pageCount > 0 else {
                isRestoring = false
                return
            }
            let target = parent.initialPage().map { min(max($0, 0), document.pageCount - 1) }
            restore(page: target, in: view, generation: loadGeneration, attempt: 0)
        }

        /// Goes to `page` once the view has been laid out (autoScales needs a real size), then
        /// starts reporting page changes.
        private func restore(page: Int?, in view: PDFView, generation: Int, attempt: Int) {
            restoreTask?.cancel()
            restoreTask = Task { @MainActor [weak self, weak view] in
                // Let the current layout pass finish (and retry briefly while the view has no size).
                if attempt > 0 { try? await Task.sleep(nanoseconds: 50_000_000) } else { await Task.yield() }
                guard !Task.isCancelled, let self, let view, generation == self.loadGeneration else { return }
                if view.bounds.isEmpty && attempt < 20 {
                    self.restore(page: page, in: view, generation: generation, attempt: attempt + 1)
                    return
                }
                if let page, page > 0, let document = view.document, let target = document.page(at: page) {
                    view.go(to: target)
                }
                self.lastReported = self.currentIndex(of: view)
                self.isRestoring = false
            }
        }

        private func currentIndex(of view: PDFView) -> Int? {
            guard let document = view.document, let page = view.currentPage else { return nil }
            let index = document.index(for: page)
            return index >= 0 && index < document.pageCount ? index : nil
        }

        @objc private func pageChangedNotification(_ note: Notification) {
            guard !isRestoring, let view, let index = currentIndex(of: view), index != lastReported else { return }
            lastReported = index
            parent.onPageChange(index)
        }

        nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            guard url.scheme?.lowercased() == "https" else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
