import CryptoKit
import Foundation

/// Discovers books in the tracking directory and local libraries.
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

    /// Scans the tracking directory first so a book that has an active copy
    /// resolves to that copy rather than to its local-library original.
    func scan(layout: TrackingLayout, localLibraries: [URL], progressStates: [String: BookProgressState]) throws -> [Book] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.booksDirectory, withIntermediateDirectories: true)

        var hashCache = loadHashCache()
        var seenCachePaths = Set<String>()
        seenCachePaths.reserveCapacity(hashCache.records.count)
        var generatedBooks: [Book] = []
        var seenHashes = Set<String>()
        var cacheUpdated = false
        var completedScan = false

        func saveCacheIfNeeded() {
            guard cacheUpdated else { return }
            saveHashCache(hashCache)
            cacheUpdated = false
        }

        defer {
            // Only prune after a full scan; a cancelled scan hasn't seen every file.
            if completedScan {
                for path in Array(hashCache.records.keys) where !seenCachePaths.contains(path) {
                    hashCache.records.removeValue(forKey: path)
                    cacheUpdated = true
                }
            }
            saveCacheIfNeeded()
        }

        func processDirectory(at url: URL) throws {
            guard
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { return }

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

                generatedBooks.append(
                    Book(
                        id: hash,
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        fileURL: fileURL,
                        format: format,
                        fileSize: fileSize,
                        addedAt: modifiedAt,
                        modifiedAt: modifiedAt,
                        progressState: progressStates[hash]
                    )
                )
            }

            saveCacheIfNeeded()
        }

        try processDirectory(at: layout.booksDirectory)
        for library in localLibraries {
            try processDirectory(at: library)
        }

        completedScan = true
        generatedBooks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return generatedBooks
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
