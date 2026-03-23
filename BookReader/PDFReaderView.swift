@preconcurrency import PDFKit
import SwiftUI

/// Proxy object that bridges SwiftUI key events to the underlying PDFView,
/// allowing Space / Shift+Space to scroll by one viewport height.
@MainActor
final class PDFScrollProxy: ObservableObject {
    weak var pdfView: PDFView?

    /// Scroll the PDF down by one viewport height (with slight overlap).
    func scrollPageDown() {
        guard let scrollView = findScrollView() else { return }
        let pageHeight = scrollView.bounds.height * 0.9
        let maxY = scrollView.contentSize.height - scrollView.bounds.height
        let newY = min(scrollView.contentOffset.y + pageHeight, maxY)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: true)
    }

    /// Scroll the PDF up by one viewport height (with slight overlap).
    func scrollPageUp() {
        guard let scrollView = findScrollView() else { return }
        let pageHeight = scrollView.bounds.height * 0.9
        let newY = max(scrollView.contentOffset.y - pageHeight, 0)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: true)
    }

    /// PDFView embeds a UIScrollView as a subview; find it by traversal.
    private func findScrollView() -> UIScrollView? {
        guard let pdfView else { return nil }
        for subview in pdfView.subviews {
            if let scrollView = subview as? UIScrollView {
                return scrollView
            }
        }
        return nil
    }
}

struct PDFBookView: View {
    let book: Book
    let bookURL: URL
    @ObservedObject var controller: LibraryController
    @StateObject private var scrollProxy = PDFScrollProxy()

    var body: some View {
        PDFReaderRepresentable(
            documentURL: bookURL,
            initialPageIndex: book.progressState?.pdfPageIndex ?? 0,
            scrollProxy: scrollProxy
        ) { pageIndex, pageCount in
            controller.savePDFPosition(for: book, pageIndex: pageIndex, pageCount: pageCount)
        }
        .focusable()
        .onKeyPress(.space, phases: .down) { keyPress in
            // Space scrolls down, Shift+Space scrolls up (like macOS Preview).
            if keyPress.modifiers.contains(.shift) {
                scrollProxy.scrollPageUp()
            } else {
                scrollProxy.scrollPageDown()
            }
            return .handled
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) {
            controller.markOpened(book)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

struct PDFReaderRepresentable: UIViewRepresentable {
    let documentURL: URL
    let initialPageIndex: Int
    let scrollProxy: PDFScrollProxy
    let onPositionChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPositionChange: onPositionChange)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView(frame: .zero)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .secondarySystemBackground
        // Wire up the scroll proxy so SwiftUI key events can drive scrolling.
        scrollProxy.pdfView = pdfView
        context.coordinator.install(documentURL: documentURL, initialPageIndex: initialPageIndex, in: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPositionChange = onPositionChange
        scrollProxy.pdfView = pdfView
        context.coordinator.install(documentURL: documentURL, initialPageIndex: initialPageIndex, in: pdfView)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPositionChange: (Int, Int) -> Void

        private weak var pdfView: PDFView?
        private var currentDocumentURL: URL?
        private var observer: NSObjectProtocol?
        private var lastSentPageIndex: Int?

        init(onPositionChange: @escaping (Int, Int) -> Void) {
            self.onPositionChange = onPositionChange
        }

        func install(documentURL: URL, initialPageIndex: Int, in pdfView: PDFView) {
            guard currentDocumentURL != documentURL else {
                return
            }

            currentDocumentURL = documentURL
            self.pdfView = pdfView
            lastSentPageIndex = nil
            pdfView.document = PDFDocument(url: documentURL)

            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }

            observer = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pageDidChange()
                }
            }

            Task { @MainActor [weak self, weak pdfView] in
                guard let self, let pdfView, let document = pdfView.document else {
                    return
                }
                let pageCount = document.pageCount
                if let page = document.page(at: min(max(initialPageIndex, 0), max(pageCount - 1, 0))) {
                    pdfView.go(to: page)
                }
                self.pageDidChange()
            }
        }

        private func pageDidChange() {
            guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else {
                return
            }

            let pageIndex = document.index(for: page)
            guard lastSentPageIndex != pageIndex else {
                return
            }

            lastSentPageIndex = pageIndex
            onPositionChange(pageIndex, document.pageCount)
        }
    }
}
