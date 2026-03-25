import Foundation
import zlib

struct EPUBDocument: Sendable {
    struct SpineItem: Hashable, Sendable {
        var index: Int
        var href: String
        var url: URL
    }

    var title: String
    var extractedRootURL: URL
    var spine: [SpineItem]
    /// URL of the combined single-page HTML that merges all spine chapters
    /// into one continuous scrollable document.
    var combinedHTMLURL: URL
}

enum EPUBPreparation {
    /// Prepares an EPUB document for reading by extracting it to the cache directory.
    /// Uses NSFileCoordinator to ensure the source file is accessible — this is required
    /// on iOS when reading files from user-selected directories backed by file providers
    /// (iCloud Drive, Syncthing, Files app, etc.). Without coordination, the file may
    /// appear in directory listings but fail with "No such file" when reading content.
    static func prepareDocument(for book: Book, sourceURL: URL) throws -> EPUBDocument {
        var coordinatorError: NSError?
        var result: Result<EPUBDocument, Error>!

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            result = Result { try prepareFromCoordinatedURL(for: book, sourceURL: coordinatedURL) }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        return try result.get()
    }

    /// The actual preparation logic, called with a coordinated URL that the system
    /// guarantees is accessible on disk.
    private static func prepareFromCoordinatedURL(for book: Book, sourceURL: URL) throws -> EPUBDocument {
        let fileManager = FileManager.default
        let cacheRoot = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "EPUBCache", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let extractedRoot = cacheRoot.appending(path: book.id, directoryHint: .isDirectory)
        let versionURL = extractedRoot.appending(path: ".version")

        // Use URL-based resource values instead of path-based attributesOfItem —
        // URL-based APIs respect security-scoped access better on iOS.
        let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(resourceValues.fileSize ?? 0)
        let modifiedAt = resourceValues.contentModificationDate ?? .distantPast
        let expectedVersion = "\(fileSize)-\(Int(modifiedAt.timeIntervalSince1970))"

        let currentVersion = try? String(contentsOf: versionURL, encoding: .utf8)
        if currentVersion != expectedVersion {
            try? fileManager.removeItem(at: extractedRoot)
            try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
            try EPUBArchiveExtractor.extractArchive(at: sourceURL, to: extractedRoot)
            try expectedVersion.write(to: versionURL, atomically: true, encoding: .utf8)
        }

        return try parseExtractedBook(at: extractedRoot, fallbackTitle: book.title)
    }

    private static func parseExtractedBook(at extractedRoot: URL, fallbackTitle: String) throws -> EPUBDocument {
        let containerURL = extractedRoot.appending(path: "META-INF/container.xml")
        let container = try ContainerDocument.parse(url: containerURL)
        guard let rootFilePath = container.rootFilePath else {
            throw EPUBError.missingPackagePath
        }

        let packageURL = extractedRoot.appending(path: rootFilePath)
        let package = try PackageDocumentParser.parse(url: packageURL)
        let packageDirectory = packageURL.deletingLastPathComponent()

        let spineItems: [EPUBDocument.SpineItem] = package.spine.enumerated().compactMap { offset, item in
            guard let manifestItem = package.manifest[item] else {
                return nil
            }

            let href = manifestItem.href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? manifestItem.href
            let decodedHref = href.removingPercentEncoding ?? href
            let itemURL = URL(fileURLWithPath: decodedHref, relativeTo: packageDirectory).standardizedFileURL
            return EPUBDocument.SpineItem(index: offset, href: decodedHref, url: itemURL)
        }

        guard !spineItems.isEmpty else {
            throw EPUBError.missingReadableContent
        }

        // Build a single combined HTML that merges all chapters for continuous scrolling.
        let combinedURL = try EPUBCombiner.buildCombinedHTML(
            spine: spineItems,
            extractedRootURL: extractedRoot
        )

        return EPUBDocument(
            title: package.title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nonEmpty ?? fallbackTitle,
            extractedRootURL: extractedRoot,
            spine: spineItems,
            combinedHTMLURL: combinedURL
        )
    }
}

// MARK: - Combined HTML Generator

