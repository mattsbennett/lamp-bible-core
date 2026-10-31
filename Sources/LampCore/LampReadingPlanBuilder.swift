import Foundation
import LampModuleKit

/// A reading plan made to order: which passages, read alongside each other,
/// over how many days, from which day.
///
/// A plan's days are days of the year, as `LampPlanCalendar` numbers them, so
/// a made plan is laid on the dates it will be read: one starting on
/// 1 November has its first reading on day 306, and comes round again each
/// November. Drafted, it is an ordinary plan module, installed, synced and
/// ticked off like any other.
///
/// The arithmetic is all here, so a form, an agent and the on-device model
/// each say only what to read and how fast, and every plan is laid out alike.
public struct LampReadingPlanRequest: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    /// Read alongside each other: every reading day has a portion of each.
    public var tracks: [Track]
    /// How many days have a reading. Nil: as many as the paced tracks take
    /// to be read once through.
    public var readingDays: Int?
    /// The first day with a reading, unless it is a rest day.
    public var start: Date
    /// Weekdays with no reading. The plan runs on past them, so it still has
    /// `readingDays` days of reading.
    public var restDays: Set<LampWeekday>

    public struct Track: Codable, Equatable, Sendable {
        public var passages: [LampPlanPassage]
        /// Whole chapters a day, from the start again once the passages are
        /// read, so a short track such as Proverbs can run beside a long one.
        /// Nil spreads the passages over the plan's days, evenly by verses.
        public var chaptersPerDay: Int?

        public init(passages: [LampPlanPassage], chaptersPerDay: Int? = nil) {
            self.passages = passages
            self.chaptersPerDay = chaptersPerDay
        }
    }

    public init(
        name: String,
        description: String? = nil,
        tracks: [Track],
        readingDays: Int? = nil,
        start: Date,
        restDays: Set<LampWeekday> = []
    ) {
        self.name = name
        self.description = description
        self.tracks = tracks
        self.readingDays = readingDays
        self.start = start
        self.restDays = restDays
    }

    /// The plan laid out on its dates, under `id`.
    ///
    /// A track spread over the days is cut at chapter ends, each day as near
    /// an even share of its verses as whole chapters allow; one with fewer
    /// chapters than days is cut between verses instead.
    public func draft(
        id: String = UUID().uuidString,
        calendar: Calendar = LampPlanCalendar.calendar
    ) throws -> LampReadingPlanDraft {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LampReadingPlanError.noName }
        let tracks = try tracks.map { track -> (portions: [Portion], pace: Int?) in
            let portions = track.passages.flatMap(\.portions)
            guard !portions.isEmpty else { throw LampReadingPlanError.noPassages }
            if let pace = track.chaptersPerDay, pace < 1 { throw LampReadingPlanError.invalidPace(pace) }
            return (portions, track.chaptersPerDay)
        }
        guard !tracks.isEmpty else { throw LampReadingPlanError.noPassages }

        let paced = tracks.compactMap { track in
            track.pace.map { (track.portions.count + $0 - 1) / $0 }
        }
        guard let days = readingDays ?? paced.max() else { throw LampReadingPlanError.noLength }
        guard days >= 1 else { throw LampReadingPlanError.noLength }
        guard days <= 366 else { throw LampReadingPlanError.longerThanAYear }

        let resting = Set(restDays.map(\.calendarWeekday))
        guard resting.count < 7 else { throw LampReadingPlanError.noReadingWeekdays }
        var dates: [Date] = []
        var date = calendar.startOfDay(for: start)
        while dates.count < days {
            if !resting.contains(calendar.component(.weekday, from: date)) { dates.append(date) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        let numbers = dates.map { LampPlanCalendar.dayNumber(for: $0, calendar: calendar) }
        // A plan comes round each year, so it holds each day of the year once.
        guard Set(numbers).count == numbers.count else { throw LampReadingPlanError.longerThanAYear }

        let portionsByTrack = try tracks.map { track in
            if let pace = track.pace {
                return Self.paced(track.portions, chaptersPerDay: pace, days: days)
            }
            return try Self.spread(track.portions, over: days)
        }
        let planDays = dates.indices.map { index in
            let readings = portionsByTrack.flatMap { Self.readings($0[index]) }
            return LampReadingPlanDraft.Day(
                date: dates[index],
                number: numbers[index],
                readings: readings.enumerated().map {
                    LampPlanReading(id: $0.offset, startReference: $0.element.start, endReference: $0.element.end)
                }
            )
        }
        let description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LampReadingPlanDraft(
            plan: LampReadingPlan(
                id: id,
                name: name,
                description: description?.isEmpty == false ? description : nil,
                duration: days,
                readingsPerDay: tracks.count
            ),
            days: planDays
        )
    }

    /// One chapter, or the part of it a passage reads.
    struct Portion: Equatable {
        let book: Int
        let chapter: Int
        let first: Int
        let last: Int
        /// The verses in the whole chapter.
        let length: Int

        var verses: Int { last - first + 1 }
    }

    /// `portions` cut into `days` runs in order, each as near an even share
    /// of the verses as the cuts allow.
    static func spread(_ portions: [Portion], over days: Int) throws -> [[Portion]] {
        if portions.count >= days {
            return cut(portions, into: days)
        }
        let verses = portions.flatMap { portion in
            (portion.first...portion.last).map {
                Portion(book: portion.book, chapter: portion.chapter, first: $0, last: $0, length: portion.length)
            }
        }
        guard verses.count >= days else {
            throw LampReadingPlanError.tooFewVerses(verses: verses.count, days: days)
        }
        return cut(verses, into: days).map(joined)
    }

    /// Cuts between portions, never inside one, so each run holds at least one.
    private static func cut(_ portions: [Portion], into days: Int) -> [[Portion]] {
        var cumulative = [0]
        for portion in portions { cumulative.append(cumulative[cumulative.count - 1] + portion.verses) }
        let total = Double(cumulative[cumulative.count - 1])
        var cuts = [0]
        for day in 1..<days {
            let target = total * Double(day) / Double(days)
            let latest = portions.count - (days - day)
            var cut = cuts[cuts.count - 1] + 1
            while cut < latest,
                  abs(Double(cumulative[cut + 1]) - target) <= abs(Double(cumulative[cut]) - target) {
                cut += 1
            }
            cuts.append(cut)
        }
        cuts.append(portions.count)
        return (0..<days).map { Array(portions[cuts[$0]..<cuts[$0 + 1]]) }
    }

    /// Adjacent verses of one chapter as one portion.
    private static func joined(_ verses: [Portion]) -> [Portion] {
        var portions: [Portion] = []
        for verse in verses {
            if let last = portions.last, last.book == verse.book, last.chapter == verse.chapter,
               last.last + 1 == verse.first {
                portions[portions.count - 1] = Portion(
                    book: last.book, chapter: last.chapter, first: last.first, last: verse.last, length: last.length
                )
            } else {
                portions.append(verse)
            }
        }
        return portions
    }

    static func paced(_ portions: [Portion], chaptersPerDay: Int, days: Int) -> [[Portion]] {
        let pace = min(chaptersPerDay, portions.count)
        return (0..<days).map { day in
            (0..<pace).map { portions[(day * pace + $0) % portions.count] }
        }
    }

    /// A day's portions of one track as readings: one for each unbroken run
    /// within a book, whole chapters ending on the 999 every plan uses for a
    /// chapter's last verse.
    static func readings(_ portions: [Portion]) -> [(start: Int, end: Int)] {
        var runs: [[Portion]] = []
        for portion in portions {
            if let last = runs.last?.last, last.book == portion.book,
               (portion.chapter == last.chapter && portion.first == last.last + 1)
                || (portion.chapter == last.chapter + 1 && last.last == last.length && portion.first == 1) {
                runs[runs.count - 1].append(portion)
            } else {
                runs.append([portion])
            }
        }
        return runs.map { run in
            let first = run[0]
            let last = run[run.count - 1]
            let whole = first.first == 1 && last.last == last.length
            return (
                LampPlanPassage.reference(first.book, first.chapter, first.first),
                LampPlanPassage.reference(last.book, last.chapter, whole ? 999 : last.last)
            )
        }
    }
}

