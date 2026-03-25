import SwiftUI
import WebKit

/// Proxy object that bridges SwiftUI key events to the underlying WKWebView,
/// allowing Space / Shift+Space to scroll by one viewport height and
/// Shift+"+"/"-" to adjust font size.
@MainActor
final class EPUBScrollProxy: ObservableObject {
    weak var webView: WKWebView?

    /// Current font size as a percentage of the default (100%). Range: 50–200%.
    @Published var fontSizePercent: Int = 100

    private static let minFontSize = 50
    private static let maxFontSize = 200
    private static let fontSizeStep = 10

    /// Scroll the EPUB content down by ~90% of the viewport (slight overlap for context).
    func scrollPageDown() {
        webView?.evaluateJavaScript("window.scrollBy(0, window.innerHeight * 0.9)")
    }

    /// Scroll the EPUB content up by ~90% of the viewport.
    func scrollPageUp() {
        webView?.evaluateJavaScript("window.scrollBy(0, -window.innerHeight * 0.9)")
    }

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

    var body: some View {
        Group {
            if let document {
                EPUBWebView(
                    document: document,
                    initialScrollTarget: initialScrollTarget,
                    scrollProxy: scrollProxy,
                    initialFontSizePercent: scrollProxy.fontSizePercent
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
                }
            } else if isPreparing {
                ProgressView("Opening EPUB…")
            } else {
                ContentUnavailableView(
                    "Could Not Open EPUB", systemImage: "exclamationmark.triangle", description: Text(loadError ?? "Unknown error"))
            }
        }
        .focusable()
        .onKeyPress(.space, phases: .down) { keyPress in
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
    /// Called with (chapterIndex, chapterProgress, overallProgress) as the user scrolls.
    let onProgressChange: (Int, Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, initialFontSizePercent: initialFontSizePercent, onProgressChange: onProgressChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "readerProgress")
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
        scrollProxy.webView = webView
        context.coordinator.loadCombinedDocument(scrollTarget: initialScrollTarget)
    }

    // MARK: - JavaScript for tracking scroll position across combined chapters

    /// Tracks the overall scroll progress and determines which chapter div is currently
    /// visible at the top of the viewport. Posts a JSON message with chapterIndex,
    /// chapterProgress (within that chapter), and overallProgress (across entire document).
    static let scrollTrackingScript = """
        window.isReadyForProgress = false;
        window.currentCenterProgress = null;
        let isResizing = false;
        let resizeTimeout = null;

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

          if (!isResizing) {
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
          if (!isResizing) {
              window.currentCenterProgress = window.computeCenterProgress();
          }
          if (scrollTimeout) return;
          scrollTimeout = setTimeout(() => {
            scrollTimeout = null;
            sendProgress();
          }, 120);
        }, { passive: true });

        window.addEventListener('resize', () => {
          isResizing = true;
          if (window.currentCenterProgress) {
            window.restoreCenterProgress(window.currentCenterProgress);
          }
          clearTimeout(resizeTimeout);
          resizeTimeout = setTimeout(() => {
            isResizing = false;
            sendProgress();
          }, 200);
        });

        window.addEventListener('load', () => setTimeout(() => {
            if (!window.currentCenterProgress) {
                window.currentCenterProgress = window.computeCenterProgress();
            }
            sendProgress();
        }, 80));
        """

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var document: EPUBDocument
        var onProgressChange: (Int, Double, Double) -> Void

        private weak var webView: WKWebView?
        /// Tracks whether the combined document has been loaded to avoid redundant loads.
        private var currentToken: UUID?
        /// The scroll target to restore after the document finishes loading.
        private var pendingScrollTarget: EPUBScrollTarget?
        /// Font size percentage to apply after document load (restored from saved state).
        private var initialFontSizePercent: Int

        init(document: EPUBDocument, initialFontSizePercent: Int, onProgressChange: @escaping (Int, Double, Double) -> Void) {
            self.document = document
            self.initialFontSizePercent = initialFontSizePercent
            self.onProgressChange = onProgressChange
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
