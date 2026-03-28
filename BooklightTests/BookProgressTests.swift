import XCTest
@testable import Booklight

final class BookProgressTests: XCTestCase {
    private let oldDate = Date(timeIntervalSince1970: 1_000)
    private let newDate = Date(timeIntervalSince1970: 2_000)

    func testPDFProgressNormalization() {
        let state = BookProgressState.pdf(
            bookID: "test-pdf",
            pageIndex: 5,
            pageCount: 10,
            pageOffsetY: 0.5,
            lastOpenedAt: oldDate
        )

        // 10 pages -> 9 intervals. (5 + 0.5) / 9 = 5.5 / 9 = 0.6111
        XCTAssertEqual(state.progress, 0.6111, accuracy: 0.001)
        XCTAssertEqual(state.pdfPageIndex, 5)
        XCTAssertEqual(state.pdfPageOffsetY, 0.5)
        XCTAssertFalse(state.isFinished)
    }

    func testEPUBProgressNormalization() {
        let state = BookProgressState.epub(
            bookID: "test-epub",
            chapterIndex: 3,
            chapterPath: "chapter3.html",
            chapterProgress: 0.4,
            overallProgress: 0.9991,  // Should trigger isFinished
            lastOpenedAt: oldDate
        )

        XCTAssertEqual(state.progress, 1.0)
        XCTAssertTrue(state.isFinished)
        XCTAssertEqual(state.epubChapterIndex, 3)
    }

    func testPDFReadingPositionClampsValuesBeforeComputingProgress() {
        let position = PDFReadingPosition(pageIndex: 99, pageCount: 10, pageOffsetY: 1.5)

        XCTAssertEqual(position.pageIndex, 9)
        XCTAssertEqual(position.pageCount, 10)
        XCTAssertEqual(position.pageOffsetY, 1)
        XCTAssertEqual(position.progress, 1)
    }

    func testMergeStatesPrefersMostRecentlyUpdatedPosition() {
        var olderState = BookProgressState.pdf(
            bookID: "merge",
            pageIndex: 2,
            pageCount: 10,
            lastOpenedAt: oldDate
        )
        olderState.updatedAt = oldDate

        var newerState = BookProgressState.pdf(
            bookID: "merge",
            pageIndex: 5,
            pageCount: 10,
            lastOpenedAt: newDate
        )
        newerState.updatedAt = newDate

        let merged = LibraryController.mergeStates(local: olderState, remote: newerState)

        XCTAssertEqual(merged.pdfPageIndex, 5)
        XCTAssertEqual(merged.lastOpenedAt, newDate)
        XCTAssertEqual(merged.updatedAt, newDate)
    }

    func testMergeStatesKeepsNewestEPUBFontSizePreference() {
        var olderState = BookProgressState.epub(
            bookID: "merge-font",
            chapterIndex: 1,
            chapterPath: "chapter1.html",
            chapterProgress: 0.2,
            overallProgress: 0.2,
            lastOpenedAt: oldDate,
            fontSizePercent: 110
        )
        olderState.updatedAt = oldDate

        var newerState = olderState
        newerState.updatedAt = newDate
        newerState.epubFontSizePercent = 130

        let merged = LibraryController.mergeStates(local: olderState, remote: newerState)

        XCTAssertEqual(merged.epubFontSizePercent, 130)
        XCTAssertEqual(merged.updatedAt, newDate)
    }

    func testMergeStatesPreservesLatestOpenDateAndFinishedStatus() {
        var finishedState = BookProgressState.epub(
            bookID: "merge-finished",
            chapterIndex: 3,
            chapterPath: "chapter3.html",
            chapterProgress: 1,
            overallProgress: 1,
            lastOpenedAt: oldDate
        )
        finishedState.updatedAt = oldDate

        var newerUnfinishedState = BookProgressState.pdf(
            bookID: "merge-finished",
            pageIndex: 1,
            pageCount: 10,
            lastOpenedAt: newDate
        )
        newerUnfinishedState.updatedAt = newDate

        let merged = LibraryController.mergeStates(local: finishedState, remote: newerUnfinishedState)

        XCTAssertTrue(merged.isFinished)
        XCTAssertEqual(merged.lastOpenedAt, newDate)
        XCTAssertEqual(merged.updatedAt, newDate)
    }
}
