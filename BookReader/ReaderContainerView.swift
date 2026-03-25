import SwiftUI
import UIKit

struct ReaderContainerView: View {
    @ObservedObject var controller: LibraryController
    let bookID: String
    @Environment(\.dismiss) private var dismiss

    /// Controls visibility of the floating back button in the top-left corner.
    @State private var showBackButton = false

    private var book: Book? {
        controller.books.first(where: { $0.id == bookID })
    }

    /// The book filename without extension, used as the window title in reader mode.
    private var windowTitle: String {
        guard let book else { return "" }
        return book.fileURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let book, let bookURL = controller.absoluteURL(for: book) {
                    switch book.format {
                    case .pdf:
                        PDFBookView(book: book, bookURL: bookURL, controller: controller)
                    case .epub:
                        EPUBBookView(book: book, bookURL: bookURL, controller: controller)
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
            controller.openBookTitle = windowTitle
            setSceneTitle(windowTitle)
        }
        .onDisappear {
            controller.openBookTitle = nil
            // Restore the library title when leaving the reader.
            let libraryTitle = ContentView.windowTitle(for: controller.trackingDirectoryURL)
            setSceneTitle(libraryTitle)
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
