import Foundation

/// Devotional facets used by both database-backed and in-memory search.
public struct LampDevotionalSearchCriteria: Codable, Equatable, Sendable {
    public var date: String?
    public var monthDay: String?
    public var tags: Set<String>?
    public var categories: Set<String>?

    public init(
        date: String? = nil,
        monthDay: String? = nil,
        tags: Set<String>? = nil,
        categories: Set<String>? = nil
    ) {
        self.date = date
        self.monthDay = monthDay
        self.tags = tags
        self.categories = categories
    }

    /// Whether no facet is set, so the criteria pass everything.
    public var isEmpty: Bool {
        date == nil && monthDay == nil && (tags ?? []).isEmpty && (categories ?? []).isEmpty
    }

    public func matches(date candidateDate: String?, tags candidateTags: [String], category: String?) -> Bool {
        if let date, candidateDate != date { return false }
        if let monthDay, candidateDate?.hasSuffix("-\(monthDay)") != true { return false }
        if let tags, !tags.isEmpty,
           !tags.contains(where: { requested in
               candidateTags.contains { $0.localizedCaseInsensitiveContains(requested) }
           }) { return false }
        if let categories, !categories.isEmpty {
            // Writing of no kind is of no kind, not of every kind: a blank
            // among the requests folds to nothing and must not meet it.
            guard let kind = LampWritingCategory.foldedKey(category),
                  categories.contains(where: { LampWritingCategory.foldedKey($0) == kind })
            else { return false }
        }
        return true
    }

    /// Parameters are returned separately for a prepared SQL statement.
    public func sqlConditions(tableAlias: String) -> (clauses: [String], arguments: [String]) {
        let column = tableAlias.isEmpty ? "" : "\(tableAlias)."
        var clauses: [String] = []
        var arguments: [String] = []
        if let date {
            clauses.append("\(column)date = ?")
            arguments.append(date)
        }
        if let monthDay {
            clauses.append("\(column)date LIKE ?")
            arguments.append("%-\(monthDay)")
        }
        if let tags, !tags.isEmpty {
            clauses.append("(" + Array(repeating: "\(column)tags LIKE ?", count: tags.count)
                .joined(separator: " OR ") + ")")
            arguments += tags.sorted().map { "%\($0)%" }
        }
        if let categories, !categories.isEmpty {
            // The kinds are an open vocabulary, so the comparison folds case
            // and takes in the old `sermon` name; a request of nothing but
            // blanks named no kind, and so matches no writing rather than all.
            let wanted = LampWritingCategory.storedValuesMatching(categories)
            clauses.append(wanted.isEmpty ? "1 = 0"
                : "\(column)category COLLATE NOCASE IN ("
                    + Array(repeating: "?", count: wanted.count).joined(separator: ", ") + ")")
            arguments += wanted
        }
        return (clauses, arguments)
    }
}