/// A run of verses a made plan reads, in canonical order, on the KJV grid
/// every Lamp translation shares.
public struct LampPlanPassage: Codable, Hashable, Sendable {
    /// The first verse, as BBCCCVVV.
    public let start: Int
    /// The last verse, as BBCCCVVV.
    public let end: Int

    /// From `start` to `end`, either of which may give a verse of 999 for its
    /// chapter's last.
    public init(start: Int, end: Int) throws {
        let source = "\(start)–\(end)"
        guard let first = Self.verse(start, source: source, isEnd: false),
              let last = Self.verse(end, source: source, isEnd: true),
              first <= last else {
            throw LampReadingPlanError.unknownPassage(source)
        }
        self.start = first
        self.end = last
    }

    /// Checked as `init(start:end:)` checks, so a request read from outside
    /// holds only passages Lamp can read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            start: try container.decode(Int.self, forKey: .start),
            end: try container.decode(Int.self, forKey: .end)
        )
    }

    /// Whole books, from the first's first verse to the last's last.
    public init(books: ClosedRange<Int>) throws {
        try self.init(
            start: Self.reference(books.lowerBound, 1, 1),
            end: Self.reference(books.upperBound, LampReferenceParser.chapterCount(ofBook: books.upperBound) ?? 0, 999)
        )
    }

    /// Reads a passage as people write one: "Genesis–Deuteronomy", "NT",
    /// "1 John", "Psalms 1–41", "Romans 8", "Matthew 5:1–7:29".
    public init(_ text: String) throws {
        do {
            if let range = try? LampReferenceParser.parse(text) {
                try self.init(
                    start: Self.reference(range.start.book, range.start.chapter, range.start.verse ?? 1),
                    end: Self.reference(range.end.book, range.end.chapter, range.end.verse ?? 999)
                )
            } else {
                try self.init(books: try LampReferenceParser.books(text))
            }
        } catch {
            throw LampReadingPlanError.unknownPassage(text)
        }
    }

    /// The chapters, or parts of them, the passage reads.
    var portions: [LampReadingPlanRequest.Portion] {
        let (startBook, startChapter, startVerse) = LampBibleReferenceFormatter.components(of: start)
        let (endBook, endChapter, endVerse) = LampBibleReferenceFormatter.components(of: end)
        var portions: [LampReadingPlanRequest.Portion] = []
        for book in startBook...endBook {
            guard let lengths = LampCanonicalBooks.book(book)?.verseCounts else { continue }
            let firstChapter = book == startBook ? startChapter : 1
            let lastChapter = book == endBook ? endChapter : lengths.count
            guard firstChapter <= lastChapter else { continue }
            for chapter in firstChapter...lastChapter {
                let length = lengths[chapter - 1]
                portions.append(.init(
                    book: book,
                    chapter: chapter,
                    first: book == startBook && chapter == startChapter ? startVerse : 1,
                    last: book == endBook && chapter == endChapter ? endVerse : length,
                    length: length
                ))
            }
        }
        return portions
    }

    static func reference(_ book: Int, _ chapter: Int, _ verse: Int) -> Int {
        book * 1_000_000 + chapter * 1_000 + verse
    }

    /// `reference` checked against the grid, an end's 999 made its chapter's
    /// last verse.
    private static func verse(_ reference: Int, source: String, isEnd: Bool) -> Int? {
        let (book, chapter, verse) = LampBibleReferenceFormatter.components(of: reference)
        guard let lengths = LampCanonicalBooks.book(book)?.verseCounts,
              lengths.indices.contains(chapter - 1) else { return nil }
        let length = lengths[chapter - 1]
        if isEnd && verse == 999 { return Self.reference(book, chapter, length) }
        guard (1...length).contains(verse) else { return nil }
        return reference
    }
}

