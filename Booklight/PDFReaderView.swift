@preconcurrency import PDFKit
import SwiftUI

/// Proxy object that bridges SwiftUI key events to the underlying PDFView,
/// allowing Space / Shift+Space to scroll by one viewport height.
/// Also manages in-document text search via PDFKit's built-in findString API.
@MainActor
final class PDFScrollProxy: ObservableObject {
    weak var pdfView: PDFView?

    // MARK: - Search state

    /// All selections matching the current search query.
    @Published var searchSelections: [PDFSelection] = []
    /// Zero-based index of the currently highlighted match.
    @Published var searchCurrentIndex: Int = 0
    /// The text that was last searched, used to detect whether a new search
    /// is needed or we can just navigate between existing results.
    var lastSearchText: String = ""

    // MARK: - Position save/restore (for returning to pre-search position)

    /// Saved PDF destination from before the search was opened,
    /// so we can return to the original reading position on dismiss.
    private var savedDestination: PDFDestination?

    /// Saves the current scroll position so it can be restored later.
    func savePosition() {
        savedDestination = topOfViewportDestination()
    }

    /// Restores the scroll position saved by `savePosition()`,
    /// returning the user to where they were before searching.
    func restorePosition() {
        guard let dest = savedDestination else { return }
        pdfView?.go(to: dest)
        savedDestination = nil
    }

    /// Discards the saved position without restoring it.
    /// Used when the user confirms they want to stay at the current location
    /// (e.g. by clicking on the content during search).
    func discardSavedPosition() {
        savedDestination = nil
    }

    /// Returns a PDFDestination representing the top of the visible viewport.
    /// Unlike `currentDestination` (which returns the center of the visible area),
    /// this computes the actual top edge, so `go(to:)` round-trips correctly.
    func topOfViewportDestination() -> PDFDestination? {
        guard let pdfView else { return nil }
        let topCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY)
        guard let page = pdfView.page(for: topCenter, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(topCenter, to: page)
        return PDFDestination(page: page, at: pagePoint)
    }

    // MARK: - Search

    /// Performs a case-insensitive search across the entire PDF document.
    /// Highlights all matches in yellow and navigates to the first one.
    func search(for text: String) {
        guard let pdfView, let document = pdfView.document else {
            clearSearch()
            return
        }

        // Clear previous highlights.
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        searchSelections = []
        searchCurrentIndex = 0
        lastSearchText = text

        guard !text.isEmpty else { return }

        let results = document.findString(text, withOptions: [.caseInsensitive])
        searchSelections = results

        if !results.isEmpty {
            // Show all matches as yellow highlights.
            pdfView.highlightedSelections = results
            goToMatch(0)
        }
    }

    /// Navigates to the next search match, wrapping around at the end.
    func nextSearchMatch() {
        guard !searchSelections.isEmpty else { return }
        let nextIndex = (searchCurrentIndex + 1) % searchSelections.count
        goToMatch(nextIndex)
    }

    /// Navigates to the previous search match, wrapping around at the start.
    func previousSearchMatch() {
        guard !searchSelections.isEmpty else { return }
        let prevIndex = (searchCurrentIndex - 1 + searchSelections.count) % searchSelections.count
        goToMatch(prevIndex)
    }

    /// Clears all search highlights and resets search state.
    /// Does NOT clear `lastSearchText` so it persists for the next search open.
    func clearSearch() {
        pdfView?.highlightedSelections = nil
        pdfView?.clearSelection()
        searchSelections = []
        searchCurrentIndex = 0
    }

