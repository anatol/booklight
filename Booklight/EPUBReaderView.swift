import SwiftUI
import WebKit

/// Proxy object that bridges SwiftUI key events to the underlying WKWebView,
/// allowing Space / Shift+Space to scroll by one viewport height and
/// Shift+"+"/"-" to adjust font size.
/// Also manages in-document text search via injected JavaScript.
@MainActor
@Observable
final class EPUBScrollProxy {
    @ObservationIgnored weak var webView: WKWebView?

    /// Current font size as a percentage of the default (100%). Range: 50–200%.
    var fontSizePercent: Int = 100

    // MARK: - Search state

    /// Number of matches found for the current search query.
    var searchMatchCount: Int = 0
    /// Zero-based index of the currently highlighted match.
    var searchCurrentIndex: Int = 0
    /// The text that was last searched, used to detect whether a new search
    /// is needed or we can just navigate between existing results.
    var lastSearchText: String = ""

    private static let minFontSize = 50
    private static let maxFontSize = 200
    private static let fontSizeStep = 10

    // MARK: - Position save/restore (for returning to pre-search position)

    /// Saved chapter-based progress from before the search was opened,
    /// captured via `computeCenterProgress()` so we can restore on dismiss.
    @ObservationIgnored private var savedProgressJSON: String?

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

