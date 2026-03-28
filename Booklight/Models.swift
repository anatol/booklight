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
    var isFinished: Bool
    var pdfPageIndex: Int?
    var pdfPageCount: Int?
    /// Normalized Y offset within the current page (0.0 = top, 1.0 = bottom).
    /// Enables sub-page position restore. nil means top of page (backward compatible).
    var pdfPageOffsetY: Double?
    var epubChapterIndex: Int?
    var epubChapterPath: String?
    var epubChapterProgress: Double?
    /// Per-book font size preference for EPUB reading, as a percentage (100 = default).
    /// nil means use the default size (100%).
    var epubFontSizePercent: Int?

    func normalized() -> BookProgressState {
        var copy = self
        copy.progress = progress.clampedToUnit
        copy.pdfPageOffsetY = pdfPageOffsetY?.clampedToUnit
        copy.epubChapterProgress = epubChapterProgress?.clampedToUnit
        if copy.progress >= 0.999 {
            copy.progress = 1
            copy.isFinished = true
        }
        return copy
    }
}

struct Book: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var fileURL: URL
    var format: BookFormat
    var fileSize: Int64
    var addedAt: Date
    var modifiedAt: Date
    var progressState: BookProgressState?

    var progress: Double {
        progressState?.progress ?? 0
    }

    var isFinished: Bool {
        progressState?.isFinished ?? false
    }

    var isActive: Bool {
        progress > 0 && !isFinished
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
    static func pdf(bookID: String, pageIndex: Int, pageCount: Int, pageOffsetY: Double = 0, lastOpenedAt: Date) -> BookProgressState {
        let readingPosition = PDFReadingPosition(pageIndex: pageIndex, pageCount: pageCount, pageOffsetY: pageOffsetY)
        return BookProgressState(
            bookID: bookID,
            updatedAt: .now,
            lastOpenedAt: lastOpenedAt,
            progress: readingPosition.progress,
            isFinished: readingPosition.progress >= 0.999,
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
        overallProgress: Double,
        lastOpenedAt: Date,
        fontSizePercent: Int? = nil
    ) -> BookProgressState {
        BookProgressState(
            bookID: bookID,
            updatedAt: .now,
            lastOpenedAt: lastOpenedAt,
            progress: overallProgress.clampedToUnit,
            isFinished: overallProgress >= 0.999,
            pdfPageIndex: nil,
            pdfPageCount: nil,
            epubChapterIndex: max(chapterIndex, 0),
            epubChapterPath: chapterPath,
            epubChapterProgress: chapterProgress.clampedToUnit,
            epubFontSizePercent: fontSizePercent
        ).normalized()
    }
}

extension Double {
    var clampedToUnit: Double {
        min(max(self, 0), 1)
    }
}
