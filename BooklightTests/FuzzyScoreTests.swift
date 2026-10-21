import XCTest
@testable import Booklight

final class FuzzyScoreTests: XCTestCase {
    private func score(_ query: String, _ title: String) -> Int? {
        LibrarySearch.fuzzyScore(query: LibrarySearch.normalized(query), candidate: title)
    }

    func testNormalizationFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(LibrarySearch.normalized("  Café—Déjà Vu!! "), "cafe deja vu")
    }

    func testEmptyQueryMatchesEverythingAndNothingMatchesEmptyCandidates() {
        XCTAssertEqual(LibrarySearch.fuzzyScore(query: "", searchKey: "anything"), 0)
        XCTAssertEqual(LibrarySearch.fuzzyScore(query: "", searchKey: ""), 0)
        XCTAssertNil(LibrarySearch.fuzzyScore(query: "a", searchKey: ""))
    }

    func testSubstringBeatsSubsequenceAndEarlierBeatsLater() {
        let prefix = score("swift", "Swift Programming")
        let later = score("swift", "Learning Swift")
        let subsequence = score("swpr", "Swift Programming")

        XCTAssertNotNil(prefix)
        XCTAssertNotNil(later)
        XCTAssertNotNil(subsequence)
        XCTAssertGreaterThan(prefix!, later!)
        XCTAssertGreaterThan(later!, subsequence!)
    }

    func testCharactersMustAppearInOrder() {
        XCTAssertNotNil(score("abc", "a big cat"))
        XCTAssertNil(score("cba", "abc"))
        XCTAssertNil(score("xyz", "Swift Programming"))
    }

    func testTighterSubsequenceScoresHigher() {
        let tight = score("fcv", "Foundations of Computer Vision")
        let loose = score("fcv", "Fundamental Principles Of Machine Learning And Statistical Computing")
        XCTAssertNotNil(tight)
        if let loose { XCTAssertGreaterThan(tight!, loose) }
    }
}
