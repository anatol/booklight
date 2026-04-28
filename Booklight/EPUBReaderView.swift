import SwiftUI
import WebKit

/// Proxy object that bridges SwiftUI key events to the underlying WKWebView,
/// allowing Space / Shift+Space to scroll by one viewport height and
/// Shift+"+"/"-" to adjust font size.
/// Also manages in-document text search via injected JavaScript.
@MainActor
final class EPUBScrollProxy: ObservableObject {
    weak var webView: WKWebView?

    /// Current font size as a percentage of the default (100%). Range: 50–200%.
    @Published var fontSizePercent: Int = 100

    // MARK: - Search state

    /// Number of matches found for the current search query.
    @Published var searchMatchCount: Int = 0
    /// Zero-based index of the currently highlighted match.
    @Published var searchCurrentIndex: Int = 0
    /// The text that was last searched, used to detect whether a new search
    /// is needed or we can just navigate between existing results.
    var lastSearchText: String = ""

    private static let minFontSize = 50
    private static let maxFontSize = 200
    private static let fontSizeStep = 10

    // MARK: - Position save/restore (for returning to pre-search position)

    /// Saved chapter-based progress from before the search was opened,
    /// captured via `computeCenterProgress()` so we can restore on dismiss.
    private var savedProgressJSON: String?

    /// Saves the current scroll position so it can be restored later.
    /// Uses the chapter-based progress (robust across font size changes).
    func savePosition() {
        webView?.evaluateJavaScript("JSON.stringify(window.computeCenterProgress())") { [weak self] result, _ in
            Task { @MainActor [weak self] in
                self?.savedProgressJSON = result as? String
            }
        }
    }

    /// Restores the scroll position saved by `savePosition()`,
    /// returning the user to where they were before searching.
    func restorePosition() {
        guard let json = savedProgressJSON else { return }
        webView?.evaluateJavaScript("window.restoreCenterProgress(\(json));")
        savedProgressJSON = nil
    }

    /// Discards the saved position without restoring it.
    /// Used when the user confirms they want to stay at the current location
    /// (e.g. by clicking on the content during search).
    func discardSavedPosition() {
        savedProgressJSON = nil
    }

    // MARK: - Search

