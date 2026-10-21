import Foundation

enum BookFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case pdf
    case epub

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf":
            self = .pdf
        case "epub":
            self = .epub
        default:
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .pdf:
            return "doc.richtext"
        case .epub:
            return "book.closed"
        }
    }
}

struct BookProgressState: Codable, Hashable, Sendable {
    var schemaVersion: Int = 1
    var bookID: String
    var updatedAt: Date
    var lastOpenedAt: Date?
    var progress: Double
    var pdfPageIndex: Int?
    var pdfPageCount: Int?
    /// Normalized Y offset within the current page (0.0 = top, 1.0 = bottom).
    /// Enables sub-page position restore. nil means top of page (backward compatible).
    var pdfPageOffsetY: Double?
    var epubChapterIndex: Int?
    var epubChapterPath: String?
    var epubChapterProgress: Double?
    /// Pixels from the anchored text position down to the window center when the
    /// position was saved. Nonzero when the center rested on an image or margin
    /// rather than on text, so the same view can be restored.
    var epubChapterOffsetY: Double?
    /// Per-book font size preference for EPUB reading, as a percentage (100 = default).
    /// nil means use the default size (100%).
    var epubFontSizePercent: Int?

    /// Completion is derived from current position rather than persisted as sticky state.
    var isFinished: Bool {
        progress >= 0.999
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bookID
        case updatedAt
        case lastOpenedAt
        case progress
        case isFinished
        case pdfPageIndex
        case pdfPageCount
        case pdfPageOffsetY
        case epubChapterIndex
        case epubChapterPath
        case epubChapterProgress
        case epubChapterOffsetY
        case epubFontSizePercent
    }

    init(
        schemaVersion: Int = 1,
        bookID: String,
        updatedAt: Date,
        lastOpenedAt: Date?,
        progress: Double,
        pdfPageIndex: Int?,
        pdfPageCount: Int?,
        pdfPageOffsetY: Double? = nil,
        epubChapterIndex: Int?,
        epubChapterPath: String?,
        epubChapterProgress: Double?,
        epubChapterOffsetY: Double? = nil,
        epubFontSizePercent: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.bookID = bookID
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.progress = progress
        self.pdfPageIndex = pdfPageIndex
        self.pdfPageCount = pdfPageCount
        self.pdfPageOffsetY = pdfPageOffsetY
        self.epubChapterIndex = epubChapterIndex
        self.epubChapterPath = epubChapterPath
        self.epubChapterProgress = epubChapterProgress
        self.epubChapterOffsetY = epubChapterOffsetY
        self.epubFontSizePercent = epubFontSizePercent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bookID = try container.decode(String.self, forKey: .bookID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        progress = try container.decode(Double.self, forKey: .progress)
        pdfPageIndex = try container.decodeIfPresent(Int.self, forKey: .pdfPageIndex)
        pdfPageCount = try container.decodeIfPresent(Int.self, forKey: .pdfPageCount)
        pdfPageOffsetY = try container.decodeIfPresent(Double.self, forKey: .pdfPageOffsetY)
        epubChapterIndex = try container.decodeIfPresent(Int.self, forKey: .epubChapterIndex)
        epubChapterPath = try container.decodeIfPresent(String.self, forKey: .epubChapterPath)
        epubChapterProgress = try container.decodeIfPresent(Double.self, forKey: .epubChapterProgress)
        epubChapterOffsetY = try container.decodeIfPresent(Double.self, forKey: .epubChapterOffsetY)
        epubFontSizePercent = try container.decodeIfPresent(Int.self, forKey: .epubFontSizePercent)
        // Intentionally ignore legacy persisted `isFinished`; completion is position-derived.
        _ = try container.decodeIfPresent(Bool.self, forKey: .isFinished)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(bookID, forKey: .bookID)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encode(progress, forKey: .progress)
        try container.encodeIfPresent(pdfPageIndex, forKey: .pdfPageIndex)
        try container.encodeIfPresent(pdfPageCount, forKey: .pdfPageCount)
        try container.encodeIfPresent(pdfPageOffsetY, forKey: .pdfPageOffsetY)
        try container.encodeIfPresent(epubChapterIndex, forKey: .epubChapterIndex)
        try container.encodeIfPresent(epubChapterPath, forKey: .epubChapterPath)
        try container.encodeIfPresent(epubChapterProgress, forKey: .epubChapterProgress)
        try container.encodeIfPresent(epubChapterOffsetY, forKey: .epubChapterOffsetY)
        try container.encodeIfPresent(epubFontSizePercent, forKey: .epubFontSizePercent)
    }

    func normalized() -> BookProgressState {
        var copy = self
        copy.progress = progress.clampedToUnit
        copy.pdfPageOffsetY = pdfPageOffsetY?.clampedToUnit
        copy.epubChapterProgress = epubChapterProgress?.clampedToUnit
        if copy.progress >= 0.999 {
            copy.progress = 1
        }
        return copy
    }
}

struct Book: Identifiable, Hashable, Sendable {
    static let unreadProgressThreshold = 0.01

