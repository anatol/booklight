import XCTest
@testable import Booklight

final class LibraryScannerTests: XCTestCase {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeScanner() throws -> LibraryScanner {
        LibraryScanner(cacheDirectory: try TestSupport.makeTempDirectory())
    }

    func testFindsBooksRecursivelyAndIgnoresOtherFiles() async throws {
        let dir = try TestSupport.makeTempDirectory()
        try write("pdf one", to: dir.appending(path: "a.pdf"))
        try write("epub one", to: dir.appending(path: "sub/b.epub"))
        try write("text", to: dir.appending(path: "notes.txt"))
        try write("hidden", to: dir.appending(path: ".hidden.pdf"))

        let files = try await makeScanner().scan(directories: [dir])

        XCTAssertEqual(Set(files.map(\.fileURL.lastPathComponent)), ["a.pdf", "b.epub"])
        XCTAssertEqual(files.first { $0.fileURL.lastPathComponent == "b.epub" }?.format, .epub)
    }

    func testIdenticalContentIsDeduplicatedAndFirstDirectoryWins() async throws {
        let first = try TestSupport.makeTempDirectory()
        let second = try TestSupport.makeTempDirectory()
        try write("same bytes", to: first.appending(path: "Book.pdf"))
        try write("same bytes", to: second.appending(path: "Copy of Book.pdf"))
        try write("different", to: second.appending(path: "Other.pdf"))

        let files = try await makeScanner().scan(directories: [first, second])

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.first { $0.fileURL.lastPathComponent == "Book.pdf" }?.fileURL.deletingLastPathComponent().path(), first.path())
        XCTAssertNil(files.first { $0.fileURL.lastPathComponent == "Copy of Book.pdf" })
    }

    func testIDIsTheSHA256OfTheContent() async throws {
        let dir = try TestSupport.makeTempDirectory()
        try write("hello", to: dir.appending(path: "h.pdf"))

        let files = try await makeScanner().scan(directories: [dir])

        // sha256("hello")
        XCTAssertEqual(files.first?.id, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testChangedFileIsRehashedDespiteCache() async throws {
        let dir = try TestSupport.makeTempDirectory()
        let url = dir.appending(path: "b.pdf")
        let scanner = try makeScanner()
        try write("version one", to: url)
        let first = try await scanner.scan(directories: [dir])

        try write("version two is longer", to: url)
        let second = try await scanner.scan(directories: [dir])

        XCTAssertNotEqual(first.first?.id, second.first?.id)
    }

    func testComposeBooksPrefersTrackingCopiesAndAttachesProgress() {
        func file(_ id: String, _ path: String) -> ScannedFile {
            ScannedFile(id: id, fileURL: URL(fileURLWithPath: path), format: .pdf, fileSize: 1, modifiedAt: .distantPast)
        }
        let state = BookProgressState.initial(bookID: "x")

        let books = LibraryScanner.composeBooks(
            trackingFiles: [file("x", "/tracking/books/zeta.pdf")],
            libraryFiles: [file("x", "/library/zeta original.pdf"), file("y", "/library/Alpha.pdf")],
            progressStates: ["x": state])

        XCTAssertEqual(books.map(\.title), ["Alpha", "zeta"])
        XCTAssertEqual(books.last?.fileURL.path(), "/tracking/books/zeta.pdf")
        XCTAssertNotNil(books.last?.progressState)
        XCTAssertNil(books.first?.progressState)
    }

    func testTrackedCopyNamesAvoidCollisionsBetweenDifferentBooks() throws {
        let sourceDir = try TestSupport.makeTempDirectory()
        let booksDir = try TestSupport.makeTempDirectory()
        let sourceA = sourceDir.appending(path: "A/Book.pdf")
        let sourceB = sourceDir.appending(path: "B/Book.pdf")
        try write("content A", to: sourceA)
        try write("content B", to: sourceB)
        func book(_ id: String, _ url: URL) -> Book {
            Book(id: id, title: "Book", fileURL: url, format: .pdf, fileSize: 9, addedAt: .now, modifiedAt: .now, progressState: nil)
        }

        let layout = TrackingLayout(root: booksDir)
        let shelf = ActiveShelf(layout: layout)
        let trackedA = try shelf.ensureTracked(book(TestSupport.bookID("a"), sourceA))
        let trackedB = try shelf.ensureTracked(book(TestSupport.bookID("b"), sourceB))
        // Tracking the same book twice reuses the copy.
        let trackedAAgain = try shelf.ensureTracked(book(TestSupport.bookID("a"), sourceA))

        XCTAssertEqual(trackedA.lastPathComponent, "Book.pdf")
        XCTAssertNotEqual(trackedA, trackedB)
        XCTAssertTrue(trackedB.lastPathComponent.hasPrefix("Book-bbbbbbbb"))
        XCTAssertEqual(trackedA, trackedAAgain)
        XCTAssertEqual(try String(contentsOf: trackedA, encoding: .utf8), "content A")
        XCTAssertEqual(try String(contentsOf: trackedB, encoding: .utf8), "content B")
    }

    func testRemovingTrackedCopyNeverDeletesAnUnrelatedFile() throws {
        let root = try TestSupport.makeTempDirectory()
        let layout = TrackingLayout(root: root)
        let library = try TestSupport.makeTempDirectory().appending(path: "Book.pdf")
        try write("original", to: library)
        let book = Book(
            id: TestSupport.bookID("a"), title: "Book", fileURL: library, format: .pdf, fileSize: 8, addedAt: .now,
            modifiedAt: .now, progressState: nil)
        // A same-named file belonging to a different book sits in books/.
        let other = layout.booksDirectory.appending(path: "Book.pdf")
        try write("someone else's", to: other)

        try ActiveShelf(layout: layout).removeTrackedCopy(of: book)

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path()))
    }
}