    /// Performs a case-insensitive search in the EPUB content using injected JavaScript.
    /// Highlights all matches with yellow and the current match with orange.
    func search(for text: String) {
        guard let webView else {
            searchMatchCount = 0
            searchCurrentIndex = 0
            return
        }

        lastSearchText = text

        // Escape single quotes and backslashes for safe JS string interpolation.
        let escaped =
            text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let js = "window._bookSearch.search('\(escaped)');"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let dict = result as? [String: Any],
                    let count = dict["count"] as? Int
                {
                    self.searchMatchCount = count
                    self.searchCurrentIndex = count > 0 ? 0 : 0
                } else {
                    self.searchMatchCount = 0
                    self.searchCurrentIndex = 0
                }
            }
        }
    }

    /// Navigates to the next search match, wrapping around at the end.
    func nextSearchMatch() {
        guard searchMatchCount > 0 else { return }
        let nextIndex = (searchCurrentIndex + 1) % searchMatchCount
        goToMatch(nextIndex)
    }

    /// Navigates to the previous search match, wrapping around at the start.
    func previousSearchMatch() {
        guard searchMatchCount > 0 else { return }
        let prevIndex = (searchCurrentIndex - 1 + searchMatchCount) % searchMatchCount
        goToMatch(prevIndex)
    }

    /// Clears all search highlights from the DOM and resets search state.
    /// Does NOT clear `lastSearchText` so it persists for the next search open.
    func clearSearch() {
        searchMatchCount = 0
        searchCurrentIndex = 0
        webView?.evaluateJavaScript("window._bookSearch.clear();")
    }

    /// Scrolls to and highlights the match at the given index.
    private func goToMatch(_ index: Int) {
        searchCurrentIndex = index
        webView?.evaluateJavaScript("window._bookSearch.goTo(\(index));")
    }

    // MARK: - Scrolling

    /// Scroll the EPUB content down by ~90% of the viewport (slight overlap for context).
    func scrollPageDown() {
        webView?.evaluateJavaScript("window.scrollBy(0, window.innerHeight * 0.9)")
    }

    /// Scroll the EPUB content up by ~90% of the viewport.
    func scrollPageUp() {
        webView?.evaluateJavaScript("window.scrollBy(0, -window.innerHeight * 0.9)")
    }

    // MARK: - Font size

    /// Increase font size by one step (10%), capped at 200%.
    func increaseFontSize() {
        fontSizePercent = min(fontSizePercent + Self.fontSizeStep, Self.maxFontSize)
        applyFontSize()
    }

    /// Decrease font size by one step (10%), floored at 50%.
    func decreaseFontSize() {
        fontSizePercent = max(fontSizePercent - Self.fontSizeStep, Self.minFontSize)
        applyFontSize()
    }

    /// Injects CSS to override the root font size, preserving the current reading position.
    /// Uses both font-size on <html> (works for em/rem-based EPUBs) and
    /// -webkit-text-size-adjust on <body> (works for EPUBs using absolute px sizing).
    ///
    /// To keep the reading position stable across the text reflow caused by a font size change,
    /// we record the progress ratio (scrollY / maxScroll) before the change and restore
    /// the equivalent scroll offset after the DOM reflows.
    func applyFontSize() {
        let js = """
            (function() {
                // Remember the current reading position as a fraction of total scrollable height.
                var root = document.documentElement;
                var maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                var progressRatio = window.scrollY / maxScroll;

                // Apply the new font size.
                root.style.fontSize = '\(fontSizePercent)%';
                document.body.style.webkitTextSizeAdjust = '\(fontSizePercent)%';

                // After the DOM reflows, restore the reading position.
                // Prefer the fine-grained center progress, or fallback to ratio.
                requestAnimationFrame(function() {
                    if (window.currentCenterProgress && typeof window.restoreCenterProgress === 'function') {
                        window.restoreCenterProgress(window.currentCenterProgress);
                    } else {
                        var newMaxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                        window.scrollTo(0, newMaxScroll * progressRatio);
                    }
                });
            })();
            """
        webView?.evaluateJavaScript(js)
    }
}

struct EPUBBookView: View {
    let book: Book
    let bookURL: URL
    @ObservedObject var controller: LibraryController

    @State private var document: EPUBDocument?
    @State private var loadError: String?
    @State private var isPreparing = true
    /// Initial scroll target computed from saved progress when the document loads.
    @State private var initialScrollTarget: EPUBScrollTarget?
    @StateObject private var scrollProxy = EPUBScrollProxy()

