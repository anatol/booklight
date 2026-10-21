import XCTest
@testable import Booklight

final class BookSortingTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 10_000)

    func testSortOtherBooksByModificationTimeNewestFirst() {
        let older = makeBook(
            id: "older",
            title: "Older",
            modifiedAt: baseDate.addingTimeInterval(-1_000)
        )
        let newer = makeBook(
            id: "newer",
            title: "Newer",
            modifiedAt: baseDate
        )

        let sorted = LibrarySearch.sortOtherBooks([older, newer], using: .modifiedAt)

        XCTAssertEqual(sorted.map(\.id), ["newer", "older"])
    }

    func testSortOtherBooksByLastOpenedPlacesNeverOpenedLast() {
        let neverOpened = makeBook(
            id: "never-opened",
            title: "Never Opened",
            modifiedAt: baseDate
        )
        let recentlyOpened = makeBook(
            id: "recently-opened",
            title: "Recently Opened",
            modifiedAt: baseDate.addingTimeInterval(-500),
            lastOpenedAt: baseDate
        )

        let sorted = LibrarySearch.sortOtherBooks([neverOpened, recentlyOpened], using: .lastOpenedAt)

        XCTAssertEqual(sorted.map(\.id), ["recently-opened", "never-opened"])
    }

    func testSortOtherBooksKeepsSearchRelevanceAheadOfSelectedSort() {
        let betterMatch = makeBook(
            id: "best-match",
            title: "Alpha",
            modifiedAt: baseDate.addingTimeInterval(-10_000)
        )
        let newerButWorseMatch = makeBook(
            id: "worse-match",
            title: "The Alpha Handbook",
            modifiedAt: baseDate
        )

        let sorted = LibrarySearch.sortOtherBooks(
            [newerButWorseMatch, betterMatch],
            using: .modifiedAt,
            query: "alp"
        )

        XCTAssertEqual(sorted.map(\.id), ["best-match", "worse-match"])
    }

    private func makeBook(
        id: String,
        title: String,
        modifiedAt: Date,
        lastOpenedAt: Date? = nil
    ) -> Book {
        Book(
            id: id,
            title: title,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).pdf"),
            format: .pdf,
            fileSize: 1_024,
            addedAt: modifiedAt,
            modifiedAt: modifiedAt,
            progressState: lastOpenedAt.map {
                BookProgressState.pdf(
                    bookID: id,
                    pageIndex: 0,
                    pageCount: 10,
                    lastOpenedAt: $0
                )
            }
        )
    }
}
