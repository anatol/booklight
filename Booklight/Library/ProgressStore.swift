import Foundation

/// Reads and writes per-book progress files in one tracking directory.
///
/// Writes are debounced per book so scrolling doesn't hammer a synced folder.
/// Every write merges with what is currently on disk (newest `updatedAt` wins),
/// so a position saved by another device in the meantime is never clobbered by
/// an older local one.
actor ProgressStore {
    static let writeDebounce: Duration = .seconds(2)

    let layout: TrackingLayout
    private let debounce: Duration
    private var pending: [String: BookProgressState] = [:]
    private var writeTasks: [String: Task<Void, Never>] = [:]
    /// Modification date of each progress file as of our last read or write, used
    /// to detect changes made by other devices.
    private var lastKnownModification: [String: Date] = [:]
    /// Debounced background writes have no caller to throw to; failures go here.
    private let onWriteError: @MainActor @Sendable (Error) -> Void

    init(
        layout: TrackingLayout,
        debounce: Duration = ProgressStore.writeDebounce,
        onWriteError: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
    ) {
        self.layout = layout
        self.debounce = debounce
        self.onWriteError = onWriteError
    }

    // MARK: - Reading

    /// Loads every canonical progress file. Sync-conflict copies and unreadable
    /// files are skipped.
    func loadAll() throws -> [String: BookProgressState] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.progressDirectory, withIntermediateDirectories: true)

        var results: [String: BookProgressState] = [:]
        let files = try fileManager.contentsOfDirectory(at: layout.progressDirectory, includingPropertiesForKeys: nil)

        for fileURL in files where Self.isCanonicalProgressStateFileName(fileURL.lastPathComponent) {
            guard let state = try? Self.loadState(from: fileURL) else { continue }
            results[state.bookID] = state
        }
        return results
    }

    /// States scheduled for writing but not yet on disk.
    func pendingStates() -> [String: BookProgressState] {
        pending
    }

    /// Records the current modification date of a book's progress file so a later
    /// `changedState(for:)` only reports changes made after this point.
    func noteCurrentModification(for bookID: String) {
        if let modifiedAt = Self.modificationDate(of: layout.progressFileURL(for: bookID)) {
            lastKnownModification[bookID] = modifiedAt
        }
    }

    /// Returns the on-disk state if the file changed since we last read or wrote
    /// it (i.e. another device updated it), otherwise nil.
    func changedState(for bookID: String) -> BookProgressState? {
        let fileURL = layout.progressFileURL(for: bookID)
        guard let modifiedAt = Self.modificationDate(of: fileURL) else { return nil }

        let lastKnown = lastKnownModification[bookID] ?? .distantPast
        guard modifiedAt.timeIntervalSince(lastKnown) > 0.001 else { return nil }
        lastKnownModification[bookID] = modifiedAt

        return try? Self.loadState(from: fileURL)
    }

    // MARK: - Writing

    /// Queues a state for writing after the debounce interval, merging with any
    /// state already queued for the same book.
    func schedule(_ state: BookProgressState) {
        let bookID = state.bookID
        pending[bookID] = Self.mergeStates(local: state, remote: pending[bookID])

        writeTasks[bookID]?.cancel()
        let debounce = self.debounce
        writeTasks[bookID] = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.writePending(bookID: bookID)
        }
    }

    /// Writes all queued states immediately (e.g. when the app goes to background).
    func flush() throws {
        writeTasks.values.forEach { $0.cancel() }
        writeTasks.removeAll()

        var firstError: Error?
        for bookID in Array(pending.keys) {
            do {
                try write(bookID: bookID)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// Deletes a book's progress file and drops any queued write so it can't
    /// recreate the file afterwards.
    func remove(bookID: String) throws {
        writeTasks[bookID]?.cancel()
        writeTasks[bookID] = nil
        pending[bookID] = nil

        let fileURL = layout.progressFileURL(for: bookID)
        if FileManager.default.fileExists(atPath: fileURL.path()) {
            try FileManager.default.removeItem(at: fileURL)
        }
        lastKnownModification[bookID] = nil
    }

    private func writePending(bookID: String) {
        writeTasks[bookID] = nil
        do {
            try write(bookID: bookID)
        } catch {
            let onWriteError = self.onWriteError
            Task { @MainActor in onWriteError(error) }
        }
    }

    private func write(bookID: String) throws {
        guard let state = pending[bookID] else { return }
        try Self.persist(state: state, layout: layout)
        pending[bookID] = nil
        noteCurrentModification(for: bookID)
    }

    // MARK: - File format

    private static func persist(state: BookProgressState, layout: TrackingLayout) throws {
        try FileManager.default.createDirectory(at: layout.progressDirectory, withIntermediateDirectories: true)

        let stateFileURL = layout.progressFileURL(for: state.bookID)
        let diskState = try loadState(from: stateFileURL)
        let merged = mergeStates(local: state, remote: diskState)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(merged).write(to: stateFileURL, options: [.atomic])
    }

    static func loadState(from url: URL) throws -> BookProgressState? {
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookProgressState.self, from: Data(contentsOf: url)).normalized()
    }

    private static func modificationDate(of fileURL: URL) -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Accepts only `<64 hex chars>.json`; sync tools leave conflict copies like
    /// `<id>.sync-conflict-….json` that must not be treated as progress.
    static func isCanonicalProgressStateFileName(_ fileName: String) -> Bool {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].lowercased() == "json" else {
            return false
        }

        let bookID = parts[0]
        guard bookID.count == 64 else {
            return false
        }

        return bookID.allSatisfy { char in
            switch char {
            case "0" ... "9", "a" ... "f", "A" ... "F":
                return true
            default:
                return false
            }
        }
    }

    static func mergeStates(local: BookProgressState, remote: BookProgressState?) -> BookProgressState {
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