    @State private var showSearch = false
    @State private var searchText = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let document {
                    EPUBWebView(
                        document: document,
                        initialScrollTarget: initialScrollTarget,
                        scrollProxy: scrollProxy,
                        initialFontSizePercent: scrollProxy.fontSizePercent,
                        onContentTapped: {
                            // Clicking content during search confirms the current
                            // position as the new reading location.
                            guard showSearch else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                confirmSearchPosition()
                            }
                        }
                    ) { chapterIndex, chapterProgress, overallProgress in
                        // Clamp values to valid ranges before persisting.
                        let clampedIndex = min(max(chapterIndex, 0), max(document.spine.count - 1, 0))
                        let clampedChapterProgress = chapterProgress.clampedToUnit
                        let clampedOverall = overallProgress.clampedToUnit

                        controller.saveEPUBPosition(
                            for: book,
                            chapterIndex: clampedIndex,
                            chapterPath: document.spine[clampedIndex].href,
                            chapterProgress: clampedChapterProgress,
                            overallProgress: clampedOverall
                        )
                        // Update title progress only when not searching, so the title
                        // reflects the actual reading position rather than search matches.
                        if !showSearch {
                            controller.openBookProgress = clampedOverall
                        }
                    }
                } else if isPreparing {
                    ProgressView("Opening EPUB…")
                } else {
                    ContentUnavailableView(
                        "Could Not Open EPUB", systemImage: "exclamationmark.triangle", description: Text(loadError ?? "Unknown error"))
                }
            }

            if showSearch {
                ReaderSearchBar(
                    searchText: $searchText,
                    matchCount: scrollProxy.searchMatchCount,
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
            // .onKeyPress which breaks on Mac Catalyst after dismiss).
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
        // Shift+"+" increases font size, Shift+"-" (or just "-") decreases it.
        .onKeyPress(characters: .init(charactersIn: "+="), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.shift) else { return .ignored }
            scrollProxy.increaseFontSize()
            controller.saveEPUBFontSize(for: book, fontSizePercent: scrollProxy.fontSizePercent)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "-_"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.shift) else { return .ignored }
            scrollProxy.decreaseFontSize()
            controller.saveEPUBFontSize(for: book, fontSizePercent: scrollProxy.fontSizePercent)
            return .handled
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: book.id) {
            // Restore saved font size preference before the document loads,
            // so it's ready to apply when the web view finishes navigation.
            scrollProxy.fontSizePercent = book.progressState?.epubFontSizePercent ?? 100
            controller.markOpened(book)
            await loadDocument()
        }
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
        if searchText == scrollProxy.lastSearchText && scrollProxy.searchMatchCount > 0 {
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
    /// the pre-search location. Triggers a progress report so the title and
    /// saved position update immediately.
    private func confirmSearchPosition() {
        showSearch = false
        scrollProxy.clearSearch()
        scrollProxy.discardSavedPosition()
        searchText = ""
        // Force an immediate progress report so the title bar and persisted
        // position reflect the newly confirmed reading location.
        scrollProxy.webView?.evaluateJavaScript("sendProgress();")
    }

    private func loadDocument() async {
        isPreparing = true
        loadError = nil

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try EPUBPreparation.prepareDocument(for: book, sourceURL: bookURL)
            }.value

            await MainActor.run {
                document = prepared

                let storedOverall = book.progressState?.progress ?? 0
                let storedChapterPath = book.progressState?.epubChapterPath
                let storedChapterIndex = book.progressState?.epubChapterIndex ?? 0
                let storedChapterProgress = book.progressState?.epubChapterProgress ?? 0

                // Resolve the chapter index, preferring path-based lookup for robustness
                // (handles chapter reordering in updated EPUBs).
                let resolvedIndex: Int
                if let storedChapterPath,
                    let pathIndex = prepared.spine.firstIndex(where: { $0.href == storedChapterPath })
                {
                    resolvedIndex = pathIndex
                } else {
                    resolvedIndex = min(max(storedChapterIndex, 0), max(prepared.spine.count - 1, 0))
                }

                initialScrollTarget = EPUBScrollTarget(
                    overallProgress: storedOverall,
                    chapterIndex: resolvedIndex,
                    chapterProgress: storedChapterProgress
                )
                isPreparing = false
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isPreparing = false
            }
        }
    }
}

/// Describes where to scroll when the combined document finishes loading.
/// Uses chapterIndex and chapterProgress as the reliable targets for positioning,
/// while overallProgress is passed along but not used for exact coordinate calculation.
private struct EPUBScrollTarget: Equatable {
    var token = UUID()
    var overallProgress: Double
    var chapterIndex: Int
    var chapterProgress: Double
}

// MARK: - WKWebView wrapper for continuous EPUB scrolling

