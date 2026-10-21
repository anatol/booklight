import Foundation
import zlib

struct EPUBDocument: Sendable {
    struct SpineItem: Hashable, Sendable {
        var index: Int
        var href: String
        var url: URL
    }

    struct TOCEntry: Hashable, Sendable {
        var title: String
        var level: Int
        var spineIndex: Int
        var fragment: String?
    }

    var title: String
    var extractedRootURL: URL
    var spine: [SpineItem]
    var tableOfContents: [TOCEntry]
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

    static func parseExtractedBook(at extractedRoot: URL, fallbackTitle: String) throws -> EPUBDocument {
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

        // The table of contents is optional: a missing or malformed one just
        // means the book has no contents list.
        var tableOfContents: [EPUBDocument.TOCEntry] = []
        if let tocHref = package.tocHref {
            let tocURL = URL(fileURLWithPath: tocHref.removingPercentEncoding ?? tocHref, relativeTo: packageDirectory).standardizedFileURL
            tableOfContents = EPUBTableOfContents.entries(at: tocURL, spine: spineItems)
        }

        return EPUBDocument(
            title: package.title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nonEmpty ?? fallbackTitle,
            extractedRootURL: extractedRoot,
            spine: spineItems,
            tableOfContents: tableOfContents,
            combinedHTMLURL: combinedURL
        )
    }
}

// MARK: - Combined HTML Generator

// The helpers below are internal (not private) so unit tests can exercise them directly.

