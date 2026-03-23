@preconcurrency import PDFKit
import SwiftUI

struct PDFBookView: View {
    let book: Book
    let bookURL: URL
    @ObservedObject var controller: LibraryController

    var body: some View {
        PDFReaderRepresentable(
            documentURL: bookURL,
            initialPageIndex: book.progressState?.pdfPageIndex ?? 0
        ) { pageIndex, pageCount in
            controller.savePDFPosition(for: book, pageIndex: pageIndex, pageCount: pageCount)
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
        context.coordinator.install(documentURL: documentURL, initialPageIndex: initialPageIndex, in: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPositionChange = onPositionChange
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