private struct EPUBWebView: UIViewRepresentable {
    let document: EPUBDocument
    let initialScrollTarget: EPUBScrollTarget?
    let scrollProxy: EPUBScrollProxy
    /// Initial font size percentage to apply after the document loads.
    let initialFontSizePercent: Int
    /// Called when the user clicks/taps on the content area (not text selection).
    let onContentTapped: () -> Void
    /// Called with (chapterIndex, chapterProgress, overallProgress) as the user scrolls.
    let onProgressChange: (Int, Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            document: document, initialFontSizePercent: initialFontSizePercent, onProgressChange: onProgressChange,
            onContentTapped: onContentTapped)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "readerProgress")
        contentController.add(context.coordinator, name: "contentTapped")
        // Inject search functionality (must run before scroll tracking so it's
        // available when the page loads, but after the DOM is ready).
        contentController.addUserScript(
            WKUserScript(
                source: Self.searchScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        contentController.addUserScript(
            WKUserScript(
                source: Self.scrollTrackingScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Wire up scroll proxy so SwiftUI key events can drive scrolling.
        scrollProxy.webView = webView
        context.coordinator.attach(webView)
        context.coordinator.loadCombinedDocument(scrollTarget: initialScrollTarget)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.document = document
        context.coordinator.onProgressChange = onProgressChange
        context.coordinator.onContentTapped = onContentTapped
        scrollProxy.webView = webView
        context.coordinator.loadCombinedDocument(scrollTarget: initialScrollTarget)
    }

    // MARK: - JavaScript for in-document text search

    /// Provides search-and-highlight functionality using DOM TreeWalker.
    /// Wraps each match in a <mark> element with CSS classes for styling.
    /// The current match gets an additional "current" class with an orange background.
    static let searchScript = """
        (function() {
            // Inject search highlight CSS.
            var style = document.createElement('style');
            style.textContent = `
                mark.search-hl { background-color: rgba(255, 255, 0, 0.5); color: inherit; padding: 0; border-radius: 2px; }
                mark.search-hl.current { background-color: rgba(255, 149, 0, 0.7); color: inherit; }
            `;
            document.head.appendChild(style);

            window._bookSearch = {
                _matches: [],
                _currentIndex: -1,

                // Remove all <mark class="search-hl"> elements, restoring original text nodes.
                clear: function() {
                    document.querySelectorAll('mark.search-hl').forEach(function(mark) {
                        var parent = mark.parentNode;
                        parent.replaceChild(document.createTextNode(mark.textContent), mark);
                        // Merge adjacent text nodes back together.
                        parent.normalize();
                    });
                    this._matches = [];
                    this._currentIndex = -1;
                    return { count: 0 };
                },

                // Search all text nodes for the query (case-insensitive).
                // Returns { count: N } with the number of matches found.
                search: function(query) {
                    this.clear();
                    if (!query) return { count: 0 };

                    var lowerQuery = query.toLowerCase();
                    var matches = [];

                    // Collect all text nodes that contain the query.
                    var walker = document.createTreeWalker(
                        document.body, NodeFilter.SHOW_TEXT, null, false
                    );
                    var textNodes = [];
                    while (walker.nextNode()) {
                        if (walker.currentNode.nodeValue.toLowerCase().indexOf(lowerQuery) !== -1) {
                            textNodes.push(walker.currentNode);
                        }
                    }

                    // Wrap each occurrence in a <mark> element.
                    for (var t = 0; t < textNodes.length; t++) {
                        var node = textNodes[t];
                        var text = node.nodeValue;
                        var lower = text.toLowerCase();
                        var fragment = document.createDocumentFragment();
                        var lastIndex = 0;
                        var idx;

                        while ((idx = lower.indexOf(lowerQuery, lastIndex)) !== -1) {
                            // Text before the match.
                            if (idx > lastIndex) {
                                fragment.appendChild(document.createTextNode(text.substring(lastIndex, idx)));
                            }
                            // The match itself, wrapped in <mark>.
                            var mark = document.createElement('mark');
                            mark.className = 'search-hl';
                            mark.textContent = text.substring(idx, idx + query.length);
                            fragment.appendChild(mark);
                            matches.push(mark);
                            lastIndex = idx + query.length;
                        }

                        // Remaining text after the last match.
                        if (lastIndex < text.length) {
                            fragment.appendChild(document.createTextNode(text.substring(lastIndex)));
                        }

                        node.parentNode.replaceChild(fragment, node);
                    }

                    this._matches = matches;
                    // Automatically navigate to the first match.
                    if (matches.length > 0) {
                        this.goTo(0);
                    }
                    return { count: matches.length };
                },

                // Navigate to the match at the given index and scroll it into view.
                goTo: function(index) {
                    if (!this._matches.length || index < 0 || index >= this._matches.length) return;

                    // Remove "current" class from the previous match.
                    if (this._currentIndex >= 0 && this._currentIndex < this._matches.length) {
                        this._matches[this._currentIndex].classList.remove('current');
                    }

                    this._currentIndex = index;
                    var match = this._matches[index];
                    match.classList.add('current');
                    match.scrollIntoView({ behavior: 'smooth', block: 'center' });
                }
            };
        })();
        """

    // MARK: - JavaScript for tracking scroll position across combined chapters

    /// Tracks the overall scroll progress and determines which chapter div is currently
    /// visible at the top of the viewport. Posts a JSON message with chapterIndex,
    /// chapterProgress (within that chapter), and overallProgress (across entire document).
    static let scrollTrackingScript = """
        window.isReadyForProgress = false;
        window.currentCenterProgress = null;
        let resizeState = { isResizing: false, resizeTimeout: null };

        window.computeCenterProgress = () => {
          const centerY = window.innerHeight / 2;
          const chapters = document.querySelectorAll('.epub-chapter');
          let currentChapter = 0;
          let chapterProgress = 0;
          for (let i = chapters.length - 1; i >= 0; i--) {
            const rect = chapters[i].getBoundingClientRect();
            if (rect.top <= centerY) {
              currentChapter = parseInt(chapters[i].dataset.chapterIndex) || 0;
              const chapterHeight = Math.max(rect.height, 1);
              chapterProgress = Math.max(0, Math.min(1, (centerY - rect.top) / chapterHeight));
              break;
            }
          }
          return { chapterIndex: currentChapter, chapterProgress: chapterProgress };
        };

        window.restoreCenterProgress = (target) => {
          if (!target) return;
          const chapter = document.getElementById('chapter-' + target.chapterIndex);
          if (chapter) {
            const rect = chapter.getBoundingClientRect();
            const chapterHeight = Math.max(rect.height, 1);
            const offset = chapterHeight * target.chapterProgress;
            window.scrollTo(0, window.scrollY + rect.top + offset - window.innerHeight / 2);
          }
        };

        const sendProgress = () => {
          if (!window.isReadyForProgress) return;

          const root = document.documentElement;
          const maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
          const overallProgress = Math.max(0, Math.min(1, window.scrollY / maxScroll));

          if (!resizeState.isResizing) {
              window.currentCenterProgress = window.computeCenterProgress();
          }

          if (!window.currentCenterProgress) return;

          window.webkit.messageHandlers.readerProgress.postMessage({
            chapterIndex: window.currentCenterProgress.chapterIndex,
            chapterProgress: window.currentCenterProgress.chapterProgress,
            overallProgress: overallProgress
          });
        };

        let scrollTimeout = null;
        window.addEventListener('scroll', () => {
          if (!resizeState.isResizing) {
              window.currentCenterProgress = window.computeCenterProgress();
          }
          if (scrollTimeout) return;
          scrollTimeout = setTimeout(() => {
            scrollTimeout = null;
            sendProgress();
          }, 120);
        }, { passive: true });

        window.addEventListener('resize', () => {
          resizeState.isResizing = true;
          if (window.currentCenterProgress) {
            window.restoreCenterProgress(window.currentCenterProgress);
          }
          clearTimeout(resizeState.resizeTimeout);
          resizeState.resizeTimeout = setTimeout(() => {
            resizeState.isResizing = false;
            sendProgress();
          }, 200);
        });

        window.addEventListener('load', () => setTimeout(() => {
            if (!window.currentCenterProgress) {
                window.currentCenterProgress = window.computeCenterProgress();
            }
            sendProgress();
        }, 80));

        // Notify native code when user clicks on content (not a text drag/selection).
        // Used to confirm the current position as the new reading location during search.
        document.addEventListener('click', function() {
            var sel = window.getSelection();
            if (sel && sel.toString().length > 0) return;
            window.webkit.messageHandlers.contentTapped.postMessage({});
        });
        """

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var document: EPUBDocument
        var onProgressChange: (Int, Double, Double) -> Void
        /// Called when the user clicks/taps on the EPUB content area.
        var onContentTapped: () -> Void

        private weak var webView: WKWebView?
        /// Tracks whether the combined document has been loaded to avoid redundant loads.
        private var currentToken: UUID?
        /// The scroll target to restore after the document finishes loading.
        private var pendingScrollTarget: EPUBScrollTarget?
        /// Font size percentage to apply after document load (restored from saved state).
        private var initialFontSizePercent: Int

        init(
            document: EPUBDocument, initialFontSizePercent: Int, onProgressChange: @escaping (Int, Double, Double) -> Void,
            onContentTapped: @escaping () -> Void
        ) {
            self.document = document
            self.initialFontSizePercent = initialFontSizePercent
            self.onProgressChange = onProgressChange
            self.onContentTapped = onContentTapped
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        /// Loads the combined HTML document if not already loaded.
        func loadCombinedDocument(scrollTarget: EPUBScrollTarget?) {
            let token = scrollTarget?.token
            guard currentToken != token else { return }
            currentToken = token
            pendingScrollTarget = scrollTarget

            webView?.loadFileURL(
                document.combinedHTMLURL,
                allowingReadAccessTo: document.extractedRootURL
            )
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let target = pendingScrollTarget else { return }

            // Apply saved font size FIRST so the DOM reflows before we compute
            // scroll offsets — otherwise the position would be wrong for the
            // final layout.
            let fontSizeJS: String
            if initialFontSizePercent != 100 {
                fontSizeJS = """
                    document.documentElement.style.fontSize = '\(initialFontSizePercent)%';
                    document.body.style.webkitTextSizeAdjust = '\(initialFontSizePercent)%';
                    """
            } else {
                fontSizeJS = ""
            }

            // Always use chapter-based scrolling. It is much more robust against
            // changes in text size, display area, and partial loading than `overallProgress`,
            // which can point to arbitrary offsets if layout parameters change.
            let scrollJS: String

            // Scroll to the chapter element and then offset by chapter progress.
            scrollJS = """
                const chapter = document.getElementById('chapter-\(target.chapterIndex)');
                if (chapter) {
                    const rect = chapter.getBoundingClientRect();
                    const chapterHeight = Math.max(rect.height, 1);
                    const offset = chapterHeight * \(target.chapterProgress.clampedToUnit);
                    window.scrollTo(0, window.scrollY + rect.top + offset - window.innerHeight / 2);
                } else {
                    const root = document.documentElement;
                    const maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                    window.scrollTo(0, maxScroll * \(target.overallProgress.clampedToUnit));
                }
                window.currentCenterProgress = {
                    chapterIndex: \(target.chapterIndex),
                    chapterProgress: \(target.chapterProgress.clampedToUnit)
                };
                """

            // Apply font size first, then scroll after reflow completes.
            if fontSizeJS.isEmpty {
                webView.evaluateJavaScript(scrollJS) { _, _ in
                    webView.evaluateJavaScript("window.isReadyForProgress = true; sendProgress();")
                }
            } else {
                webView.evaluateJavaScript(fontSizeJS) { _, _ in
                    // Use requestAnimationFrame to ensure the DOM has reflowed
                    // with the new font size before computing scroll position.
                    let wrappedScroll =
                        "requestAnimationFrame(function() { \(scrollJS); setTimeout(() => { window.isReadyForProgress = true; sendProgress(); }, 50); });"
                    webView.evaluateJavaScript(wrappedScroll)
                }
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "contentTapped" {
                onContentTapped()
                return
            }

            guard message.name == "readerProgress",
                let body = message.body as? [String: Any],
                let chapterIndex = body["chapterIndex"] as? Int,
                let chapterProgress = body["chapterProgress"] as? Double,
                let overallProgress = body["overallProgress"] as? Double
            else {
                return
            }
            onProgressChange(
                chapterIndex,
                chapterProgress.clampedToUnit,
                overallProgress.clampedToUnit
            )
        }
    }
}