    /// Scrolls to and highlights the match at the given index.
    /// The current match is shown as the active selection (blue),
    /// while all other matches remain as yellow highlights.
    /// The match is centered vertically in the viewport.
    private func goToMatch(_ index: Int) {
        guard index >= 0, index < searchSelections.count,
            let pdfView
        else { return }
        searchCurrentIndex = index
        let selection = searchSelections[index]
        pdfView.setCurrentSelection(selection, animate: true)

        // Convert the selection to a PDFDestination so we get predictable
        // scroll positioning. go(to: PDFSelection) has inconsistent behavior
        // across matches — sometimes it just ensures visibility rather than
        // scrolling to a fixed edge. go(to: PDFDestination) always places the
        // destination point at the top edge of the viewport.
        if let page = selection.pages.first {
            let bounds = selection.bounds(for: page)
            // PDFDestination uses PDF coordinates (origin at bottom-left, Y up).
            // bounds.origin.y is the bottom of the selection rect, so add height
            // to get the top of the selection in PDF coords.
            let topOfSelection = CGPoint(
                x: bounds.origin.x,
                y: bounds.origin.y + bounds.height)
            let destination = PDFDestination(page: page, at: topOfSelection)
            pdfView.go(to: destination)
        }

        // Now the selection is at the top edge of the viewport.
        // Scroll back by half the viewport height to center it vertically.
        if let scrollView = findScrollView() {
            let halfHeight = scrollView.bounds.height / 2.0
            let newY = max(scrollView.contentOffset.y - halfHeight, 0)
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: newY),
                animated: false
            )
        }
    }

    // MARK: - Scrolling

    /// Scroll the PDF down by one viewport height (with slight overlap).
    func scrollPageDown() {
        guard let scrollView = findScrollView() else { return }
        let pageHeight = scrollView.bounds.height * 0.9
        let maxY = scrollView.contentSize.height - scrollView.bounds.height
        let newY = min(scrollView.contentOffset.y + pageHeight, maxY)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: true)
    }

    /// Scroll the PDF up by one viewport height (with slight overlap).
    func scrollPageUp() {
        guard let scrollView = findScrollView() else { return }
        let pageHeight = scrollView.bounds.height * 0.9
        let newY = max(scrollView.contentOffset.y - pageHeight, 0)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: true)
    }

    /// PDFView embeds a UIScrollView as a subview; find it by traversal.
    private func findScrollView() -> UIScrollView? {
        guard let pdfView else { return nil }
        for subview in pdfView.subviews {
            if let scrollView = subview as? UIScrollView {
                return scrollView
            }
        }
        return nil
    }
}

struct PDFBookView: View {
    let book: Book
    let bookURL: URL
    @ObservedObject var controller: LibraryController
    let syncToken: UUID?
    @StateObject private var scrollProxy = PDFScrollProxy()