/// Combines all EPUB spine chapters into a single HTML document for continuous scrolling.
/// Each chapter's body content is extracted, resource paths are rewritten to be relative
/// to the extraction root, and everything is wrapped in chapter dividers.
/// The result is cached as `_combined.html` in the extraction directory — it's automatically
/// invalidated when the EPUB is re-extracted (the directory is wiped on version change).
enum EPUBCombiner {
    /// Builds (or returns cached) combined HTML from all spine items.
    /// - Returns: URL of the `_combined.html` file in the extraction directory.
    static func buildCombinedHTML(
        spine: [EPUBDocument.SpineItem],
        extractedRootURL: URL
    ) throws -> URL {
        let combinedURL = extractedRootURL.appending(path: "_combined.html")

        // If the combined file already exists (from a previous open), reuse it.
        if FileManager.default.fileExists(atPath: combinedURL.path()) {
            return combinedURL
        }

        var stylesheetPaths: [String] = []
        var chapterBodies: [(index: Int, html: String)] = []

        let rootPath = extractedRootURL.path()

        for item in spine {
            guard let rawContent = try? String(contentsOf: item.url, encoding: .utf8) else {
                continue
            }

            // Compute the chapter's directory relative to the extraction root,
            // so we can prefix relative resource paths (images, CSS, etc.).
            let chapterDir: String
            let chapterFilePath = item.url.path()
            if chapterFilePath.hasPrefix(rootPath) {
                let relativePath = String(chapterFilePath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
                let components = relativePath.split(separator: "/").dropLast()
                chapterDir = components.isEmpty ? "" : components.joined(separator: "/") + "/"
            } else {
                chapterDir = ""
            }

            // Collect <link rel="stylesheet"> hrefs from the chapter's <head>.
            collectStylesheets(from: rawContent, chapterDir: chapterDir, into: &stylesheetPaths)

            // Extract the <body> content (everything between <body...> and </body>).
            let bodyContent = extractBody(from: rawContent)

            // Rewrite relative resource paths (src="...", href="...") to be
            // relative to the extraction root by prefixing with the chapter's directory.
            var rewritten = rewriteResourcePaths(in: bodyContent, chapterDir: chapterDir)
            // Add lazy loading to images so off-screen content doesn't consume memory.
            rewritten = addLazyLoading(to: rewritten)

            chapterBodies.append((index: item.index, html: rewritten))
        }

        // Build the combined HTML document.
        var html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">

            """

        // Include each unique stylesheet once at the top.
        for path in stylesheetPaths {
            html += "<link rel=\"stylesheet\" href=\"\(escapeHTMLAttribute(path))\">\n"
        }

        html += """
            <style>
            /* Divider between chapters for visual separation */
            .epub-chapter-divider {
                height: 1px;
                background: rgba(128, 128, 128, 0.3);
                margin: 3em 0;
            }
            </style>
            </head>
            <body>

            """

        for (offset, chapter) in chapterBodies.enumerated() {
            if offset > 0 {
                html += "<div class=\"epub-chapter-divider\"></div>\n"
            }
            html += "<div id=\"chapter-\(chapter.index)\" class=\"epub-chapter\" data-chapter-index=\"\(chapter.index)\">\n"
            html += chapter.html
            html += "\n</div>\n"
        }

        html += """
            </body>
            </html>
            """

        try html.write(to: combinedURL, atomically: true, encoding: .utf8)
        return combinedURL
    }

    // MARK: - HTML Parsing Helpers

    /// Extracts the inner content of the <body> element.
    /// Falls back to the full content if no <body> tag is found (some EPUBs omit it).
    private static func extractBody(from html: String) -> String {
        // Find opening <body...> tag (case-insensitive).
        guard let bodyOpenRange = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) else {
            return html
        }
        let afterBodyOpen = html[bodyOpenRange.upperBound...]

        // Find closing </body> tag.
        guard let bodyCloseRange = afterBodyOpen.range(of: "</body>", options: [.caseInsensitive]) else {
            return String(afterBodyOpen)
        }

        return String(afterBodyOpen[..<bodyCloseRange.lowerBound])
    }

    /// Finds <link rel="stylesheet" href="..."> in the HTML head and collects
    /// their hrefs (prefixed with chapterDir for correct resolution).
    private static func collectStylesheets(
        from html: String,
        chapterDir: String,
        into paths: inout [String]
    ) {
        // Match <link> tags with rel="stylesheet" and extract the href value.
        // This handles both single and double quotes, and attributes in any order.
        let linkPattern = #"<link\b[^>]*rel\s*=\s*["']stylesheet["'][^>]*href\s*=\s*["']([^"']+)["'][^>]*/?\s*>"#
        let altPattern = #"<link\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*rel\s*=\s*["']stylesheet["'][^>]*/?\s*>"#

        for pattern in [linkPattern, altPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let nsRange = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: nsRange) {
                guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
                let href = String(html[hrefRange])
                // Skip absolute URLs (http/https/data).
                guard !href.hasPrefix("http") && !href.hasPrefix("data:") else { continue }
                let fullPath = chapterDir + href
                if !paths.contains(fullPath) {
                    paths.append(fullPath)
                }
            }
        }
    }

    /// Rewrites relative `src` and `href` attribute values by prefixing them with the
    /// chapter's directory path. Skips absolute URLs, data URIs, fragment-only refs,
    /// and stylesheet links (handled separately).
    private static func rewriteResourcePaths(in html: String, chapterDir: String) -> String {
        // If the chapter is at the extraction root, no rewriting needed.
        guard !chapterDir.isEmpty else { return html }

        // Match src="..." and href="..." attributes, capturing the attribute value.
        let pattern = #"((?:src|href)\s*=\s*["'])([^"']+)(["'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }

        var result = html
        let nsString = result as NSString

        // Process matches in reverse order so replacements don't shift offsets.
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                let prefixRange = Range(match.range(at: 1), in: result),
                let valueRange = Range(match.range(at: 2), in: result),
                let suffixRange = Range(match.range(at: 3), in: result)
            else {
                continue
            }

            let value = String(result[valueRange])

            // Skip values that are already absolute, data URIs, or fragment-only references.
            if value.hasPrefix("http") || value.hasPrefix("data:") || value.hasPrefix("#") || value.hasPrefix("/") {
                continue
            }

            let rewritten = chapterDir + value
            let replacement = String(result[prefixRange]) + rewritten + String(result[suffixRange])
            result.replaceSubrange(match.range(at: 0).asRange(in: result)!, with: replacement)
        }

        return result
    }

    /// Adds `loading="lazy"` to <img> tags that don't already have it,
    /// so off-screen images don't consume memory until scrolled into view.
    private static func addLazyLoading(to html: String) -> String {
        let pattern = #"(<img\b)(?![^>]*loading\s*=)([^>]*>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: "$1 loading=\"lazy\"$2"
        )
    }

    private static func escapeHTMLAttribute(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - NSRange → Range<String.Index> helper

private extension NSRange {
    func asRange(in string: String) -> Range<String.Index>? {
        Range(self, in: string)
    }
}

private enum EPUBError: LocalizedError {
    case invalidArchive
    case missingContainer
    case missingPackagePath
    case missingReadableContent
    case unsupportedCompression
    case invalidCompressedData

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "The EPUB file is not a valid ZIP archive."
        case .missingContainer:
            return "The EPUB container manifest is missing."
        case .missingPackagePath:
            return "The EPUB package document could not be located."
        case .missingReadableContent:
            return "The EPUB does not contain readable XHTML content."
        case .unsupportedCompression:
            return "The EPUB uses a compression mode this app does not support."
        case .invalidCompressedData:
            return "The EPUB archive could not be decompressed."
        }
    }
}

private enum EPUBArchiveExtractor {
    private struct Entry {
        var path: String
        var compressionMethod: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    static func extractArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let entries = try parseCentralDirectory(in: archiveData)
        let fileManager = FileManager.default

        for entry in entries {
            let safeComponents = entry.path
                .split(separator: "/")
                .map(String.init)
                .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

            guard !safeComponents.isEmpty else {
                continue
            }

            var outputURL = destinationURL
            for component in safeComponents {
                outputURL.append(path: component)
            }

            if entry.path.hasSuffix("/") {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }

            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let extractedData = try data(for: entry, in: archiveData)
            try extractedData.write(to: outputURL, options: [.atomic])
        }
    }

    private static func parseCentralDirectory(in data: Data) throws -> [Entry] {
        let eocdSignature: UInt32 = 0x06054b50
        let centralSignature: UInt32 = 0x02014b50

        let lowerBound = max(0, data.count - 65_557)
        guard
            let eocdOffset = stride(from: data.count - 22, through: lowerBound, by: -1).first(where: {
                data.uint32LE(at: $0) == eocdSignature
            })
        else {
            throw EPUBError.invalidArchive
        }

        let entryCount = Int(data.uint16LE(at: eocdOffset + 10))
        let centralDirectoryOffset = Int(data.uint32LE(at: eocdOffset + 16))

        var cursor = centralDirectoryOffset
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0 ..< entryCount {
            guard data.uint32LE(at: cursor) == centralSignature else {
                throw EPUBError.invalidArchive
            }

            let compressionMethod = data.uint16LE(at: cursor + 10)
            let compressedSize = Int(data.uint32LE(at: cursor + 20))
            let uncompressedSize = Int(data.uint32LE(at: cursor + 24))
            let fileNameLength = Int(data.uint16LE(at: cursor + 28))
            let extraFieldLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let localHeaderOffset = Int(data.uint32LE(at: cursor + 42))

            let fileNameOffset = cursor + 46
            let fileNameData = data.subdata(in: fileNameOffset ..< (fileNameOffset + fileNameLength))
            let fileName = String(data: fileNameData, encoding: .utf8) ?? String(data: fileNameData, encoding: .isoLatin1) ?? ""

            entries.append(
                Entry(
                    path: fileName,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )

            cursor += 46 + fileNameLength + extraFieldLength + commentLength
        }

        return entries
    }

    private static func data(for entry: Entry, in archiveData: Data) throws -> Data {
        let localSignature: UInt32 = 0x04034b50
        let localHeaderOffset = entry.localHeaderOffset
        guard archiveData.uint32LE(at: localHeaderOffset) == localSignature else {
            throw EPUBError.invalidArchive
        }

        let fileNameLength = Int(archiveData.uint16LE(at: localHeaderOffset + 26))
        let extraFieldLength = Int(archiveData.uint16LE(at: localHeaderOffset + 28))
        let payloadOffset = localHeaderOffset + 30 + fileNameLength + extraFieldLength
        let payloadRange = payloadOffset ..< (payloadOffset + entry.compressedSize)
        let payload = archiveData.subdata(in: payloadRange)

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try inflateRawDeflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw EPUBError.unsupportedCompression
        }
    }

    private static func inflateRawDeflate(_ compressedData: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let windowBits = -MAX_WBITS
        let status = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw EPUBError.invalidCompressedData
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data(count: max(expectedSize, 32_768))
        var resultStatus: Int32 = Z_OK

        try compressedData.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.bindMemory(to: Bytef.self).baseAddress else {
                throw EPUBError.invalidCompressedData
            }

            stream.next_in = UnsafeMutablePointer(mutating: sourceBase)
            stream.avail_in = uInt(compressedData.count)

            while resultStatus == Z_OK {
                if Int(stream.total_out) >= output.count {
                    output.count += max(expectedSize / 2, 32_768)
                }

                let availableOut = output.count - Int(stream.total_out)
                resultStatus = output.withUnsafeMutableBytes { outputBytes in
                    let outputBase = outputBytes.bindMemory(to: Bytef.self).baseAddress!
                    stream.next_out = outputBase.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(availableOut)
                    return inflate(&stream, Z_SYNC_FLUSH)
                }
            }
        }

        guard resultStatus == Z_STREAM_END else {
            throw EPUBError.invalidCompressedData
        }

        output.count = Int(stream.total_out)
        return output
    }
}

private struct ContainerDocument {
    var rootFilePath: String?

    static func parse(url: URL) throws -> ContainerDocument {
        guard let parser = XMLParser(contentsOf: url) else {
            throw EPUBError.missingContainer
        }

        let mutableDelegate = MutableContainerParser()
        parser.delegate = mutableDelegate
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? EPUBError.missingContainer
        }

        guard let rootFilePath = mutableDelegate.rootFilePath else {
            throw EPUBError.missingPackagePath
        }

        return ContainerDocument(rootFilePath: rootFilePath)
    }
}

private final class MutableContainerParser: NSObject, XMLParserDelegate {
    var rootFilePath: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName.lowercased().hasSuffix("rootfile") {
            rootFilePath = attributeDict["full-path"]
        }
    }
}

private struct PackageDocument {
    var title: String?
    var manifest: [String: ManifestItem]
    var spine: [String]

    struct ManifestItem {
        var href: String
        var mediaType: String
    }
}

private enum PackageDocumentParser {
    static func parse(url: URL) throws -> PackageDocument {
        guard let parser = XMLParser(contentsOf: url) else {
            throw EPUBError.missingPackagePath
        }

        let delegate = MutablePackageParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? EPUBError.missingPackagePath
        }

        let readableManifest = delegate.manifest.filter { _, item in
            item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html"
        }
        let spine = delegate.spine.filter { readableManifest[$0] != nil }

        return PackageDocument(
            title: delegate.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            manifest: readableManifest,
            spine: spine
        )
    }
}

private final class MutablePackageParser: NSObject, XMLParserDelegate {
    var title = ""
    var manifest: [String: PackageDocument.ManifestItem] = [:]
    var spine: [String] = []

    private var isInsideTitle = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let lowered = elementName.lowercased()

        if lowered.hasSuffix("title") {
            isInsideTitle = true
        } else if lowered == "item" || lowered.hasSuffix(":item") {
            if let id = attributeDict["id"], let href = attributeDict["href"], let mediaType = attributeDict["media-type"] {
                manifest[id] = .init(href: href, mediaType: mediaType)
            }
        } else if lowered == "itemref" || lowered.hasSuffix(":itemref") {
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideTitle {
            title += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased().hasSuffix("title") {
            isInsideTitle = false
        }
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
