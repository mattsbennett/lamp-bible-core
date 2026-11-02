import Foundation

/// STEPBible's morphology codes for the Hebrew and Aramaic of the Old
/// Testament, which `TAHOT`'s tags carry: `HVqp3ms` is a Hebrew verb, Qal,
/// perfect, third person, masculine, singular.
///
/// The shape is a language letter, a function letter, and then fields whose
/// layout the function decides. A code this does not know reads as no features,
/// never as a guess — the same rule the Greek decoder keeps.
///
/// Two things the Greek codes have no equivalent of.
///
/// A verb's fields depend on its form. A finite verb is followed by person,
/// gender and number; a participle by gender, number and state; an infinitive
/// by state alone. The form letter `c` is an infinitive when one field follows
/// it and an imperfect when three do, which is why the fields are counted
/// before they are read.
///
/// And a word can be several morphemes, written with `/` between them:
/// `Hc/Vqw3ms` is a consecutive conjunction joined to a verb, `HNcmsc/Sp3ms` a
/// construct noun with a pronominal suffix. The features reported are the
/// content morpheme's — the noun, verb, adjective or pronoun — because the
/// analysis that asks for them is keyed on that morpheme's Strong's number, and
/// the article or conjunction beside it has a number of its own. Where no
/// segment is a content word, the first is read.
///
/// Derived from the Translators Expansion of Hebrew Morphology Codes (TEHMC),
/// by STEPBible.org based on work at Tyndale House, Cambridge, CC BY 4.0,
/// <https://STEPBible.github.io/STEPBible-Data>.
public enum LampHebrewMorphology {
    public static func features(of code: String) -> [LampGrammarValue] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (language, segment) = contentSegment(of: trimmed) else { return [] }
        return features(of: segment, language: language)
    }

    /// The features joined for display, or nil for a code this does not know.
    public static func describe(_ code: String) -> String? {
        let values = features(of: code)
        return values.isEmpty ? nil : values.map(\.value).joined(separator: " · ")
    }

    // MARK: - Segments

    private static let contentFunctions: Set<Character> = ["N", "V", "A", "P"]

    /// Splits a code into its morphemes and returns the one worth reading, with
    /// the language the first morpheme declared. Only the first carries the
    /// language letter, so the others are read under it.
    private static func contentSegment(of code: String) -> (Character, Substring)? {
        let parts = code.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first, let language = first.first,
              language == "H" || language == "A" else { return nil }
        let segments = parts.enumerated().map { index, part in
            index == 0 ? part.dropFirst() : part
        }.filter { !$0.isEmpty }
        guard let fallback = segments.first else { return nil }
        let content = segments.first { contentFunctions.contains($0.first ?? " ") }
        return (language, content ?? fallback)
    }

    // MARK: - One segment

    private static func features(
        of segment: Substring, language: Character
    ) -> [LampGrammarValue] {
        guard let function = segment.first else { return [] }
        let fields = Array(segment.dropFirst())
        switch function {
        case "N": return nominal("Noun", nounForms, fields)
        case "A": return nominal("Adjective", adjectiveForms, fields)
        case "V": return verb(fields, language: language)
        case "P": return pronoun("Pronoun", pronounForms, fields)
        case "S": return pronoun("Suffix", suffixForms, fields)
        case "T": return particle("Particle", particleForms, fields)
        case "R": return particle("Preposition", prepositionForms, fields)
        case "C": return [value(.partOfSpeech, "Conjunction")]
        case "c": return [value(.partOfSpeech, "Conjunction"), value(.form, "Consecutive")]
        case "D": return [value(.partOfSpeech, "Adverb")]
        default: return []
        }
    }

    /// A noun or adjective: form, gender, number, state.
    ///
    /// A proper noun is the exception, and carries neither number nor state —
    /// `HNpm` is all there is of one. What follows the form is a gender, or
    /// else what kind of name it is: a location or a title.
    private static func nominal(
        _ part: String, _ forms: [Character: String], _ fields: [Character]
    ) -> [LampGrammarValue] {
        var values = [value(.partOfSpeech, part)]
        guard let first = fields.first, let form = forms[first] else {
            return fields.isEmpty ? values : []
        }
        values.append(value(.form, form))
        if form == "Proper" {
            guard fields.count == 2, let kind = properNounKinds[fields[1]] else { return [] }
            values.append(value(.gender, kind))
            return values
        }
        guard fields.count >= 4, let gender = genders[fields[1]],
              let number = numbers[fields[2]], let state = states[fields[3]] else { return [] }
        values.append(value(.number, number))
        values.append(value(.gender, gender))
        values.append(value(.state, state))
        return values
    }

    /// A pronoun or a suffix: form, then person, gender and number.
    private static func pronoun(
        _ part: String, _ forms: [Character: String], _ fields: [Character]
    ) -> [LampGrammarValue] {
        var values = [value(.partOfSpeech, part)]
        guard let first = fields.first, let form = forms[first] else { return [] }
        values.append(value(.form, form))
        guard fields.count >= 4 else { return values }
        guard let person = persons[fields[1]], let gender = genders[fields[2]],
              let number = numbers[fields[3]] else { return values }
        values.append(value(.person, person))
        values.append(value(.number, number))
        values.append(value(.gender, gender))
        return values
    }

    private static func particle(
        _ part: String, _ forms: [Character: String], _ fields: [Character]
    ) -> [LampGrammarValue] {
        var values = [value(.partOfSpeech, part)]
        if let first = fields.first, let form = forms[first] {
            values.append(value(.form, form))
        }
        return values
    }

    private static func verb(_ fields: [Character], language: Character) -> [LampGrammarValue] {
        var values = [value(.partOfSpeech, "Verb")]
        guard fields.count >= 2 else { return [] }
        let stems = language == "A" ? aramaicStems : hebrewStems
        guard let stem = stems[fields[0]] else { return [] }
        values.append(value(.stem, stem))
        let tail = Array(fields.dropFirst(2))
        guard let form = verbForm(fields[1], fieldCount: tail.count) else { return [] }
        values.append(value(.form, form))
        switch tail.count {
        case 1:
            guard let state = states[tail[0]] else { return [] }
            values.append(value(.state, state))
        case 3 where form.hasPrefix("Participle"):
            guard let gender = genders[tail[0]], let number = numbers[tail[1]],
                  let state = states[tail[2]] else { return [] }
            values.append(value(.number, number))
            values.append(value(.gender, gender))
            values.append(value(.state, state))
        case 3:
            guard let person = persons[tail[0]], let gender = genders[tail[1]],
                  let number = numbers[tail[2]] else { return [] }
            values.append(value(.person, person))
            values.append(value(.number, number))
            values.append(value(.gender, gender))
        default:
            return []
        }
        return values
    }

    /// `c` is an infinitive with one field after it and an imperfect with three.
    private static func verbForm(_ letter: Character, fieldCount: Int) -> String? {
        if letter == "c" { return fieldCount == 1 ? "Infinitive" : "Imperfect" }
        return verbForms[letter]
    }

    private static func value(_ feature: LampGrammarFeature, _ text: String) -> LampGrammarValue {
        LampGrammarValue(feature: feature, value: text)
    }

    // MARK: - The codes, from TEHMC

    private static let nounForms: [Character: String] = [
        "c": "Common", "p": "Proper", "g": "Gentilic", "t": "Title",
    ]
    private static let adjectiveForms: [Character: String] = [
        "a": "Common", "c": "Numerical", "o": "Numerical position",
    ]
    private static let pronounForms: [Character: String] = [
        "p": "Personal", "d": "Demonstrative", "i": "Interrogative", "r": "Relative",
        "f": "Indefinite",
    ]
    private static let suffixForms: [Character: String] = [
        "p": "Personal", "d": "Directional", "h": "Paragogic Hé", "n": "Paragogic Nun",
    ]
    private static let properNounKinds: [Character: String] = [
        "m": "Masculine", "f": "Feminine", "l": "Location", "t": "Title",
    ]
    /// A preposition's `d` says it carries the article, where a particle's `d`
    /// is the article itself.
    private static let prepositionForms: [Character: String] = ["d": "Definite"]
    private static let particleForms: [Character: String] = [
        "a": "Definite article", "d": "Definite article", "c": "Conditional",
        "i": "Interrogative", "j": "Interjection", "m": "Demonstrative",
        "n": "Negative", "o": "Object indicator", "r": "Relative", "e": "Exhortation",
    ]
    private static let genders: [Character: String] = [
        "m": "Masculine", "f": "Feminine", "b": "Either gender", "c": "Either gender",
    ]
    private static let numbers: [Character: String] = [
        "s": "Singular", "p": "Plural", "d": "Dual",
    ]
    private static let states: [Character: String] = [
        "a": "Absolute", "c": "Construct", "d": "Definite",
    ]
    private static let persons: [Character: String] = [
        "1": "First", "2": "Second", "3": "Third",
    ]
    private static let hebrewStems: [Character: String] = [
        "q": "Qal", "N": "Niphal", "p": "Piel", "P": "Pual", "h": "Hiphil",
        "H": "Hophal", "t": "Hithpael", "u": "Hothpaal", "D": "Nithpael",
        "O": "Polal", "c": "Tiphil", "v": "Hishtaphel",
    ]
    private static let aramaicStems: [Character: String] = [
        "q": "Peal", "Q": "Peil", "p": "Pael", "a": "Aphel", "h": "Haphel",
        "H": "Hophal", "i": "Hitpeel", "P": "Pual", "M": "Hitpaal",
        "u": "Hitpael", "e": "Shaphel", "v": "Ishtaphel",
    ]
    // Two letters carry two meanings in TEHMC itself, and the commoner reading
    // is taken: Aramaic `P` is Pual in three of its five codes and Hitpeel in
    // the other two, and the form letter `i` is an imperfect in 92 codes and a
    // perfect in two. Four of its 921 definitions therefore read differently
    // here, which `LampHebrewMorphologyTests` records by name.
    private static let verbForms: [Character: String] = [
        "p": "Perfect", "q": "Consecutive Perfect", "i": "Imperfect",
        "w": "Consecutive Imperfect", "j": "Imperfect", "n": "Imperfect",
        "u": "Conjunction+Imperfect", "v": "Imperative", "a": "Infinitive",
        "r": "Participle", "s": "Participle passive",
    ]
}