    @State private var showSearch = false
    @State private var searchText = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PDFReaderRepresentable(
                documentURL: bookURL,
                initialPageIndex: book.progressState?.pdfPageIndex ?? 0,
                initialPageOffsetY: book.progressState?.pdfPageOffsetY ?? 0,
                externalJumpToken: syncToken,
                externalPageIndex: book.progressState?.pdfPageIndex ?? 0,
                externalPageOffsetY: book.progressState?.pdfPageOffsetY ?? 0,
                scrollProxy: scrollProxy,
                onContentTapped: {
                    // Clicking content during search confirms the current
                    // position as the new reading location.
                    guard showSearch else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        confirmSearchPosition()
                    }
                }
            ) { pageIndex, pageCount, pageOffsetY in
                controller.savePDFPosition(for: book, pageIndex: pageIndex, pageCount: pageCount, pageOffsetY: pageOffsetY)
                // Update title progress only when not searching, so the title
                // reflects the actual reading position rather than search matches.
                if !showSearch {
                    let readingPosition = PDFReadingPosition(
                        pageIndex: pageIndex,
                        pageCount: pageCount,
                        pageOffsetY: pageOffsetY
                    )
                    controller.openBookProgress = readingPosition.progress.clampedToUnit
                }
            }

            if showSearch {
                ReaderSearchBar(
                    searchText: $searchText,
                    matchCount: scrollProxy.searchSelections.count,
                    currentMatchIndex: scrollProxy.searchCurrentIndex,
                    hasActiveSearch: !scrollProxy.lastSearchText.isEmpty
                        && scrollProxy.lastSearchText == searchText,
                    onSearchOrNext: { handleSearchOrNext() },
                    onNext: { scrollProxy.nextSearchMatch() },
                    onPrevious: { scrollProxy.previousSearchMatch() },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            dismissSearch()
                        }
                    }
                )
                .padding(.top, 8)
                .padding(.trailing, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Cmd+F toggle button — invisible, uses .keyboardShortcut so it
            // works regardless of which view currently has focus (unlike
            // .onKeyPress which requires the view to be focused, and breaks
            // on Mac Catalyst after the search bar is dismissed).
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if showSearch {
                        dismissSearch()
                    } else {
                        openSearch()
                    }
                }
            } label: {
                EmptyView()
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .focusable()
        .onKeyPress(.space, phases: .down) { keyPress in
            // Don't intercept Space when search bar is active (user is typing).
            guard !showSearch else { return .ignored }
            // Space scrolls down, Shift+Space scrolls up (like macOS Preview).
            if keyPress.modifiers.contains(.shift) {
                scrollProxy.scrollPageUp()
            } else {
                scrollProxy.scrollPageDown()
            }
            return .handled
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: book.id) {
            controller.markOpened(book)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func openSearch() {
        // Save position before searching so we can restore on dismiss.
        scrollProxy.savePosition()
        // Pre-fill with the last searched text (stays empty if no prior search).
        searchText = scrollProxy.lastSearchText
        showSearch = true
    }

    /// Enter in the search bar: perform a new search if the text changed,
    /// or navigate to the next match if the same text is already searched.
    private func handleSearchOrNext() {
        guard !searchText.isEmpty else { return }
        if searchText == scrollProxy.lastSearchText && !scrollProxy.searchSelections.isEmpty {
            scrollProxy.nextSearchMatch()
        } else {
            scrollProxy.search(for: searchText)
        }
    }

    private func dismissSearch() {
        showSearch = false
        // Restore the reading position from before search was opened.
        scrollProxy.clearSearch()
        scrollProxy.restorePosition()
        // Keep searchText on the proxy's lastSearchText for next open,
        // but clear the local binding.
        searchText = ""
    }

    /// Confirms the current scroll position as the new reading location.
    /// Called when the user clicks on content during search — hides the search bar,
    /// clears highlights, but keeps the current position instead of restoring
    /// the pre-search location.
    private func confirmSearchPosition() {
        showSearch = false
        scrollProxy.clearSearch()
        scrollProxy.discardSavedPosition()
        searchText = ""
        // Directly compute and set the title progress from the current PDFView
        // position. We can't rely on the debounced position notification because
        // the coordinator deduplicates unchanged positions, and the user may not
        // have scrolled since the last emit.
        guard let readingPosition = scrollProxy.pdfView?.readingPosition() else { return }

        controller.savePDFPosition(
            for: book,
            pageIndex: readingPosition.pageIndex,
            pageCount: readingPosition.pageCount,
            pageOffsetY: readingPosition.pageOffsetY
        )
        controller.openBookProgress = readingPosition.progress.clampedToUnit
    }
}

struct PDFReaderRepresentable: UIViewRepresentable {
    let documentURL: URL
    let initialPageIndex: Int
    /// Normalized Y offset within the initial page (0 = top, 1 = bottom).
    let initialPageOffsetY: Double
    /// External-sync token; when changed, jump to the provided page+offset.
    let externalJumpToken: UUID?
    let externalPageIndex: Int
    let externalPageOffsetY: Double
    let scrollProxy: PDFScrollProxy
    /// Called when the user taps on the PDF content area.
    let onContentTapped: () -> Void
    /// Callback: (pageIndex, pageCount, normalizedPageOffsetY)
    let onPositionChange: (Int, Int, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPositionChange: onPositionChange, onContentTapped: onContentTapped)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView(frame: .zero)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .secondarySystemBackground
        // Wire up the scroll proxy so SwiftUI key events can drive scrolling.
        scrollProxy.pdfView = pdfView
        // Tap gesture to detect content clicks (used to confirm search position).
        // cancelsTouchesInView=false so it doesn't interfere with text selection or links.
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleContentTap))
        tapGesture.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(tapGesture)
        context.coordinator.install(
            documentURL: documentURL,
            initialPageIndex: initialPageIndex,
            initialPageOffsetY: initialPageOffsetY,
            in: pdfView
        )
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPositionChange = onPositionChange
        context.coordinator.onContentTapped = onContentTapped
        scrollProxy.pdfView = pdfView
        context.coordinator.install(
            documentURL: documentURL,
            initialPageIndex: initialPageIndex,
            initialPageOffsetY: initialPageOffsetY,
            in: pdfView
        )
        context.coordinator.applyExternalJumpIfNeeded(
            token: externalJumpToken,
            pageIndex: externalPageIndex,
            pageOffsetY: externalPageOffsetY
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPositionChange: (Int, Int, Double) -> Void
        /// Called when the user taps on the PDF content area.
        var onContentTapped: () -> Void

        private weak var pdfView: PDFView?
        private var currentDocumentURL: URL?
        private var pageChangedObserver: NSObjectProtocol?
        /// Observes the underlying UIScrollView to detect intra-page scrolling.
        private var scrollObserver: NSObjectProtocol?
        private var lastSentPageIndex: Int?
        private var lastSentOffsetY: Double?
        private var appliedExternalJumpToken: UUID?

        /// Debounce timer for scroll-based position saves to avoid excessive writes.
        private var scrollDebounceTimer: Timer?
        private static let scrollDebounceInterval: TimeInterval = 0.5

        init(onPositionChange: @escaping (Int, Int, Double) -> Void, onContentTapped: @escaping () -> Void) {
            self.onPositionChange = onPositionChange
            self.onContentTapped = onContentTapped
        }

        /// Handles tap gesture on the PDF content area.
        @objc func handleContentTap() {
            onContentTapped()
        }

        func install(documentURL: URL, initialPageIndex: Int, initialPageOffsetY: Double, in pdfView: PDFView) {
            guard currentDocumentURL != documentURL else {
                return
            }

            currentDocumentURL = documentURL
            self.pdfView = pdfView
            lastSentPageIndex = nil
            lastSentOffsetY = nil
            scrollDebounceTimer?.invalidate()
            pdfView.document = PDFDocument(url: documentURL)

            // Remove old observers.
            if let pageChangedObserver {
                NotificationCenter.default.removeObserver(pageChangedObserver)
            }
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }

            // Observe page changes (fires when the "current page" changes).
            pageChangedObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePositionUpdate()
                }
            }

            // Observe visible-pages changes — fires on any scroll, including intra-page.
            // This is what enables sub-page offset tracking.
            scrollObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewVisiblePagesChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePositionUpdate()
                }
            }

            // Restore saved position: go to the exact page + offset.
            Task { @MainActor [weak self, weak pdfView] in
                guard let self, let pdfView, let document = pdfView.document else {
                    return
                }
                let pageCount = document.pageCount
                let safeIndex = min(max(initialPageIndex, 0), max(pageCount - 1, 0))
                if let page = document.page(at: safeIndex) {
                    if initialPageOffsetY > 0 {
                        // Restore sub-page position using PDFDestination.
                        // PDF coordinate system has origin at bottom-left, so Y increases upward.
                        let pageHeight = page.bounds(for: .mediaBox).height
                        // offsetY=0 means top of page, which in PDF coords is the max Y value.
                        let pdfY = pageHeight * (1.0 - initialPageOffsetY)
                        let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pdfY))
                        pdfView.go(to: destination)
                    } else {
                        pdfView.go(to: page)
                    }
                }
                self.emitPosition()
            }
        }

        /// Debounce scroll events: reset the timer on each scroll, fire after the interval.
        private func schedulePositionUpdate() {
            scrollDebounceTimer?.invalidate()
            scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.scrollDebounceInterval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.emitPosition()
                }
            }
        }

        /// Compute and emit the current position (page index + sub-page offset).
        /// Uses `currentDestination` for both page and offset to ensure they are
        /// consistent — `currentPage` can flip to the next page before the
        /// destination point catches up, causing progress to jump back and forth.
        private func emitPosition() {
            guard let pdfView else { return }
            guard let readingPosition = pdfView.readingPosition() else { return }

            // Deduplicate: skip if page and offset haven't meaningfully changed.
            let offsetThreshold = 0.005
            if lastSentPageIndex == readingPosition.pageIndex,
                let lastOffset = lastSentOffsetY,
                abs(lastOffset - readingPosition.pageOffsetY) < offsetThreshold
            {
                return
            }

            lastSentPageIndex = readingPosition.pageIndex
            lastSentOffsetY = readingPosition.pageOffsetY
            onPositionChange(
                readingPosition.pageIndex,
                readingPosition.pageCount,
                readingPosition.pageOffsetY
            )
        }

        func applyExternalJumpIfNeeded(token: UUID?, pageIndex: Int, pageOffsetY: Double) {
            guard let token, token != appliedExternalJumpToken else { return }
            appliedExternalJumpToken = token
            guard let pdfView, let document = pdfView.document else { return }

            let safeIndex = min(max(pageIndex, 0), max(document.pageCount - 1, 0))
            guard let page = document.page(at: safeIndex) else { return }

            if pageOffsetY > 0 {
                let pageHeight = page.bounds(for: .mediaBox).height
                let pdfY = pageHeight * (1.0 - pageOffsetY.clampedToUnit)
                let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pdfY))
                pdfView.go(to: destination)
            } else {
                pdfView.go(to: page)
            }
            emitPosition()
        }
    }
}

private extension PDFView {
    /// Sample the top edge of the viewport instead of PDFKit's current page
    /// bookkeeping so page index and within-page offset stay in sync.
    func readingPosition() -> PDFReadingPosition? {
        guard let document else { return nil }

        let topCenter = CGPoint(x: bounds.midX, y: bounds.minY)
        guard let page = page(for: topCenter, nearest: true) else { return nil }

        let pagePoint = convert(topCenter, to: page)
        let pageHeight = page.bounds(for: .mediaBox).height
        let pageOffsetY = pageHeight > 0 ? (1.0 - (pagePoint.y / pageHeight)).clampedToUnit : 0

        return PDFReadingPosition(
            pageIndex: document.index(for: page),
            pageCount: document.pageCount,
            pageOffsetY: pageOffsetY
        )
    }
}
