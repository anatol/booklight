import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = LibraryController()

    var body: some View {
        NavigationStack {
            Group {
                if controller.libraryURL == nil {
                    emptyLibraryView
                } else {
                    libraryView
                }
            }
            .navigationTitle("Book Reader")
            .toolbar {
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

    private var emptyLibraryView: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

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
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.libraryURL?.lastPathComponent ?? "Library")
                        .font(.headline)
                    Text(controller.libraryURL?.path() ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let lastScanAt = controller.lastScanAt {
                        Text("Last synced \(lastScanAt.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if !controller.activeBooks.isEmpty {
                Section("Active Books") {
                    ForEach(controller.activeBooks) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book)
                        }
                    }
                }
            }

            Section(controller.activeBooks.isEmpty ? "Books" : "Library") {
                if controller.books.isEmpty {
                    Text("No PDF or EPUB files found in the selected folder.")
                        .foregroundStyle(.secondary)
                } else if controller.activeBooks.isEmpty && controller.otherBooks.isEmpty && !controller.searchText.isEmpty {
                    Text("No books match “\(controller.searchText)”")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.otherBooks) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: Book.self) { book in
            ReaderContainerView(controller: controller, bookID: book.id)
        }
        .listStyle(.insetGrouped)
    }
}

private struct BookRow: View {
    let book: Book

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: book.format.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(book.displaySubtitle)
                    if book.isFinished {
                        Text("Finished")
                    } else if book.progress > 0 {
                        Text("\(Int((book.progress * 100).rounded()))%")
                    } else {
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
        .padding(.vertical, 4)
    }
}
