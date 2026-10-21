import XCTest
@testable import Booklight

final class ProgressStoreTests: XCTestCase {
    private func makeLayout() throws -> TrackingLayout {
        TrackingLayout(root: try TestSupport.makeTempDirectory())
    }

    private func pdfState(_ id: String, page: Int, updatedAt: Date, opened: Date? = nil) -> BookProgressState {
        var state = BookProgressState.pdf(bookID: id, pageIndex: page, pageCount: 10, lastOpenedAt: opened ?? updatedAt)
        state.updatedAt = updatedAt
        return state
    }

    func testFlushWritesAndLoadAllReadsBack() async throws {
        let layout = try makeLayout()
        let store = ProgressStore(layout: layout, debounce: .seconds(60))
        let id = TestSupport.bookID("a")

        await store.schedule(pdfState(id, page: 3, updatedAt: Date(timeIntervalSince1970: 100)))
        // Debounced: nothing on disk yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.progressFileURL(for: id).path()))

        try await store.flush()
        let loaded = try await store.loadAll()

        XCTAssertEqual(loaded[id]?.pdfPageIndex, 3)
    }

    func testNewerWriteWinsAndOlderWriteCannotClobberDisk() async throws {
        let layout = try makeLayout()
        let id = TestSupport.bookID("b")
        let store = ProgressStore(layout: layout, debounce: .seconds(60))

        // Another device already saved a newer position.
        await store.schedule(pdfState(id, page: 8, updatedAt: Date(timeIntervalSince1970: 500)))
        try await store.flush()

        // A stale local state (older updatedAt) must not overwrite it.
        let second = ProgressStore(layout: layout, debounce: .seconds(60))
        await second.schedule(pdfState(id, page: 2, updatedAt: Date(timeIntervalSince1970: 100)))
        try await second.flush()

        let loaded = try await second.loadAll()
        XCTAssertEqual(loaded[id]?.pdfPageIndex, 8)
    }

    func testRemoveDeletesFileAndDropsPendingWrite() async throws {
        let layout = try makeLayout()
        let id = TestSupport.bookID("c")
        let store = ProgressStore(layout: layout, debounce: .seconds(60))

        await store.schedule(pdfState(id, page: 1, updatedAt: .now))
        try await store.flush()
        await store.schedule(pdfState(id, page: 5, updatedAt: .now.addingTimeInterval(10)))
        try await store.remove(bookID: id)
        try await store.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.progressFileURL(for: id).path()))
        let loaded = try await store.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testDebouncedWriteEventuallyHappens() async throws {
        let layout = try makeLayout()
        let id = TestSupport.bookID("d")
        let store = ProgressStore(layout: layout, debounce: .milliseconds(50))

        await store.schedule(pdfState(id, page: 4, updatedAt: .now))
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.progressFileURL(for: id).path()))
    }

    func testLoadAllSkipsConflictCopiesAndCorruptFiles() async throws {
        let layout = try makeLayout()
        let id = TestSupport.bookID("e")
        let store = ProgressStore(layout: layout, debounce: .seconds(60))
        await store.schedule(pdfState(id, page: 6, updatedAt: .now))
        try await store.flush()

        let dir = layout.progressDirectory
        let original = try Data(contentsOf: layout.progressFileURL(for: id))
        try original.write(to: dir.appending(path: "\(id).sync-conflict-20240101-abc.json"))
        try Data("{ not json".utf8).write(to: layout.progressFileURL(for: TestSupport.bookID("f")))

        let loaded = try await store.loadAll()

        XCTAssertEqual(Set(loaded.keys), [id])
    }

    func testEPUBOffsetRoundTripsAndOldFilesStillDecode() throws {
        let state = BookProgressState.epub(
            bookID: TestSupport.bookID("1"), chapterIndex: 2, chapterPath: "c.xhtml", chapterProgress: 0.25,
            chapterOffsetY: 123.5, overallProgress: 0.4, lastOpenedAt: .now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BookProgressState.self, from: encoder.encode(state))
        XCTAssertEqual(decoded.epubChapterOffsetY, 123.5)

        // A file written before the field existed.
        let legacy = """
            {"bookID":"x","updatedAt":"2024-01-01T00:00:00Z","progress":0.5,"epubChapterIndex":1,"epubChapterPath":"a","epubChapterProgress":0.2}
            """
        let old = try decoder.decode(BookProgressState.self, from: Data(legacy.utf8))
        XCTAssertNil(old.epubChapterOffsetY)
        XCTAssertEqual(old.epubChapterIndex, 1)
    }
}
