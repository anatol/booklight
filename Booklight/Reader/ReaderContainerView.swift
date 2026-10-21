import SwiftUI
import UIKit

struct ReaderContainerView: View {
    var library: LibraryModel
    let bookID: String
    /// The reader's title, published to the window so the library screen
    /// underneath doesn't overwrite it.
    @Binding var readerTitle: String?
    @Environment(\.scenePhase) private var scenePhase

    /// Reading progress (0.0–1.0) shown in the window title.
    @State private var displayedProgress: Double?
    /// The file the reader opened. Opening copies the book into the tracking
    /// directory in the background, which changes `book.fileURL`; pinning the
    /// original avoids reloading the document mid-read when the copy lands.
    @State private var openedURL: URL?

    private var book: Book? {
        library.book(withID: bookID)
    }

    /// The book filename without extension, used as the base window title in reader mode.
    private var bookName: String {
        guard let book else { return "" }
        return book.fileURL.deletingPathExtension().lastPathComponent
    }

    /// Window title including reading progress, e.g. "MyBook  |  42%".
    private var windowTitle: String {
        let name = bookName
        guard !name.isEmpty else { return "" }
        if let progress = displayedProgress {
            let percent = Int(round(progress * 100))
            return "\(name)  |  \(percent)%"
        }
        return name
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let book {
                    switch book.format {
                    case .pdf:
                        PDFBookView(
                            book: book,
                            bookURL: openedURL ?? book.fileURL,
                            library: library,
                            displayedProgress: $displayedProgress,
                            syncToken: library.readerSyncToken(for: bookID)
                        )
                    case .epub:
                        EPUBBookView(
                            book: book,
                            bookURL: openedURL ?? book.fileURL,
                            library: library,
                            displayedProgress: $displayedProgress,
                            syncToken: library.readerSyncToken(for: bookID)
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "Book Missing", systemImage: "exclamationmark.triangle",
                        description: Text("This book is no longer present in the library."))
                }
            }
        }
        .navigationTitle(windowTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Set initial progress from saved state so the title shows it immediately.
            displayedProgress = book?.progress
            if openedURL == nil {
                openedURL = book?.fileURL
            }
            readerTitle = windowTitle
            library.registerReaderProgressObservation(for: bookID)
        }
        .onDisappear {
            // The library screen's title takes over again.
            readerTitle = nil
        }
        // Keep the window title's progress readout current.
        .onChange(of: displayedProgress) {
            readerTitle = windowTitle
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            library.synchronizeReaderProgressIfNeeded(for: bookID)
        }
    }
}