    var id: String
    let title: String
    /// `title` normalized for search, computed once instead of on every
    /// comparison while filtering and sorting.
    let searchKey: String
    var fileURL: URL
    var format: BookFormat
    var fileSize: Int64
    var addedAt: Date
    var modifiedAt: Date
    var progressState: BookProgressState?

    init(
        id: String,
        title: String,
        fileURL: URL,
        format: BookFormat,
        fileSize: Int64,
        addedAt: Date,
        modifiedAt: Date,
        progressState: BookProgressState?
    ) {
        self.id = id
        self.title = title
        self.searchKey = LibrarySearch.normalized(title)
        self.fileURL = fileURL
        self.format = format
        self.fileSize = fileSize
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.progressState = progressState
    }

    var progress: Double {
        progressState?.progress ?? 0
    }

    var isFinished: Bool {
        progressState?.isFinished ?? false
    }

    var isActive: Bool {
        progressState != nil
    }

    var isUnreadLike: Bool {
        guard progressState != nil else { return false }
        return !isFinished && progress <= Self.unreadProgressThreshold
    }

    var lastOpenedAt: Date? {
        progressState?.lastOpenedAt
    }

    var displaySubtitle: String {
        switch format {
        case .pdf:
            return "PDF"
        case .epub:
            return "EPUB"
        }
    }
}

struct FileHashRecord: Codable, Hashable, Sendable {
    var path: String
    var fileSize: Int64
    var modifiedAt: Date
    var contentHash: String
}

struct FileHashCache: Codable, Sendable {
    var version: Int = 1
    var records: [String: FileHashRecord] = [:]  // url.path -> record
}

/// Normalized PDF reading location expressed as page index plus within-page offset.
struct PDFReadingPosition: Hashable, Sendable {
    let pageIndex: Int
    let pageCount: Int
    let pageOffsetY: Double

    init(pageIndex: Int, pageCount: Int, pageOffsetY: Double = 0) {
        let safePageCount = max(pageCount, 1)
        self.pageCount = safePageCount
        self.pageIndex = min(max(pageIndex, 0), safePageCount - 1)
        self.pageOffsetY = pageOffsetY.clampedToUnit
    }

    /// Convert a page-relative position into overall book progress.
    /// PDF progress is measured across the intervals between page tops.
    var progress: Double {
        guard pageCount > 1 else { return 1 }
        return ((Double(pageIndex) + pageOffsetY) / Double(pageCount - 1)).clampedToUnit
    }
}

extension BookProgressState {
    /// A fresh record for a book that was just opened (or reset) with no position yet.
    static func initial(bookID: String, at date: Date = .now) -> BookProgressState {
        BookProgressState(
            bookID: bookID,
            updatedAt: date,
            lastOpenedAt: date,
            progress: 0,
            pdfPageIndex: nil,
            pdfPageCount: nil,
            epubChapterIndex: nil,
            epubChapterPath: nil,
            epubChapterProgress: nil
        )
    }

    static func pdf(bookID: String, pageIndex: Int, pageCount: Int, pageOffsetY: Double = 0, lastOpenedAt: Date) -> BookProgressState {
        let readingPosition = PDFReadingPosition(pageIndex: pageIndex, pageCount: pageCount, pageOffsetY: pageOffsetY)
        return BookProgressState(
            bookID: bookID,
            updatedAt: .now,
            lastOpenedAt: lastOpenedAt,
            progress: readingPosition.progress,
            pdfPageIndex: readingPosition.pageIndex,
            pdfPageCount: readingPosition.pageCount,
            pdfPageOffsetY: readingPosition.pageOffsetY,
            epubChapterIndex: nil,
            epubChapterPath: nil,
            epubChapterProgress: nil
        ).normalized()
    }

    static func epub(
        bookID: String,
        chapterIndex: Int,
        chapterPath: String,
        chapterProgress: Double,
        chapterOffsetY: Double = 0,
        overallProgress: Double,
        lastOpenedAt: Date,
        fontSizePercent: Int? = nil
    ) -> BookProgressState {
        BookProgressState(
            bookID: bookID,
            updatedAt: .now,
            lastOpenedAt: lastOpenedAt,
            progress: overallProgress.clampedToUnit,
            pdfPageIndex: nil,
            pdfPageCount: nil,
            epubChapterIndex: max(chapterIndex, 0),
            epubChapterPath: chapterPath,
            epubChapterProgress: chapterProgress.clampedToUnit,
            epubChapterOffsetY: chapterOffsetY,
            epubFontSizePercent: fontSizePercent
        ).normalized()
    }
}

extension Double {
    var clampedToUnit: Double {
        min(max(self, 0), 1)
    }
}
