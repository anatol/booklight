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
    /// Last computed sections and their inputs. The library view re-renders for
    /// many reasons that don't affect filtering (loading state, alerts, …), so
    /// recompute only when the books, query or sort actually changed.
    @ObservationIgnored private var cachedSections: (books: [Book], query: String, sort: LibrarySortOption, result: LibrarySearch.Sections)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.sortKey), let sort = LibrarySortOption(rawValue: stored) {
            self.sort = sort
        }
    }

    func sections(of books: [Book]) -> LibrarySearch.Sections {
        let query = debouncedSearchText
        let sort = self.sort
        if let cached = cachedSections, cached.query == query, cached.sort == sort, cached.books == books {
            return cached.result
        }
        let result = LibrarySearch.sections(of: books, query: query, sort: sort)
        cachedSections = (books, query, sort, result)
        return result
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
