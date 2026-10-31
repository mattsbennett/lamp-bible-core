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
             "length": 0, "lengthUnit": "days", "start": "nextMonday", "restDays": ["saturday", "sunday"]}
            """#))
        let request = answer.request(asked: "Mark, two chapters each weekday", today: date(2026, 10, 31), calendar: calendar)
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
    /// and the chapters people write are read as the model gives them.
    @available(macOS 26, iOS 26, *)
    @Test func everyBookTheModelMayNameIsRead() throws {
        for book in LampCanonicalBooks.all {
            let answer = PassageAnswer(firstBook: book.name, lastBook: book.name, firstChapter: 0, lastChapter: 0)
            #expect(try LampPlanPassage(answer.text(keeping: [])) == LampPlanPassage(books: book.number...book.number))
        }
        func span(_ first: String, _ last: String, _ firstChapter: Int, _ lastChapter: Int) throws -> [Int] {
            let answer = PassageAnswer(firstBook: first, lastBook: last, firstChapter: firstChapter, lastChapter: lastChapter)
            let passage = try LampPlanPassage(answer.text(keeping: [firstChapter, lastChapter]))
            return [passage.start, passage.end]
        }
        #expect(try span("Genesis", "Deuteronomy", 0, 0) == [1_001_001, 5_034_012])
        #expect(try span("Psalms", "Psalms", 1, 41) == [19_001_001, 19_041_013])
        #expect(try span("Romans", "Romans", 8, 0) == [45_008_001, 45_016_027])
        #expect(try span("Romans", "Romans", 8, 8) == [45_008_001, 45_008_039])
        #expect(try span("Song of Songs", "Isaiah", 0, 12) == [22_001_001, 23_012_006])
        #expect(try span("Genesis", "Exodus", 12, 20) == [1_012_001, 2_020_026])
    }

    /// A chapter the person didn't write is the model counting a book's
    /// chapters, and is dropped: on the phone it ran Mark to chapter 20.
    @available(macOS 26, iOS 26, *)
    @Test func onlyChaptersPeopleWriteAreKept() throws {
        func text(_ words: String, _ book: String, _ first: Int, _ last: Int) throws -> String {
            let text = PassageAnswer(firstBook: book, lastBook: book, firstChapter: first, lastChapter: last)
                .text(keeping: PlanAnswer.numbers(in: words))
            _ = try LampPlanPassage(text)
            return text
        }
        #expect(try text("the Gospels in a month", "Mark", 1, 20) == "Mark")
        #expect(try text("the Gospels in 30 days", "Luke", 1, 22) == "Luke")
        #expect(try text("Proverbs in 31 days", "Proverbs", 1, 31) == "Proverbs")
        #expect(try text("Romans 1 to 8 over two weeks", "Romans", 1, 8) == "Romans 1–8")
        #expect(try text("the first eight chapters of Romans", "Romans", 1, 8) == "Romans 1–8")
        #expect(try text("Romans 8 to the end", "Romans", 8, 16) == "Romans 8–16")
        #expect(try text("Romans 8 this week", "Romans", 8, 8) == "Romans 8")
        // A last chapter past the end can only mean the end.
        #expect(try text("Mark 1-20", "Mark", 1, 20) == "Mark")
        #expect(PlanAnswer.numbers(in: "Psalms 1–41 in twenty-one days, 2nd try") == [1, 41, 21, 2])
    }

    /// What the phone's model answered to "the gospels in a month, weekdays
    /// only": the Gospels, read on the weekdays before a month is out.
    @available(macOS 26, iOS 26, *)
    @Test func aMonthOfWeekdaysIsTheWeekdaysOfAMonth() throws {
        let answer = try PlanAnswer(GeneratedContent(json: #"""
            {"name": "Gospels in a Month", "description": "The four Gospels on weekdays over a month.",
             "tracks": [{"passages": [
                 {"firstBook": "Matthew", "lastBook": "Matthew", "firstChapter": 1, "lastChapter": 28},
                 {"firstBook": "Mark", "lastBook": "Mark", "firstChapter": 1, "lastChapter": 20},
                 {"firstBook": "Luke", "lastBook": "Luke", "firstChapter": 1, "lastChapter": 24},
                 {"firstBook": "John", "lastBook": "John", "firstChapter": 1, "lastChapter": 21}],
                 "chaptersPerDay": 0}],
             "length": 1, "lengthUnit": "months", "start": "today", "restDays": ["saturday", "sunday"]}
            """#))
        let request = answer.request(asked: "the gospels in a month, weekdays only", today: date(2026, 10, 31), calendar: calendar)
        #expect(request.tracks.first?.passages == ["Matthew", "Mark", "Luke", "John"])
        // Saturday 31 October to Sunday 29 November.
        #expect(request.readingDays == 20)
        let draft = try request.request(calendar: calendar).draft(calendar: calendar)
        #expect(draft.days.first?.date == date(2026, 11, 2))
        #expect(draft.days.last?.date == date(2026, 11, 27))
        #expect(draft.days.last.map { $0.readings.last!.endReference / 1_000_000 } == 43)
    }

    @available(macOS 26, iOS 26, *)
    @Test func aLengthIsMeasuredOnTheCalendar() throws {
        func readingDays(_ length: Int, _ unit: LengthUnitAnswer, from start: Date, resting: [WeekdayAnswer] = []) -> Int? {
            PlanAnswer(name: "", description: "", tracks: [], length: length, lengthUnit: unit, start: .today, restDays: resting)
                .readingDays(from: start, calendar: calendar)
        }
        #expect(readingDays(30, .days, from: date(2026, 10, 31)) == 30)
        #expect(readingDays(1, .months, from: date(2026, 10, 31)) == 30)
        #expect(readingDays(1, .months, from: date(2027, 1, 1)) == 31)
        #expect(readingDays(2, .weeks, from: date(2026, 11, 2)) == 14)
        #expect(readingDays(1, .years, from: date(2027, 1, 1)) == 365)
        #expect(readingDays(1, .years, from: date(2027, 1, 1), resting: [.saturday, .sunday]) == 261)
        #expect(readingDays(0, .days, from: date(2026, 10, 31)) == nil)

        // A year that takes in 29 February still fits the plan's year.
        #expect(readingDays(1, .years, from: date(2027, 3, 1)) == 366)
        let year = LampAgentReadingPlanRequest(
            name: "The Bible in a Year",
            tracks: [.init(passages: ["Genesis–Malachi"]), .init(passages: ["Matthew–Revelation"])],
            readingDays: 366,
            startDate: "2027-03-01"
        )
        let draft = try year.request(calendar: calendar).draft(calendar: calendar)
        #expect(draft.days.last?.date == date(2028, 2, 29))

        // Every day a rest day: the builder says there is none to read on.
        let everyDay: [WeekdayAnswer] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        #expect(readingDays(1, .weeks, from: date(2026, 11, 2), resting: everyDay) == 7)
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

    /// What the model throws reaches people as something to do, in the
    /// 26 releases' errors and the 27 ones'.
    @available(macOS 26, iOS 26, *)
    @Test func theModelsFailuresAreSaidPlainly() {
        func explained(_ error: any Error) -> LampReadingPlanAssistantError {
            LampReadingPlanAssistant.explained(error)
        }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        #expect(explained(LanguageModelSession.GenerationError.exceededContextWindowSize(context)) == .tooLong)
        #expect(explained(LanguageModelSession.GenerationError.guardrailViolation(context)) == .declined)
        #expect(explained(LanguageModelSession.GenerationError.decodingFailure(context)) == .notUnderstood)
        #expect(explained(LanguageModelSession.GenerationError.concurrentRequests(context)) == .busy)
        #expect(explained(LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)) == .unsupportedLanguage)
        // What the iOS simulator throws without the guardrail's assets.
        #expect(explained(NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15)) == .failed)
        if #available(macOS 27, iOS 27, *) {
            #expect(explained(LanguageModelError.contextSizeExceeded(
                .init(contextSize: 4_096, tokenCount: 5_000, debugDescription: "test")
            )) == .tooLong)
            #expect(explained(LanguageModelError.refusal(.init(explanation: "No", debugDescription: "test"))) == .declined)
            #expect(explained(LanguageModelError.timeout(.init(debugDescription: "test"))) == .busy)
            #expect(explained(LanguageModelSession.Error.concurrentRequests) == .busy)
        }
        #expect(LampReadingPlanAssistantError.failed.errorDescription?.hasPrefix("Apple Intelligence") == true)
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

        let weekdayGospels = try await draft("the gospels in a month, weekdays only")
        #expect(weekdayGospels.days.count == 20)
        #expect(books(weekdayGospels) == 40...43)

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
