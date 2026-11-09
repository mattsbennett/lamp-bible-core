import Foundation

/// How to say a Greek or Hebrew word with an English voice.
///
/// An English voice reads a transliteration by English spelling, so "agápē"
/// comes out as the English "agape" (mouth agape), and the Greek and Hebrew
/// voices read the modern languages — the Hebrew one ignores vowel points
/// altogether. What both platforms' speech can do is take IPA for a word and
/// say exactly that, so this gives IPA, kept to sounds an English voice has:
/// one it lacks, such as the "ch" of Bach, is dropped without a sound.
///
/// Greek is the Erasmian reading most English-speaking classrooms teach,
/// worked out from the word in Greek script, so any lexicon's headword will
/// do; or, as a reader may choose, the word as Greek is spoken today, which a
/// Greek voice reads from the headword itself. Hebrew comes from Strong's own
/// respelling ("kaw-far'"), with no modern reading to offer: the Hebrew voice
/// ignores vowel points, so it cannot read a biblical word from its spelling.
public enum LampPronunciation {
    /// How a Greek word is said.
    public enum GreekReading: String, CaseIterable, Hashable, Sendable {
        case classroom, modern

        /// Where both apps keep the reader's choice.
        public static let preferenceKey = "pronunciation.greekReading"

        public var title: String {
            switch self {
            case .classroom: "Classroom (Erasmian)"
            case .modern: "Modern Greek"
            }
        }

        /// The reading to give: the stored choice, except that Modern Greek
        /// needs a Greek voice, and without one the word is said — and
        /// labelled — the classroom way rather than not at all.
        public static func resolved(_ stored: String?, hasGreekVoice: Bool) -> GreekReading {
            let chosen = stored.flatMap(GreekReading.init(rawValue:)) ?? .classroom
            return chosen == .modern && !hasGreekVoice ? .classroom : chosen
        }
    }

    /// The language of the voice that reads Modern Greek.
    public static let greekVoiceLanguage = "el-GR"
    /// The language of the voice that says IPA, when the reader has not
    /// chosen an English voice of their own.
    public static let englishVoiceLanguage = "en-US"

    /// A word made ready for a speech engine.
    public struct Utterance: Hashable, Sendable {
        /// The word in its own script, as the reader sees it.
        public let word: String
        /// What an English voice is to say; nil when a Greek voice reads
        /// `word` itself.
        public let ipa: String?
        /// The language of the voice to use: English for IPA, Greek for a
        /// modern reading.
        public let voiceLanguage: String
        /// How a Greek word is said; nil for Hebrew, which has one reading.
        public let greekReading: GreekReading?

        public init(word: String, ipa: String?, voiceLanguage: String, greekReading: GreekReading?) {
            self.word = word
            self.ipa = ipa
            self.voiceLanguage = voiceLanguage
            self.greekReading = greekReading
        }

        /// What the speech engine is handed.
        public var text: NSAttributedString {
            ipa.map { spoken(word, ipa: $0) } ?? NSAttributedString(string: word)
        }
    }

    /// The key's word as `greekReading` says it, or nil when no entry can
    /// say it.
    public static func utterance(
        forKey key: String,
        entries: [LampDictionaryResult],
        greekReading: GreekReading
    ) -> Utterance? {
        let normalized = LampStrongsKey.normalized(key)
        let own = entries.filter { LampStrongsKey.normalized($0.key) == normalized }
        switch normalized.first {
        case "G":
            guard let word = own.lazy.compactMap({ greekWord($0.lemma) }).first else { return nil }
            switch greekReading {
            case .classroom:
                guard let ipa = greek(word) else { return nil }
                return Utterance(word: word, ipa: ipa, voiceLanguage: englishVoiceLanguage, greekReading: .classroom)
            case .modern:
                return Utterance(word: word, ipa: nil, voiceLanguage: greekVoiceLanguage, greekReading: .modern)
            }
        case "H":
            guard let entry = own.first(where: { $0.pronunciation.flatMap(hebrew(respelling:)) != nil }),
                  let ipa = entry.pronunciation.flatMap(hebrew(respelling:)) else { return nil }
            return Utterance(word: entry.lemma, ipa: ipa, voiceLanguage: englishVoiceLanguage, greekReading: nil)
        default:
            return nil
        }
    }

    /// The key's word in IPA, from whichever of `entries` can give it: a
    /// Greek headword for a Greek key; Strong's respelling for a Hebrew one.
    public static func ipa(forKey key: String, entries: [LampDictionaryResult]) -> String? {
        utterance(forKey: key, entries: entries, greekReading: .classroom)?.ipa
    }

    /// What a speech engine is handed: `display` carrying `ipa` as its
    /// pronunciation, under the attribute name both platforms' speech
    /// synthesizers read (`AVSpeechSynthesisIPANotationAttribute`).
    public static func spoken(_ display: String, ipa: String) -> NSAttributedString {
        NSAttributedString(
            string: display,
            attributes: [NSAttributedString.Key("AVSpeechSynthesisIPANotationAttribute"): ipa]
        )
    }

