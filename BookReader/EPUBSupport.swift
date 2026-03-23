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
}

enum EPUBPreparation {
    static func prepareDocument(for book: Book, sourceURL: URL) throws -> EPUBDocument {
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

        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path())
        let fileSize = attributes[.size] as? NSNumber
        let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
        let expectedVersion = "\(fileSize?.int64Value ?? 0)-\(Int(modifiedAt.timeIntervalSince1970))"

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

        return EPUBDocument(
            title: package.title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nonEmpty ?? fallbackTitle,
            extractedRootURL: extractedRoot,
            spine: spineItems
        )
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
        guard let eocdOffset = stride(from: data.count - 22, through: lowerBound, by: -1).first(where: {
            data.uint32LE(at: $0) == eocdSignature
        }) else {
            throw EPUBError.invalidArchive
        }

        let entryCount = Int(data.uint16LE(at: eocdOffset + 10))
        let centralDirectoryOffset = Int(data.uint32LE(at: eocdOffset + 16))

        var cursor = centralDirectoryOffset
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
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
            let fileNameData = data.subdata(in: fileNameOffset..<(fileNameOffset + fileNameLength))
            let fileName = String(data: fileNameData, encoding: .utf8) ??
                String(data: fileNameData, encoding: .isoLatin1) ??
                ""

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
        let payloadRange = payloadOffset..<(payloadOffset + entry.compressedSize)
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

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
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

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
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
        UInt32(self[offset]) |
        (UInt32(self[offset + 1]) << 8) |
        (UInt32(self[offset + 2]) << 16) |
        (UInt32(self[offset + 3]) << 24)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
