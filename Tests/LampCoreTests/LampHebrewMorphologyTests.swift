import Foundation
import Testing
@testable import LampCore

/// Reading STEPBible's Hebrew morphology codes, which `TAHOT` tags every word
/// with and which were unread until there was a tagged text to read.
///
/// Checked against the Translators Expansion of Hebrew Morphology Codes
/// (TEHMC), the dataset's own definitions: 915 of its 921 agree, and the six
/// that do not are rows where TEHMC contradicts itself. Those six are named
/// below rather than left as a silent difference.
struct LampHebrewMorphologyTests {
    @Test(arguments: [
        // Verbs, one per field layout.
        ("HVqp3ms", "Verb · Qal · Perfect · Third · Singular · Masculine"),
        ("HVqw3ms", "Verb · Qal · Consecutive Imperfect · Third · Singular · Masculine"),
        ("HVqv2fs", "Verb · Qal · Imperative · Second · Singular · Feminine"),
        ("HVhi1cp", "Verb · Hiphil · Imperfect · First · Plural · Either gender"),
        ("HVqrmsa", "Verb · Qal · Participle · Singular · Masculine · Absolute"),
        ("HVqsmsa", "Verb · Qal · Participle passive · Singular · Masculine · Absolute"),
        ("HVqcc", "Verb · Qal · Infinitive · Construct"),
        ("HVqaa", "Verb · Qal · Infinitive · Absolute"),
        ("HVNp3ms", "Verb · Niphal · Perfect · Third · Singular · Masculine"),
        ("HVtp3ms", "Verb · Hithpael · Perfect · Third · Singular · Masculine"),
        // Nouns and adjectives.
        ("HNcfsa", "Noun · Common · Singular · Feminine · Absolute"),
        ("HNcmsc", "Noun · Common · Singular · Masculine · Construct"),
        ("HNcmpd", "Noun · Common · Plural · Masculine · Definite"),
        ("HNcmda", "Noun · Common · Dual · Masculine · Absolute"),
        ("HAamsa", "Adjective · Common · Singular · Masculine · Absolute"),
        ("HAcmsa", "Adjective · Numerical · Singular · Masculine · Absolute"),
        // Pronouns, suffixes, particles.
        ("HPp3ms", "Pronoun · Personal · Third · Singular · Masculine"),
        ("HSp3ms", "Suffix · Personal · Third · Singular · Masculine"),
        ("HTd", "Particle · Definite article"),
        ("HTo", "Particle · Object indicator"),
        ("HTn", "Particle · Negative"),
        ("HR", "Preposition"),
        ("HRd", "Preposition · Definite"),
        ("HC", "Conjunction"),
        ("Hc", "Conjunction · Consecutive"),
        ("HD", "Adverb"),
        // Aramaic takes its own stem names under the same letters.
        ("AVqp3ms", "Verb · Peal · Perfect · Third · Singular · Masculine"),
        ("AVap3ms", "Verb · Aphel · Perfect · Third · Singular · Masculine"),
    ])
    func acodeReadsAsItsParsing(code: String, parsing: String) {
        #expect(LampHebrewMorphology.describe(code) == parsing)
    }

    /// A proper noun carries no number or state, and what follows its form is a
    /// gender or the kind of name it is.
    @Test(arguments: [
        ("HNpm", "Noun · Proper · Masculine"),
        ("HNpf", "Noun · Proper · Feminine"),
        ("HNpl", "Noun · Proper · Location"),
        ("HNpt", "Noun · Proper · Title"),
    ])
    func apropernounStopsAtItsKind(code: String, parsing: String) {
        #expect(LampHebrewMorphology.describe(code) == parsing)
    }

