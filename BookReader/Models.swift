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
    var records: [String: FileHashRecord] = [:] // url.path -> record
}

extension BookProgressState {
    static func pdf(bookID: String, pageIndex: Int, pageCount: Int, pageOffsetY: Double = 0, lastOpenedAt: Date) -> BookProgressState {
        let safeCount = max(pageCount, 1)
        let safeIndex = min(max(pageIndex, 0), safeCount - 1)
        let clampedOffset = min(max(pageOffsetY, 0), 1)
        // Sub-page progress: fractional page position divided by total pages.
        let progress = safeCount == 1 ? 1 : (Double(safeIndex) + clampedOffset) / Double(max(safeCount - 1, 1))
        return BookProgressState(
            bookID: bookID,
            updatedAt: .now,
            lastOpenedAt: lastOpenedAt,
            progress: progress,
            isFinished: progress >= 0.999,
            pdfPageIndex: safeIndex,
            pdfPageCount: safeCount,
            pdfPageOffsetY: clampedOffset,
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
