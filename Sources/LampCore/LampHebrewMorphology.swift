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
/// construct noun with a pronominal suffix. One of them is reported: the one
/// the word's Strong's number names, because that is the morpheme an analysis
/// asking for a parsing is keyed on. Which one that is cannot be read off the
/// code, which is why the number is passed in beside it.
///
/// Derived from the Translators Expansion of Hebrew Morphology Codes (TEHMC),
/// by STEPBible.org based on work at Tyndale House, Cambridge, CC BY 4.0,
/// <https://STEPBible.github.io/STEPBible-Data>.
public enum LampHebrewMorphology {
    public static func features(of code: String, strongsKey: String?) -> [LampGrammarValue] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (language, segment) = contentSegment(of: trimmed, strongsKey: strongsKey)
        else { return [] }
        return features(of: segment, language: language)
    }

    /// The features joined for display, or nil for a code this does not know.
    public static func describe(_ code: String, strongsKey: String?) -> String? {
        let values = features(of: code, strongsKey: strongsKey)
        return values.isEmpty ? nil : values.map(\.value).joined(separator: " · ")
    }

    // MARK: - Segments

    /// Splits a code into its morphemes and returns the one worth reading, with
    /// the language the first morpheme declared. Only the first carries the
    /// language letter, so the others are read under it.
    private static func contentSegment(
        of code: String, strongsKey: String?
    ) -> (Character, Substring)? {
        let parts = code.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first, let language = first.first,
              language == "H" || language == "A" else { return nil }
        let segments = parts.enumerated().map { index, part in
            index == 0 ? part.dropFirst() : part
        }.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }
        return (language, segments[contentIndex(of: segments, strongsKey: strongsKey)])
    }

    /// Which morpheme the word's number names.
    ///
    /// `HC/R/Sp3ms` is a conjunction, a preposition and a suffix whether the
    /// preposition is אֶל, a word with a Strong's number of its own, or an
    /// inseparable לְ, which has none — and the morpheme worth reading is the
    /// preposition in the first and the suffix in the second. The code is the
    /// same both times, so the number decides: STEPBible numbers every
    /// morpheme, lexically where it is a word and out of its own 9000s where it
    /// is a piece of grammar, and the number stored beside the code is the one
    /// the word is keyed on. A grammatical number therefore names a morpheme
    /// outright. Only when the number is lexical is the code read, and then the
    /// morpheme wanted is the first that is a word rather than a clitic.
    ///
    /// Measured against TAHOT's own alignment of numbers to morphemes, which
    /// braces the one each word is keyed on: of its 145,688 segmented words
    /// this reads 145,683 as the data does, and `LampHebrewMorphologyTests`
    /// names the five it does not.
    private static func contentIndex(of segments: [Substring], strongsKey: String?) -> Int {
        // The last, where a word carries two morphemes of the same function:
        // Aramaic `AR/R` is keyed on the second. No parsing in TAHOT turns on
        // it — both read as a preposition — so the first would measure as well
        // here while naming the morpheme the data does not.
        if let number = grammaticalNumber(of: strongsKey), let names = morpheme(named: number),
           let named = segments.lastIndex(where: names) {
            return named
        }
        if let word = segments.firstIndex(where: isWord) { return word }
        // Nothing but grammar, and a suffix is the least likely to be the word:
        // `HR/Sp3ms` with no number to go on reads as its preposition.
        return segments.lastIndex { $0.first != "S" } ?? 0
    }

    /// Whether a morpheme is a word rather than something a word carries.
    ///
    /// The clitics are the conjunction, the suffixes, and three particles that
    /// attach to what follows them: the article, the interrogative hé, and the
    /// shortened relative שֶׁ. A particle of any other form is a word — `To` is
    /// אֵת, `Tn` is לֹא — which is why the form is read and not just the
    /// function.
    private static func isWord(_ segment: Substring) -> Bool {
        switch segment.first {
        case "N", "V", "A", "P", "D": true
        case "T": !"adir".contains(segment.dropFirst().first ?? " ")
        default: false
        }
    }

    /// The morpheme a number out of STEPBible's 9000s names, as a test of a
    /// segment's function. Read from TAHOT's own numbering of its morphemes.
    private static func morpheme(named number: Int) -> ((Substring) -> Bool)? {
        switch number {
        case 9001, 9002: { $0.first == "C" || $0.first == "c" }
        case 9003...9006: { $0.first == "R" }
        case 9007: { $0.hasPrefix("Tr") }
        case 9008: { $0.hasPrefix("Ti") }
        case 9009, 9010: { $0.hasPrefix("Ta") || $0.hasPrefix("Td") }
        case 9011...9013, 9020...9049: { $0.first == "S" }
        default: nil
        }
    }

    /// The number read as an integer, and only if it is one of the 9000s a
    /// morpheme of grammar carries. A lexical number says nothing about which
    /// morpheme it belongs to, so it is left alone.
    private static func grammaticalNumber(of key: String?) -> Int? {
        guard let key, let language = key.first, language == "H" || language == "A",
              let number = Int(key.dropFirst().prefix(while: \.isNumber)), number >= 9000
        else { return nil }
        return number
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

/// Which decoder reads a code, decided by the Strong's key beside it.
///
/// The code alone does not say which language it belongs to — `HR` could be a
/// Robinson code as easily as a Hebrew one — so the key's letter decides, and a
/// word with no key is left unread rather than guessed at.
public enum LampMorphology {
    public static func features(of code: String, strongsKey: String?) -> [LampGrammarValue] {
        switch strongsKey?.first {
        case "G": LampGreekMorphology.features(of: code)
        case "H": LampHebrewMorphology.features(of: code, strongsKey: strongsKey)
        default: []
        }
    }

    public static func describe(_ code: String, strongsKey: String?) -> String? {
        switch strongsKey?.first {
        case "G": LampGreekMorphology.describe(code)
        case "H": LampHebrewMorphology.describe(code, strongsKey: strongsKey)
        default: nil
        }
    }
}
