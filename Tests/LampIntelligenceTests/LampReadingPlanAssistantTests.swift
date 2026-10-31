import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampIntelligence

#if canImport(FoundationModels)
import FoundationModels

struct LampReadingPlanAssistantTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The model's answer, as it arrives, is the request the builder takes.
    @available(macOS 26, iOS 26, *)
    @Test func anAnswerBecomesARequest() throws {
        let answer = try PlanAnswer(GeneratedContent(json: #"""
            {"name": "Mark on Weekdays", "description": "Mark, two chapters each weekday.",
             "tracks": [{"passages": [{"firstBook": "Mark", "lastBook": "Mark", "firstChapter": 0, "lastChapter": 0}],
                         "chaptersPerDay": 2}],
             "readingDays": 0, "start": "nextMonday", "restDays": ["saturday", "sunday"]}
            """#))
        let request = answer.request(today: date(2026, 10, 31), calendar: calendar)
        #expect(request == LampAgentReadingPlanRequest(
            name: "Mark on Weekdays",
            description: "Mark, two chapters each weekday.",
            tracks: [.init(passages: ["Mark"], chaptersPerDay: 2)],
            readingDays: nil,
            startDate: "2026-11-02",
            restDays: ["saturday", "sunday"]
        ))
        let draft = try request.request(calendar: calendar).draft(calendar: calendar)
        #expect(draft.days.count == 8)
        #expect(draft.days.first?.date == date(2026, 11, 2))
    }

    /// Every name the model may give is a book the passage reader knows,
    /// and chapters are read as the model gives them.
    @available(macOS 26, iOS 26, *)
    @Test func everyBookTheModelMayNameIsRead() throws {
        for book in LampCanonicalBooks.all {
            let answer = PassageAnswer(firstBook: book.name, lastBook: book.name, firstChapter: 0, lastChapter: 0)
            #expect(try LampPlanPassage(answer.text) == LampPlanPassage(books: book.number...book.number))
        }
        func span(_ first: String, _ last: String, _ firstChapter: Int, _ lastChapter: Int) throws -> [Int] {
            let passage = try LampPlanPassage(
                PassageAnswer(firstBook: first, lastBook: last, firstChapter: firstChapter, lastChapter: lastChapter).text
            )
            return [passage.start, passage.end]
        }
        #expect(try span("Genesis", "Deuteronomy", 0, 0) == [1_001_001, 5_034_012])
        #expect(try span("Psalms", "Psalms", 1, 41) == [19_001_001, 19_041_013])
        #expect(try span("Romans", "Romans", 8, 0) == [45_008_001, 45_016_027])
        #expect(try span("Song of Songs", "Isaiah", 0, 12) == [22_001_001, 23_012_006])
    }

    @available(macOS 26, iOS 26, *)
    @Test func aStartIsADate() {
        func start(_ answer: StartAnswer, from today: Date) -> String {
            answer.date(after: today, calendar: calendar)
        }
        let saturday = date(2026, 10, 31)
        #expect(start(.today, from: saturday) == "2026-10-31")
        #expect(start(.tomorrow, from: saturday) == "2026-11-01")
        #expect(start(.nextMonday, from: saturday) == "2026-11-02")
        #expect(start(.firstOfNextMonth, from: saturday) == "2026-11-01")
        #expect(start(.firstOfNextYear, from: saturday) == "2027-01-01")
        // The next one, never today's.
        #expect(start(.nextMonday, from: date(2026, 11, 2)) == "2026-11-09")
        #expect(start(.firstOfNextMonth, from: date(2026, 11, 1)) == "2026-12-01")
    }

    /// Asks the model itself, so it runs only when asked to, on a Mac where
    /// Apple Intelligence is on: `LAMP_LIVE_MODEL=1 swift test`.
    @available(macOS 26, iOS 26, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LAMP_LIVE_MODEL"] == "1"))
    func theModelAsksForPlansThatCanBeLaidOut() async throws {
        try #require(LampReadingPlanAssistant.unavailableReason == nil)
        let assistant = LampReadingPlanAssistant()
        let saturday = date(2026, 10, 31)
        func draft(_ words: String) async throws -> LampReadingPlanDraft {
            let request = try await assistant.request(for: words, today: saturday, calendar: calendar)
            print("\(words)\n  → \(request)")
            return try request.request(today: saturday, calendar: calendar).draft(calendar: calendar)
        }
        func books(_ draft: LampReadingPlanDraft) -> ClosedRange<Int>? {
            let references = draft.days.flatMap(\.readings).flatMap { [$0.startReference, $0.endReference] }
            guard let first = references.min(), let last = references.max() else { return nil }
            return first / 1_000_000...last / 1_000_000
        }

        let gospels = try await draft("The Gospels in 30 days")
        #expect(gospels.days.count == 30)
        #expect(books(gospels) == 40...43)

        let proverbs = try await draft("Proverbs, a chapter a day")
        #expect(proverbs.days.count == 31)
        #expect(books(proverbs) == 20...20)

        let newTestament = try await draft("The New Testament in 90 days, with a psalm each day")
        #expect(newTestament.days.count == 90)
        #expect(newTestament.plan.readingsPerDay == 2)

        let john = try await draft("John, a chapter a day on weekdays, starting Monday")
        #expect(john.days.count == 21)
        #expect(john.days.first?.date == date(2026, 11, 2))
        #expect(john.days.allSatisfy { !calendar.isDateInWeekend($0.date) })
    }
}
#endif
