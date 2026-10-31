import Foundation
import LampCore
import LampModuleKit

#if canImport(FoundationModels)
import FoundationModels

/// Asks the on-device Apple Intelligence model what plan a person's words
/// describe: "the Gospels in a month", "Proverbs on weekdays".
///
/// The model only says what to read and how fast, in the words
/// `LampAgentReadingPlanRequest` takes, and `LampReadingPlanRequest.draft`
/// lays out the days, so no reference, count or date is the model's own
/// arithmetic. Its books are held to the 66 by name, so it cannot name one
/// that isn't there. Show the draft before installing it: the model can still
/// misread what was asked.
@available(macOS 26, iOS 26, *)
public struct LampReadingPlanAssistant: Sendable {
    public init() {}

    /// Why the model can't be asked on this device, in words to show, or nil
    /// when it can.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to make a plan from a description."
        case .unavailable(.modelNotReady):
            notReady
        case .unavailable:
            "Apple Intelligence isn't available right now."
        }
    }

    private static let notReady = "Apple Intelligence is still getting ready. Try again later."

    /// The plan `words` describe, starting from `today`.
    ///
    /// Throws a `LampReadingPlanAssistantError` to show as it is, or
    /// `CancellationError`.
    public func request(
        for words: String,
        today: Date = Date(),
        calendar: Calendar = LampPlanCalendar.calendar
    ) async throws -> LampAgentReadingPlanRequest {
        if let reason = Self.unavailableReason { throw LampReadingPlanAssistantError.unavailable(reason) }
        let session = LanguageModelSession(instructions: Self.instructions(today: today, calendar: calendar))
        do {
            let answer = try await session.respond(to: words, generating: PlanAnswer.self).content
            return answer.request(today: today, calendar: calendar)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.explained(error)
        }
    }

    /// The model's failure as something a person can act on. Its own
    /// descriptions name its internals: a simulator without the guardrail's
    /// assets says "SensitiveContentAnalysisML error 15".
    ///
    /// The errors moved in the 27 releases, so both the new types and the
    /// 26 ones are read.
    static func explained(_ error: any Error) -> LampReadingPlanAssistantError {
        if #available(macOS 27, iOS 27, *) {
            switch error {
            case let error as LanguageModelError:
                switch error {
                case .contextSizeExceeded: return .tooLong
                case .rateLimited, .timeout: return .busy
                case .guardrailViolation, .refusal: return .declined
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                default: return .failed
                }
            case is GeneratedContent.ParsingError:
                return .notUnderstood
            case is SystemLanguageModel.Error:
                return .unavailable(notReady)
            case let error as LanguageModelSession.Error where error == .concurrentRequests:
                return .busy
            default:
                break
            }
        }
        guard let error = error as? LanguageModelSession.GenerationError else { return .failed }
        switch error {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation, .refusal: return .declined
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .rateLimited, .concurrentRequests: return .busy
        case .decodingFailure, .unsupportedGuide: return .notUnderstood
        case .assetsUnavailable: return .unavailable(notReady)
        @unknown default: return .failed
        }
    }

    static func instructions(today: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return """
            You turn a request for a Bible reading plan into the plan's parts. \
            Today is \(formatter.string(from: today)).

            A plan has one or more tracks read side by side: each day reads some \
            of every track. A track's passages are spread over the plan's days, \
            unless the request sets a pace such as a chapter a day.

            Examples:
            - "The Gospels in 30 days": one track, Matthew to John. 30 days.
            - "The Bible in a year": two tracks, Genesis to Malachi, and Matthew \
            to Revelation. 365 days.
            - "The New Testament in 90 days with a psalm a day": two tracks, \
            Matthew to Revelation, and Psalms at 1 chapter a day. 90 days.
            - "John, a chapter a day, weekdays only": one track, John at 1 chapter \
            a day. 0 days. Rest on Saturday and Sunday.
            - "Romans 1 to 8 over two weeks": one track, Romans chapters 1 to 8. \
            14 days.

            Name and describe the plan plainly, by what it reads and when. Say \
            nothing about what the passages teach.
            """
    }
}