    // MARK: - Greek

    /// The first word of a headword when it is in Greek script: a headword
    /// such as Dodson's "ἀγάπη, ης, ἡ" is read to its first comma.
    static func greekWord(_ headword: String) -> String? {
        guard let word = headword.split(whereSeparator: { $0 == "," || $0.isWhitespace }).first,
              word.unicodeScalars.contains(where: { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) })
        else { return nil }
        return String(word)
    }

    /// The first word of a Greek headword in IPA; nil when it has no Greek.
    public static func greek(_ headword: String) -> String? {
        let word = greekWord(headword) ?? ""
        var letters: [GreekLetter] = []
        for scalar in word.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x0300, 0x0301, 0x0342: letters.last?.accented = true
            case 0x0314: letters.last?.rough = true
            case 0x0308: letters.last?.diaeresis = true
            case 0x03B1...0x03C9: letters.append(GreekLetter(Character(scalar)))
            default: continue
            }
        }
        guard !letters.isEmpty else { return nil }

        var phones: [Phone] = []
        var index = 0
        while index < letters.count {
            let letter = letters[index]
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            if let next, !next.diaeresis, let sound = greekDiphthongs["\(letter.character)\(next.character)"] {
                // A diphthong's breathing and accent sit on its second vowel.
                if letter.rough || next.rough { phones.append(.consonant("h")) }
                phones.append(.vowel(sound, stressed: letter.accented || next.accented))
                index += 2
                continue
            }
            if let vowel = greekVowels[letter.character] {
                if letter.rough { phones.append(.consonant("h")) }
                phones.append(.vowel(vowel, stressed: letter.accented))
            } else if letter.character == "γ", let next, "γκξχ".contains(next.character) {
                phones.append(.consonant("ŋ"))
            } else if let consonant = greekConsonants[letter.character] {
                // A doubled letter, as in ἐκκλησία, is said once.
                if case .consonant(consonant)? = phones.last {} else { phones.append(.consonant(consonant)) }
            }
            index += 1
        }
        return written(phones)
    }

    private final class GreekLetter {
        let character: Character
        var accented = false
        var rough = false
        var diaeresis = false
        init(_ character: Character) { self.character = character }
    }

    /// υ is a plain "u": marked long, the voice draws it out, and πνεῦμα
    /// comes out in three syllables, "pnyoo-oo-ma".
    private static let greekVowels: [Character: String] = [
        "α": "ɑ", "ε": "ɛ", "η": "eɪ", "ι": "i", "ο": "ɔ", "υ": "u", "ω": "oʊ",
    ]

    private static let greekDiphthongs: [String: String] = [
        "αι": "aɪ", "ει": "eɪ", "οι": "ɔɪ", "υι": "wi",
        "αυ": "aʊ", "ευ": "ju", "ηυ": "ju", "ου": "uː",
    ]

    /// χ is "k", as English speakers say Christ: the voice has no "ch" of
    /// Bach, and drops one silently.
    private static let greekConsonants: [Character: String] = [
        "β": "b", "γ": "ɡ", "δ": "d", "ζ": "z", "θ": "θ", "κ": "k", "λ": "l",
        "μ": "m", "ν": "n", "ξ": "ks", "π": "p", "ρ": "ɹ", "σ": "s", "ς": "s",
        "τ": "t", "φ": "f", "χ": "k", "ψ": "ps",
    ]

    // MARK: - Hebrew

    /// Strong's respelling of a Hebrew word ("kaw-far'", "kheh'-sed") in IPA.
    ///
    /// The respelling, not the transliteration: it was written for English
    /// readers, so it already says which syllable is stressed and tells the
    /// vowels apart that the transliteration writes alike — "chêçêd" is
    /// "kheh'-sed". Only its first reading is said, where it offers another.
    public static func hebrew(respelling: String) -> String? {
        var text = respelling.lowercased()
        if let alternative = text.range(of: " or ") { text = String(text[..<alternative.lowerBound]) }
        let words = text.split(whereSeparator: \.isWhitespace).compactMap { word -> String? in
            let syllables = word.split(separator: "-").map(String.init)
            // Unmarked, the last syllable, where Hebrew most often puts it.
            let stressed = syllables.lastIndex { $0.contains("'") } ?? syllables.count - 1
            var spoken = syllables.map { hebrewSyllable($0.filter(\.isLetter)) }
            // A doubled letter across syllables ("tsad-deek") is said once,
            // with the syllable it begins.
            for index in spoken.indices.dropFirst() {
                if let first = spoken[index].first, !isVowelSound(first), spoken[index - 1].last == first {
                    spoken[index - 1].removeLast()
                }
                // A syllable the respelling begins on its vowel ("shel-ee'")
                // takes the consonant before it, so the stress falls on "lee".
                if let first = spoken[index].first, isVowelSound(first),
                   spoken[index - 1].count > 1, let last = spoken[index - 1].last, !isVowelSound(last) {
                    spoken[index].insert(spoken[index - 1].removeLast(), at: 0)
                }
            }
            let written = spoken.enumerated().map { index, phones in
                (index == stressed && spoken.count > 1 && !phones.isEmpty ? "ˈ" : "") + phones.joined()
            }.joined()
            return written.isEmpty ? nil : written
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func hebrewSyllable(_ syllable: String) -> [String] {
        var letters = Array(syllable)
        // English's silent e: "bale", "bode", "ore" end on a long vowel and a
        // consonant, and "mawce" on an "s".
        var lengthened: Int?
        if letters.count >= 3, letters.last == "e", !isVowelLetter(letters[letters.count - 2]) {
            letters.removeLast()
            if letters.last == "c" { letters[letters.count - 1] = "s" }
            lengthened = letters.lastIndex(where: isVowelLetter)
        }
        var phones: [String] = []
        var index = 0
        while index < letters.count {
            let pair = index + 1 < letters.count ? String(letters[index...index + 1]) : ""
            if let vowel = respellingVowels[pair], !(pair.hasSuffix("h") && index + 2 < letters.count && isVowelLetter(letters[index + 2])) {
                phones.append(vowel)
                index += 2
            } else if pair == "kh" {
                // The voice has no "ch" of Bach: "h" to begin a syllable
                // (hesed), "k" after a vowel, where an "h" makes no sound.
                phones.append(phones.contains(where: isVowelSound) ? "k" : "h")
                index += 2
            } else if let consonant = respellingDigraphs[pair] {
                phones.append(consonant)
                index += 2
            } else if index == lengthened, let long = longVowels[letters[index]] {
                phones.append(long)
                index += 1
            } else if let sound = respellingLetters[letters[index]] {
                phones.append(sound)
                index += 1
            } else {
                index += 1
            }
        }
        return phones
    }

    private static func isVowelLetter(_ letter: Character) -> Bool { "aeiou".contains(letter) }

    private static func isVowelSound(_ sound: String) -> Bool {
        sound.unicodeScalars.contains { "ɑɛɪiəoʊuæʌɔeaɪ".unicodeScalars.contains($0) }
    }

    private static let respellingVowels: [String: String] = [
        "aw": "ɑ", "ay": "eɪ", "ah": "ɑ", "eh": "ɛ", "ee": "iː", "oo": "uː",
        "ow": "oʊ", "oy": "ɔɪ", "ai": "aɪ",
    ]

    private static let longVowels: [Character: String] = [
        "a": "eɪ", "e": "iː", "i": "aɪ", "o": "oʊ", "u": "uː",
    ]

    /// "th" is tav, said "t" as Hebrew is taught now rather than the "th" of
    /// Strong's day.
    private static let respellingDigraphs: [String: String] = [
        "sh": "ʃ", "ts": "ts", "th": "t", "ph": "f", "gh": "ɡ",
    ]

    private static let respellingLetters: [Character: String] = [
        "a": "ɑ", "e": "ɛ", "i": "ɪ", "o": "oʊ", "u": "ʊ",
        "b": "b", "c": "k", "d": "d", "f": "f", "g": "ɡ", "h": "h", "j": "dʒ", "k": "k",
        "l": "l", "m": "m", "n": "n", "p": "p", "q": "k", "r": "ɹ", "s": "s", "t": "t",
        "v": "v", "w": "w", "y": "j", "z": "z",
    ]

    // MARK: - Writing

    private enum Phone {
        case consonant(String)
        case vowel(String, stressed: Bool)

        var sound: String {
            switch self {
            case .consonant(let sound), .vowel(let sound, _): sound
            }
        }
    }

    /// Consonants that may begin an English syllable together, so the stress
    /// mark goes before "st" in "Christós" but between the "s" and "m" of
    /// "hilasmós".
    private static let onsets: Set<String> = [
        "pl", "pɹ", "bl", "bɹ", "tɹ", "dɹ", "kl", "kɹ", "ɡl", "ɡɹ", "fl", "fɹ", "θɹ",
        "sp", "st", "sk", "sm", "sn", "sl", "spɹ", "stɹ", "skɹ", "ʃɹ",
    ]

    private static func written(_ phones: [Phone]) -> String {
        guard let stressed = phones.firstIndex(where: { if case .vowel(_, true) = $0 { true } else { false } }) else {
            return phones.map(\.sound).joined()
        }
        var onsetStart = stressed
        while onsetStart > 0, case .consonant = phones[onsetStart - 1] {
            let cluster = phones[(onsetStart - 1)..<stressed].map(\.sound).joined()
            // One consonant always begins the syllable; more only as English
            // allows, or all of them at the start of a word, as πν in πνεῦμα.
            let atStart = phones[..<(onsetStart - 1)].allSatisfy { if case .consonant = $0 { true } else { false } }
            guard onsetStart == stressed || onsets.contains(cluster) || atStart else { break }
            onsetStart -= 1
        }
        let before = phones[..<onsetStart].map(\.sound).joined()
        let after = phones[onsetStart...].map(\.sound).joined()
        return before + "ˈ" + after
    }
}
