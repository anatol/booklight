import Observation
import SwiftUI

/// What the shared reader UI needs from a format-specific reader (PDFKit or
/// the EPUB web view): scrolling, in-document search, and position bookkeeping.
@MainActor
protocol ReaderEngine: AnyObject, Observable {
    // MARK: Search
    var searchMatchCount: Int { get }
    /// Zero-based index of the currently highlighted match.
    var searchCurrentIndex: Int { get }
    /// True while matches are still being collected.
    var isSearchInProgress: Bool { get }
    /// The last query searched; kept after the search bar closes to pre-fill it.
    var lastSearchText: String { get }
    func search(for text: String)
    func nextSearchMatch()
    func previousSearchMatch()
    /// Removes highlights and resets match state (keeps `lastSearchText`).
    func clearSearch()

    // MARK: Position
    /// Remembers the current position (before search starts jumping around).
    func savePosition()
    /// Returns to the position remembered by `savePosition()`.
    func restorePosition()
    func discardSavedPosition()
    /// Re-emits the current position through the reader's progress callback,
    /// even if it hasn't changed since the last report.
    func reportCurrentPosition()

    // MARK: Navigation
    func scrollPageDown()
    func scrollPageUp()
    /// Returns to where the reader was before the last followed link or jump.
    func jumpBack()

    // MARK: Text size
    /// Whether the format reflows text, so text size can change.
    var supportsTextSize: Bool { get }
    func increaseTextSize()
    func decreaseTextSize()
}

extension ReaderEngine {
    var supportsTextSize: Bool { false }
    func increaseTextSize() {}
    func decreaseTextSize() {}
}

/// Per-reader UI state shared by both formats: the find bar and its
/// save/restore/confirm position semantics.
@MainActor
@Observable
final class ReaderSession<Engine: ReaderEngine> {
    let engine: Engine
    var isSearchVisible = false
    var searchText = ""

    init(engine: Engine) {
        self.engine = engine
    }

    /// Whether the text field still shows the query whose results are displayed.
    var hasActiveSearch: Bool {
        !engine.lastSearchText.isEmpty && engine.lastSearchText == searchText
    }

    func toggleSearch() {
        if isSearchVisible {
            dismissSearch()
        } else {
            openSearch()
        }
    }

    func openSearch() {
        guard !isSearchVisible else { return }
        // Save position before searching so we can restore on dismiss.
        engine.savePosition()
        // Pre-fill with the last searched text (stays empty if no prior search).
        searchText = engine.lastSearchText
        isSearchVisible = true
    }

    /// Enter in the search bar: perform a new search if the text changed,
    /// or navigate to the next match if the same text is already searched.
    func searchOrNext() {
        guard !searchText.isEmpty else { return }
        if searchText == engine.lastSearchText && engine.searchMatchCount > 0 {
            engine.nextSearchMatch()
        } else {
            engine.search(for: searchText)
        }
    }

    /// Closes the find bar and returns to the pre-search reading position.
    func dismissSearch() {
        isSearchVisible = false
        engine.clearSearch()
        engine.restorePosition()
        searchText = ""
    }

    /// Closes the find bar but keeps the current position as the new reading
    /// location (the user tapped the content at a match).
    func confirmSearchPosition() {
        guard isSearchVisible else { return }
        isSearchVisible = false
        engine.clearSearch()
        engine.discardSavedPosition()
        searchText = ""
        // The position may not have changed since the last (deduplicated)
        // report, so force one to update the title and saved progress.
        engine.reportCurrentPosition()
    }
}