/// Why the model gave no plan, in words to show.
public enum LampReadingPlanAssistantError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case tooLong
    case declined
    case unsupportedLanguage
    case busy
    case notUnderstood
    case failed

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            reason
        case .tooLong:
            "That description is too long for Apple Intelligence. Try a sentence or two."
        case .declined:
            "Apple Intelligence wouldn't make a plan from that description. Try putting it another way, or fill in the plan yourself."
        case .unsupportedLanguage:
            "Apple Intelligence doesn't support this language or region yet. Fill in the plan yourself instead."
        case .busy:
            "Apple Intelligence is busy. Try again in a moment."
        case .notUnderstood:
            "Apple Intelligence couldn't turn that into a plan. Try saying what to read and for how long."
        case .failed:
            "Apple Intelligence couldn't make a plan just now. Try again, or fill in the plan yourself."
        }
    }
}

@available(macOS 26, iOS 26, *)
@Generable
struct PlanAnswer {
    @Guide(description: "A short name for the plan, two to five words, such as The Gospels in a Month")
    var name: String

    @Guide(description: "One plain sentence saying what the plan reads and how often")
    var description: String

    @Guide(description: "Tracks read side by side. Most plans have one.", .count(1...4))
    var tracks: [TrackAnswer]

    @Guide(
        description: "How many days have a reading, when the request gives a length: 30 for a month, 365 for a year. 0 when it gives a pace instead.",
        .range(0...366)
    )
    var readingDays: Int

    @Guide(description: "When the plan starts. Today unless the request says otherwise.")
    var start: StartAnswer

    @Guide(description: "Days of the week with no reading. Empty unless the request asks for days off.")
    var restDays: [WeekdayAnswer]

    /// The answer as a request, its start a date.
    func request(today: Date, calendar: Calendar) -> LampAgentReadingPlanRequest {
        LampAgentReadingPlanRequest(
            name: name,
            description: description,
            tracks: tracks.map {
                .init(passages: $0.passages.map(\.text), chaptersPerDay: $0.chaptersPerDay > 0 ? $0.chaptersPerDay : nil)
            },
            readingDays: readingDays > 0 ? readingDays : nil,
            startDate: start.date(after: today, calendar: calendar),
            restDays: restDays.map(\.rawValue)
        )
    }
}

@available(macOS 26, iOS 26, *)
@Generable
struct TrackAnswer {
    @Guide(description: "What the track reads, in order", .count(1...12))
    var passages: [PassageAnswer]

    @Guide(
        description: "Chapters a day, when the request sets a pace such as a chapter a day. 0 when the track is spread over the plan's days.",
        .range(0...20)
    )
    var chaptersPerDay: Int
}

/// The 66 books by name, the only answers a passage's books may give.
private let bookNames = LampCanonicalBooks.all.map(\.name)

@available(macOS 26, iOS 26, *)
@Generable
struct PassageAnswer {
    @Guide(description: "The first book", .anyOf(bookNames))
    var firstBook: String

    @Guide(description: "The last book: the first again for a single book", .anyOf(bookNames))
    var lastBook: String

    @Guide(description: "The first chapter, when the request names chapters. 0 for the start of the first book.", .range(0...150))
    var firstChapter: Int

    @Guide(description: "The last chapter, when the request names chapters. 0 for the end of the last book.", .range(0...150))
    var lastChapter: Int

    /// As people write a passage, which `LampPlanPassage` reads.
    var text: String {
        if firstChapter == 0 && lastChapter == 0 {
            return firstBook == lastBook ? firstBook : "\(firstBook)–\(lastBook)"
        }
        let last = lastChapter > 0
            ? lastChapter
            : LampCanonicalBooks.book(named: lastBook)?.verseCounts.count ?? 1
        return "\(firstBook) \(max(firstChapter, 1))–\(lastBook) \(last)"
    }
}

@available(macOS 26, iOS 26, *)
@Generable
enum StartAnswer {
    case today
    case tomorrow
    case nextMonday
    case firstOfNextMonth
    case firstOfNextYear

    /// Year-month-day, as `LampAgentReadingPlanRequest` takes a start.
    func date(after today: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: today)
        let date: Date? = switch self {
        case .today:
            day
        case .tomorrow:
            calendar.date(byAdding: .day, value: 1, to: day)
        case .nextMonday:
            calendar.nextDate(after: day, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)
        case .firstOfNextMonth:
            calendar.nextDate(after: day, matching: DateComponents(day: 1), matchingPolicy: .nextTime)
        case .firstOfNextYear:
            calendar.nextDate(after: day, matching: DateComponents(month: 1, day: 1), matchingPolicy: .nextTime)
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date ?? day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

@available(macOS 26, iOS 26, *)
@Generable
enum WeekdayAnswer: String {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday
}
#endif
