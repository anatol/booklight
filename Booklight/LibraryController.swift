import Combine
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var trackingDirectoryURL: URL?
    @Published private(set) var localLibraries: [URL] = []

    @Published private(set) var books: [Book] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastScanAt: Date?
    @Published var isPickingTrackingDirectory = false
    @Published var searchText = ""
    @Published private(set) var debouncedSearchText = ""
    @Published var errorMessage: String?

    /// Set by ReaderContainerView when a book is open; used by ContentView to update the window title.
    @Published var openBookTitle: String?

    private let trackingBookmarkKey = "Booklight.trackingDirectoryBookmark"
    private let localLibrariesKey = "Booklight.localLibrariesBookmarks"
    private let defaults = UserDefaults.standard

    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var writeTasks: [String: Task<Void, Never>] = [:]

    private var scopedTrackingDirectoryURL: URL?
    private var scopedLocalLibraries: [URL] = []

    private nonisolated(unsafe) var searchDebounceSubscription: AnyCancellable?

    #if targetEnvironment(macCatalyst)
        private let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
        private let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
        private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    init() {
        restoreLibraries()
        startPolling()

        searchDebounceSubscription =
            $searchText
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .assign(to: \.debouncedSearchText, on: self)
    }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
        writeTasks.values.forEach { $0.cancel() }
        searchDebounceSubscription?.cancel()
        scopedTrackingDirectoryURL?.stopAccessingSecurityScopedResource()
        scopedLocalLibraries.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    var activeBooks: [Book] {
        visibleBooks(from: books)
            .filter(\.isActive)
            .sorted {
                ($0.lastOpenedAt ?? .distantPast, fuzzyScore(for: $0), $0.title.localizedLowercase) > (
                    $1.lastOpenedAt ?? .distantPast, fuzzyScore(for: $1), $1.title.localizedLowercase
                )
            }
    }

    var otherBooks: [Book] {
        visibleBooks(from: books)
            .filter { !$0.isActive }
            .sorted {
                let leftScore = fuzzyScore(for: $0)
                let rightScore = fuzzyScore(for: $1)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    private func visibleBooks(from source: [Book]) -> [Book] {
        let query = normalizedQuery
        guard !query.isEmpty else {
            return source
        }

        return source.compactMap { book in
            guard Self.fuzzyScore(query: query, candidate: book.title) != nil else {
                return nil
            }
            return book
        }
    }

    private func fuzzyScore(for book: Book) -> Int {
        guard !normalizedQuery.isEmpty else {
            return 0
        }
        return Self.fuzzyScore(query: normalizedQuery, candidate: book.title) ?? 0
    }

    private var normalizedQuery: String {
        Self.normalized(debouncedSearchText)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fuzzyScore(query: String, candidate: String) -> Int? {
        let normalizedCandidate = normalized(candidate)
        guard !query.isEmpty, !normalizedCandidate.isEmpty else {
            return query.isEmpty ? 0 : nil
        }
        if let range = normalizedCandidate.range(of: query) {
            let distance = normalizedCandidate.distance(from: normalizedCandidate.startIndex, to: range.lowerBound)
            return 10_000 - distance
        }
        let queryScalars = Array(query.replacingOccurrences(of: " ", with: ""))
        let candidateScalars = Array(normalizedCandidate.replacingOccurrences(of: " ", with: ""))
        guard !queryScalars.isEmpty, !candidateScalars.isEmpty else {
            return nil
        }
        var score = 0
        var candidateIndex = 0
        for scalar in queryScalars {
            var foundIndex: Int?
            while candidateIndex < candidateScalars.count {
                if candidateScalars[candidateIndex] == scalar {
                    foundIndex = candidateIndex
                    candidateIndex += 1
                    break
                }
                candidateIndex += 1
            }
            guard let foundIndex else {
                return nil
            }
            let gapPenalty = max(foundIndex - score / 20, 0)
            score += max(1, 24 - gapPenalty)
        }
        return score
    }

    func handlePickedTrackingDirectory(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try selectTrackingDirectory(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func handlePickedLocalLibrary(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try addLocalLibrary(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func removeLocalLibrary(at index: Int) {
        guard index >= 0 && index < localLibraries.count else { return }
        scopedLocalLibraries[index].stopAccessingSecurityScopedResource()
        scopedLocalLibraries.remove(at: index)
        localLibraries.remove(at: index)

        let bookmarks = scopedLocalLibraries.compactMap {
            try? $0.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: localLibrariesKey)

        refresh(silently: false)
    }

    func removeFromActive(book: Book) {
        // Find if it's in tracking directory
        guard let trackingDirectoryURL else { return }
        let trackingBooksURL = trackingDirectoryURL.appending(path: "books", directoryHint: .isDirectory)
        let stateDirectory = trackingDirectoryURL.appending(path: "progress", directoryHint: .isDirectory)

        // Remove file
        try? FileManager.default.removeItem(at: trackingBooksURL.appending(path: book.fileURL.lastPathComponent))
        // Remove progress
        try? FileManager.default.removeItem(at: stateDirectory.appending(path: "\(book.id).json"))

        refresh(silently: true)
    }

    func refresh(silently: Bool = false) {
        guard refreshTask == nil, let trackingDirectoryURL else {
            return
        }

        if !silently {
            isLoading = true
        }

        refreshTask = Task { [weak self, trackingDirectoryURL, localLibraries = self.localLibraries] in
            defer {
                Task { @MainActor [weak self] in
                    self?.refreshTask = nil
                    self?.isLoading = false
                }
            }

            do {
                let booksResult = try await Task.detached(priority: .userInitiated) {
                    try Self.scanLibraries(trackingDirectoryURL: trackingDirectoryURL, localLibraries: localLibraries)
                }.value

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self?.books = booksResult
                    self?.lastScanAt = .now
                    self?.errorMessage = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func absoluteURL(for book: Book) -> URL? {
        return book.fileURL
    }

    private func ensureBookInTrackingDirectory(_ book: Book) throws -> Book {
        guard let trackingDirectoryURL else { throw LibraryError.accessDenied }
        let trackingBooksURL = trackingDirectoryURL.appending(path: "books", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trackingBooksURL, withIntermediateDirectories: true)

        // If the book is already in the tracking directory, return it
        if book.fileURL.path().hasPrefix(trackingDirectoryURL.path()) {
            return book
        }

        // Ensure name uniqueness in tracking directory, though preserving name is required
        let destURL = trackingBooksURL.appending(path: book.fileURL.lastPathComponent)

        if !FileManager.default.fileExists(atPath: destURL.path()) {
            try FileManager.default.copyItem(at: book.fileURL, to: destURL)
        }

        var updated = book
        updated.fileURL = destURL

        // Update local memory so we don't need a full refresh immediately
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = updated
        }

        return updated
    }

    func markOpened(_ incomingBook: Book) {
        do {
            let book = try ensureBookInTrackingDirectory(incomingBook)
            var state =
                book.progressState
                ?? BookProgressState(
                    bookID: book.id,
                    updatedAt: .now,
                    lastOpenedAt: .now,
                    progress: 0,
                    isFinished: false,
                    pdfPageIndex: nil,
                    pdfPageCount: nil,
                    epubChapterIndex: nil,
                    epubChapterPath: nil,
                    epubChapterProgress: nil
                )
            state.updatedAt = .now
            state.lastOpenedAt = .now
            apply(state: state.normalized(), toBookID: book.id)
            schedulePersist(state: state)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func savePDFPosition(for book: Book, pageIndex: Int, pageCount: Int, pageOffsetY: Double = 0) {
        let state =
            BookProgressState
            .pdf(bookID: book.id, pageIndex: pageIndex, pageCount: pageCount, pageOffsetY: pageOffsetY, lastOpenedAt: .now)
        apply(state: mergedLocalState(for: book.id, with: state), toBookID: book.id)
        schedulePersist(state: state)
    }

    func saveEPUBPosition(
        for book: Book,
        chapterIndex: Int,
        chapterPath: String,
        chapterProgress: Double,
        overallProgress: Double
    ) {
        let state = BookProgressState.epub(
            bookID: book.id,
            chapterIndex: chapterIndex,
            chapterPath: chapterPath,
            chapterProgress: chapterProgress,
            overallProgress: overallProgress,
            lastOpenedAt: .now
        )
        apply(state: mergedLocalState(for: book.id, with: state), toBookID: book.id)
        schedulePersist(state: state)
    }

    func saveEPUBFontSize(for book: Book, fontSizePercent: Int) {
        guard var state = book.progressState else { return }
        state.epubFontSizePercent = fontSizePercent
        state.updatedAt = .now
        apply(state: state.normalized(), toBookID: book.id)
        schedulePersist(state: state)
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.refresh(silently: true)
                }
            }
        }
    }

    private func selectTrackingDirectory(at url: URL) throws {
        let bookmark = try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)

        scopedTrackingDirectoryURL?.stopAccessingSecurityScopedResource()

        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard resolved.startAccessingSecurityScopedResource() else {
            throw LibraryError.accessDenied
        }

        scopedTrackingDirectoryURL = resolved
        trackingDirectoryURL = resolved.standardizedFileURL
        defaults.set(bookmark, forKey: trackingBookmarkKey)

        if isStale {
            let refreshed = try resolved.bookmarkData(
                options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(refreshed, forKey: trackingBookmarkKey)
        }

        refresh(silently: false)
    }

    private func addLocalLibrary(at url: URL) throws {
        let bookmark = try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)

        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard resolved.startAccessingSecurityScopedResource() else {
            throw LibraryError.accessDenied
        }

        scopedLocalLibraries.append(resolved)
        localLibraries.append(resolved.standardizedFileURL)

        let bookmarks = scopedLocalLibraries.compactMap {
            try? $0.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: localLibrariesKey)

        refresh(silently: false)
    }

    private func restoreLibraries() {
        if let data = defaults.data(forKey: trackingBookmarkKey) {
            do {
                var isStale = false
                let resolved = try URL(
                    resolvingBookmarkData: data,
                    options: bookmarkResolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if resolved.startAccessingSecurityScopedResource() {
                    scopedTrackingDirectoryURL = resolved
                    trackingDirectoryURL = resolved.standardizedFileURL

                    if isStale {
                        let refreshed = try resolved.bookmarkData(
                            options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                        defaults.set(refreshed, forKey: trackingBookmarkKey)
                    }
                }
            } catch {
                defaults.removeObject(forKey: trackingBookmarkKey)
            }
        }

        if let datas = defaults.array(forKey: localLibrariesKey) as? [Data] {
            var updatedBookmarks: [Data] = []
            for data in datas {
                do {
                    var isStale = false
                    let resolved = try URL(
                        resolvingBookmarkData: data, options: bookmarkResolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale)
                    if resolved.startAccessingSecurityScopedResource() {
                        scopedLocalLibraries.append(resolved)
                        localLibraries.append(resolved.standardizedFileURL)

                        if isStale {
                            let refreshed = try resolved.bookmarkData(
                                options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                            updatedBookmarks.append(refreshed)
                        } else {
                            updatedBookmarks.append(data)
                        }
                    }
                } catch {
                    // Skip
                }
            }
            defaults.set(updatedBookmarks, forKey: localLibrariesKey)
        }

        if trackingDirectoryURL != nil {
            refresh(silently: false)
        }
    }

    private func schedulePersist(state proposedState: BookProgressState) {
        guard let trackingDirectoryURL else {
            return
        }

        let normalized = mergedLocalState(for: proposedState.bookID, with: proposedState).normalized()
        let bookID = proposedState.bookID

        writeTasks[bookID]?.cancel()
        writeTasks[bookID] = Task { [weak self, trackingDirectoryURL] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try await Task.detached(priority: .utility) {
                    try Self.persist(state: normalized, at: trackingDirectoryURL)
                }.value
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                self?.writeTasks[bookID] = nil
            }
        }
    }

    private func mergedLocalState(for bookID: String, with incomingState: BookProgressState) -> BookProgressState {
        guard let current = books.first(where: { $0.id == bookID })?.progressState else {
            return incomingState.normalized()
        }
        return Self.mergeStates(local: incomingState, remote: current)
    }

    private func apply(state: BookProgressState, toBookID bookID: String) {
        books = books.map { book in
            guard book.id == bookID else {
                return book
            }
            var updatedBook = book
            updatedBook.progressState = Self.mergeStates(local: state, remote: book.progressState)
            return updatedBook
        }
    }

    // --- Scanning & Hashing Logic ---

    private nonisolated static func cacheDirectory() -> URL {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let cacheDir = urls[0].appending(path: "com.anatol.Booklight", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }

    private nonisolated static func hashCacheURL() -> URL {
        cacheDirectory().appending(path: "hashes.json")
    }

    private nonisolated static func loadHashCache() -> FileHashCache {
        let url = hashCacheURL()
        guard let data = try? Data(contentsOf: url),
            let cache = try? JSONDecoder().decode(FileHashCache.self, from: data)
        else {
            return FileHashCache()
        }
        return cache
    }

    private nonisolated static func saveHashCache(_ cache: FileHashCache) {
        let url = hashCacheURL()
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func calculateHash(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func scanLibraries(trackingDirectoryURL: URL, localLibraries: [URL]) throws -> [Book] {
        let fileManager = FileManager.default
        let stateDirectory = trackingDirectoryURL.appending(path: "progress", directoryHint: .isDirectory)
        let trackingBooksDirectory = trackingDirectoryURL.appending(path: "books", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: trackingBooksDirectory, withIntermediateDirectories: true)

        let progressStates = try loadStates(from: stateDirectory)
        var hashCache = loadHashCache()
        var cacheUpdated = false

        // Helper to scan a directory and yield (URL, format, fileSize, modifiedAt, hash)
        func processDirectory(at url: URL) -> [(URL, BookFormat, Int64, Date, String, String)] {
            // Use enumerator instead of contentsOfDirectory to recursively
            // discover books in subdirectories (e.g. organized by author/genre)
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            var results: [(URL, BookFormat, Int64, Date, String, String)] = []

            for case let fileURL as URL in enumerator {
                guard let format = BookFormat(url: fileURL) else { continue }
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate,
                    let fileSizeVal = values.fileSize
                else { continue }
                let fileSize = Int64(fileSizeVal)

                let pathKey = fileURL.path()
                let hash: String

                if let record = hashCache.records[pathKey], record.fileSize == fileSize,
                    abs(record.modifiedAt.timeIntervalSince(modifiedAt)) < 1.0
                {
                    hash = record.contentHash
                } else {
                    guard let newHash = try? calculateHash(fileURL: fileURL) else { continue }
                    hash = newHash
                    hashCache.records[pathKey] = FileHashRecord(
                        path: pathKey, fileSize: fileSize, modifiedAt: modifiedAt, contentHash: hash)
                    cacheUpdated = true
                }

                results.append((fileURL, format, fileSize, modifiedAt, hash, fileURL.deletingPathExtension().lastPathComponent))
            }
            return results
        }

        // 1. Scan Tracking Directory
        let trackedBooks = processDirectory(at: trackingBooksDirectory)

        // 2. Scan Local Libraries
        var localBooks: [(URL, BookFormat, Int64, Date, String, String)] = []
        for lib in localLibraries {
            localBooks.append(contentsOf: processDirectory(at: lib))
        }

        if cacheUpdated {
            saveHashCache(hashCache)
        }

        var generatedBooks: [Book] = []
        var seenHashes = Set<String>()

        // Process tracked books first to ensure they are the authoritative copy if duplicated
        for (fileURL, format, fileSize, modifiedAt, hash, title) in trackedBooks {
            guard !seenHashes.contains(hash) else { continue }
            seenHashes.insert(hash)

            let state = progressStates[hash]
            let book = Book(
                id: hash,
                title: title,
                fileURL: fileURL,
                format: format,
                fileSize: fileSize,
                addedAt: modifiedAt,  // Just use modifiedAt as addedAt for tracked copies
                modifiedAt: modifiedAt,
                progressState: state
            )
            generatedBooks.append(book)
        }

        // Process local books
        for (fileURL, format, fileSize, modifiedAt, hash, title) in localBooks {
            guard !seenHashes.contains(hash) else { continue }
            seenHashes.insert(hash)

            let state = progressStates[hash]
            let book = Book(
                id: hash,
                title: title,
                fileURL: fileURL,
                format: format,
                fileSize: fileSize,
                addedAt: modifiedAt,
                modifiedAt: modifiedAt,
                progressState: state
            )
            generatedBooks.append(book)
        }

        generatedBooks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return generatedBooks
    }

    private nonisolated static func persist(state: BookProgressState, at trackingDirectoryURL: URL) throws {
        let fileManager = FileManager.default
        let stateDirectory = trackingDirectoryURL.appending(path: "progress", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let stateFileURL = stateDirectory.appending(path: "\(state.bookID).json")
        let diskState = try loadState(from: stateFileURL)
        let merged = mergeStates(local: state, remote: diskState).normalized()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(merged).write(to: stateFileURL, options: [.atomic])
    }

    private nonisolated static func loadStates(from stateDirectory: URL) throws -> [String: BookProgressState] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stateDirectory.path()) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [String: BookProgressState] = [:]
        let files = try fileManager.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil)

        for fileURL in files where fileURL.pathExtension.lowercased() == "json" {
            do {
                let state = try decoder.decode(BookProgressState.self, from: Data(contentsOf: fileURL)).normalized()
                results[state.bookID] = state
            } catch {
                continue
            }
        }
        return results
    }

    private nonisolated static func loadState(from url: URL) throws -> BookProgressState? {
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookProgressState.self, from: Data(contentsOf: url)).normalized()
    }

    nonisolated static func mergeStates(local: BookProgressState, remote: BookProgressState?) -> BookProgressState {
        guard let remote else {
            return local.normalized()
        }

        let normalizedLocal = local.normalized()
        let normalizedRemote = remote.normalized()

        // Prioritize the most recently updated state so users can scroll backward
        // without their position being overridden by their own 'furthest' state.
        let selected = normalizedLocal.updatedAt >= normalizedRemote.updatedAt ? normalizedLocal : normalizedRemote

        var merged = selected
        merged.lastOpenedAt = [normalizedLocal.lastOpenedAt, normalizedRemote.lastOpenedAt].compactMap { $0 }.max()
        merged.updatedAt = max(normalizedLocal.updatedAt, normalizedRemote.updatedAt)
        merged.isFinished = normalizedLocal.isFinished || normalizedRemote.isFinished || merged.progress >= 0.999

        if normalizedLocal.epubFontSizePercent != nil && normalizedRemote.epubFontSizePercent != nil {
            merged.epubFontSizePercent =
                normalizedLocal.updatedAt >= normalizedRemote.updatedAt
                ? normalizedLocal.epubFontSizePercent
                : normalizedRemote.epubFontSizePercent
        } else {
            merged.epubFontSizePercent = normalizedLocal.epubFontSizePercent ?? normalizedRemote.epubFontSizePercent
        }

        return merged.normalized()
    }
}

private enum LibraryError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "The selected folder could not be opened with read and write access."
        }
    }
}