    /// The form letter `c` is an infinitive with one field after it and an
    /// imperfect with three, so the fields are counted before they are read.
    @Test func theletterCIsToldApartByWhatFollowsIt() {
        #expect(LampHebrewMorphology.describe("HVqcc") == "Verb · Qal · Infinitive · Construct")
        #expect(
            LampHebrewMorphology.describe("HVqc3ms")
                == "Verb · Qal · Imperfect · Third · Singular · Masculine"
        )
    }

    /// A word of several morphemes reports the content one's parsing. The
    /// analysis asking is keyed on that morpheme's Strong's number, and the
    /// article or conjunction beside it has a number of its own.
    @Test(arguments: [
        ("Hc/Vqw3ms", "Verb · Qal · Consecutive Imperfect · Third · Singular · Masculine"),
        ("HC/Vqp3ms", "Verb · Qal · Perfect · Third · Singular · Masculine"),
        ("HTd/Ncmpa", "Noun · Common · Plural · Masculine · Absolute"),
        ("HR/Ncfsa", "Noun · Common · Singular · Feminine · Absolute"),
        ("HNcmsc/Sp3ms", "Noun · Common · Singular · Masculine · Construct"),
        ("HR/Td/Ncmsa", "Noun · Common · Singular · Masculine · Absolute"),
    ])
    func asegmentedCodeReadsItsContentMorpheme(code: String, parsing: String) {
        #expect(LampHebrewMorphology.describe(code) == parsing)
    }

    /// With nothing but prefixes and suffixes, the first morpheme is read
    /// rather than nothing at all.
    @Test func acodeOfNoContentWordStillReadsItsFirstMorpheme() {
        #expect(LampHebrewMorphology.describe("HR/Sp3ms") == "Preposition")
    }

    @Test(arguments: ["", "G", "X", "HZ", "HVz", "HV", "HNc", "HNcm", "V-PAI-3S", "nonsense"])
    func acodeThisDoesNotKnowReadsAsNothing(code: String) {
        #expect(LampHebrewMorphology.describe(code) == nil)
        #expect(LampHebrewMorphology.features(of: code).isEmpty)
    }

    /// The features come back labelled, which is what the grammar summary
    /// counts, and in the order a parsing is spoken.
    @Test func thefeaturesAreLabelledAndOrdered() {
        let features = LampHebrewMorphology.features(of: "HVqp3ms")
        #expect(features.map(\.feature) == [.partOfSpeech, .stem, .form, .person, .number, .gender])
        #expect(features.map(\.value) == ["Verb", "Qal", "Perfect", "Third", "Singular", "Masculine"])
    }

    /// Where TEHMC disagrees with itself, the commoner reading is taken. Each
    /// of these is one row against dozens reading the other way, and naming
    /// them here is what stops the difference looking like a defect.
    @Test(arguments: [
        // TEHMC calls Aramaic `P` Pual in three codes and Hitpeel in these two.
        ("AVPi3mp", "Verb · Pual · Imperfect · Third · Plural · Masculine"),
        ("AVPi3ms", "Verb · Pual · Imperfect · Third · Singular · Masculine"),
        // The form letter `i` is an imperfect in 92 codes and a perfect in two.
        ("AVvi3mp", "Verb · Ishtaphel · Imperfect · Third · Plural · Masculine"),
        ("HVvi3mp", "Verb · Hishtaphel · Imperfect · Third · Plural · Masculine"),
        // A Hebrew-prefixed code whose stem TEHMC names with the Aramaic word.
        ("HVqq3mp", "Verb · Qal · Consecutive Perfect · Third · Plural · Masculine"),
        // A gender letter TEHMC reads as Feminine here and Either gender elsewhere.
        ("HVqrcsc", "Verb · Qal · Participle · Singular · Either gender · Construct"),
    ])
    func wheretehmcDisagreesWithItselfTheCommonerReadingIsTaken(code: String, parsing: String) {
        #expect(LampHebrewMorphology.describe(code) == parsing)
    }
}

/// Which decoder reads a code is decided by the key beside it, in one place, so
/// a passage and an analysis of the same word cannot parse it differently.
struct LampMorphologyDispatchTests {
    @Test func thekeysLetterChoosesTheDecoder() {
        #expect(
            LampMorphology.describe("HVqp3ms", strongsKey: "H1254")
                == "Verb · Qal · Perfect · Third · Singular · Masculine"
        )
        #expect(
            LampMorphology.describe("N-NSF", strongsKey: "G26")
                == "Noun · Nominative · Singular · Feminine"
        )
    }

    /// A code says nothing about which language it belongs to — `HR` could be a
    /// Robinson code as easily as a Hebrew one — so a word with no key, or a
    /// key of neither language, is left unread.
    @Test(arguments: [nil, "", "X123", "1234"] as [String?])
    func acodeWithNoUsableKeyIsLeftUnread(key: String?) {
        #expect(LampMorphology.describe("HVqp3ms", strongsKey: key) == nil)
        #expect(LampMorphology.features(of: "N-NSF", strongsKey: key).isEmpty)
    }

    /// Reading a Hebrew code under a Greek key must not half-succeed.
    @Test func thewrongDecoderReadsNothingRatherThanGuessing() {
        #expect(LampMorphology.describe("HVqp3ms", strongsKey: "G26") == nil)
        #expect(LampMorphology.describe("N-NSF", strongsKey: "H1254") == nil)
    }
}
