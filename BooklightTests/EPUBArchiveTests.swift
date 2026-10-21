import XCTest
@testable import Booklight

final class EPUBArchiveTests: XCTestCase {
    private func extract(_ archive: Data) throws -> URL {
        let work = try TestSupport.makeTempDirectory()
        let zipURL = work.appending(path: "book.zip")
        try archive.write(to: zipURL)
        let destination = work.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try EPUBArchiveExtractor.extractArchive(at: zipURL, to: destination)
        return destination
    }

    func testExtractsStoredAndDeflatedEntries() throws {
        let long = String(repeating: "The quick brown fox. ", count: 200)
        var zip = ZipBuilder()
        zip.add("mimetype", "application/epub+zip")
        zip.add("OEBPS/chapter1.xhtml", long, deflate: true)
        zip.add("OEBPS/images/", "")
        zip.add("OEBPS/images/cover.bin", data: Data(0..<255), deflate: false)

        let out = try extract(zip.build())

        XCTAssertEqual(try String(contentsOf: out.appending(path: "mimetype"), encoding: .utf8), "application/epub+zip")
        XCTAssertEqual(try String(contentsOf: out.appending(path: "OEBPS/chapter1.xhtml"), encoding: .utf8), long)
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "OEBPS/images/cover.bin")), Data(0..<255))
    }

    func testParentDirectoryComponentsCannotEscapeTheDestination() throws {
        var zip = ZipBuilder()
        zip.add("../../escaped.txt", "nope")
        zip.add("ok.txt", "fine")

        let out = try extract(zip.build())

        // The `..` components are dropped, so the file lands inside the destination.
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appending(path: "escaped.txt").path()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.deletingLastPathComponent().appending(path: "escaped.txt").path()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appending(path: "ok.txt").path()))
    }

    func testTruncatedArchivesThrowInsteadOfCrashing() throws {
        var zip = ZipBuilder()
        zip.add("a.txt", String(repeating: "abc", count: 500), deflate: true)
        zip.add("b.txt", "second")
        let full = zip.build()

        // Cut the archive at many points, including inside the end record.
        for length in stride(from: 0, to: full.count, by: 7) {
            XCTAssertThrowsError(try extract(full.prefix(length)), "length \(length)")
        }
    }

    func testGarbageThrows() throws {
        XCTAssertThrowsError(try extract(Data("this is not a zip file at all".utf8)))
        XCTAssertThrowsError(try extract(Data()))
    }

    func testEntryPointingPastTheEndOfTheArchiveThrows() throws {
        var zip = ZipBuilder()
        zip.add("a.txt", "hello")
        var data = zip.build()
        // Corrupt the central directory's local-header offset (last 4 bytes before the name).
        let centralStart = data.count - 22 - (46 + "a.txt".utf8.count)
        let offsetField = centralStart + 42
        data.replaceSubrange(offsetField ..< offsetField + 4, with: [0xFF, 0xFF, 0xFF, 0x7F])

        XCTAssertThrowsError(try extract(data))
    }
}
