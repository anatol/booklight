import SwiftUI
import UIKit

struct ReaderContainerView: View {
    var library: LibraryModel
    let bookID: String
    /// The reader's title, published to the window so the library screen
    /// underneath doesn't overwrite it.
    @Binding var readerTitle: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Controls visibility of the floating back button in the top-left corner.
    @State private var showBackButton = false
    /// Reading progress (0.0–1.0) shown in the window title.
    @State private var displayedProgress: Double?

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
                            bookURL: book.fileURL,
                            library: library,
                            displayedProgress: $displayedProgress,
                            syncToken: library.readerSyncToken(for: bookID)
                        )
                    case .epub:
                        EPUBBookView(
                            book: book,
                            bookURL: book.fileURL,
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

            // Invisible hover zone in the top-left corner that reveals the back button.
            Color.clear
                .frame(width: 80, height: 80)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showBackButton = hovering
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showBackButton {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .transition(.opacity)
                        // Keep the button visible while the user is interacting with it.
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showBackButton = hovering
                            }
                        }
                    }
                }
        }
        .navigationTitle(windowTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Set initial progress from saved state so the title shows it immediately.
            displayedProgress = book?.progress
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
