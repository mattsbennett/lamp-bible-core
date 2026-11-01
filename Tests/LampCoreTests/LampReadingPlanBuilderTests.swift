import Foundation
import LampModuleKit
import Testing
@testable import LampCore

struct LampReadingPlanBuilderTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func passage(_ text: String) throws -> LampPlanPassage { try LampPlanPassage(text) }

    /// Every verse a reading covers, on the KJV grid.
    private func verses(from start: Int, to end: Int) -> [Int] {
        let (startBook, startChapter, startVerse) = LampBibleReferenceFormatter.components(of: start)
        let (endBook, endChapter, endVerse) = LampBibleReferenceFormatter.components(of: end)
        var verses: [Int] = []
        for book in startBook...endBook {
            let lengths = LampCanonicalBooks.book(book)!.verseCounts
            for chapter in (book == startBook ? startChapter : 1)...(book == endBook ? endChapter : lengths.count) {
                let first = book == startBook && chapter == startChapter ? startVerse : 1
                let last = book == endBook && chapter == endChapter ? min(endVerse, lengths[chapter - 1]) : lengths[chapter - 1]
                verses += (first...last).map { book * 1_000_000 + chapter * 1_000 + $0 }
            }
        }
        return verses
    }

    private func verses(of passage: LampPlanPassage) -> [Int] { verses(from: passage.start, to: passage.end) }

    private func verses(of readings: [LampPlanReading]) -> [Int] {
        readings.flatMap { verses(from: $0.startReference, to: $0.endReference) }
    }

    /// The Gospels in thirty days from 1 November: every verse read once and
    /// in order, in whole chapters, each day near an even share, on the days
    /// of the year those dates are.
    @Test func aSpreadPlanReadsEveryVerseOnceInEvenDays() throws {
        let gospels = try passage("Matthew–John")
        let draft = try LampReadingPlanRequest(
            name: " Gospels ",
            description: "",
            tracks: [.init(passages: [gospels])],
            readingDays: 30,
            start: date(2026, 11, 1)
        ).draft(id: "GOSPELS", calendar: calendar)

        #expect(draft.plan == LampReadingPlan(id: "GOSPELS", name: "Gospels", duration: 30, readingsPerDay: 1))
        #expect(draft.days.map(\.number) == Array(306...335))
        #expect(draft.days.first?.date == date(2026, 11, 1))
        #expect(draft.days.last?.date == date(2026, 11, 30))
        #expect(verses(of: draft.days.flatMap(\.readings)) == verses(of: gospels))
        #expect(draft.days.first?.readings.map(\.displayDescription) == ["Matthew 1–5"])

        let readings = draft.days.flatMap(\.readings)
        #expect(readings.allSatisfy { $0.startReference % 1_000 == 1 && $0.endReference % 1_000 == 999 })
        #expect(readings.allSatisfy { $0.startReference / 1_000_000 == $0.endReference / 1_000_000 })
        #expect(draft.days.contains { $0.readings.count == 2 })
        // Each cut lands within half a chapter of its share, so a day is
        // within a whole chapter, Luke 1's 80 verses at most.
        let share = Double(verses(of: gospels).count) / 30
        for day in draft.days {
            #expect(abs(Double(verses(of: day.readings).count) - share) <= 80)
        }
    }

    /// Weekdays only from a Saturday: the readings start on Monday and step
    /// over the weekend. Fewer chapters than days are cut between verses.
    @Test func restDaysAreSteppedOverAndShortBooksCutBetweenVerses() throws {
        let philippians = try passage("Philippians")
        let draft = try LampReadingPlanRequest(
            name: "Philippians",
            tracks: [.init(passages: [philippians])],
            readingDays: 10,
            start: date(2026, 10, 31),
            restDays: [.saturday, .sunday]
        ).draft(calendar: calendar)

        #expect(draft.days.map(\.date) == [2, 3, 4, 5, 6, 9, 10, 11, 12, 13].map { date(2026, 11, $0) })
        #expect(verses(of: draft.days.flatMap(\.readings)) == verses(of: philippians))
        #expect(draft.days.first?.readings.map(\.displayDescription) == ["Philippians 1:1–10"])
        #expect(draft.days.allSatisfy { (9...12).contains(verses(of: $0.readings).count) })
    }

    /// A paced track runs beside a spread one, starting over when it ends.
    @Test func aPacedTrackStartsOverBesideASpreadOne() throws {
        let draft = try LampReadingPlanRequest(
            name: "Luke, Acts and Proverbs",
            tracks: [
                .init(passages: [try passage("Luke–Acts")]),
                .init(passages: [try passage("Proverbs")], chaptersPerDay: 1),
            ],
            readingDays: 40,
            start: date(2026, 11, 1)
        ).draft(calendar: calendar)

        #expect(draft.plan.readingsPerDay == 2)
        #expect(draft.days.count == 40)
        #expect(draft.days.map { $0.readings.last?.displayDescription }
            == (0..<40).map { "Proverbs \($0 % 31 + 1)" })
        #expect(draft.days.allSatisfy { $0.readings.first?.displayDescription.hasPrefix("Proverbs") == false })
    }

    /// With no length given, a plan is as long as its paced tracks take, and
    /// a day running from one book into the next reads each as its own.
    @Test func aPacedPlanIsAsLongAsItsReadingAndSplitsAtBooks() throws {
        let john = try LampReadingPlanRequest(
            name: "John",
            tracks: [.init(passages: [try passage("John")], chaptersPerDay: 1)],
            start: date(2026, 11, 1)
        ).draft(calendar: calendar)
        #expect(john.days.count == 21)
        #expect(john.days.last?.readings.map(\.displayDescription) == ["John 21"])

        let prophets = try LampReadingPlanRequest(
            name: "Obadiah and Jonah",
            tracks: [.init(passages: [try passage("Obadiah–Jonah")], chaptersPerDay: 2)],
            start: date(2026, 11, 1)
        ).draft(calendar: calendar)
        #expect(prophets.days.map { $0.readings.map(\.displayDescription) } == [
            ["Obadiah 1", "Jonah 1"],
            ["Jonah 2–3"],
            ["Jonah 4", "Obadiah 1"],
        ])
    }

    /// Day 60 is 29 February, which a common year steps over, and a plan
    /// running past 31 December carries on from day 1.
    @Test func daysAreNumberedAsEveryPlanNumbersThem() throws {
        func numbers(from start: Date, days: Int) throws -> [Int] {
            try LampReadingPlanRequest(
                name: "Psalms",
                tracks: [.init(passages: [try passage("Psalms")])],
                readingDays: days,
                start: start
            ).draft(calendar: calendar).days.map(\.number)
        }
        #expect(try numbers(from: date(2028, 2, 27), days: 4) == [58, 59, 60, 61])
        #expect(try numbers(from: date(2027, 2, 27), days: 3) == [58, 59, 61])
        #expect(try numbers(from: date(2026, 12, 30), days: 4) == [365, 366, 1, 2])
    }

    @Test func aPlanThatCannotBeLaidOutSaysWhy() throws {
        func draft(
            _ passages: [String] = ["Psalms"],
            days: Int? = 30,
            pace: Int? = nil,
            start: Date? = nil,
            rest: Set<LampWeekday> = []
        ) throws {
            _ = try LampReadingPlanRequest(
                name: "Plan",
                tracks: [.init(passages: try passages.map(passage), chaptersPerDay: pace)],
                readingDays: days,
                start: start ?? date(2026, 11, 1),
                restDays: rest
            ).draft(calendar: calendar)
        }
        #expect(throws: LampReadingPlanError.longerThanAYear) { try draft(days: 367) }
        // 366 days from 1 March reach 1 March again.
        #expect(throws: LampReadingPlanError.longerThanAYear) { try draft(days: 366, start: date(2026, 3, 1)) }
        #expect(throws: LampReadingPlanError.noReadingWeekdays) { try draft(rest: Set(LampWeekday.allCases)) }
        #expect(throws: LampReadingPlanError.noLength) { try draft(days: nil) }
        #expect(throws: LampReadingPlanError.invalidPace(0)) { try draft(pace: 0) }
        #expect(throws: LampReadingPlanError.noPassages) { try draft([]) }
        #expect(throws: LampReadingPlanError.tooFewVerses(verses: 25, days: 30)) { try draft(["Philemon"]) }
        #expect(throws: LampReadingPlanError.noName) {
            _ = try LampReadingPlanRequest(name: "  ", tracks: [], start: date(2026, 11, 1)).draft(calendar: calendar)
        }
    }

    @Test func passagesAreReadAsPeopleWriteThem() throws {
        func span(_ text: String) throws -> [Int] {
            let passage = try LampPlanPassage(text)
            return [passage.start, passage.end]
        }
        #expect(try span("Genesis–Deuteronomy") == [1_001_001, 5_034_012])
        #expect(try span("NT") == [40_001_001, 66_022_021])
        #expect(try span("1 John") == [62_001_001, 62_005_021])
        #expect(try span("Psalms 1–41") == [19_001_001, 19_041_013])
        #expect(try span("Romans 8") == [45_008_001, 45_008_039])
        #expect(try span("Matthew 5:1–7:29") == [40_005_001, 40_007_029])
        #expect(throws: LampReadingPlanError.unknownPassage("Hezekiah 3")) { try LampPlanPassage("Hezekiah 3") }
        #expect(throws: LampReadingPlanError.unknownPassage("Romans 17")) { try LampPlanPassage("Romans 17") }
        #expect(throws: LampReadingPlanError.unknownPassage("John 3:37")) { try LampPlanPassage("John 3:37") }
        // Read from outside, a passage is held to the same grid.
        #expect(throws: LampReadingPlanError.self) {
            try JSONDecoder().decode(LampPlanPassage.self, from: Data(#"{"start": 45017001, "end": 45017010}"#.utf8))
        }
    }

    /// An agent asks in words and is shown dates and readings, with nothing
    /// installed.
    @Test func anAgentDraftsAPlanInWords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-agent-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampAgentLibrary(libraryRootURL: root.appendingPathComponent("Library"))

        let request = LampAgentReadingPlanRequest(
            name: "Mark",
            description: "Mark on weekdays",
            tracks: [.init(passages: ["Mark"], chaptersPerDay: 2)],
            startDate: "2026-10-31",
            restDays: ["weekends"]
        )
        let draft = try await library.draftReadingPlan(request)
        #expect(draft.readingDays == 8)
        #expect(draft.days.first == .init(date: "2026-11-02", day: 307, readings: ["Mark 1–2"]))
        #expect(draft.days.map(\.date) == ["02", "03", "04", "05", "06", "09", "10", "11"].map { "2026-11-\($0)" })
        #expect(draft.days.last?.readings == ["Mark 15–16"])
        #expect(try await library.listReadingPlans().isEmpty)

        func restDays(_ names: [String]) throws -> Set<LampWeekday> {
            try LampAgentReadingPlanRequest(name: "P", tracks: [], restDays: names).request().restDays
        }
        #expect(try restDays(["Sundays", "sat", "Thurs", "tue"]) == [.sunday, .saturday, .thursday, .tuesday])
        #expect(throws: LampReadingPlanError.unknownWeekday("s")) { try restDays(["s"]) }
        #expect(throws: LampReadingPlanError.unknownWeekday("Funday")) { try restDays(["Funday"]) }
        for date in ["2026-02-30", "November 1", "2026-11"] {
            #expect(throws: LampReadingPlanError.unknownDate(date)) {
                try LampAgentReadingPlanRequest(name: "P", tracks: [], startDate: date).request()
            }
        }
        await library.updatePolicy(.disabled)
        await #expect(throws: LampAgentError.disabled) { try await library.draftReadingPlan(request) }
    }

    /// Installed, a made plan is an ordinary plan, read back as drafted.
    @Test func aDraftInstallsAsAPlan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-made-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))

        let draft = try LampReadingPlanRequest(
            name: "Luke and Proverbs",
            description: "A Gospel and a proverb a day.",
            tracks: [
                .init(passages: [try passage("Luke")]),
                .init(passages: [try passage("Proverbs")], chaptersPerDay: 1),
            ],
            readingDays: 12,
            start: date(2026, 11, 1),
            restDays: [.sunday]
        ).draft(calendar: calendar)
        let installed = try await library.installReadingPlan(draft)
        #expect(installed.kind == .plan)
        #expect(installed.id == draft.plan.id)
        #expect(try await library.readingPlans() == [draft.plan])
        for day in draft.days {
            let stored = try await library.readingPlanDay(moduleID: draft.plan.id, day: day.number)
            #expect(stored?.readings == day.readings)
        }
        // Sundays have no day of their own.
        #expect(try await library.readingPlanDay(moduleID: draft.plan.id, day: 306) == nil)
    }

    /// A plan that goes takes its progress with it, and says so.
    ///
    /// Unticking one reading records when it happened, so another device's
    /// older tick cannot outrank it. Removing a plan unticks every reading at
    /// once and stops following it, and both have to be recorded the same
    /// way: a row deleted with nothing said about when says nothing at all.
    /// Otherwise the plan is deleted on every device and its ticks come back
    /// from the one that still holds them.
    @Test func removingAPlanRecordsTheUnfollowAndEveryUntick() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-removed-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))

        let draft = try LampReadingPlanRequest(
            name: "Luke",
            tracks: [.init(passages: [try passage("Luke")])],
            readingDays: 4,
            start: date(2026, 11, 1)
        ).draft(calendar: calendar)
        let installed = try await library.installReadingPlan(draft)
        try await library.setPlanSelected(moduleID: installed.id, selected: true)
        let firstDay = try #require(draft.days.first).number
        try await library.setReadingCompleted(
            planID: installed.id, day: firstDay, readingIndex: 0, year: 2026, completed: true
        )
        let readingID = LampLibrary.completedReadingID(
            planID: installed.id, day: firstDay, readingIndex: 0, year: 2026
        )
        #expect(try await library.planProgressLedger().completedReadings.keys.contains(readingID))

        try await library.remove(moduleID: installed.id)

        let ledger = try await library.planProgressLedger()
        #expect(try await library.readingPlans().isEmpty, "the plan is gone")
        #expect(try await library.selectedPlanIDs().isEmpty, "and unfollowed")
        #expect(ledger.selectedPlanIDs.isEmpty)
        #expect(
            ledger.selections[installed.id]?.deletedAt != nil,
            "when it stopped being followed is recorded, which is what outranks the other device"
        )
        #expect(ledger.completedReadings.isEmpty, "every tick taken back")
        #expect(
            ledger.readings[readingID]?.deletedAt != nil,
            "and each of them says when, so none comes back"
        )
    }
}
