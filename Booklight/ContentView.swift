import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = LibraryController()
    @State private var showingSettings = false

    /// Builds the window title: "Booklight - ~/path/to/dir" or just "Booklight" if no directory set.
    static func windowTitle(for trackingURL: URL?) -> String {
        guard let url = trackingURL else { return "Booklight" }
        return "Booklight - \(displayPath(for: url))"
    }

    var body: some View {
        NavigationStack {
            // Wrapped in a child view so it can read @Environment(\.isSearching)
            // and clear the search text when the user cancels/dismisses search.
            LibraryContentView(controller: controller)
                .navigationTitle(controller.openBookTitle ?? Self.windowTitle(for: controller.trackingDirectoryURL))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        LibraryTitleView(libraryURL: controller.trackingDirectoryURL)
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if controller.trackingDirectoryURL != nil {
                            Button {
                                controller.refresh(silently: false)
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }

                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(controller: controller)
        }
        .fileImporter(
            isPresented: $controller.isPickingTrackingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let firstURL = urls.first {
                    controller.handlePickedTrackingDirectory(.success(firstURL))
                }
            case .failure(let error):
                controller.handlePickedTrackingDirectory(.failure(error))
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
            if controller.trackingDirectoryURL == nil {
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
                Text("Choose Tracking Directory")
                    .font(.title2.weight(.semibold))

                Text("Pick a folder to store currently active books and reading progress. Local libraries can be added later in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button("Choose Tracking Directory") {
                controller.isPickingTrackingDirectory = true
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
                } else if controller.activeBooks.isEmpty && controller.otherBooks.isEmpty && !controller.debouncedSearchText.isEmpty {
                    Text("No books match “\(controller.searchText)”")
                        .foregroundStyle(.secondary)
                } else {
                    if !controller.activeBooks.isEmpty {
                        BookGallerySection(
                            title: "Active Books",
                            books: controller.activeBooks,
                            controller: controller,
                            isActiveSection: true
                        )
                    }

                    if !controller.otherBooks.isEmpty || controller.activeBooks.isEmpty {
                        BookGallerySection(
                            title: controller.activeBooks.isEmpty ? "Books" : "Library",
                            books: controller.otherBooks,
                            controller: controller,
                            isActiveSection: false
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
    var isActiveSection: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 12)

                if !isActiveSection {
                    Menu {
                        Picker("Sort by", selection: $controller.otherBooksSort) {
                            ForEach(LibraryController.OtherBooksSortOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort: \(controller.otherBooksSort.shortLabel)", systemImage: "arrow.up.arrow.down.circle")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        BookCard(book: book, fileURL: controller.absoluteURL(for: book))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if isActiveSection {
                            Button {
                                controller.markUnread(book: book)
                            } label: {
                                Label("Mark as Unread", systemImage: "arrow.uturn.backward.circle")
                            }

                            Button(role: .destructive) {
                                controller.removeFromActive(book: book)
                            } label: {
                                Label("Remove from Active", systemImage: "trash")
                            }
                        }
                    }
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
                BookThumbnailView(bookID: book.id, fileURL: fileURL, format: book.format)
                    .aspectRatio(0.72, contentMode: .fit)
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 8)

                if book.isFinished {
                    statusBadge("Finished", tint: .green)
                        .padding(10)
                } else if !book.isUnreadLike {
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
                    if book.isUnreadLike {
                        Text("Unread")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !book.isUnreadLike && !book.isFinished {
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

/// Formats a directory path for display, replacing the home directory prefix with "~".
private func displayPath(for url: URL) -> String {
    var path = url.path()
    if path.hasSuffix("/") && path.count > 1 { path = String(path.dropLast()) }
    let home = NSHomeDirectory()
    if path == home {
        return "~"
    } else if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

struct SettingsView: View {
    @ObservedObject var controller: LibraryController
    @Environment(\.dismiss) private var dismiss

    @State private var isPickingTrackingDirectory = false
    @State private var isPickingLocalLibrary = false

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("Tracking Directory"),
                    footer: Text("This folder stores your active books and reading progress.")
                ) {
                    HStack {
                        if let url = controller.trackingDirectoryURL {
                            Text(displayPath(for: url))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Not Selected")
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Change...") {
                            isPickingTrackingDirectory = true
                        }
                    }
                }
                .fileImporter(
                    isPresented: $isPickingTrackingDirectory,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let firstURL = urls.first {
                            controller.handlePickedTrackingDirectory(.success(firstURL))
                        }
                    case .failure(let error):
                        controller.handlePickedTrackingDirectory(.failure(error))
                    }
                }

                Section(
                    header: Text("Local Libraries"),
                    footer: Text("These folders are scanned for books, but their contents are never modified by the app.")
                ) {
                    List {
                        ForEach(Array(controller.localLibraries.enumerated()), id: \.element) { index, url in
                            Text(displayPath(for: url))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                controller.removeLocalLibrary(at: index)
                            }
                        }
                    }

                    Button {
                        isPickingLocalLibrary = true
                    } label: {
                        Label("Add Local Library", systemImage: "plus")
                    }
                }
                .fileImporter(
                    isPresented: $isPickingLocalLibrary,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let firstURL = urls.first {
                            controller.handlePickedLocalLibrary(.success(firstURL))
                        }
                    case .failure(let error):
                        controller.handlePickedLocalLibrary(.failure(error))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
