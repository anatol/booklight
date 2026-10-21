import CryptoKit
import Foundation

/// A book file found on disk, identified by its content hash.
struct ScannedFile: Hashable, Sendable {
    var id: String
    var fileURL: URL
    var format: BookFormat
    var fileSize: Int64
    var modifiedAt: Date
}

/// Discovers book files in the tracking directory and local libraries.
///
/// Books are identified by the SHA-256 of their contents so the same file in
/// several folders (or on several devices) maps to one progress record. Hashes
/// are cached by path, size and modification date so rescans stay cheap. Being
/// an actor serializes scans, so two can never race on the hash cache file.
actor LibraryScanner {
    private let cacheFileURL: URL

    init(cacheDirectory: URL = AppPaths.cacheDirectory) {
        self.cacheFileURL = cacheDirectory.appending(path: "hashes.json")
    }

    /// Returns every PDF/EPUB under `directories`, deduplicated by content (the
    /// first directory wins). Cache records for files that disappeared from the
    /// scanned directories are pruned; records for other directories are kept so
    /// a tracking-only scan doesn't evict the local libraries' hashes.
    func scan(directories: [URL]) throws -> [ScannedFile] {
        let fileManager = FileManager.default
        var hashCache = loadHashCache()
        var seenCachePaths = Set<String>()
        var files: [ScannedFile] = []
        var seenHashes = Set<String>()
        var cacheUpdated = false
        var completedScan = false

        func saveCacheIfNeeded() {
            guard cacheUpdated else { return }
            saveHashCache(hashCache)
            cacheUpdated = false
        }

        defer {
            // Only prune after a full pass; a cancelled scan hasn't seen every file.
            if completedScan {
                let scannedPrefixes = directories.map { Self.directoryPrefix(for: $0) }
                for path in Array(hashCache.records.keys) where !seenCachePaths.contains(path) {
                    if scannedPrefixes.contains(where: { path.hasPrefix($0) }) {
                        hashCache.records.removeValue(forKey: path)
                        cacheUpdated = true
                    }
                }
            }
            saveCacheIfNeeded()
        }

        for directory in directories {
            guard
                let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }

            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()
                guard let format = BookFormat(url: fileURL) else { continue }
                guard
                    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate,
                    let fileSizeVal = values.fileSize
                else { continue }

                let fileSize = Int64(fileSizeVal)
                let pathKey = fileURL.path()
                seenCachePaths.insert(pathKey)

                let hash: String
                if let record = hashCache.records[pathKey], record.fileSize == fileSize,
                    abs(record.modifiedAt.timeIntervalSince(modifiedAt)) < 1.0
                {
                    hash = record.contentHash
                } else {
                    hash = try Self.calculateHash(fileURL: fileURL)
                    hashCache.records[pathKey] = FileHashRecord(
                        path: pathKey,
                        fileSize: fileSize,
                        modifiedAt: modifiedAt,
                        contentHash: hash
                    )
                    cacheUpdated = true
                }

                guard seenHashes.insert(hash).inserted else { continue }
                files.append(ScannedFile(id: hash, fileURL: fileURL, format: format, fileSize: fileSize, modifiedAt: modifiedAt))
            }

            saveCacheIfNeeded()
        }

        completedScan = true
        return files
    }

    /// Builds the library from the tracking directory's files and the local
    /// libraries' files. Tracking files come first so a book with an active copy
    /// resolves to that copy rather than to its local-library original.
    static func composeBooks(
        trackingFiles: [ScannedFile],
        libraryFiles: [ScannedFile],
        progressStates: [String: BookProgressState]
    ) -> [Book] {
        var seen = Set<String>()
        var books: [Book] = []
        for file in trackingFiles + libraryFiles where seen.insert(file.id).inserted {
            books.append(
                Book(
                    id: file.id,
                    title: file.fileURL.deletingPathExtension().lastPathComponent,
                    fileURL: file.fileURL,
                    format: file.format,
                    fileSize: file.fileSize,
                    addedAt: file.modifiedAt,
                    modifiedAt: file.modifiedAt,
                    progressState: progressStates[file.id]
                )
            )
        }
        books.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return books
    }

    /// Cache keys are `URL.path()` strings, so match them against the same form.
    private static func directoryPrefix(for directory: URL) -> String {
        let path = directory.path()
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func loadHashCache() -> FileHashCache {
        guard let data = try? Data(contentsOf: cacheFileURL),
            let cache = try? JSONDecoder().decode(FileHashCache.self, from: data)
        else {
            return FileHashCache()
        }
        return cache
    }

    private func saveHashCache(_ cache: FileHashCache) {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }

    static func calculateHash(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
