import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = LibraryController()

    var body: some View {
        NavigationStack {
            // Wrapped in a child view so it can read @Environment(\.isSearching)
            // and clear the search text when the user cancels/dismisses search.
            LibraryContentView(controller: controller)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        LibraryTitleView(libraryURL: controller.libraryURL)
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if controller.libraryURL != nil {
                            Button {
                                controller.refresh(silently: false)
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }

                        Button {
                            controller.isPickingLibrary = true
                        } label: {
                            Label("Choose Library", systemImage: "folder")
                        }
                    }
                }
        }
        .overlay {
            if controller.isLoading {
                ProgressView("Scanning library…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .fileImporter(
            isPresented: $controller.isPickingLibrary,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let firstURL = urls.first {
                    controller.handlePickedLibrary(.success(firstURL))
                }
            case let .failure(error):
                controller.handlePickedLibrary(.failure(error))
            }
        }
        .alert(
            "Problem",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                Text(controller.errorMessage ?? "")
            }
        )
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.refresh(silently: true)
            }
        }
        .searchable(text: $controller.searchText, prompt: "Search by title")
    }

}

/// Child view that reads `@Environment(\.isSearching)` to detect when the user
/// dismisses or cancels the search bar, and clears the search text so book
/// filtering is removed and the default list is restored.
private struct LibraryContentView: View {
    @ObservedObject var controller: LibraryController
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Group {
            if controller.libraryURL == nil {
                emptyLibraryView
            } else {
                libraryView
            }
        }
        .onChange(of: isSearching) { _, searching in
            if !searching {
                controller.searchText = ""
            }
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 20) {
            BooklightIconView(size: 108)
                .shadow(color: .black.opacity(0.18), radius: 22, y: 10)

            VStack(spacing: 8) {
                Text("Choose a Book Folder")
                    .font(.title2.weight(.semibold))

                Text("Pick a flat directory of PDF and EPUB files. The app will create `.book-app` inside that folder and keep reading progress synced there.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button("Choose Library") {
                controller.isPickingLibrary = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var libraryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if controller.books.isEmpty {
                    Text("No PDF or EPUB files found in the selected folder.")
                        .foregroundStyle(.secondary)
                } else if controller.activeBooks.isEmpty && controller.otherBooks.isEmpty && !controller.searchText.isEmpty {
                    Text("No books match “\(controller.searchText)”")
                        .foregroundStyle(.secondary)
                } else {
                    if !controller.activeBooks.isEmpty {
                        BookGallerySection(
                            title: "Active Books",
                            books: controller.activeBooks,
                            controller: controller
                        )
                    }

                    if !controller.otherBooks.isEmpty || controller.activeBooks.isEmpty {
                        BookGallerySection(
                            title: controller.activeBooks.isEmpty ? "Books" : "Library",
                            books: controller.otherBooks,
                            controller: controller
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .navigationDestination(for: Book.self) { book in
            ReaderContainerView(controller: controller, bookID: book.id)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct LibraryTitleView: View {
    let libraryURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            BooklightIconView(size: 28)
                .frame(width: 28, height: 28)
        }
        .frame(maxWidth: 320)
    }
}

private struct BookGallerySection: View {
    let title: String
    let books: [Book]
    @ObservedObject var controller: LibraryController

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
//            Text(title)
//                .font(.title3.weight(.semibold))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        BookCard(book: book, fileURL: controller.absoluteURL(for: book))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BookCard: View {
    let book: Book
    let fileURL: URL?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                BookThumbnailView(fileURL: fileURL, format: book.format)
                    .aspectRatio(0.72, contentMode: .fit)
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 8)

                if book.isFinished {
                    statusBadge("Finished", tint: .green)
                        .padding(10)
                } else if book.progress > 0 {
                    statusBadge("\(Int((book.progress * 100).rounded()))%", tint: .accentColor)
                        .padding(10)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(book.displaySubtitle)
                    if !book.isFinished && book.progress == 0 {
                        Text("Unread")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if book.progress > 0 && !book.isFinished {
                    ProgressView(value: book.progress)
                        .progressViewStyle(.linear)
                }

                if let lastOpenedAt = book.lastOpenedAt {
                    Text("Opened \(Self.relativeFormatter.localizedString(for: lastOpenedAt, relativeTo: .now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint, in: Capsule())
    }
}
