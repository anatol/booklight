import Foundation

/// File layout of the tracking directory, which is shared between devices:
///
///     <root>/books/<book file>       active book copies
///     <root>/progress/<book-id>.json per-book reading state
struct TrackingLayout: Hashable, Sendable {
    let root: URL

    var booksDirectory: URL {
        root.appending(path: "books", directoryHint: .isDirectory)
    }

    var progressDirectory: URL {
        root.appending(path: "progress", directoryHint: .isDirectory)
    }

    func progressFileURL(for bookID: String) -> URL {
        progressDirectory.appending(path: "\(bookID).json")
    }

    /// Compares path components (after resolving symlinks) so `/Books` doesn't
    /// match a sibling like `/BooksExtra`.
    static func isFileURL(_ fileURL: URL, containedInDirectory directoryURL: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let directoryComponents = directoryURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        guard fileComponents.count > directoryComponents.count else {
            return false
        }

        return zip(directoryComponents, fileComponents).allSatisfy { directoryComponent, fileComponent in
            directoryComponent == fileComponent
        }
    }
}

/// Locations owned by the app itself (not shared between devices).
enum AppPaths {
    /// Root for caches that can be regenerated: file hashes, thumbnails.
    static var cacheDirectory: URL {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let cacheDir = urls[0].appending(path: "com.anatol.Booklight", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }
}
