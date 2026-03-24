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
            initialPageOffsetY: book.progressState?.pdfPageOffsetY ?? 0,
            scrollProxy: scrollProxy
        ) { pageIndex, pageCount, pageOffsetY in
            controller.savePDFPosition(for: book, pageIndex: pageIndex, pageCount: pageCount, pageOffsetY: pageOffsetY)
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
        .toolbar(.hidden, for: .navigationBar)
        .task(id: book.id) {
            controller.markOpened(book)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

struct PDFReaderRepresentable: UIViewRepresentable {
    let documentURL: URL
    let initialPageIndex: Int
    /// Normalized Y offset within the initial page (0 = top, 1 = bottom).
    let initialPageOffsetY: Double
    let scrollProxy: PDFScrollProxy
    /// Callback: (pageIndex, pageCount, normalizedPageOffsetY)
    let onPositionChange: (Int, Int, Double) -> Void

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
        context.coordinator.install(
            documentURL: documentURL,
            initialPageIndex: initialPageIndex,
            initialPageOffsetY: initialPageOffsetY,
            in: pdfView
        )
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPositionChange = onPositionChange
        scrollProxy.pdfView = pdfView
        context.coordinator.install(
            documentURL: documentURL,
            initialPageIndex: initialPageIndex,
            initialPageOffsetY: initialPageOffsetY,
            in: pdfView
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPositionChange: (Int, Int, Double) -> Void

        private weak var pdfView: PDFView?
        private var currentDocumentURL: URL?
        private var pageChangedObserver: NSObjectProtocol?
        /// Observes the underlying UIScrollView to detect intra-page scrolling.
        private var scrollObserver: NSObjectProtocol?
        private var lastSentPageIndex: Int?
        private var lastSentOffsetY: Double?

        /// Debounce timer for scroll-based position saves to avoid excessive writes.
        private var scrollDebounceTimer: Timer?
        private static let scrollDebounceInterval: TimeInterval = 0.5

        init(onPositionChange: @escaping (Int, Int, Double) -> Void) {
            self.onPositionChange = onPositionChange
        }

        func install(documentURL: URL, initialPageIndex: Int, initialPageOffsetY: Double, in pdfView: PDFView) {
            guard currentDocumentURL != documentURL else {
                return
            }

            currentDocumentURL = documentURL
            self.pdfView = pdfView
            lastSentPageIndex = nil
            lastSentOffsetY = nil
            scrollDebounceTimer?.invalidate()
            pdfView.document = PDFDocument(url: documentURL)

            // Remove old observers.
            if let pageChangedObserver {
                NotificationCenter.default.removeObserver(pageChangedObserver)
            }
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }

            // Observe page changes (fires when the "current page" changes).
            pageChangedObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePositionUpdate()
                }
            }

            // Observe visible-pages changes — fires on any scroll, including intra-page.
            // This is what enables sub-page offset tracking.
            scrollObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewVisiblePagesChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePositionUpdate()
                }
            }

            // Restore saved position: go to the exact page + offset.
            Task { @MainActor [weak self, weak pdfView] in
                guard let self, let pdfView, let document = pdfView.document else {
                    return
                }
                let pageCount = document.pageCount
                let safeIndex = min(max(initialPageIndex, 0), max(pageCount - 1, 0))
                if let page = document.page(at: safeIndex) {
                    if initialPageOffsetY > 0 {
                        // Restore sub-page position using PDFDestination.
                        // PDF coordinate system has origin at bottom-left, so Y increases upward.
                        let pageHeight = page.bounds(for: .mediaBox).height
                        // offsetY=0 means top of page, which in PDF coords is the max Y value.
                        let pdfY = pageHeight * (1.0 - initialPageOffsetY)
                        let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pdfY))
                        pdfView.go(to: destination)
                    } else {
                        pdfView.go(to: page)
                    }
                }
                self.emitPosition()
            }
        }

        /// Debounce scroll events: reset the timer on each scroll, fire after the interval.
        private func schedulePositionUpdate() {
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.scrollDebounceInterval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emitPosition()
                }
            }
        }

        /// Compute and emit the current position (page index + sub-page offset).
        private func emitPosition() {
            guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else {
                return
            }

            let pageIndex = document.index(for: page)
            let offsetY = currentNormalizedOffsetY(pdfView: pdfView, page: page)

            // Deduplicate: skip if page and offset haven't meaningfully changed.
            let offsetThreshold = 0.005
            if lastSentPageIndex == pageIndex,
               let lastOffset = lastSentOffsetY,
               abs(lastOffset - offsetY) < offsetThreshold {
                return
            }

            lastSentPageIndex = pageIndex
            lastSentOffsetY = offsetY
            onPositionChange(pageIndex, document.pageCount, offsetY)
        }

        /// Returns the normalized Y offset (0 = top, 1 = bottom) for the current viewport
        /// position within the given page.
        private func currentNormalizedOffsetY(pdfView: PDFView, page: PDFPage) -> Double {
            guard let destination = pdfView.currentDestination else {
                return 0
            }
            let pageHeight = page.bounds(for: .mediaBox).height
            guard pageHeight > 0 else { return 0 }
            // PDF coords: Y increases upward from bottom-left.
            // destination.point.y is the Y in PDF coords at the top of the viewport.
            // offsetY=0 means top of page (point.y ≈ pageHeight), offsetY=1 means bottom (point.y ≈ 0).
            let normalizedOffset = 1.0 - (destination.point.y / pageHeight)
            return min(max(normalizedOffset, 0), 1)
        }
    }
}
