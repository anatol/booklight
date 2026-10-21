import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LibraryModel.self) private var library
    @State private var browser = LibraryBrowserState()
    @State private var showingSettings = false
    @State private var isPickingTrackingDirectory = false
    @State private var isPickingLocalLibrary = false
    /// Title of the open reader, if any; keeps the window title on the book
    /// while the library view underneath re-renders.
    @State private var readerTitle: String?

    /// Builds the window title: "Booklight - ~/path/to/dir" or just "Booklight" if no directory set.
    static func windowTitle(for trackingURL: URL?) -> String {
        guard let url = trackingURL else { return "Booklight" }
        return "Booklight - \(displayPath(for: url))"
    }

    var body: some View {
        NavigationStack {
            // Wrapped in a child view so it can read @Environment(\.isSearching)
            // and clear the search text when the user cancels/dismisses search.
            LibraryContentView(
                library: library,
                browser: browser,
                isPickingTrackingDirectory: $isPickingTrackingDirectory,
                isPickingLocalLibrary: $isPickingLocalLibrary,
                showingSettings: $showingSettings,
                readerTitle: $readerTitle
            )
            .navigationTitle(readerTitle ?? Self.windowTitle(for: library.trackingDirectoryURL))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    LibraryTitleView(libraryURL: library.trackingDirectoryURL)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if library.trackingDirectoryURL != nil {
                        Button {
                            library.refresh(silently: false)
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
        // Applied outside the stack: UIKit detaches the root screen's views while
        // a reader is pushed, so a setter inside it would stop updating.
        .sceneTitle(readerTitle ?? Self.windowTitle(for: library.trackingDirectoryURL))
        .overlay {
            if library.isLoading {
                ProgressView("Scanning library…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(library: library)
        }
        .fileImporter(
            isPresented: $isPickingTrackingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let firstURL = urls.first {
                    library.handlePickedTrackingDirectory(.success(firstURL))
                }
            case .failure(let error):
                library.handlePickedTrackingDirectory(.failure(error))
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
                    library.handlePickedLocalLibrary(.success(firstURL))
                }
            case .failure(let error):
                library.handlePickedLocalLibrary(.failure(error))
            }
        }
        .alert(
            "Problem",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                Text(library.errorMessage ?? "")
            }
        )
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refresh(silently: true)
            } else if phase == .background {
                flushProgressInBackground()
            }
        }
        .onDisappear {
            flushProgressInBackground()
        }
        .searchable(text: $browser.searchText, prompt: "Search by title")
    }

    /// Writes queued progress before the app is suspended. The background task
    /// keeps the process alive long enough for the asynchronous flush to finish.
    private func flushProgressInBackground() {
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Flush reading progress")
        Task {
            await library.flushPendingProgressWrites()
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
}

/// Child view that reads `@Environment(\.isSearching)` to detect when the user
/// dismisses or cancels the search bar, and clears the search text so book
/// filtering is removed and the default list is restored.
private struct LibraryContentView: View {
    var library: LibraryModel
    var browser: LibraryBrowserState
    @Binding var isPickingTrackingDirectory: Bool
    @Binding var isPickingLocalLibrary: Bool
    @Binding var showingSettings: Bool
    @Binding var readerTitle: String?
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Group {
            if library.trackingDirectoryURL == nil {
                emptyLibraryView
            } else {
                libraryView
            }
        }
        .onChange(of: isSearching) { _, searching in
            if !searching {
                browser.searchText = ""
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
                isPickingTrackingDirectory = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var noBooksView: some View {
        ContentUnavailableView {
            Label("No Books Found", systemImage: "books.vertical")
        } description: {
            Text(
                library.localLibraries.isEmpty
                    ? "The tracking directory has no PDF or EPUB files yet. Add a local library to browse your collection."
                    : "No PDF or EPUB files were found in the tracking directory or your \(library.localLibraries.count == 1 ? "local library" : "\(library.localLibraries.count) local libraries")."
            )
        } actions: {
            Button("Add Local Library") {
                isPickingLocalLibrary = true
            }
            .buttonStyle(.borderedProminent)

            Button("Open Settings") {
                showingSettings = true
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var libraryView: some View {
        let sections = browser.sections(of: library.books)
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if library.books.isEmpty {
                    // Don't claim the library is empty while the first scan is running.
                    if library.hasLoadedOnce && !library.isLoading {
                        noBooksView
                    }
                } else if sections.active.isEmpty && sections.other.isEmpty && !browser.debouncedSearchText.isEmpty {
                    ContentUnavailableView.search(text: browser.searchText)
                        .frame(maxWidth: .infinity)
                } else {
                    if !sections.active.isEmpty {
                        BookGallerySection(
                            title: "Active Books",
                            books: sections.active,
                            library: library,
                            browser: browser,
                            isActiveSection: true
                        )
                    }

                    if !sections.other.isEmpty || sections.active.isEmpty {
                        BookGallerySection(
                            title: sections.active.isEmpty ? "Books" : "Library",
                            books: sections.other,
                            library: library,
                            browser: browser,
                            isActiveSection: false
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .navigationDestination(for: Book.self) { book in
            ReaderContainerView(library: library, bookID: book.id, readerTitle: $readerTitle)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = library.backgroundProblem {
                ProblemBanner(
                    message: problem,
                    onRetry: { library.refresh(silently: false, restart: true) },
                    onDismiss: { library.dismissBackgroundProblem() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: library.backgroundProblem)
    }
}

/// Inline, dismissible notice for background failures.
private struct ProblemBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
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
    var library: LibraryModel
    @Bindable var browser: LibraryBrowserState
    var isActiveSection: Bool = false
    /// Book awaiting confirmation before it is removed from the active shelf.
    @State private var bookPendingRemoval: Book?

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
                        Picker("Sort by", selection: $browser.sort) {
                            ForEach(LibrarySortOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort: \(browser.sort.shortLabel)", systemImage: "arrow.up.arrow.down.circle")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        BookCard(book: book, fileURL: book.fileURL)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if isActiveSection {
                            Button {
                                library.markUnread(book: book)
                            } label: {
                                Label("Mark as Unread", systemImage: "arrow.uturn.backward.circle")
                            }
                        } else {
                            // Copies the book into the tracking directory so it syncs
                            // with its progress, without having to open it first.
                            Button {
                                library.markOpened(book)
                            } label: {
                                Label("Add to Active Books", systemImage: "plus.circle")
                            }
                        }

                        #if targetEnvironment(macCatalyst)
                            Button {
                                // Opening a folder URL shows it in Finder.
                                UIApplication.shared.open(book.fileURL.deletingLastPathComponent())
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                        #endif

                        if isActiveSection {
                            Divider()

                            Button(role: .destructive) {
                                bookPendingRemoval = book
                            } label: {
                                Label("Remove from Active", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove “\(bookPendingRemoval?.title ?? "")” from Active Books?",
            isPresented: Binding(
                get: { bookPendingRemoval != nil },
                set: { if !$0 { bookPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: bookPendingRemoval
        ) { book in
            Button("Remove", role: .destructive) {
                library.removeFromActive(book: book)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "This deletes the copy in the tracking directory and its reading progress, on every device that syncs it. Your original file in a local library is not touched."
            )
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
                    .frame(height: 240)
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 8)

                if book.isFinished {
                    statusBadge("Finished", tint: .green)
                        .padding(10)
                } else if book.isActive && !book.isUnreadLike {
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

                if book.isActive && !book.isUnreadLike && !book.isFinished {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), \(book.displaySubtitle)")
        .accessibilityValue(accessibilityStatus)
    }

    /// Reading state spoken after the title, e.g. "42 percent read, opened 2 hours ago".
    private var accessibilityStatus: String {
        var parts: [String] = []
        if book.isFinished {
            parts.append("Finished")
        } else if book.isUnreadLike {
            parts.append("Unread")
        } else if book.isActive {
            parts.append("\(Int((book.progress * 100).rounded())) percent read")
        }
        if let lastOpenedAt = book.lastOpenedAt {
            parts.append("opened \(Self.relativeFormatter.localizedString(for: lastOpenedAt, relativeTo: .now))")
        }
        return parts.joined(separator: ", ")
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
    var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var isPickingTrackingDirectory = false
    @State private var isPickingLocalLibrary = false

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("Tracking Directory"),
                    footer: Text(
                        "Use this as your shared active shelf: it stores the small set of books you are currently reading and their progress. Keep it in ~/Documents to sync with iCloud, or share it between computers with tools like Syncthing."
                    )
                ) {
                    HStack {
                        if let url = library.trackingDirectoryURL {
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
                            library.handlePickedTrackingDirectory(.success(firstURL))
                        }
                    case .failure(let error):
                        library.handlePickedTrackingDirectory(.failure(error))
                    }
                }

                Section(
                    header: Text("Local Libraries"),
                    footer: Text(
                        "These folders are local to this computer and are not shared across machines. They are usually best for bulk collections or older books; the app scans them for books but never modifies their contents."
                    )
                ) {
                    ForEach(Array(library.localLibraries.enumerated()), id: \.element) { index, url in
                        HStack {
                            Text(displayPath(for: url))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            // An explicit button: swipe-to-delete is hard to
                            // discover with a mouse or trackpad.
                            Button(role: .destructive) {
                                library.removeLocalLibrary(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(displayPath(for: url))")
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                library.removeLocalLibrary(at: index)
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
                            library.handlePickedLocalLibrary(.success(firstURL))
                        }
                    case .failure(let error):
                        library.handlePickedLocalLibrary(.failure(error))
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
