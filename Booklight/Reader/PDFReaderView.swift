@preconcurrency import PDFKit
import SwiftUI

/// Proxy object that bridges SwiftUI key events to the underlying PDFView,
/// allowing Space / Shift+Space to scroll by one viewport height.
/// Also manages in-document text search via PDFKit's built-in findString API.
@MainActor
@Observable
final class PDFScrollProxy: ReaderEngine {
    @ObservationIgnored weak var pdfView: PDFView?
    /// Set by the representable's coordinator; re-emits the current position.
    @ObservationIgnored var positionReporter: (() -> Void)?

    // MARK: - Search state

    /// All selections matching the current search query.
    var searchSelections: [PDFSelection] = []
    /// Zero-based index of the currently highlighted match.
    var searchCurrentIndex: Int = 0
    /// True while PDFKit is still scanning the document for matches.
    var isSearchInProgress = false
    /// The text that was last searched, used to detect whether a new search
    /// is needed or we can just navigate between existing results.
    var lastSearchText: String = ""
    @ObservationIgnored private var findObservers: [NSObjectProtocol] = []

    var searchMatchCount: Int { searchSelections.count }

    func reportCurrentPosition() {
        positionReporter?()
    }

    // MARK: - Table of contents

    /// The document outline flattened in reading order. Entries without a page
    /// destination are skipped.
    var tableOfContents: [ReaderTOCEntry] {
        guard let document = pdfView?.document, let root = document.outlineRoot else { return [] }
        var entries: [ReaderTOCEntry] = []
        func visit(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                if let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                    let destination = child.destination, let page = destination.page
                {
                    let pageIndex = document.index(for: page)
                    let height = page.bounds(for: .mediaBox).height
                    // A destination's point is in PDF space (origin bottom-left);
                    // unspecified coordinates come through as a huge sentinel.
                    let y = destination.point.y
                    let offsetY = (height > 0 && y >= 0 && y <= height) ? 1 - Double(y / height) : 0
                    entries.append(
                        ReaderTOCEntry(
                            id: entries.count, title: title, level: level,
                            destination: .pdf(pageIndex: pageIndex, offsetY: offsetY)))
                }
                visit(child, level: level + 1)
            }
        }
        visit(root, level: 0)
        return entries
    }

    func go(to entry: ReaderTOCEntry) {
        guard case .pdf(let pageIndex, let offsetY) = entry.destination else { return }
        pdfView?.go(toPageIndex: pageIndex, offsetY: offsetY)
    }

    // MARK: - Position save/restore (for returning to pre-search position)

    /// Saved PDF destination from before the search was opened,
    /// so we can return to the original reading position on dismiss.
    @ObservationIgnored private var savedDestination: PDFDestination?

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
    ///
    /// Uses PDFKit's asynchronous find: the synchronous `findString` blocks the
    /// main thread for seconds on large books. Matches stream in as they are
    /// found; the first one is shown immediately.
    func search(for text: String) {
        guard let pdfView, let document = pdfView.document else {
            clearSearch()
            return
        }

        // Clear previous highlights and stop any search still running.
        cancelFind()
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        searchSelections = []
        searchCurrentIndex = 0
        lastSearchText = text

        guard !text.isEmpty else { return }

        let center = NotificationCenter.default
        findObservers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
                // Delivered on the main queue (see `queue:`), so the selection
                // never actually crosses threads.
                nonisolated(unsafe) let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                MainActor.assumeIsolated {
                    guard let self, let selection else { return }
                    self.searchSelections.append(selection)
                    if self.searchSelections.count == 1 {
                        self.pdfView?.highlightedSelections = [selection]
                        self.goToMatch(0)
                    }
                }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSearchInProgress = false
                    self.removeFindObservers()
                    // Highlight everything once, rather than on every match.
                    if !self.searchSelections.isEmpty {
                        self.pdfView?.highlightedSelections = self.searchSelections
                    }
                }
            },
        ]
        isSearchInProgress = true
        document.beginFindString(text, withOptions: [.caseInsensitive])
    }

    /// Stops an in-progress asynchronous find.
    private func cancelFind() {
        if isSearchInProgress {
            pdfView?.document?.cancelFindString()
            isSearchInProgress = false
        }
        removeFindObservers()
    }

    private func removeFindObservers() {
        findObservers.forEach { NotificationCenter.default.removeObserver($0) }
        findObservers.removeAll()
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
        cancelFind()
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

    /// Jumps to an overall position using the same page-interval measure as
    /// `PDFReadingPosition.progress`.
    func seek(toProgress progress: Double) {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let intervals = Double(max(document.pageCount - 1, 1))
        let position = progress.clampedToUnit * intervals
        let pageIndex = min(Int(position), document.pageCount - 1)
        pdfView.go(toPageIndex: pageIndex, offsetY: position - Double(pageIndex))
    }

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

    /// Jump back to the previous PDF navigation destination (e.g. after links/find jumps).
    func jumpBack() {
        guard let pdfView, pdfView.canGoBack else { return }
        pdfView.goBack(nil)
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
    var library: LibraryModel
    /// Progress shown in the window title; only updated from real reading
    /// positions, not while search is jumping around.
    @Binding var displayedProgress: Double?
    let syncToken: UUID?
    @State private var session = ReaderSession(engine: PDFScrollProxy())

    var body: some View {
        ReaderScaffold(session: session, progress: displayedProgress) {
            PDFReaderRepresentable(
                documentURL: bookURL,
                initialPageIndex: book.progressState?.pdfPageIndex ?? 0,
                initialPageOffsetY: book.progressState?.pdfPageOffsetY ?? 0,
                externalJumpToken: syncToken,
                externalPageIndex: book.progressState?.pdfPageIndex ?? 0,
                externalPageOffsetY: book.progressState?.pdfPageOffsetY ?? 0,
                scrollProxy: session.engine,
                onContentTapped: {
                    // During search, a tap confirms the current position as the
                    // reading location; otherwise it toggles the reader bars.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        session.contentTapped()
                    }
                }
            ) { pageIndex, pageCount, pageOffsetY in
                library.savePDFPosition(for: book, pageIndex: pageIndex, pageCount: pageCount, pageOffsetY: pageOffsetY)
                // Update title progress only when not searching, so the title
                // reflects the actual reading position rather than search matches.
                if !session.isSearchVisible {
                    let readingPosition = PDFReadingPosition(
                        pageIndex: pageIndex,
                        pageCount: pageCount,
                        pageOffsetY: pageOffsetY
                    )
                    displayedProgress = readingPosition.progress.clampedToUnit
                }
            }
        }
        .task(id: book.id) {
            library.markOpened(book)
        }
        .background(Color(uiColor: .secondarySystemBackground))
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
        // The reader's own scrubber replaces the system scroll indicator. PDFView
        // creates its scroll view lazily, so look again once it has been laid out.
        func hideSystemIndicator(of pdfView: PDFView?) {
            pdfView?.subviews.compactMap { $0 as? UIScrollView }.forEach { $0.showsVerticalScrollIndicator = false }
        }
        hideSystemIndicator(of: pdfView)
        DispatchQueue.main.async { [weak pdfView] in hideSystemIndicator(of: pdfView) }
        // Wire up the scroll proxy so SwiftUI key events can drive scrolling.
        scrollProxy.pdfView = pdfView
        scrollProxy.positionReporter = { [weak coordinator = context.coordinator] in
            coordinator?.emitPosition(force: true)
        }
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

        /// True while the saved position is being re-applied during initial layout.
        private var isRestoring = false

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
                guard let self, let pdfView, pdfView.document != nil else {
                    return
                }
                pdfView.go(toPageIndex: initialPageIndex, offsetY: initialPageOffsetY)

                // The view is created at a provisional size and resized (which
                // rescales the page, since it auto-scales to width) a few hundred
                // milliseconds later; the point at the top then lands somewhere
                // else. Keep re-applying the saved position whenever the size
                // changes during the first 1.5 s, and report nothing meanwhile so
                // the saved value isn't overwritten with a mid-layout measurement.
                self.isRestoring = true
                defer { self.isRestoring = false }
                var appliedSize = pdfView.bounds.size
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if pdfView.bounds.size != appliedSize {
                        appliedSize = pdfView.bounds.size
                        pdfView.go(toPageIndex: initialPageIndex, offsetY: initialPageOffsetY)
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
        func emitPosition(force: Bool = false) {
            guard let pdfView, !isRestoring else { return }
            guard let readingPosition = pdfView.readingPosition() else { return }

            // Deduplicate: skip if page and offset haven't meaningfully changed.
            let offsetThreshold = 0.005
            if !force, lastSentPageIndex == readingPosition.pageIndex,
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
            guard let pdfView, pdfView.document != nil else { return }
            pdfView.go(toPageIndex: pageIndex, offsetY: pageOffsetY)
            emitPosition()
        }
    }
}

extension PDFView {
    /// Scrolls so the given page, `offsetY` of the way down it (0 = top), is at
    /// the top of the viewport.
    func go(toPageIndex pageIndex: Int, offsetY: Double) {
        guard let document, let page = document.page(at: min(max(pageIndex, 0), max(document.pageCount - 1, 0))) else { return }
        if offsetY > 0 {
            // PDF coordinates have their origin bottom-left, so the top of the
            // page is the maximum Y.
            let pageHeight = page.bounds(for: .mediaBox).height
            let pdfY = pageHeight * (1.0 - offsetY.clampedToUnit)
            go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: pdfY)))
        } else {
            go(to: page)
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
