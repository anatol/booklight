import SwiftUI
import WebKit

/// Proxy object that bridges SwiftUI key events to the underlying WKWebView,
/// allowing Space / Shift+Space to scroll by one viewport height.
@MainActor
final class EPUBScrollProxy: ObservableObject {
    weak var webView: WKWebView?

    /// Scroll the EPUB content down by ~90% of the viewport (slight overlap for context).
    func scrollPageDown() {
        webView?.evaluateJavaScript("window.scrollBy(0, window.innerHeight * 0.9)")
    }

    /// Scroll the EPUB content up by ~90% of the viewport.
    func scrollPageUp() {
        webView?.evaluateJavaScript("window.scrollBy(0, -window.innerHeight * 0.9)")
    }
}

struct EPUBBookView: View {
    let book: Book
    let bookURL: URL
    @ObservedObject var controller: LibraryController

    @State private var document: EPUBDocument?
    @State private var loadError: String?
    @State private var isPreparing = true
    @State private var navigationRequest = EPUBNavigationRequest(chapterIndex: 0, chapterProgress: 0)
    @StateObject private var scrollProxy = EPUBScrollProxy()

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    EPUBWebView(
                        document: document,
                        request: navigationRequest,
                        scrollProxy: scrollProxy
                    ) { chapterIndex, chapterProgress in
                        let clampedIndex = min(max(chapterIndex, 0), max(document.spine.count - 1, 0))
                        let clampedProgress = chapterProgress.clampedToUnit
                        let overallProgress = document.spine.count <= 1
                            ? clampedProgress
                            : (Double(clampedIndex) + clampedProgress) / Double(document.spine.count)

                        controller.saveEPUBPosition(
                            for: book,
                            chapterIndex: clampedIndex,
                            chapterPath: document.spine[clampedIndex].href,
                            chapterProgress: clampedProgress,
                            overallProgress: overallProgress
                        )
                    }

                    if document.spine.count > 1 {
                        readerControls(for: document)
                    }
                }
            } else if isPreparing {
                ProgressView("Opening EPUB…")
            } else {
                ContentUnavailableView("Could Not Open EPUB", systemImage: "exclamationmark.triangle", description: Text(loadError ?? "Unknown error"))
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
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) {
            controller.markOpened(book)
            await loadDocument()
        }
    }

    private func readerControls(for document: EPUBDocument) -> some View {
        HStack {
            Button {
                let nextIndex = max(navigationRequest.chapterIndex - 1, 0)
                navigationRequest = .init(chapterIndex: nextIndex, chapterProgress: 0)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(navigationRequest.chapterIndex == 0)

            Spacer()

            Text("Chapter \(navigationRequest.chapterIndex + 1) of \(document.spine.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                let nextIndex = min(navigationRequest.chapterIndex + 1, document.spine.count - 1)
                navigationRequest = .init(chapterIndex: nextIndex, chapterProgress: 0)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(navigationRequest.chapterIndex >= document.spine.count - 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
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

                let storedChapterPath = book.progressState?.epubChapterPath
                let storedChapterIndex = book.progressState?.epubChapterIndex ?? 0
                let storedProgress = book.progressState?.epubChapterProgress ?? 0

                let initialIndex: Int
                if let storedChapterPath, let resolvedIndex = prepared.spine.firstIndex(where: { $0.href == storedChapterPath }) {
                    initialIndex = resolvedIndex
                } else {
                    initialIndex = min(max(storedChapterIndex, 0), max(prepared.spine.count - 1, 0))
                }

                navigationRequest = .init(chapterIndex: initialIndex, chapterProgress: storedProgress)
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

private struct EPUBNavigationRequest: Equatable {
    var token = UUID()
    var chapterIndex: Int
    var chapterProgress: Double

    init(chapterIndex: Int, chapterProgress: Double) {
        self.chapterIndex = chapterIndex
        self.chapterProgress = chapterProgress
    }
}

private struct EPUBWebView: UIViewRepresentable {
    let document: EPUBDocument
    let request: EPUBNavigationRequest
    let scrollProxy: EPUBScrollProxy
    let onProgressChange: (Int, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, onProgressChange: onProgressChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "readerProgress")
        contentController.addUserScript(WKUserScript(
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
        context.coordinator.load(request: request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.document = document
        context.coordinator.onProgressChange = onProgressChange
        scrollProxy.webView = webView
        context.coordinator.load(request: request)
    }

    static let scrollTrackingScript = """
    const sendProgress = () => {
      const root = document.documentElement;
      const max = Math.max(root.scrollHeight - window.innerHeight, 1);
      const progress = Math.max(0, Math.min(1, window.scrollY / max));
      window.webkit.messageHandlers.readerProgress.postMessage(progress);
    };
    let timeout = null;
    window.addEventListener('scroll', () => {
      if (timeout) return;
      timeout = setTimeout(() => {
        timeout = null;
        sendProgress();
      }, 120);
    }, { passive: true });
    window.addEventListener('load', () => setTimeout(sendProgress, 80));
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var document: EPUBDocument
        var onProgressChange: (Int, Double) -> Void

        private weak var webView: WKWebView?
        private var currentToken: UUID?
        private var requestedChapterIndex = 0
        private var requestedChapterProgress = 0.0

        init(document: EPUBDocument, onProgressChange: @escaping (Int, Double) -> Void) {
            self.document = document
            self.onProgressChange = onProgressChange
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func load(request: EPUBNavigationRequest) {
            guard currentToken != request.token else {
                return
            }
            currentToken = request.token
            requestedChapterIndex = min(max(request.chapterIndex, 0), max(document.spine.count - 1, 0))
            requestedChapterProgress = request.chapterProgress.clampedToUnit

            let chapter = document.spine[requestedChapterIndex]
            webView?.loadFileURL(chapter.url, allowingReadAccessTo: document.extractedRootURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let clampedProgress = requestedChapterProgress.clampedToUnit
            let script = """
            const root = document.documentElement;
            const max = Math.max(root.scrollHeight - window.innerHeight, 1);
            window.scrollTo(0, max * \(clampedProgress));
            """
            webView.evaluateJavaScript(script) { [weak self] _, _ in
                guard let self else { return }
                self.onProgressChange(self.requestedChapterIndex, clampedProgress)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "readerProgress",
                  let progress = message.body as? Double else {
                return
            }
            onProgressChange(requestedChapterIndex, progress.clampedToUnit)
        }
    }
}
