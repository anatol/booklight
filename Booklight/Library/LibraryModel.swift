import Foundation
import SwiftUI

/// The app's library: which folders are configured, which books they contain,
/// and each book's reading progress. Views observe this; the file work is
/// delegated to `FolderAccess`, `LibraryScanner`, `ProgressStore` and `ActiveShelf`.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var trackingDirectoryURL: URL?
    @Published private(set) var localLibraries: [URL] = []
    @Published private(set) var books: [Book] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Bumped per book when another device changed its progress, telling an open
    /// reader to jump to the new position.
    @Published private var readerSyncTokens: [String: UUID] = [:]

    private let folders: FolderAccess
    private let scanner: LibraryScanner
    /// Per-tracking-directory services; replaced when the directory changes.
    private var progressStore: ProgressStore?
    private var shelf: ActiveShelf?

    private var refreshTask: Task<Void, Never>?
    /// Identifies the latest refresh so a superseded one can't publish stale
    /// results or clear the newer one's loading state.
    private var refreshGeneration = 0
    private var pollTask: Task<Void, Never>?

    init() {
        folders = FolderAccess()
        scanner = LibraryScanner()
        trackingDirectoryURL = folders.trackingDirectoryURL
        localLibraries = folders.localLibraries
        configureTrackingServices()
        if trackingDirectoryURL != nil {
            refresh(silently: false)
        }
        startPolling()
    }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
    }

    func book(withID bookID: String) -> Book? {
        books.first(where: { $0.id == bookID })
    }

    // MARK: - Folders

    func handlePickedTrackingDirectory(_ result: Result<URL, Error>) {
        do {
            try folders.selectTrackingDirectory(at: result.get())
            trackingDirectoryURL = folders.trackingDirectoryURL
            configureTrackingServices()
            refresh(silently: false, restart: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handlePickedLocalLibrary(_ result: Result<URL, Error>) {
        do {
            try folders.addLocalLibrary(at: result.get())
            localLibraries = folders.localLibraries
            refresh(silently: false, restart: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeLocalLibrary(at index: Int) {
        folders.removeLocalLibrary(at: index)
        localLibraries = folders.localLibraries
        refresh(silently: false, restart: true)
    }

    /// Creates the progress store and shelf for the current tracking directory,
    /// flushing anything still queued for the previous one.
    private func configureTrackingServices() {
        if let previous = progressStore {
            Task { try? await previous.flush() }
        }

        guard let trackingDirectoryURL else {
            progressStore = nil
            shelf = nil
            return
        }

        let layout = TrackingLayout(root: trackingDirectoryURL)
        progressStore = ProgressStore(layout: layout) { [weak self] error in
            self?.errorMessage = error.localizedDescription
        }
        shelf = ActiveShelf(layout: layout)
    }

    // MARK: - Scanning

    /// Rescans all folders. A refresh already in flight is left alone unless
    /// `restart` is set (used when the folder configuration changed).
    func refresh(silently: Bool = false, restart: Bool = false) {
        guard let trackingDirectoryURL, let progressStore else { return }
        if refreshTask != nil {
            guard restart else { return }
            refreshTask?.cancel()
        }

        if !silently {
            isLoading = true
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let layout = TrackingLayout(root: trackingDirectoryURL)
        let localLibraries = self.localLibraries

        refreshTask = Task { [weak self, scanner] in
            defer {
                if self?.refreshGeneration == generation {
                    self?.refreshTask = nil
                    self?.isLoading = false
                }
            }

            do {
                let states = try await progressStore.loadAll()
                let scanned = try await scanner.scan(layout: layout, localLibraries: localLibraries, progressStates: states)
                let pending = await progressStore.pendingStates()

                guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
                // The scan only sees what's on disk; re-apply debounced writes
                // that haven't landed yet so in-memory progress doesn't jump back.
                self.books = scanned.map { book in
                    guard let pendingState = pending[book.id] else { return book }
                    var updated = book
                    updated.progressState = ProgressStore.mergeStates(local: pendingState, remote: book.progressState)
                    return updated
                }
                self.errorMessage = nil
            } catch {
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.refresh(silently: true)
            }
        }
    }

    // MARK: - Active shelf

    /// Moves the book onto the active shelf (copying it into the tracking
    /// directory) and stamps it as opened now.
    func markOpened(_ incomingBook: Book) {
        guard let shelf else {
            errorMessage = LibraryError.noTrackingDirectory.localizedDescription
            return
        }

        do {
            let trackedURL = try shelf.ensureTracked(incomingBook)
            if trackedURL != incomingBook.fileURL, let index = books.firstIndex(where: { $0.id == incomingBook.id }) {
                // Point at the copy right away instead of waiting for the next scan.
                books[index].fileURL = trackedURL
            }

            var state = incomingBook.progressState ?? .initial(bookID: incomingBook.id)
            state.updatedAt = .now
            state.lastOpenedAt = .now
            record(state)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markUnread(book: Book) {
        var state = book.progressState ?? .initial(bookID: book.id)
        state.updatedAt = .now
        state.progress = 0
        state.pdfPageIndex = 0
        state.pdfPageCount = nil
        state.pdfPageOffsetY = 0
        state.epubChapterIndex = 0
        state.epubChapterPath = nil
        state.epubChapterProgress = 0
        record(state)
    }

    /// Removes the book's tracked copy and its progress file (on every synced device).
    func removeFromActive(book: Book) {
        guard let shelf, let progressStore else { return }

        do {
            try shelf.removeTrackedCopy(of: book)
        } catch {
            errorMessage = error.localizedDescription
        }

        Task { [weak self] in
            do {
                try await progressStore.remove(bookID: book.id)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.refresh(silently: true, restart: true)
        }
    }

    // MARK: - Progress

    func savePDFPosition(for book: Book, pageIndex: Int, pageCount: Int, pageOffsetY: Double = 0) {
        record(.pdf(bookID: book.id, pageIndex: pageIndex, pageCount: pageCount, pageOffsetY: pageOffsetY, lastOpenedAt: .now))
    }

    func saveEPUBPosition(for book: Book, chapterIndex: Int, chapterPath: String, chapterProgress: Double, overallProgress: Double) {
        record(
            .epub(
                bookID: book.id,
                chapterIndex: chapterIndex,
                chapterPath: chapterPath,
                chapterProgress: chapterProgress,
                overallProgress: overallProgress,
                lastOpenedAt: .now
            ))
    }

    func saveEPUBFontSize(for book: Book, fontSizePercent: Int) {
        guard var state = self.book(withID: book.id)?.progressState ?? book.progressState else { return }
        state.epubFontSizePercent = fontSizePercent
        state.updatedAt = .now
        record(state)
    }

    func readerSyncToken(for bookID: String) -> UUID? {
        readerSyncTokens[bookID]
    }

    /// Called when a reader opens, so only changes made after this point count as
    /// coming from another device.
    func registerReaderProgressObservation(for bookID: String) {
        guard let progressStore else { return }
        Task { await progressStore.noteCurrentModification(for: bookID) }
    }

    /// Picks up progress another device wrote for an open book and tells its
    /// reader to jump there.
    func synchronizeReaderProgressIfNeeded(for bookID: String) {
        guard let progressStore else { return }
        Task { [weak self] in
            guard let diskState = await progressStore.changedState(for: bookID), let self else { return }
            self.apply(state: diskState, toBookID: bookID)
            self.readerSyncTokens[bookID] = UUID()
        }
    }

    func flushPendingProgressWrites() async {
        guard let progressStore else { return }
        do {
            try await progressStore.flush()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Updates the in-memory book immediately and queues the debounced write.
    private func record(_ state: BookProgressState) {
        let normalized = state.normalized()
        apply(state: normalized, toBookID: normalized.bookID)
        guard let progressStore else { return }
        Task { await progressStore.schedule(normalized) }
    }

    private func apply(state: BookProgressState, toBookID bookID: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].progressState = ProgressStore.mergeStates(local: state, remote: books[index].progressState)
    }
}
