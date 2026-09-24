import Foundation

/// Devotional facets used by both database-backed and in-memory search.
public struct LampDevotionalSearchCriteria: Equatable, Sendable {
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

    public func matches(date candidateDate: String?, tags candidateTags: [String], category: String?) -> Bool {
        if let date, candidateDate != date { return false }
        if let monthDay, candidateDate?.hasSuffix("-\(monthDay)") != true { return false }
        if let tags, !tags.isEmpty,
           !tags.contains(where: { requested in
               candidateTags.contains { $0.localizedCaseInsensitiveContains(requested) }
           }) { return false }
        if let categories, !categories.isEmpty,
           !categories.contains(category ?? "") { return false }
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
            clauses.append("\(column)category IN (" + Array(repeating: "?", count: categories.count)
                .joined(separator: ", ") + ")")
            arguments += categories.sorted()
        }
        return (clauses, arguments)
    }
}
