import Foundation

/// Persists the user-picked folders (tracking directory and local libraries) as
/// bookmarks and keeps their security scope open while the app runs.
@MainActor
final class FolderAccess {
    private struct ResolvedScopedURL {
        let scopedURL: URL
        let bookmarkData: Data

        var displayURL: URL {
            scopedURL.standardizedFileURL
        }
    }

    private(set) var trackingDirectoryURL: URL?
    private(set) var localLibraries: [URL] = []

    private var scopedTrackingDirectoryURL: URL?
    private var scopedLocalLibraries: [URL] = []

    private let defaults: UserDefaults
    private let trackingBookmarkKey = "Booklight.trackingDirectoryBookmark"
    private let localLibrariesKey = "Booklight.localLibrariesBookmarks"

    #if targetEnvironment(macCatalyst)
        private let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
        private let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
        private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    deinit {
        scopedTrackingDirectoryURL?.stopAccessingSecurityScopedResource()
        scopedLocalLibraries.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    func selectTrackingDirectory(at url: URL) throws {
        let resolved = try makeResolvedScopedURL(from: url)

        scopedTrackingDirectoryURL?.stopAccessingSecurityScopedResource()
        scopedTrackingDirectoryURL = resolved.scopedURL
        trackingDirectoryURL = resolved.displayURL
        defaults.set(resolved.bookmarkData, forKey: trackingBookmarkKey)
    }

    func addLocalLibrary(at url: URL) throws {
        let resolved = try makeResolvedScopedURL(from: url)

        scopedLocalLibraries.append(resolved.scopedURL)
        localLibraries.append(resolved.displayURL)
        persistLocalLibrariesBookmarks()
    }

    func removeLocalLibrary(at index: Int) {
        guard localLibraries.indices.contains(index) else { return }
        // The two lists are parallel, except for Debug-hook folders, which have
        // no security scope to release.
        if scopedLocalLibraries.indices.contains(index) {
            scopedLocalLibraries[index].stopAccessingSecurityScopedResource()
            scopedLocalLibraries.remove(at: index)
        }
        localLibraries.remove(at: index)
        persistLocalLibrariesBookmarks()
    }

    private func restore() {
        #if DEBUG
            // Test hook: `-BooklightTrackingDir <path> [-BooklightLibraryDir <path>]`
            // launch arguments select folders directly, skipping the picker and
            // bookmarks, so the app can be driven from scripts and screenshots.
            if let path = defaults.string(forKey: "BooklightTrackingDir") {
                trackingDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
                if let libraryPath = defaults.string(forKey: "BooklightLibraryDir") {
                    localLibraries = [URL(fileURLWithPath: libraryPath, isDirectory: true)]
                }
                return
            }
        #endif

        if let data = defaults.data(forKey: trackingBookmarkKey) {
            do {
                let resolved = try resolveScopedURL(from: data)
                scopedTrackingDirectoryURL = resolved.scopedURL
                trackingDirectoryURL = resolved.displayURL
                defaults.set(resolved.bookmarkData, forKey: trackingBookmarkKey)
            } catch {
                defaults.removeObject(forKey: trackingBookmarkKey)
            }
        }

        if let datas = defaults.array(forKey: localLibrariesKey) as? [Data] {
            for data in datas {
                guard let resolved = try? resolveScopedURL(from: data) else { continue }
                scopedLocalLibraries.append(resolved.scopedURL)
                localLibraries.append(resolved.displayURL)
            }
            persistLocalLibrariesBookmarks()
        }
    }

    /// Round-trip through bookmark resolution immediately so we always store the
    /// scoped URL variant the system actually granted access to.
    private func makeResolvedScopedURL(from url: URL) throws -> ResolvedScopedURL {
        let bookmark = try makeBookmarkData(for: url)
        return try resolveScopedURL(from: bookmark)
    }

    private func makeBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolveScopedURL(from bookmarkData: Data) throws -> ResolvedScopedURL {
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmarkData,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard resolved.startAccessingSecurityScopedResource() else {
            throw LibraryError.accessDenied
        }

        let refreshedBookmarkData = isStale ? try makeBookmarkData(for: resolved) : bookmarkData
        return ResolvedScopedURL(scopedURL: resolved, bookmarkData: refreshedBookmarkData)
    }

    private func persistLocalLibrariesBookmarks() {
        let bookmarks = scopedLocalLibraries.compactMap { try? makeBookmarkData(for: $0) }
        defaults.set(bookmarks, forKey: localLibrariesKey)
    }
}

enum LibraryError: LocalizedError {
    case accessDenied
    case noTrackingDirectory

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "The selected folder could not be opened with read and write access."
        case .noTrackingDirectory:
            return "Choose a tracking directory first."
        }
    }
}