        // Pass the query as an argument rather than splicing it into the script,
        // so quotes, backslashes and newlines can't break (or inject) JavaScript.
        Task { [weak self, weak webView] in
            guard let webView else { return }
            let result = try? await webView.callAsyncJavaScript(
                "return window._bookSearch.search(query);",
                arguments: ["query": text],
                contentWorld: .page
            )
            guard let self, self.lastSearchText == text else { return }
            let count = (result as? [String: Any])?["count"] as? Int ?? 0
            self.searchMatchCount = count
            self.searchCurrentIndex = 0
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

    /// Jump back to where the reader was before the last followed internal link.
    /// Links never navigate the web view (see `linkScript`), so this pops the
    /// in-page jump stack instead of using WebKit's history.
    func jumpBack() {
        webView?.evaluateJavaScript("window.readerJumpBack && window.readerJumpBack();")
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

    /// The reading base font size (px) that corresponds to 100%. The combined HTML
    /// sets the same value on <html>, so the percentage controls scale a comfortable
    /// default rather than the browser's small 16px. Kept in sync with EPUBSupport's CSS.
    static let baseFontPx = 20

    /// Injects CSS to override the root font size, preserving the current reading position.
    /// Uses both font-size on <html> in px (works for em/rem-based EPUBs) and
    /// -webkit-text-size-adjust on <body> as a percentage (works for EPUBs using absolute px sizing).
    ///
    /// To keep the reading position stable across the text reflow caused by a font size change,
    /// we record the progress ratio (scrollY / maxScroll) before the change and restore
    /// the equivalent scroll offset after the DOM reflows.
    func applyFontSize() {
        let pixels = fontSizePercent * Self.baseFontPx / 100
        let js = """
            (function() {
                // Remember the current reading position as a fraction of total scrollable height.
                var root = document.documentElement;
                var maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                var progressRatio = window.scrollY / maxScroll;

                // Apply the new font size.
                root.style.fontSize = '\(pixels)px';
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
    var library: LibraryModel
    /// Progress shown in the window title; only updated from real reading
    /// positions, not while search is jumping around.
    @Binding var displayedProgress: Double?
    let syncToken: UUID?

    @State private var document: EPUBDocument?
    @State private var loadError: String?
    @State private var isPreparing = true
    /// Initial scroll target computed from saved progress when the document loads.
    @State private var initialScrollTarget: EPUBScrollTarget?
    @State private var scrollProxy = EPUBScrollProxy()

    @State private var showSearch = false
    @State private var searchText = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let document {
                    EPUBWebView(
                        document: document,
                        initialScrollTarget: initialScrollTarget,
                        externalScrollToken: syncToken,
                        externalChapterIndex: book.progressState?.epubChapterIndex ?? 0,
                        externalChapterProgress: book.progressState?.epubChapterProgress ?? 0,
                        externalOverallProgress: book.progressState?.progress ?? 0,
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

                        library.saveEPUBPosition(
                            for: book,
                            chapterIndex: clampedIndex,
                            chapterPath: document.spine[clampedIndex].href,
                            chapterProgress: clampedChapterProgress,
                            overallProgress: clampedOverall
                        )
                        // Update title progress only when not searching, so the title
                        // reflects the actual reading position rather than search matches.
                        if !showSearch {
                            displayedProgress = clampedOverall
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
            // Standard back-navigation shortcuts.
            Button {
                scrollProxy.jumpBack()
            } label: {
                EmptyView()
            }
            .keyboardShortcut("[", modifiers: .command)
            .hidden()
            Button {
                scrollProxy.jumpBack()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
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
            library.saveEPUBFontSize(for: book, fontSizePercent: scrollProxy.fontSizePercent)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "-_"), phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.shift) else { return .ignored }
            scrollProxy.decreaseFontSize()
            library.saveEPUBFontSize(for: book, fontSizePercent: scrollProxy.fontSizePercent)
            return .handled
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: book.id) {
            // Restore saved font size preference before the document loads,
            // so it's ready to apply when the web view finishes navigation.
            scrollProxy.fontSizePercent = book.progressState?.epubFontSizePercent ?? 100
            library.markOpened(book)
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
    let externalScrollToken: UUID?
    let externalChapterIndex: Int
    let externalChapterProgress: Double
    let externalOverallProgress: Double
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
        contentController.addUserScript(
            WKUserScript(
                source: Self.linkScript,
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
        context.coordinator.applyExternalScrollIfNeeded(
            token: externalScrollToken,
            chapterIndex: externalChapterIndex,
            chapterProgress: externalChapterProgress,
            overallProgress: externalOverallProgress
        )
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

    // MARK: - JavaScript for internal links

    /// Keeps link navigation inside the combined document. EPUB links point at
    /// individual chapter files (`ch2.xhtml#sec`) or at fragments within the
    /// current chapter (`#note1`); following them natively would load the raw
    /// chapter file and lose the combined layout and progress tracking. Instead
    /// we scroll to the matching element inside the right `.epub-chapter` div,
    /// remembering the previous position so Cmd+[ can jump back.
    static let linkScript = """
        (function() {
            const jumpStack = [];

            // Absolute, decoded paths of each chapter's original file, resolved
            // against the combined document's location.
            const chapterPaths = new Map();
            document.querySelectorAll('.epub-chapter[data-chapter-path]').forEach((el) => {
                try {
                    const path = decodeURIComponent(new URL(el.dataset.chapterPath, document.baseURI).pathname);
                    chapterPaths.set(path, el);
                } catch (e) {}
            });

            const findTarget = (chapter, fragment) => {
                if (!fragment) return chapter;
                const scope = chapter || document;
                const escaped = CSS.escape(fragment);
                return scope.querySelector('#' + escaped)
                    || scope.querySelector('[name="' + escaped + '"]')
                    || document.getElementById(fragment)
                    || chapter;
            };

            window.readerJumpTo = (chapter, fragment) => {
                const target = findTarget(chapter, fragment);
                if (!target) return false;
                jumpStack.push(window.computeCenterProgress());
                target.scrollIntoView({ block: 'start' });
                return true;
            };

            window.readerJumpToChapterIndex = (index, fragment) => {
                return window.readerJumpTo(document.getElementById('chapter-' + index), fragment);
            };

            window.readerJumpBack = () => {
                const previous = jumpStack.pop();
                if (previous) window.restoreCenterProgress(previous);
            };

            document.addEventListener('click', (event) => {
                const link = event.target.closest ? event.target.closest('a[href]') : null;
                if (!link) return;
                const href = link.getAttribute('href');
                if (!href) return;

                // Same-chapter fragment: scope the lookup to the enclosing chapter
                // because ids are only unique per chapter, not per combined book.
                if (href.startsWith('#')) {
                    event.preventDefault();
                    let fragment = href.slice(1);
                    try { fragment = decodeURIComponent(fragment); } catch (e) {}
                    window.readerJumpTo(link.closest('.epub-chapter'), fragment);
                    return;
                }

                let url;
                try { url = new URL(href, document.baseURI); } catch (e) { return; }
                // Non-file links (http, mailto) are handed to the system by native code.
                if (url.protocol !== 'file:') return;

                event.preventDefault();
                const chapter = chapterPaths.get(decodeURIComponent(url.pathname));
                if (!chapter) return;
                let fragment = url.hash ? url.hash.slice(1) : '';
                try { fragment = decodeURIComponent(fragment); } catch (e) {}
                window.readerJumpTo(chapter, fragment);
            }, true);
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
        private var appliedExternalScrollToken: UUID?
        private var isDocumentReadyForExternalScroll = false
        private var pendingExternalScroll: (token: UUID, chapterIndex: Int, chapterProgress: Double, overallProgress: Double)?

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

        /// Only the combined document itself may load in the web view. The link
        /// script handles internal links in-page; this is the native safety net for
        /// anything it misses, and the hand-off point for external links.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }

            if url.isFileURL {
                let combinedPath = document.combinedHTMLURL.standardizedFileURL.resolvingSymlinksInPath().path
                let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                if targetPath == combinedPath {
                    return .allow
                }
                // A link to a chapter file slipped past the script: jump in-page.
                if let chapter = document.spine.first(where: {
                    $0.url.standardizedFileURL.resolvingSymlinksInPath().path == targetPath
                }) {
                    _ = try? await webView.callAsyncJavaScript(
                        "window.readerJumpToChapterIndex && window.readerJumpToChapterIndex(index, fragment);",
                        arguments: ["index": chapter.index, "fragment": url.fragment ?? ""],
                        contentWorld: .page
                    )
                }
                return .cancel
            }

            // External links open in the default browser; the reader stays offline.
            if navigationAction.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let target = pendingScrollTarget else { return }
            // Consume the target so it is applied only once per document load.
            pendingScrollTarget = nil
            isDocumentReadyForExternalScroll = false

            // Apply saved font size FIRST so the DOM reflows before we compute
            // scroll offsets — otherwise the position would be wrong for the
            // final layout.
            let fontSizeJS: String
            if initialFontSizePercent != 100 {
                let pixels = initialFontSizePercent * EPUBScrollProxy.baseFontPx / 100
                fontSizeJS = """
                    document.documentElement.style.fontSize = '\(pixels)px';
                    document.body.style.webkitTextSizeAdjust = '\(initialFontSizePercent)%';
                    """
            } else {
                // At 100% the combined HTML's base size already applies; no override
                // needed, which also avoids an extra reflow before the initial scroll.
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
                    self.isDocumentReadyForExternalScroll = true
                    webView.evaluateJavaScript("window.isReadyForProgress = true; sendProgress();")
                    if let pending = self.pendingExternalScroll {
                        self.applyExternalScroll(
                            token: pending.token,
                            chapterIndex: pending.chapterIndex,
                            chapterProgress: pending.chapterProgress,
                            overallProgress: pending.overallProgress
                        )
                    }
                }
            } else {
                webView.evaluateJavaScript(fontSizeJS) { _, _ in
                    // Use requestAnimationFrame to ensure the DOM has reflowed
                    // with the new font size before computing scroll position.
                    let wrappedScroll =
                        "requestAnimationFrame(function() { \(scrollJS); setTimeout(() => { window.isReadyForProgress = true; sendProgress(); }, 50); });"
                    webView.evaluateJavaScript(wrappedScroll)
                    self.isDocumentReadyForExternalScroll = true
                    if let pending = self.pendingExternalScroll {
                        self.applyExternalScroll(
                            token: pending.token,
                            chapterIndex: pending.chapterIndex,
                            chapterProgress: pending.chapterProgress,
                            overallProgress: pending.overallProgress
                        )
                    }
                }
            }
        }

        func applyExternalScrollIfNeeded(token: UUID?, chapterIndex: Int, chapterProgress: Double, overallProgress: Double) {
            guard let token, token != appliedExternalScrollToken else { return }
            pendingExternalScroll = (token, chapterIndex, chapterProgress, overallProgress)
            guard isDocumentReadyForExternalScroll else { return }
            applyExternalScroll(
                token: token,
                chapterIndex: chapterIndex,
                chapterProgress: chapterProgress,
                overallProgress: overallProgress
            )
        }

        private func applyExternalScroll(token: UUID, chapterIndex: Int, chapterProgress: Double, overallProgress: Double) {
            guard let webView else { return }
            guard token != appliedExternalScrollToken else { return }
            appliedExternalScrollToken = token
            let safeProgress = chapterProgress.clampedToUnit
            let safeOverall = overallProgress.clampedToUnit
            let js = """
                const chapter = document.getElementById('chapter-\(chapterIndex)');
                if (chapter) {
                    const rect = chapter.getBoundingClientRect();
                    const chapterHeight = Math.max(rect.height, 1);
                    const offset = chapterHeight * \(safeProgress);
                    window.scrollTo(0, window.scrollY + rect.top + offset - window.innerHeight / 2);
                } else {
                    const root = document.documentElement;
                    const maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                    window.scrollTo(0, maxScroll * \(safeOverall));
                }
                window.currentCenterProgress = {
                    chapterIndex: \(chapterIndex),
                    chapterProgress: \(safeProgress)
                };
                sendProgress();
                """
            webView.evaluateJavaScript(js)
            pendingExternalScroll = nil
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
