import Foundation

/// Manages the active-book copies in the tracking directory's `books/` folder.
/// Opening a book copies it there so it travels with the synced progress.
struct ActiveShelf: Sendable {
    let layout: TrackingLayout

    /// Returns the URL of the book's tracked copy, copying it in if needed.
    func ensureTracked(_ book: Book) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.booksDirectory, withIntermediateDirectories: true)

        if TrackingLayout.isFileURL(book.fileURL, containedInDirectory: layout.root) {
            return book.fileURL
        }

        let destURL = Self.destinationURL(for: book, in: layout.booksDirectory)
        if !fileManager.fileExists(atPath: destURL.path()) {
            try fileManager.copyItem(at: book.fileURL, to: destURL)
        }
        return destURL
    }

    /// Deletes the book's tracked copy. Only a file inside `books/` is removed: if
    /// the copy is gone and the book resolves to a local library, a same-named
    /// file in `books/` belongs to a different book and must be left alone.
    func removeTrackedCopy(of book: Book) throws {
        if TrackingLayout.isFileURL(book.fileURL, containedInDirectory: layout.booksDirectory) {
            try FileManager.default.removeItem(at: book.fileURL)
        }
    }

    /// Resolve a destination in the tracking directory that avoids collisions when
    /// different books share the same source filename.
    static func destinationURL(for book: Book, in booksDirectory: URL) -> URL {
        let fileManager = FileManager.default
        let preferredURL = booksDirectory.appending(path: book.fileURL.lastPathComponent)

        if !fileManager.fileExists(atPath: preferredURL.path()) {
            return preferredURL
        }

        // Reuse an existing file if it already matches byte-for-byte.
        if fileManager.contentsEqual(atPath: book.fileURL.path(), andPath: preferredURL.path()) {
            return preferredURL
        }

        let ext = book.fileURL.pathExtension
        let base = book.fileURL.deletingPathExtension().lastPathComponent
        let shortID = String(book.id.prefix(8))
        var candidateBase = "\(base)-\(shortID)"
        var counter = 2

        while true {
            let fileName = ext.isEmpty ? candidateBase : "\(candidateBase).\(ext)"
            let candidateURL = booksDirectory.appending(path: fileName)

            if !fileManager.fileExists(atPath: candidateURL.path())
                || fileManager.contentsEqual(atPath: book.fileURL.path(), andPath: candidateURL.path())
            {
                return candidateURL
            }

            candidateBase = "\(base)-\(shortID)-\(counter)"
            counter += 1
        }
    }
}
