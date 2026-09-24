import Testing
@testable import LampCore

struct LampDevotionalSearchCriteriaTests {
    @Test func sqlAndInMemoryFacetsAgree() {
        let criteria = LampDevotionalSearchCriteria(
            date: "2026-08-03", monthDay: "08-03",
            tags: ["hope", "grace"], categories: ["reflection"]
        )
        #expect(criteria.matches(
            date: "2026-08-03", tags: ["Hopeful"], category: "reflection"
        ))
        #expect(!criteria.matches(
            date: "2026-08-04", tags: ["Hopeful"], category: "reflection"
        ))
        let sql = criteria.sqlConditions(tableAlias: "d")
        #expect(sql.clauses.count == 4)
        #expect(sql.arguments.contains("%-08-03"))
        #expect(sql.arguments.contains("%hope%"))
        #expect(sql.arguments.contains("reflection"))
    }
}
