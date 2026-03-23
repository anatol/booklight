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
    var epubChapterIndex: Int?
    var epubChapterPath: String?
    var epubChapterProgress: Double?

    func normalized() -> BookProgressState {
        var copy = self
        copy.progress = progress.clampedToUnit
        copy.epubChapterProgress = epubChapterProgress?.clampedToUnit
        if copy.progress >= 0.999 {
            copy.progress = 1
            copy.isFinished = true
        }
        return copy
    }
}

struct LibraryBookRecord: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var fileName: String
    var relativePath: String
    var format: BookFormat
    var fileSize: Int64
    var addedAt: Date
    var modifiedAt: Date
    var lastKnownProgress: Double
    var lastOpenedAt: Date?
    var isFinished: Bool
}

struct LibraryDatabase: Codable, Sendable {
    var schemaVersion: Int = 1
    var scannedAt: Date
    var books: [LibraryBookRecord]
}

struct Book: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var fileName: String
    var relativePath: String
    var format: BookFormat
    var fileSize: Int64
    var addedAt: Date
    var modifiedAt: Date
    var progressState: BookProgressState?

    init(record: LibraryBookRecord, progressState: BookProgressState?) {
        id = record.id
        title = record.title
        fileName = record.fileName
        relativePath = record.relativePath
        format = record.format
        fileSize = record.fileSize
        addedAt = record.addedAt
        modifiedAt = record.modifiedAt
        self.progressState = progressState
    }

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

struct LibraryScanResult: Sendable {
    var database: LibraryDatabase
    var books: [Book]
}

extension BookProgressState {
    static func pdf(bookID: String, pageIndex: Int, pageCount: Int, lastOpenedAt: Date) -> BookProgressState {
        let safeCount = max(pageCount, 1)
        let safeIndex = min(max(pageIndex, 0), safeCount - 1)
        let progress = safeCount == 1 ? 1 : Double(safeIndex) / Double(max(safeCount - 1, 1))
        return BookProgressState(
            bookID: bookID,
            updatedAt: .now,
            lastOpenedAt: lastOpenedAt,
            progress: progress,
            isFinished: progress >= 0.999,
            pdfPageIndex: safeIndex,
            pdfPageCount: safeCount,
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
        lastOpenedAt: Date
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
            epubChapterProgress: chapterProgress.clampedToUnit
        ).normalized()
    }
}

extension Double {
    var clampedToUnit: Double {
        min(max(self, 0), 1)
    }
}
