import SwiftUI
import WebKit

/// Proxy object that bridges SwiftUI key events to the underlying WKWebView,
/// allowing Space / Shift+Space to scroll by one viewport height and
/// Shift+"+"/"-" to adjust font size.
/// Also manages in-document text search via injected JavaScript.
@MainActor
@Observable
final class EPUBScrollProxy: ReaderEngine {
    @ObservationIgnored weak var webView: WKWebView?
    /// Called after the user changes the text size, to persist the preference.
    @ObservationIgnored var onTextSizeChange: ((Int) -> Void)?

    /// Current font size as a percentage of the default (100%). Range: 50–200%.
    var fontSizePercent: Int = 100

    // MARK: - Search state

    /// Number of matches found for the current search query.
    var searchMatchCount: Int = 0
    /// Zero-based index of the currently highlighted match.
    var searchCurrentIndex: Int = 0
    /// True while waiting for the page script to return match results.
    var isSearchInProgress = false
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

    func reportCurrentPosition() {
        webView?.evaluateJavaScript("sendProgress();")
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
        isSearchInProgress = true

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
            self.isSearchInProgress = false
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
        isSearchInProgress = false
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

    // MARK: - Theme

    @ObservationIgnored var theme: ReaderTheme = .light

    /// Script that sets the theme attribute the combined document's CSS keys off.
    static func themeScript(for theme: ReaderTheme) -> String {
        "document.documentElement.setAttribute('data-theme', '\(theme.rawValue)');"
    }

    func apply(theme: ReaderTheme) {
        self.theme = theme
        guard let webView else { return }
        webView.evaluateJavaScript(Self.themeScript(for: theme))
        webView.scrollView.backgroundColor = theme.uiBackground
        webView.underPageBackgroundColor = theme.uiBackground
    }

    // MARK: - Table of contents

    var tableOfContents: [ReaderTOCEntry] = []

    func setTableOfContents(_ entries: [EPUBDocument.TOCEntry]) {
        tableOfContents = entries.enumerated().map { offset, entry in
            ReaderTOCEntry(
                id: offset, title: entry.title, level: entry.level,
                destination: .epub(spineIndex: entry.spineIndex, fragment: entry.fragment))
        }
    }

    func go(to entry: ReaderTOCEntry) {
        guard case .epub(let spineIndex, let fragment) = entry.destination, let webView else { return }
        Task { [weak webView] in
            _ = try? await webView?.callAsyncJavaScript(
                "if (window.clearHold) window.clearHold(); return window.readerJumpToChapterIndex && window.readerJumpToChapterIndex(index, fragment);",
                arguments: ["index": spineIndex, "fragment": fragment ?? ""],
                contentWorld: .page
            )
        }
    }

    // MARK: - Font size

    var supportsTextSize: Bool { true }
    var textSizePercent: Int? { fontSizePercent }

    func seek(toProgress progress: Double) {
        webView?.evaluateJavaScript(
            """
            (function() {
                if (window.clearHold) window.clearHold();
                var root = document.documentElement;
                var maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                window.scrollTo(0, maxScroll * \(progress.clampedToUnit));
            })();
            """)
    }

    /// Increase font size by one step (10%), capped at 200%.
    func increaseTextSize() {
        fontSizePercent = min(fontSizePercent + Self.fontSizeStep, Self.maxFontSize)
        applyFontSize()
        onTextSizeChange?(fontSizePercent)
    }

    /// Decrease font size by one step (10%), floored at 50%.
    func decreaseTextSize() {
        fontSizePercent = max(fontSizePercent - Self.fontSizeStep, Self.minFontSize)
        applyFontSize()
        onTextSizeChange?(fontSizePercent)
    }

    /// The reading base font size (px) that corresponds to 100%. The combined HTML
    /// sets the same value on <html>, so the percentage controls scale a comfortable
    /// default rather than the browser's small 16px. Kept in sync with EPUBSupport's CSS.
    static let baseFontPx = 30

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
    @State private var session = ReaderSession(engine: EPUBScrollProxy())
    @AppStorage(ReaderTheme.storageKey) private var theme: ReaderTheme = .light

    var body: some View {
        ReaderScaffold(session: session, progress: displayedProgress) {
            Group {
                if let document {
                    EPUBWebView(
                        document: document,
                        initialScrollTarget: initialScrollTarget,
                        externalScrollToken: syncToken,
                        externalChapterIndex: book.progressState?.epubChapterIndex ?? 0,
                        externalChapterProgress: book.progressState?.epubChapterProgress ?? 0,
                        externalChapterOffsetY: book.progressState?.epubChapterOffsetY ?? 0,
                        externalOverallProgress: book.progressState?.progress ?? 0,
                        scrollProxy: session.engine,
                        initialFontSizePercent: session.engine.fontSizePercent,
                        onContentTapped: {
                            // During search, a tap confirms the current position as the
                            // reading location; otherwise it toggles the reader bars.
                            withAnimation(.easeInOut(duration: 0.2)) {
                                session.contentTapped()
                            }
                        }
                    ) { chapterIndex, chapterProgress, chapterOffsetY, overallProgress in
                        // Clamp values to valid ranges before persisting.
                        let clampedIndex = min(max(chapterIndex, 0), max(document.spine.count - 1, 0))
                        let clampedChapterProgress = chapterProgress.clampedToUnit
                        let clampedOverall = overallProgress.clampedToUnit

                        library.saveEPUBPosition(
                            for: book,
                            chapterIndex: clampedIndex,
                            chapterPath: document.spine[clampedIndex].href,
                            chapterProgress: clampedChapterProgress,
                            chapterOffsetY: chapterOffsetY,
                            overallProgress: clampedOverall
                        )
                        // Update title progress only when not searching, so the title
                        // reflects the actual reading position rather than search matches.
                        if !session.isSearchVisible {
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
        }
        .background(theme.background)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: theme, initial: true) { _, newTheme in
            session.engine.apply(theme: newTheme)
        }
        .task(id: book.id) {
            // Restore saved font size preference before the document loads,
            // so it's ready to apply when the web view finishes navigation.
            session.engine.fontSizePercent = book.progressState?.epubFontSizePercent ?? 100
            session.engine.onTextSizeChange = { percent in
                library.saveEPUBFontSize(for: book, fontSizePercent: percent)
            }
            library.markOpened(book)
            await loadDocument()
        }
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
                session.engine.setTableOfContents(prepared.tableOfContents)

                let storedOverall = book.progressState?.progress ?? 0
                let storedChapterPath = book.progressState?.epubChapterPath
                let storedChapterIndex = book.progressState?.epubChapterIndex ?? 0
                let storedChapterProgress = book.progressState?.epubChapterProgress ?? 0
                let storedChapterOffsetY = book.progressState?.epubChapterOffsetY ?? 0

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
                    chapterProgress: storedChapterProgress,
                    chapterOffsetY: storedChapterOffsetY
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
    var chapterOffsetY: Double = 0
}

// MARK: - WKWebView wrapper for continuous EPUB scrolling

private struct EPUBWebView: UIViewRepresentable {
    let document: EPUBDocument
    let initialScrollTarget: EPUBScrollTarget?
    let externalScrollToken: UUID?
    let externalChapterIndex: Int
    let externalChapterProgress: Double
    let externalChapterOffsetY: Double
    let externalOverallProgress: Double
    let scrollProxy: EPUBScrollProxy
    /// Initial font size percentage to apply after the document loads.
    let initialFontSizePercent: Int
    /// Called when the user clicks/taps on the content area (not text selection).
    let onContentTapped: () -> Void
    /// Called with (chapterIndex, chapterProgress, overallProgress) as the user scrolls.
    let onProgressChange: (Int, Double, Double, Double) -> Void

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
        // Set the theme before first paint so dark books don't flash white.
        contentController.addUserScript(
            WKUserScript(
                source: EPUBScrollProxy.themeScript(for: scrollProxy.theme),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.scrollView.backgroundColor = scrollProxy.theme.uiBackground
        webView.underPageBackgroundColor = scrollProxy.theme.uiBackground
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // The reader's own scrubber replaces the system scroll indicator.
        webView.scrollView.showsVerticalScrollIndicator = false
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
            chapterOffsetY: externalChapterOffsetY,
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
                    if (window.invalidateTextIndex) window.invalidateTextIndex();
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

                    if (window.invalidateTextIndex) window.invalidateTextIndex();
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

        // Position inside a chapter is measured by text, not pixels. Pixel heights
        // change when lazy images load, the font size changes or the window is
        // resized; the amount of text before a given point never does. That keeps
        // a saved position pointing at the same words on every reopen and device.
        const textIndexes = new Map();  // chapter element -> { nodes, starts, total, nodeIndex }
        window.invalidateTextIndex = () => textIndexes.clear();

        const textIndexFor = (chapter) => {
          let index = textIndexes.get(chapter);
          if (index) return index;
          const nodes = [], starts = [], nodeIndex = new Map();
          let total = 0;
          const walker = document.createTreeWalker(chapter, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => n.nodeValue.trim().length > 0 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT
          });
          while (walker.nextNode()) {
            const n = walker.currentNode;
            nodeIndex.set(n, nodes.length);
            nodes.push(n);
            starts.push(total);
            total += n.nodeValue.length;
          }
          index = { nodes: nodes, starts: starts, total: total, nodeIndex: nodeIndex };
          textIndexes.set(chapter, index);
          return index;
        };

        // Viewport rect of the character at `offset` in a text node (trying the
        // previous characters when that one has no box, e.g. collapsed whitespace).
        const charRect = (node, offset) => {
          const range = document.createRange();
          for (let o = Math.min(offset, node.nodeValue.length - 1); o >= Math.max(offset - 4, 0); o--) {
            range.setStart(node, o);
            range.setEnd(node, o + 1);
            const rect = range.getClientRects()[0];
            if (rect) return rect;
          }
          return null;
        };

        // The text position at or just above the point (x, y): how many characters
        // of chapter text precede it, and that character's viewport top. When the
        // point is over an image or a margin there is no text under it, so the
        // nearest text *before* it is used and the gap shows up in `top`.
        const textAnchorAt = (chapter, x, y) => {
          const index = textIndexFor(chapter);
          if (!index.total || !document.caretRangeFromPoint) return null;
          const caret = document.caretRangeFromPoint(x, y);
          if (!caret || !chapter.contains(caret.startContainer)) return null;

          let node = null;
          let offset = 0;
          const container = caret.startContainer;
          if (container.nodeType === Node.TEXT_NODE && index.nodeIndex.has(container)) {
            node = container;
            offset = Math.min(caret.startOffset, container.nodeValue.length - 1);
          } else {
            // Last indexed text node that starts before the caret position.
            let lo = 0, hi = index.nodes.length - 1, found = -1;
            while (lo <= hi) {
              const mid = (lo + hi) >> 1;
              if (caret.comparePoint(index.nodes[mid], 0) < 0) { found = mid; lo = mid + 1; } else { hi = mid - 1; }
            }
            if (found < 0) { node = index.nodes[0]; offset = 0; }
            else { node = index.nodes[found]; offset = node.nodeValue.length - 1; }
          }

          const rect = charRect(node, offset);
          return {
            chars: index.starts[index.nodeIndex.get(node)] + offset,
            top: rect ? rect.top : null
          };
        };

        window.computeCenterProgress = () => {
          const centerY = window.innerHeight / 2;
          const chapters = document.querySelectorAll('.epub-chapter');
          let currentChapter = 0;
          let chapterProgress = 0;
          let offsetY = 0;
          for (let i = chapters.length - 1; i >= 0; i--) {
            const rect = chapters[i].getBoundingClientRect();
            if (rect.top <= centerY) {
              currentChapter = parseInt(chapters[i].dataset.chapterIndex) || 0;
              const anchor = textAnchorAt(chapters[i], window.innerWidth / 2, centerY);
              const total = textIndexFor(chapters[i]).total;
              if (anchor && total > 0) {
                chapterProgress = anchor.chars / total;
                // Pixels from the anchored character down to the window center.
                if (anchor.top !== null) offsetY = centerY - anchor.top;
              } else {
                // No text to anchor to: fall back to the pixel fraction.
                chapterProgress = (centerY - rect.top) / Math.max(rect.height, 1);
              }
              chapterProgress = Math.max(0, Math.min(1, chapterProgress));
              break;
            }
          }
          return { chapterIndex: currentChapter, chapterProgress: chapterProgress, offsetY: offsetY };
        };

        // Scrolls so the saved text position is back where it was relative to the
        // window center. Returns false when the chapter doesn't exist.
        window.restoreCenterProgress = (target) => {
          if (!target) return false;
          const chapter = document.getElementById('chapter-' + target.chapterIndex);
          if (!chapter) return false;

          const index = textIndexFor(chapter);
          let top = null;
          let offsetY = target.offsetY || 0;
          if (index.total > 0) {
            const char = Math.min(Math.floor(target.chapterProgress * index.total), index.total - 1);
            let lo = 0, hi = index.starts.length - 1;
            while (lo < hi) {
              const mid = (lo + hi + 1) >> 1;
              if (index.starts[mid] <= char) lo = mid; else hi = mid - 1;
            }
            const rect = charRect(index.nodes[lo], char - index.starts[lo]);
            if (rect) top = rect.top;
          }
          if (top === null) {
            const rect = chapter.getBoundingClientRect();
            top = rect.top + Math.max(rect.height, 1) * target.chapterProgress;
            offsetY = 0;
          }
          window.scrollTo(0, window.scrollY + top + offsetY - window.innerHeight / 2);
          return true;
        };

        // Lazy images above the restored spot load after the restore and push the
        // text down. Re-apply the target as they load, until the reader interacts.
        let holdTarget = null;
        let holdUntil = 0;
        window.holdRestore = (target) => { holdTarget = target; holdUntil = Date.now() + 5000; };
        window.clearHold = () => { holdTarget = null; };
        document.addEventListener('load', () => {
          if (holdTarget && Date.now() < holdUntil) window.restoreCenterProgress(holdTarget);
        }, true);
        ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach((type) => {
          window.addEventListener(type, window.clearHold, { passive: true, capture: true });
        });

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
            chapterOffsetY: window.currentCenterProgress.offsetY || 0,
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
        document.addEventListener('click', function(event) {
            // A followed link is navigation, not a tap on the page.
            if (event.defaultPrevented) return;
            var sel = window.getSelection();
            if (sel && sel.toString().length > 0) return;
            window.webkit.messageHandlers.contentTapped.postMessage({});
        });
        """

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var document: EPUBDocument
        var onProgressChange: (Int, Double, Double, Double) -> Void
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
        private var pendingExternalScroll:
            (token: UUID, chapterIndex: Int, chapterProgress: Double, chapterOffsetY: Double, overallProgress: Double)?

        init(
            document: EPUBDocument, initialFontSizePercent: Int, onProgressChange: @escaping (Int, Double, Double, Double) -> Void,
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

            // Restore by chapter and text position, which stays valid when pixel
            // layout changes (lazy images, font size, window size); `overallProgress`
            // is only a fallback for a chapter that no longer exists. The hold keeps
            // re-applying the position while images above it finish loading.
            let scrollJS = """
                (function() {
                    const target = { chapterIndex: \(target.chapterIndex), chapterProgress: \(target.chapterProgress.clampedToUnit), offsetY: \(target.chapterOffsetY) };
                    if (window.restoreCenterProgress(target)) {
                        window.holdRestore(target);
                        window.currentCenterProgress = target;
                    } else {
                        const root = document.documentElement;
                        const maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                        window.scrollTo(0, maxScroll * \(target.overallProgress.clampedToUnit));
                    }
                })();
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
                            chapterOffsetY: pending.chapterOffsetY,
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
                            chapterOffsetY: pending.chapterOffsetY,
                            overallProgress: pending.overallProgress
                        )
                    }
                }
            }
        }

        func applyExternalScrollIfNeeded(
            token: UUID?, chapterIndex: Int, chapterProgress: Double, chapterOffsetY: Double, overallProgress: Double
        ) {
            guard let token, token != appliedExternalScrollToken else { return }
            pendingExternalScroll = (token, chapterIndex, chapterProgress, chapterOffsetY, overallProgress)
            guard isDocumentReadyForExternalScroll else { return }
            applyExternalScroll(
                token: token,
                chapterIndex: chapterIndex,
                chapterProgress: chapterProgress,
                chapterOffsetY: chapterOffsetY,
                overallProgress: overallProgress
            )
        }

        private func applyExternalScroll(
            token: UUID, chapterIndex: Int, chapterProgress: Double, chapterOffsetY: Double, overallProgress: Double
        ) {
            guard let webView else { return }
            guard token != appliedExternalScrollToken else { return }
            appliedExternalScrollToken = token
            let safeProgress = chapterProgress.clampedToUnit
            let safeOverall = overallProgress.clampedToUnit
            let js = """
                (function() {
                    const target = { chapterIndex: \(chapterIndex), chapterProgress: \(safeProgress), offsetY: \(chapterOffsetY) };
                    if (window.restoreCenterProgress(target)) {
                        window.holdRestore(target);
                        window.currentCenterProgress = target;
                    } else {
                        const root = document.documentElement;
                        const maxScroll = Math.max(root.scrollHeight - window.innerHeight, 1);
                        window.scrollTo(0, maxScroll * \(safeOverall));
                    }
                    sendProgress();
                })();
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
                body["chapterOffsetY"] as? Double ?? 0,
                overallProgress.clampedToUnit
            )
        }
    }
}
