import PDFKit
import XCTest
@testable import Booklight

@MainActor
final class PDFSearchTests: XCTestCase {
    func testAsynchronousSearchCollectsMatchesAcrossPages() async throws {
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        pdfView.document = PDFDocument(data: Self.makePDF(pages: ["Alpha beta", "gamma ALPHA", "delta"]))
        let proxy = PDFScrollProxy()
        proxy.pdfView = pdfView

        proxy.search(for: "alpha")
        XCTAssertTrue(proxy.isSearchInProgress)

        try await waitUntil { !proxy.isSearchInProgress }
        XCTAssertEqual(proxy.searchSelections.count, 2)
        XCTAssertEqual(proxy.searchCurrentIndex, 0)
        XCTAssertEqual(pdfView.highlightedSelections?.count, 2)

        proxy.nextSearchMatch()
        XCTAssertEqual(proxy.searchCurrentIndex, 1)
        proxy.nextSearchMatch()
        XCTAssertEqual(proxy.searchCurrentIndex, 0, "navigation wraps around")
    }

    func testClearSearchCancelsAndResets() async throws {
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        pdfView.document = PDFDocument(data: Self.makePDF(pages: ["one two", "two three"]))
        let proxy = PDFScrollProxy()
        proxy.pdfView = pdfView

        proxy.search(for: "two")
        proxy.clearSearch()

        XCTAssertFalse(proxy.isSearchInProgress)
        XCTAssertTrue(proxy.searchSelections.isEmpty)
        XCTAssertNil(pdfView.highlightedSelections)
        XCTAssertEqual(proxy.lastSearchText, "two", "the last query is kept to pre-fill the next search")
    }

    /// Renders one PDF page per string.
    static func makePDF(pages: [String]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for text in pages {
                context.beginPage()
                (text as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
