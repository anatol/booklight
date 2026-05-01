import SwiftUI
import UIKit

struct ReaderContainerView: View {
    @ObservedObject var controller: LibraryController
    let bookID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Controls visibility of the floating back button in the top-left corner.
    @State private var showBackButton = false

    private var book: Book? {
        controller.books.first(where: { $0.id == bookID })
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
        if let progress = controller.openBookProgress {
            let percent = Int(round(progress * 100))
            return "\(name)  |  \(percent)%"
        }
        return name
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let book, let bookURL = controller.absoluteURL(for: book) {
                    switch book.format {
                    case .pdf:
                        PDFBookView(
                            book: book,
                            bookURL: bookURL,
                            controller: controller,
                            syncToken: controller.readerSyncToken(for: bookID)
                        )
                    case .epub:
                        EPUBBookView(
                            book: book,
                            bookURL: bookURL,
                            controller: controller,
                            syncToken: controller.readerSyncToken(for: bookID)
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
            controller.openBookProgress = book?.progress
            controller.openBookTitle = windowTitle
            setSceneTitle(windowTitle)
            controller.registerReaderProgressObservation(for: bookID)
        }
        .onDisappear {
            controller.openBookTitle = nil
            controller.openBookProgress = nil
            // Restore the library title when leaving the reader.
            let libraryTitle = ContentView.windowTitle(for: controller.trackingDirectoryURL)
            setSceneTitle(libraryTitle)
        }
        // Update the Mac Catalyst window title whenever progress changes.
        .onChange(of: controller.openBookProgress) {
            let title = windowTitle
            controller.openBookTitle = title
            setSceneTitle(title)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            controller.synchronizeReaderProgressIfNeeded(for: bookID)
        }
    }

    /// Directly sets the Mac Catalyst window title via UIKit, because
    /// SwiftUI's .navigationTitle on a pushed view does not update the title bar.
    private func setSceneTitle(_ title: String) {
        #if targetEnvironment(macCatalyst)
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            scene.title = title
        #endif
    }
}
