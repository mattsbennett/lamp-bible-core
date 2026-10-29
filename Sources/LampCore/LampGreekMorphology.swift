import Foundation

/// One grammatical property of a tagged word, such as its tense or case.
public enum LampGrammarFeature: String, CaseIterable, Codable, Sendable {
    case partOfSpeech
    case tense
    case voice
    case mood
    case person
    case grammaticalCase
    case number
    case gender

    public var title: String {
        switch self {
        case .partOfSpeech: "Part of speech"
        case .tense: "Tense"
        case .voice: "Voice"
        case .mood: "Mood"
        case .person: "Person"
        case .grammaticalCase: "Case"
        case .number: "Number"
        case .gender: "Gender"
        }
    }
}

public struct LampGrammarValue: Hashable, Sendable {
    public let feature: LampGrammarFeature
    public let value: String

    public init(feature: LampGrammarFeature, value: String) {
        self.feature = feature
        self.value = value
    }
}

/// Robinson's parsing codes for New Testament Greek, which the KJV's tags
/// carry: `V-AAI-3S` is a verb, aorist, active, indicative, third person,
/// singular. A code this does not know reads as no features, never as a guess.
///
/// A second aorist, future or perfect (`V-2AAI-3S`) is read as that tense. The
/// "second" names how the stem is formed, not a tense of its own, and counting
/// it apart would split one tense in two.
public enum LampGreekMorphology {
    public static func features(of code: String) -> [LampGrammarValue] {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .split(separator: "-").map(String.init)
        guard let head = parts.first else { return [] }
        if let word = indeclinable[head] {
            return [LampGrammarValue(feature: .partOfSpeech, value: word)]
        }
        if head == "V" {
            return parts.count > 1 ? verb(parts) : []
        }
        guard let word = declinable[head], parts.count > 1 else { return [] }
        return [LampGrammarValue(feature: .partOfSpeech, value: word)] + inflection(of: parts[1], possessive: head == "S")
    }

    /// The features joined for display, or nil for a code this does not know.
    public static func describe(_ code: String) -> String? {
        let values = features(of: code)
        return values.isEmpty ? nil : values.map(\.value).joined(separator: " · ")
    }

    private static func verb(_ parts: [String]) -> [LampGrammarValue] {
        var form = Substring(parts[1])
        if form.first == "2" { form = form.dropFirst() }
        let letters = Array(form)
        guard letters.count == 3,
              let mood = moods[letters[2]] else { return [] }
        var values = [LampGrammarValue(feature: .partOfSpeech, value: "Verb")]
        if let tense = tenses[letters[0]] { values.append(.init(feature: .tense, value: tense)) }
        if let voice = voices[letters[1]] { values.append(.init(feature: .voice, value: voice)) }
        values.append(.init(feature: .mood, value: mood))
        if parts.count > 2 { values += inflection(of: parts[2], possessive: false) }
        return values
    }

    /// Person and number for a finite verb or a pronoun of person; case,
    /// number and gender for everything that declines. A possessive names its
    /// possessor's number before the case of the thing possessed (`S-1SNSF`),
    /// and that number is not the word's own.
    private static func inflection(of code: String, possessive: Bool) -> [LampGrammarValue] {
        guard !indeclinableForms.contains(code) else { return [] }
        var letters = Array(code)
        var values: [LampGrammarValue] = []
        if let first = letters.first, let person = persons[first] {
            values.append(.init(feature: .person, value: person))
            letters.removeFirst()
            if possessive, letters.count == 4 { letters.removeFirst() }
        }
        if letters.count == 1, !values.isEmpty {
            if let number = numbers[letters[0]] { values.append(.init(feature: .number, value: number)) }
            return values
        }
        guard let first = letters.first, let grammaticalCase = cases[first] else { return values }
        values.append(.init(feature: .grammaticalCase, value: grammaticalCase))
        if letters.count > 1, let number = numbers[letters[1]] {
            values.append(.init(feature: .number, value: number))
        }
        if letters.count > 2, let gender = genders[letters[2]] {
            values.append(.init(feature: .gender, value: gender))
        }
        return values
    }

    private static let indeclinable: [String: String] = [
        "ADV": "Adverb", "CONJ": "Conjunction", "COND": "Conditional", "PRT": "Particle",
        "PREP": "Preposition", "INJ": "Interjection", "HEB": "Hebrew word", "ARAM": "Aramaic word",
    ]

    private static let declinable: [String: String] = [
        "N": "Noun", "A": "Adjective", "T": "Article", "P": "Personal pronoun",
        "R": "Relative pronoun", "C": "Reciprocal pronoun", "D": "Demonstrative pronoun",
        "K": "Correlative pronoun", "I": "Interrogative pronoun", "X": "Indefinite pronoun",
        "Q": "Correlative or interrogative pronoun", "F": "Reflexive pronoun", "S": "Possessive pronoun",
    ]

    /// A proper name, numeral, letter or other word that does not decline:
    /// `N-PRI`, `A-NUI`, `N-LI`, `N-OI`.
    private static let indeclinableForms: Set<String> = ["PRI", "NUI", "LI", "OI"]

    private static let tenses: [Character: String] = [
        "P": "Present", "I": "Imperfect", "F": "Future", "A": "Aorist", "R": "Perfect", "L": "Pluperfect",
    ]

    private static let voices: [Character: String] = [
        "A": "Active", "M": "Middle", "P": "Passive", "E": "Middle or passive",
        "D": "Middle deponent", "O": "Passive deponent", "N": "Middle or passive deponent",
        "Q": "Impersonal active",
    ]

    private static let moods: [Character: String] = [
        "I": "Indicative", "S": "Subjunctive", "O": "Optative", "M": "Imperative",
        "N": "Infinitive", "P": "Participle", "R": "Imperative participle",
    ]

    private static let persons: [Character: String] = ["1": "1st person", "2": "2nd person", "3": "3rd person"]
    private static let cases: [Character: String] = [
        "N": "Nominative", "G": "Genitive", "D": "Dative", "A": "Accusative", "V": "Vocative",
    ]
    private static let numbers: [Character: String] = ["S": "Singular", "P": "Plural"]
    private static let genders: [Character: String] = ["M": "Masculine", "F": "Feminine", "N": "Neuter"]
}
