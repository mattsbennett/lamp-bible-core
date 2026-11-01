import Foundation
import LampCore

/// What a person's words settle about a plan, read from the words themselves
/// so the model's answer can't unsettle it: the chapter numbers they wrote,
/// the days of the week they read on, and whether they set a pace. Asked for
/// "the gospels in a month, weekdays only", the phone's model answered a
/// chapter a day on Saturdays only.
///
/// English only, as the model's instructions are.
struct PlanWords {
    /// The numbers the words give, in digits or spelled out: "Romans 1 to 8",
    /// "the first eight chapters of Romans".
    let numbers: Set<Int>

    /// The days with no reading: "weekdays only", "Sundays off", "every day
    /// but Sunday", "Mon–Fri".
    let restDays: Set<LampWeekday>

    /// Whether the words set a pace, such as "a chapter a day" or "a psalm
    /// each day", rather than leaving the passages spread over the plan.
    let setPace: Bool

    init(_ words: String) {
        numbers = Self.numbers(in: words)
        restDays = Self.restDays(in: Self.tokens(words))
        setPace = words.lowercased().range(of: Self.pace, options: .regularExpression) != nil
    }

    private static func numbers(in words: String) -> Set<Int> {
        let spelled = NumberFormatter()
        spelled.numberStyle = .spellOut
        spelled.locale = Locale(identifier: "en_US")
        let digits = words.split { !($0.isASCII && $0.isNumber) }.compactMap { Int($0) }
        let names = words.lowercased().split { !$0.isLetter && $0 != "-" }.compactMap {
            spelled.number(from: String($0))?.intValue
        }
        return Set(digits + names)
    }

    private static let pace = [
        #"\b(chapters?|psalms?|proverbs?)\b[^.,;:!?]*?\b(a|an|per|each|every)[\s-]+(day|weekday|morning|evening|night)\b"#,
        #"\b(chapters?|psalms?|proverbs?)\s*/\s*day\b"#,
        #"\b(chapters?|psalms?|proverbs?)[\s-]+daily\b"#,
        #"\bdaily[\s-]+(chapters?|psalms?|proverbs?)\b"#,
    ].joined(separator: "|")

    /// Lowercased words, with "-" for a dash and "," wherever a clause or
    /// list breaks.
    private static func tokens(_ words: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in words.lowercased() {
            if character.isLetter {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                tokens.append(word)
                word = ""
            }
            if "-–—".contains(character) {
                tokens.append("-")
            } else if ",;:.!?()".contains(character) {
                tokens.append(",")
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    private static let weekdays: Set<LampWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    private static let abbreviations: [String: LampWeekday] = [
        "sun": .sunday, "mon": .monday, "tue": .tuesday, "tues": .tuesday, "wed": .wednesday,
        "thu": .thursday, "thur": .thursday, "fri": .friday, "sat": .saturday,
    ]

    private static func days(named token: String) -> Set<LampWeekday>? {
        switch token {
        case "weekday", "weekdays":
            return weekdays
        case "weekend", "weekends":
            return [.saturday, .sunday]
        default:
            let name = token.count > 4 && token.hasSuffix("s") ? String(token.dropLast()) : token
            if let day = LampWeekday(rawValue: name) ?? abbreviations[name] { return [day] }
            return nil
        }
    }

    /// The days from `first` to `last`, round the week if need be.
    private static func days(from first: LampWeekday, to last: LampWeekday) -> Set<LampWeekday> {
        let all = LampWeekday.allCases
        var index = all.firstIndex(of: first)!
        var days: Set<LampWeekday> = [first]
        while all[index] != last {
            index = (index + 1) % all.count
            days.insert(all[index])
        }
        return days
    }

    private static let joins: Set<String> = [",", "and", "or", "nor"]
    private static let spans: Set<String> = ["-", "to", "through", "thru", "till", "until"]
    /// Before a day, these make it a date rather than a day of every week.
    private static let dates: Set<String> = [
        "start", "starts", "starting", "begin", "begins", "beginning", "from", "next", "this",
        "by", "until", "till", "before", "after",
    ]
    private static let restingBefore: Set<String> = [
        "no", "not", "never", "nothing", "except", "excluding", "without", "but", "minus",
        "skip", "skips", "skipping", "rest", "resting", "off",
    ]
    private static let restingAfter: Set<String> = ["off", "free", "rest", "resting", "excluded", "skipped"]

    /// Each run of days ("Saturdays and Sundays", "Mon, Wed, Fri", "Monday
    /// to Friday") is read on unless the words around it rest it: "no",
    /// "except", "but" before it, "off" or "free" after. "Only" beside a run
    /// always reads it ("but weekdays only"), and a run that is a start
    /// date ("starting Monday") says nothing about the week.
    private static func restDays(in tokens: [String]) -> Set<LampWeekday> {
        var reading: Set<LampWeekday>?
        var resting: Set<LampWeekday> = []
        var index = 0
        while index < tokens.count {
            guard var run = days(named: tokens[index]) else {
                index += 1
                continue
            }
            let before = Array(tokens[..<index].reversed().prefix { $0 != "," }.prefix(3))
            // "Starting Monday" names one day, unless it is the first of a
            // span: "from Monday to Friday".
            let dated = before.prefix(2).contains(where: dates.contains)
            var last = run
            var end = index
            var spanned = false
            while end + 1 < tokens.count {
                let link = tokens[end + 1]
                if dated && !spanned && !spans.contains(link) { break }
                if let next = days(named: link) {
                    run.formUnion(next)
                    last = next
                    end += 1
                } else if end + 2 < tokens.count, let next = days(named: tokens[end + 2]),
                          joins.contains(link) || spans.contains(link) {
                    if spans.contains(link), last.count == 1, next.count == 1 {
                        run.formUnion(days(from: last.first!, to: next.first!))
                        spanned = true
                    } else {
                        run.formUnion(next)
                    }
                    last = next
                    end += 2
                } else {
                    break
                }
            }
            let after = Array(tokens[(end + 1)...].prefix { $0 != "," }.prefix(3))
            index = end + 1
            if dated && !spanned { continue }
            let only = ["only", "just"].contains(before.first) || after.first == "only"
            if !only && (before.contains(where: restingBefore.contains) || after.contains(where: restingAfter.contains)) {
                resting.formUnion(run)
            } else {
                reading = (reading ?? []).union(run)
            }
        }
        let all = Set(LampWeekday.allCases)
        return all.subtracting((reading ?? all).subtracting(resting))
    }
}
