import Foundation

enum LibrarySortOption: String, CaseIterable, Identifiable, Sendable {
    case title
    case modifiedAt
    case lastOpenedAt
    case fileSize
    case format

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title:
            return "Name"
        case .modifiedAt:
            return "Modification Time"
        case .lastOpenedAt:
            return "Last Opened"
        case .fileSize:
            return "File Size"
        case .format:
            return "Format"
        }
    }

    var shortLabel: String {
        switch self {
        case .title:
            return "Name"
        case .modifiedAt:
            return "Modified"
        case .lastOpenedAt:
            return "Opened"
        case .fileSize:
            return "Size"
        case .format:
            return "Format"
        }
    }
}

/// Pure title matching and ordering for the library screen.
enum LibrarySearch {
    struct Sections: Equatable, Sendable {
        var active: [Book] = []
        var other: [Book] = []
    }

    /// Splits books into the Active and Library sections, filtered by `query`.
    /// Active books are ordered most-recently-read first (unread-like ones last);
    /// the rest follow `sort`, with search relevance taking precedence.
    static func sections(of books: [Book], query: String, sort: LibrarySortOption) -> Sections {
        let normalizedQuery = normalized(query)
        let visible: [Book]
        if normalizedQuery.isEmpty {
            visible = books
        } else {
            visible = books.filter { fuzzyScore(query: normalizedQuery, candidate: $0.title) != nil }
        }

        return Sections(
            active: sortActiveBooks(visible.filter(\.isActive), query: query),
            other: sortOtherBooks(visible.filter { !$0.isActive }, using: sort, query: query)
        )
    }

    static func sortActiveBooks(_ books: [Book], query: String = "") -> [Book] {
        let normalizedQuery = normalized(query)
        func score(_ book: Book) -> Int {
            normalizedQuery.isEmpty ? 0 : fuzzyScore(query: normalizedQuery, candidate: book.title) ?? 0
        }

        return books.sorted {
            let leftUnread = $0.isUnreadLike
            let rightUnread = $1.isUnreadLike
            if leftUnread != rightUnread {
                return !leftUnread && rightUnread
            }
            return ($0.lastOpenedAt ?? .distantPast, score($0), $0.title.localizedLowercase) > (
                $1.lastOpenedAt ?? .distantPast, score($1), $1.title.localizedLowercase
            )
        }
    }

    static func sortOtherBooks(_ books: [Book], using option: LibrarySortOption, query: String = "") -> [Book] {
        let normalizedQuery = normalized(query)

        return books.sorted { left, right in
            if !normalizedQuery.isEmpty {
                let leftScore = fuzzyScore(query: normalizedQuery, candidate: left.title) ?? Int.min
                let rightScore = fuzzyScore(query: normalizedQuery, candidate: right.title) ?? Int.min
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
            }

            return compareOtherBooks(left, right, using: option)
        }
    }

    /// Lowercased, diacritic-free, with runs of non-alphanumerics collapsed to one space.
    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scores how well an already-normalized `query` matches `candidate`, or nil
    /// for no match. Substring matches score 10,000 minus their offset; otherwise
    /// the query's characters must appear in order, with gaps penalized.
    static func fuzzyScore(query: String, candidate: String) -> Int? {
        let normalizedCandidate = normalized(candidate)
        guard !query.isEmpty, !normalizedCandidate.isEmpty else {
            return query.isEmpty ? 0 : nil
        }
        if let range = normalizedCandidate.range(of: query) {
            let distance = normalizedCandidate.distance(from: normalizedCandidate.startIndex, to: range.lowerBound)
            return 10_000 - distance
        }
        let queryScalars = Array(query.replacingOccurrences(of: " ", with: ""))
        let candidateScalars = Array(normalizedCandidate.replacingOccurrences(of: " ", with: ""))
        guard !queryScalars.isEmpty, !candidateScalars.isEmpty else {
            return nil
        }
        var score = 0
        var candidateIndex = 0
        for scalar in queryScalars {
            var foundIndex: Int?
            while candidateIndex < candidateScalars.count {
                if candidateScalars[candidateIndex] == scalar {
                    foundIndex = candidateIndex
                    candidateIndex += 1
                    break
                }
                candidateIndex += 1
            }
            guard let foundIndex else {
                return nil
            }
            let gapPenalty = max(foundIndex - score / 20, 0)
            score += max(1, 24 - gapPenalty)
        }
        return score
    }

    private static func compareOtherBooks(_ left: Book, _ right: Book, using option: LibrarySortOption) -> Bool {
        switch option {
        case .title:
            return compareTitles(left, right)

        case .modifiedAt:
            if left.modifiedAt != right.modifiedAt {
                return left.modifiedAt > right.modifiedAt
            }

        case .lastOpenedAt:
            let leftOpenedAt = left.lastOpenedAt ?? .distantPast
            let rightOpenedAt = right.lastOpenedAt ?? .distantPast
            if leftOpenedAt != rightOpenedAt {
                return leftOpenedAt > rightOpenedAt
            }

        case .fileSize:
            if left.fileSize != right.fileSize {
                return left.fileSize > right.fileSize
            }

        case .format:
            if left.format != right.format {
                return left.format.rawValue.localizedCaseInsensitiveCompare(right.format.rawValue) == .orderedAscending
            }
        }

        return compareTitles(left, right)
    }

    private static func compareTitles(_ left: Book, _ right: Book) -> Bool {
        let titleOrder = left.title.localizedCaseInsensitiveCompare(right.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return left.id < right.id
    }
}