public enum LampWeekday: String, Codable, CaseIterable, Sendable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    /// As `Calendar` numbers weekdays: Sunday is 1.
    public var calendarWeekday: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

/// A made plan, laid on its dates, before it is installed.
public struct LampReadingPlanDraft: Equatable, Sendable {
    public let plan: LampReadingPlan
    public let days: [Day]

    public struct Day: Equatable, Sendable {
        public let date: Date
        /// The plan's day number for `date`, 1 through 366.
        public let number: Int
        public let readings: [LampPlanReading]
    }

    /// The plan as module JSON, for `LampModuleCompiler`.
    public func moduleJSON() throws -> Data {
        var meta: [String: Any] = [
            "schemaVersion": LampModuleCompiler.formatVersion,
            "id": plan.id,
            "type": LampModuleKind.plan.rawValue,
            "name": plan.name,
            "duration": plan.duration,
        ]
        meta["description"] = plan.description
        meta["readingsPerDay"] = plan.readingsPerDay
        let days = days.map { day -> [String: Any] in
            [
                "day": day.number,
                "readings": day.readings.map { ["sv": $0.startReference, "ev": $0.endReference] },
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["meta": meta, "days": days],
            options: [.sortedKeys]
        )
    }
}

public enum LampReadingPlanError: Error, LocalizedError, Equatable, Sendable {
    case noName
    case noPassages
    case unknownPassage(String)
    case invalidPace(Int)
    case noLength
    case longerThanAYear
    case noReadingWeekdays
    case tooFewVerses(verses: Int, days: Int)
    case unknownDate(String)
    case unknownWeekday(String)

    public var errorDescription: String? {
        switch self {
        case .noName:
            "A plan needs a name."
        case .noPassages:
            "Each part of a plan needs something to read."
        case .unknownPassage(let passage):
            "‘\(passage)’ is not a passage Lamp knows. Try a form such as Matthew–John, Psalms 1–41 or Romans 8."
        case .invalidPace(let pace):
            "A plan can't read \(pace) chapters a day."
        case .noLength:
            "Say how many days the plan has, or how many chapters a day it reads."
        case .longerThanAYear:
            "A plan can run for a year at most, since it comes round again each year."
        case .noReadingWeekdays:
            "A plan needs at least one day of the week to read on."
        case .tooFewVerses(let verses, let days):
            "\(verses) verses can't be spread over \(days) days."
        case .unknownDate(let date):
            "‘\(date)’ is not a date. Give one as year-month-day, such as 2026-11-01."
        case .unknownWeekday(let day):
            "‘\(day)’ is not a day of the week."
        }
    }
}