/// Combines all EPUB spine chapters into a single HTML document for continuous scrolling.
/// Each chapter's body content is extracted, resource paths are rewritten to be relative
/// to the extraction root, and everything is wrapped in chapter dividers.
/// The result is cached as `_combined-v10.html` in the extraction directory — it's automatically
/// invalidated when the EPUB is re-extracted (the directory is wiped on version change).
enum EPUBCombiner {
    /// Builds (or returns cached) combined HTML from all spine items.
    /// - Returns: URL of the `_combined-v10.html` file in the extraction directory.
    static func buildCombinedHTML(
        spine: [EPUBDocument.SpineItem],
        extractedRootURL: URL
    ) throws -> URL {
        // The filename carries a layout version suffix so that bumping the reading
        // CSS below regenerates the combined document for already-extracted books
        // (rebuilding from the cached chapters is cheap — no re-unzip required).
        let combinedURL = extractedRootURL.appending(path: "_combined-v10.html")

        // If the combined file already exists (from a previous open), reuse it.
        if FileManager.default.fileExists(atPath: combinedURL.path()) {
            return combinedURL
        }

        var stylesheetPaths: [String] = []
        var chapterBodies: [(index: Int, path: String, html: String)] = []

        let rootPath = extractedRootURL.path()

        for item in spine {
            guard let rawContent = try? String(contentsOf: item.url, encoding: .utf8) else {
                continue
            }

            // Compute the chapter's directory relative to the extraction root,
            // so we can prefix relative resource paths (images, CSS, etc.).
            let chapterDir: String
            let chapterRelativePath: String
            let chapterFilePath = item.url.path()
            if chapterFilePath.hasPrefix(rootPath) {
                let relativePath = String(chapterFilePath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
                let components = relativePath.split(separator: "/").dropLast()
                chapterDir = components.isEmpty ? "" : components.joined(separator: "/") + "/"
                chapterRelativePath = relativePath
            } else {
                chapterDir = ""
                chapterRelativePath = item.url.lastPathComponent
            }

            // Collect <link rel="stylesheet"> hrefs from the chapter's <head>.
            collectStylesheets(from: rawContent, chapterDir: chapterDir, into: &stylesheetPaths)

            // Extract the <body> content (everything between <body...> and </body>).
            let bodyContent = expandSelfClosingTags(in: extractBody(from: rawContent))

            // Rewrite relative resource paths (src="...", href="...") to be
            // relative to the extraction root by prefixing with the chapter's directory.
            var rewritten = rewriteResourcePaths(in: bodyContent, chapterDir: chapterDir)
            // Add lazy loading to images so off-screen content doesn't consume memory.
            rewritten = addLazyLoading(to: rewritten)

            chapterBodies.append((index: item.index, path: chapterRelativePath, html: rewritten))
        }

        // Build the combined HTML document.
        var html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">

            """

        // Include each unique stylesheet once at the top.
        for path in stylesheetPaths {
            html += "<link rel=\"stylesheet\" href=\"\(escapeHTMLAttribute(path))\">\n"
        }

        // Reading layout injected after the EPUB's own stylesheets so it wins on
        // equal specificity. It turns the raw, full-bleed XHTML into a clean
        // reading page that fills the viewport width with small side margins and
        // a readable base size.
        html += """
            <style>
            :root { color-scheme: light; }

            html {
                /* Comfortable reading base. The font-size controls scale this value
                   (see EPUBReaderView); using px makes the percentage map to a
                   readable default instead of the browser's small 16px. */
                font-size: 30px;
                -webkit-text-size-adjust: 100%;
                text-size-adjust: 100%;
                background-color: #ffffff;
                /* Guard against any single element forcing horizontal scrolling,
                   which previously made the whole page shift sideways and clipped
                   the first characters of each line. */
                overflow-x: hidden;
            }

            /* The reading surface: a plain page that fills the viewport width so
               wide screens use their space instead of showing empty gutters.
               Overrides whatever box model the EPUB's own CSS sets. */
            body {
                box-sizing: border-box;
                max-width: none !important;
                width: auto !important;
                /* Some EPUBs pin body to height:100% (meant for paginated chapters);
                   force auto so the page surface grows to cover all the content. */
                height: auto !important;
                margin: 0 !important;
                /* Honor device safe areas (notch / home indicator) since the reader
                   runs full-screen with no chrome. Side margins stay small but scale
                   gently with width (4vw) so the text reflows to fill the screen. */
                padding-top: max(0.75rem, env(safe-area-inset-top)) !important;
                padding-bottom: max(6rem, env(safe-area-inset-bottom)) !important;
                padding-left: max(env(safe-area-inset-left), 24px, 4vw) !important;
                padding-right: max(env(safe-area-inset-right), 24px, 4vw) !important;
                background-color: #ffffff;
                color: #1a1a1a;
                line-height: 1.6;
                /* Wrap long words / URLs instead of overflowing the page. */
                overflow-wrap: break-word;
                word-wrap: break-word;
                -webkit-hyphens: auto;
                hyphens: auto;
                -webkit-font-smoothing: antialiased;
                text-rendering: optimizeLegibility;
            }

            /* Keep media within the column — fixed-width images, figures and SVGs
               were a major cause of horizontal overflow. */
            img, svg, video, canvas, iframe {
                max-width: 100% !important;
                height: auto;
            }
            /* Publishers often size images to the page width (img { width: 100% })
               assuming a phone-sized paginated screen. On a wide window that turns a
               portrait photo into something several screens tall. Cap the height to
               the viewport; object-fit keeps the aspect ratio when the cap kicks in. */
            img {
                max-height: 85vh;
                object-fit: contain;
            }

            /* Line spacing for running text.
               Many publisher stylesheets set tight line-heights (1em–1.2em) on every
               paragraph class, tuned for a small paginated page; on screen the lines
               nearly touch. Class rules beat the body's line-height, so this needs
               !important to apply. Headings get a tighter value so multi-line titles
               still read as one block. */
            p, li, dd, dt, blockquote, figcaption, td, th {
                line-height: 1.5 !important;
            }
            h1, h2, h3, h4, h5, h6 {
                line-height: 1.25 !important;
            }

            /* Let wide preformatted blocks wrap rather than overflow the page. */
            pre {
                white-space: pre-wrap;
                overflow-wrap: break-word;
            }
            table { max-width: 100%; }

            /* Prevent EPUB link colors from bleeding into block elements wrapped
               in <a> tags (common in textbooks for navigation anchors). */
            a { color: inherit; }

            /* Lists.
               Many EPUBs run a global CSS reset (margin:0; padding:0;
               list-style:none) and only restore markers and indentation through
               publisher-specific classes. When a list carries no such class — or
               the book ships no list CSS at all — the markers collapse against the
               body's left padding and the items read as run-together paragraphs
               with no bullets or numbers. These fallbacks give such lists a
               readable indent and visible markers.

               They are deliberately low-specificity element selectors with no
               !important, and they sit *after* the EPUB's own stylesheets. So at
               equal specificity they win over the blanket element-level reset
               (`ul, ol { list-style: none }`) but lose to any publisher rule that
               targets a class or descendant path (e.g. `ul.UList`, `body ol`),
               which is almost always more specific. Net effect: bare/unstyled
               lists get fixed, intentionally-styled lists are left untouched. */
            ul, ol {
                margin-top: 1em;
                margin-bottom: 1em;
                /* Indent enough that markers sit inside the reading column rather
                   than in the body's side padding, where they'd crowd or clip
                   against the screen edge. em units scale with the reader's
                   font-size control. */
                padding-left: 1.75em;
            }
            ul { list-style-type: disc; }
            ol { list-style-type: decimal; }
            /* Distinct markers for nested unordered lists, matching print style. */
            ul ul { list-style-type: circle; }
            ul ul ul { list-style-type: square; }
            /* Nested lists shouldn't add a large vertical gap inside their item. */
            li > ul, li > ol { margin-top: 0.4em; margin-bottom: 0.4em; }
            /* Definition lists: indent definitions under their terms. */
            dd { margin-left: 1.75em; }

            /* Reading themes: the reader sets data-theme on <html>. Light keeps the
               book's own styling; sepia and dark recolor everything so text stays
               legible regardless of the colors the EPUB hard-codes. */
            html[data-theme="sepia"], html[data-theme="sepia"] body {
                background-color: #f4ecd8 !important; color: #5b4636 !important;
            }
            html[data-theme="dark"], html[data-theme="dark"] body {
                background-color: #1c1c1e !important; color: #e4e4e6 !important;
            }
            html[data-theme="sepia"] body *, html[data-theme="dark"] body * {
                color: inherit !important; background-color: transparent !important;
            }
            /* Diagrams with transparent backgrounds assume a light page. */
            html[data-theme="dark"] img { background-color: #ffffff !important; }

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
            // `data-chapter-path` (relative to the extraction root) lets the reader map
            // cross-chapter links like `ch2.xhtml#sec` onto this div.
            html +=
                "<div id=\"chapter-\(chapter.index)\" class=\"epub-chapter\" data-chapter-index=\"\(chapter.index)\" data-chapter-path=\"\(escapeHTMLAttribute(chapter.path))\">\n"
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
    static func extractBody(from html: String) -> String {
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

    /// Rewrites XHTML self-closing tags for non-void elements (`<div/>`, `<p/>`,
    /// `<span/>`, `<a id="x"/>`, …) into explicit `<div></div>` pairs.
    ///
    /// Chapters are XHTML, where `<div class="rule"/>` is an empty element. But the
    /// combined document is parsed as HTML, which ignores the trailing slash and
    /// treats it as an *opening* tag that never closes — so everything after it
    /// becomes its child. Publishers use such empty divs for decorative rules with
    /// `width: 25%`, which then squeezed the rest of the chapter into a narrow
    /// column (nested ones compounded down to a word per line), and empty anchors
    /// turned the following text into a link.
    /// Void elements (img, br, hr, …) are left alone since HTML handles them.
    static func expandSelfClosingTags(in html: String) -> String {
        let pattern =
            #"<(?!(?:area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)\b)([A-Za-z][A-Za-z0-9:_-]*)((?:\s[^<>]*?)?)\s*/>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: "<$1$2></$1>"
        )
    }

    /// Finds <link rel="stylesheet" href="..."> in the HTML head and collects
    /// their hrefs (prefixed with chapterDir for correct resolution).
    static func collectStylesheets(
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
    static func rewriteResourcePaths(in html: String, chapterDir: String) -> String {
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
    static func addLazyLoading(to html: String) -> String {
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

    static func escapeHTMLAttribute(_ string: String) -> String {
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

enum EPUBError: LocalizedError {
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

enum EPUBArchiveExtractor {
    struct Entry {
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

        // The end-of-central-directory record is 22 bytes plus an optional comment
        // of up to 64 KiB, so it must start within the last 65,557 bytes.
        guard data.count >= 22 else {
            throw EPUBError.invalidArchive
        }
        let lowerBound = max(0, data.count - 65_557)
        guard
            let eocdOffset = stride(from: data.count - 22, through: lowerBound, by: -1).first(where: {
                (try? data.uint32LE(at: $0)) == eocdSignature
            })
        else {
            throw EPUBError.invalidArchive
        }

        let entryCount = Int(try data.uint16LE(at: eocdOffset + 10))
        let centralDirectoryOffset = Int(try data.uint32LE(at: eocdOffset + 16))

        var cursor = centralDirectoryOffset
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0 ..< entryCount {
            guard try data.uint32LE(at: cursor) == centralSignature else {
                throw EPUBError.invalidArchive
            }

            let compressionMethod = try data.uint16LE(at: cursor + 10)
            let compressedSize = Int(try data.uint32LE(at: cursor + 20))
            let uncompressedSize = Int(try data.uint32LE(at: cursor + 24))
            let fileNameLength = Int(try data.uint16LE(at: cursor + 28))
            let extraFieldLength = Int(try data.uint16LE(at: cursor + 30))
            let commentLength = Int(try data.uint16LE(at: cursor + 32))
            let localHeaderOffset = Int(try data.uint32LE(at: cursor + 42))

            let fileNameOffset = cursor + 46
            let fileNameData = try data.checkedSubdata(offset: fileNameOffset, length: fileNameLength)
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
        guard try archiveData.uint32LE(at: localHeaderOffset) == localSignature else {
            throw EPUBError.invalidArchive
        }

        let fileNameLength = Int(try archiveData.uint16LE(at: localHeaderOffset + 26))
        let extraFieldLength = Int(try archiveData.uint16LE(at: localHeaderOffset + 28))
        let payloadOffset = localHeaderOffset + 30 + fileNameLength + extraFieldLength
        let payload = try archiveData.checkedSubdata(offset: payloadOffset, length: entry.compressedSize)

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

struct ContainerDocument {
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

struct PackageDocument {
    var title: String?
    var manifest: [String: ManifestItem]
    var spine: [String]
    /// Href (relative to the package file) of the EPUB 3 nav document, or the
    /// EPUB 2 NCX as a fallback.
    var tocHref: String?

    struct ManifestItem {
        var href: String
        var mediaType: String
    }
}

enum PackageDocumentParser {
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

        let tocHref = delegate.navHref ?? delegate.spineTOCID.flatMap { delegate.manifest[$0]?.href }

        return PackageDocument(
            title: delegate.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            manifest: readableManifest,
            spine: spine,
            tocHref: tocHref
        )
    }
}

private final class MutablePackageParser: NSObject, XMLParserDelegate {
    var title = ""
    var manifest: [String: PackageDocument.ManifestItem] = [:]
    var spine: [String] = []
    /// Manifest item carrying `properties="nav"` (EPUB 3 contents).
    var navHref: String?
    /// The `toc` attribute of `<spine>`: the manifest id of the EPUB 2 NCX.
    var spineTOCID: String?

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
                if attributeDict["properties"]?.split(separator: " ").contains("nav") == true {
                    navHref = href
                }
            }
        } else if lowered == "spine" || lowered.hasSuffix(":spine") {
            spineTOCID = attributeDict["toc"]
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

// MARK: - Table of contents

/// Reads an EPUB 3 navigation document (`<nav epub:type="toc">`) or an EPUB 2
/// NCX and maps its links onto spine items.
enum EPUBTableOfContents {
    struct RawEntry: Equatable {
        var title: String
        /// As written in the document: relative to the TOC file, may carry a `#fragment`.
        var href: String
        var level: Int
    }

    static func entries(at url: URL, spine: [EPUBDocument.SpineItem]) -> [EPUBDocument.TOCEntry] {
        guard let parser = XMLParser(contentsOf: url) else { return [] }
        let delegate = TOCParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        // Keep whatever was read even if the markup is malformed further down
        // (nav documents are XHTML but not always well-formed XML).
        _ = parser.parse()
        return resolve(delegate.entries, relativeTo: url.deletingLastPathComponent(), spine: spine)
    }

    /// Drops entries whose target isn't a spine item.
    static func resolve(_ raw: [RawEntry], relativeTo directory: URL, spine: [EPUBDocument.SpineItem]) -> [EPUBDocument.TOCEntry] {
        var spineIndexByPath: [String: Int] = [:]
        for item in spine {
            spineIndexByPath[item.url.standardizedFileURL.path] = item.index
        }

        return raw.compactMap { entry in
            let parts = entry.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let filePart = parts.first.map(String.init) ?? ""
            let decoded = filePart.removingPercentEncoding ?? filePart
            let fragment = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : nil
            guard !decoded.isEmpty,
                let index = spineIndexByPath[URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL.path]
            else { return nil }
            let title = entry.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !title.isEmpty else { return nil }
            return EPUBDocument.TOCEntry(title: title, level: entry.level, spineIndex: index, fragment: fragment?.nonEmpty)
        }
    }

    private final class TOCParser: NSObject, XMLParserDelegate {
        var entries: [RawEntry] = []

        // EPUB 3 nav state
        private var navDepth = 0          // > 0 while inside the toc <nav>
        private var otherNavDepth = 0     // inside a non-toc <nav> (page-list, landmarks)
        private var listDepth = 0
        private var currentHref: String?
        private var currentTitle = ""
        private var isInsideLink = false

        // EPUB 2 NCX state
        private var navPointDepth = 0
        private var isInsideNavLabelText = false
        private var ncxTitles: [String] = []   // title of each open navPoint
        private var inNCXPageList = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            switch name {
            case "nav":
                if navDepth > 0 || otherNavDepth > 0 {
                    // Nested nav: treat as part of whichever one we're in.
                    if navDepth > 0 { navDepth += 1 } else { otherNavDepth += 1 }
                } else if (attributeDict["epub:type"] ?? attributeDict["type"])?.split(separator: " ").contains("toc") == true {
                    navDepth = 1
                } else {
                    otherNavDepth = 1
                }
            case "ol" where navDepth > 0, "ul" where navDepth > 0:
                listDepth += 1
            case "a" where navDepth > 0:
                if let href = attributeDict["href"] {
                    currentHref = href
                    currentTitle = ""
                    isInsideLink = true
                }
            case "pagelist":
                inNCXPageList = true
            case "navpoint" where !inNCXPageList:
                navPointDepth += 1
                ncxTitles.append("")
            case "text" where navPointDepth > 0:
                isInsideNavLabelText = true
                ncxTitles[ncxTitles.count - 1] = ""
            case "content" where navPointDepth > 0:
                if let src = attributeDict["src"] {
                    entries.append(RawEntry(title: ncxTitles.last ?? "", href: src, level: navPointDepth - 1))
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInsideLink { currentTitle += string }
            if isInsideNavLabelText, !ncxTitles.isEmpty { ncxTitles[ncxTitles.count - 1] += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName.lowercased() {
            case "nav":
                if navDepth > 0 { navDepth -= 1 } else if otherNavDepth > 0 { otherNavDepth -= 1 }
            case "ol" where navDepth > 0, "ul" where navDepth > 0:
                listDepth = max(listDepth - 1, 0)
            case "a" where isInsideLink:
                if let href = currentHref {
                    entries.append(RawEntry(title: currentTitle, href: href, level: max(listDepth - 1, 0)))
                }
                currentHref = nil
                isInsideLink = false
            case "pagelist":
                inNCXPageList = false
            case "navpoint" where !inNCXPageList:
                navPointDepth = max(navPointDepth - 1, 0)
                if !ncxTitles.isEmpty { ncxTitles.removeLast() }
            case "text":
                isInsideNavLabelText = false
            default:
                break
            }
        }
    }
}

/// Bounds-checked little-endian readers. Archives can be truncated (e.g. a file
/// still being synced) or malformed, and an unchecked `Data` subscript past the
/// end traps and crashes the app instead of surfacing an error.
private extension Data {
    func uint16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw EPUBError.invalidArchive }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw EPUBError.invalidArchive }
        let base = startIndex + offset
        return UInt32(self[base]) | (UInt32(self[base + 1]) << 8) | (UInt32(self[base + 2]) << 16) | (UInt32(self[base + 3]) << 24)
    }

    func checkedSubdata(offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= count - length else { throw EPUBError.invalidArchive }
        return subdata(in: (startIndex + offset) ..< (startIndex + offset + length))
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
