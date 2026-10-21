import Foundation
import Observation

/// UI state of the library screen: the search field (debounced) and the
/// chosen sort order for non-active books, which persists across launches.
@MainActor
@Observable
final class LibraryBrowserState {
    var searchText = "" {
        didSet { scheduleSearchDebounce() }
    }
    /// `searchText` after typing pauses; filtering uses this to avoid re-sorting
    /// on every keystroke.
    private(set) var debouncedSearchText = ""
    var sort: LibrarySortOption = .title {
        didSet {
            guard oldValue != sort else { return }
            defaults.set(sort.rawValue, forKey: Self.sortKey)
        }
    }

    private static let sortKey = "Booklight.otherBooksSort"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.sortKey), let sort = LibrarySortOption(rawValue: stored) {
            self.sort = sort
        }
    }

    func sections(of books: [Book]) -> LibrarySearch.Sections {
        LibrarySearch.sections(of: books, query: debouncedSearchText, sort: sort)
    }

    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()

        let query = searchText
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.debouncedSearchText != query else { return }
            self.debouncedSearchText = query
        }
    }
}
