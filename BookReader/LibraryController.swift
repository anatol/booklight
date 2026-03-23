import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var libraryURL: URL?
    @Published private(set) var books: [Book] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastScanAt: Date?
    @Published var isPickingLibrary = false
    @Published var searchText = ""
    @Published var errorMessage: String?

    private let bookmarkKey = "BookReader.selectedLibraryBookmark"
    private let defaults = UserDefaults.standard

    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var writeTasks: [String: Task<Void, Never>] = [:]
    private var scopedLibraryURL: URL?

#if targetEnvironment(macCatalyst)
    private let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
    private let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
#endif

    init() {
        restoreLibrary()
        startPolling()
    }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
        writeTasks.values.forEach { $0.cancel() }
        scopedLibraryURL?.stopAccessingSecurityScopedResource()
    }

    var activeBooks: [Book] {
        visibleBooks(from: books)
            .filter(\.isActive)
            .sorted {
                ($0.lastOpenedAt ?? .distantPast, fuzzyScore(for: $0), $0.title.localizedLowercase) >
                ($1.lastOpenedAt ?? .distantPast, fuzzyScore(for: $1), $1.title.localizedLowercase)
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
        Self.normalized(searchText)
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

    func handlePickedLibrary(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            do {
                try selectLibrary(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    func refresh(silently: Bool = false) {
        guard refreshTask == nil, let libraryURL else {
            return
        }

        if !silently {
            isLoading = true
        }

        refreshTask = Task { [weak self, libraryURL] in
            defer {
                Task { @MainActor [weak self] in
                    self?.refreshTask = nil
                    self?.isLoading = false
                }
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.scanLibrary(at: libraryURL)
                }.value

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self?.books = result.books
                    self?.lastScanAt = result.database.scannedAt
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
        libraryURL?.appending(path: book.relativePath)
    }

    func markOpened(_ book: Book) {
        var state = book.progressState ?? BookProgressState(
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
    }

    func savePDFPosition(for book: Book, pageIndex: Int, pageCount: Int) {
        let state = BookProgressState
            .pdf(bookID: book.id, pageIndex: pageIndex, pageCount: pageCount, lastOpenedAt: .now)
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

    private func selectLibrary(at url: URL) throws {
        let bookmark = try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)

        stopAccessingLibrary()

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

        scopedLibraryURL = resolved
        libraryURL = resolved.standardizedFileURL
        defaults.set(bookmark, forKey: bookmarkKey)

        if isStale {
            let refreshed = try resolved.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(refreshed, forKey: bookmarkKey)
        }

        refresh(silently: false)
    }

    private func restoreLibrary() {
        guard let data = defaults.data(forKey: bookmarkKey) else {
            return
        }

        do {
            var isStale = false
            let resolved = try URL(
                resolvingBookmarkData: data,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            guard resolved.startAccessingSecurityScopedResource() else {
                throw LibraryError.accessDenied
            }

            scopedLibraryURL = resolved
            libraryURL = resolved.standardizedFileURL

            if isStale {
                let refreshed = try resolved.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(refreshed, forKey: bookmarkKey)
            }

            refresh(silently: false)
        } catch {
            defaults.removeObject(forKey: bookmarkKey)
            errorMessage = error.localizedDescription
        }
    }

    private func stopAccessingLibrary() {
        scopedLibraryURL?.stopAccessingSecurityScopedResource()
        scopedLibraryURL = nil
        libraryURL = nil
        books = []
        lastScanAt = nil
    }

    private func schedulePersist(state proposedState: BookProgressState) {
        guard let libraryURL else {
            return
        }

        let normalized = mergedLocalState(for: proposedState.bookID, with: proposedState).normalized()
        let bookID = proposedState.bookID

        writeTasks[bookID]?.cancel()
        writeTasks[bookID] = Task { [weak self, libraryURL] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try await Task.detached(priority: .utility) {
                    try Self.persist(state: normalized, at: libraryURL)
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

    private nonisolated static func scanLibrary(at libraryURL: URL) throws -> LibraryScanResult {
        let fileManager = FileManager.default
        let metadataDirectory = self.metadataDirectory(for: libraryURL)
        let stateDirectory = self.stateDirectory(for: libraryURL)

        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let existingDatabase = try loadDatabase(from: metadataDirectory) ?? LibraryDatabase(scannedAt: .distantPast, books: [])
        let existingByPath = Dictionary(uniqueKeysWithValues: existingDatabase.books.map { ($0.relativePath, $0) })
        let progressStates = try loadStates(from: stateDirectory)

        let contents = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var seenBookIDs = Set<String>()
        var records: [LibraryBookRecord] = []

        for fileURL in contents.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let format = BookFormat(url: fileURL) else {
                continue
            }

            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                continue
            }

            let fileName = fileURL.lastPathComponent
            let relativePath = fileName
            let id = stableBookID(for: relativePath)
            seenBookIDs.insert(id)

            let previous = existingByPath[relativePath]
            let state = progressStates[id]?.normalized()
            let title = previous?.title ?? fileURL.deletingPathExtension().lastPathComponent

            let record = LibraryBookRecord(
                id: id,
                title: title,
                fileName: fileName,
                relativePath: relativePath,
                format: format,
                fileSize: Int64(values.fileSize ?? Int(previous?.fileSize ?? 0)),
                addedAt: previous?.addedAt ?? values.creationDate ?? .now,
                modifiedAt: values.contentModificationDate ?? previous?.modifiedAt ?? .now,
                lastKnownProgress: state?.progress ?? 0,
                lastOpenedAt: state?.lastOpenedAt,
                isFinished: state?.isFinished ?? false
            )
            records.append(record)
        }

        let staleStateIDs = Set(progressStates.keys).subtracting(seenBookIDs)
        for staleStateID in staleStateIDs {
            try? fileManager.removeItem(at: stateDirectory.appending(path: "\(staleStateID).json"))
        }

        let database = LibraryDatabase(
            scannedAt: .now,
            books: records.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        )

        try saveDatabase(database, to: metadataDirectory)

        let books = database.books.map { Book(record: $0, progressState: progressStates[$0.id]) }
        return LibraryScanResult(database: database, books: books)
    }

    private nonisolated static func persist(state: BookProgressState, at libraryURL: URL) throws {
        let fileManager = FileManager.default
        let metadataDirectory = self.metadataDirectory(for: libraryURL)
        let stateDirectory = self.stateDirectory(for: libraryURL)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let stateFileURL = stateDirectory.appending(path: "\(state.bookID).json")
        let diskState = try loadState(from: stateFileURL)
        let merged = mergeStates(local: state, remote: diskState).normalized()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(merged).write(to: stateFileURL, options: [.atomic])

        guard var database = try loadDatabase(from: metadataDirectory) else {
            return
        }

        if let index = database.books.firstIndex(where: { $0.id == merged.bookID }) {
            database.books[index].lastKnownProgress = merged.progress
            database.books[index].lastOpenedAt = merged.lastOpenedAt
            database.books[index].isFinished = merged.isFinished
            database.scannedAt = .now
            try saveDatabase(database, to: metadataDirectory)
        }
    }

    private nonisolated static func metadataDirectory(for libraryURL: URL) -> URL {
        libraryURL.appending(path: ".book-app", directoryHint: .isDirectory)
    }

    private nonisolated static func stateDirectory(for libraryURL: URL) -> URL {
        metadataDirectory(for: libraryURL).appending(path: "books", directoryHint: .isDirectory)
    }

    private nonisolated static func databaseURL(for metadataDirectory: URL) -> URL {
        metadataDirectory.appending(path: "library.json")
    }

    private nonisolated static func loadDatabase(from metadataDirectory: URL) throws -> LibraryDatabase? {
        let databaseURL = databaseURL(for: metadataDirectory)
        guard FileManager.default.fileExists(atPath: databaseURL.path()) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryDatabase.self, from: Data(contentsOf: databaseURL))
    }

    private nonisolated static func saveDatabase(_ database: LibraryDatabase, to metadataDirectory: URL) throws {
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(database).write(to: databaseURL(for: metadataDirectory), options: [.atomic])
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

    private nonisolated static func stableBookID(for relativePath: String) -> String {
        let digest = SHA256.hash(data: Data(relativePath.lowercased().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func mergeStates(local: BookProgressState, remote: BookProgressState?) -> BookProgressState {
        guard let remote else {
            return local.normalized()
        }

        let normalizedLocal = local.normalized()
        let normalizedRemote = remote.normalized()
        let epsilon = 0.0005

        let selected: BookProgressState
        if normalizedLocal.progress > normalizedRemote.progress + epsilon {
            selected = normalizedLocal
        } else if normalizedRemote.progress > normalizedLocal.progress + epsilon {
            selected = normalizedRemote
        } else {
            selected = normalizedLocal.updatedAt >= normalizedRemote.updatedAt ? normalizedLocal : normalizedRemote
        }

        var merged = selected
        merged.lastOpenedAt = [normalizedLocal.lastOpenedAt, normalizedRemote.lastOpenedAt].compactMap { $0 }.max()
        merged.updatedAt = max(normalizedLocal.updatedAt, normalizedRemote.updatedAt)
        merged.isFinished = normalizedLocal.isFinished || normalizedRemote.isFinished || merged.progress >= 0.999
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
