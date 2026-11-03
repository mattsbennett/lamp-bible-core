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
        #expect(LampHebrewMorphology.describe(code, strongsKey: nil) == parsing)
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
        #expect(LampHebrewMorphology.describe(code, strongsKey: nil) == parsing)
    }

    /// The form letter `c` is an infinitive with one field after it and an
    /// imperfect with three, so the fields are counted before they are read.
    @Test func theletterCIsToldApartByWhatFollowsIt() {
        #expect(LampHebrewMorphology.describe("HVqcc", strongsKey: nil)
                == "Verb · Qal · Infinitive · Construct")
        #expect(
            LampHebrewMorphology.describe("HVqc3ms", strongsKey: nil)
                == "Verb · Qal · Imperfect · Third · Singular · Masculine"
        )
    }

    /// A word of several morphemes reports the one its number names, which is
    /// the morpheme an analysis asking for the parsing is keyed on.
    @Test(arguments: [
        ("Hc/Vqw3ms", "H559", "Verb · Qal · Consecutive Imperfect · Third · Singular · Masculine"),
        ("HC/Vqp3ms", "H1254", "Verb · Qal · Perfect · Third · Singular · Masculine"),
        ("HTd/Ncmpa", "H8064", "Noun · Common · Plural · Masculine · Absolute"),
        ("HR/Ncfsa", "H7225", "Noun · Common · Singular · Feminine · Absolute"),
        ("HNcmsc/Sp3ms", "H2233", "Noun · Common · Singular · Masculine · Construct"),
        ("HR/Td/Ncmsa", "H776", "Noun · Common · Singular · Masculine · Absolute"),
        ("HR/Ncmsc/Sp3ms", "H4327", "Noun · Common · Singular · Masculine · Construct"),
    ])
    func asegmentedCodeReadsTheMorphemeItsNumberNames(
        code: String, key: String, parsing: String
    ) {
        #expect(LampHebrewMorphology.describe(code, strongsKey: key) == parsing)
    }

    /// A word of nothing but grammar is keyed on one of its own pieces, and the
    /// number says which. These read wrongly until the number was consulted:
    /// וְאֵת is the object marker with a conjunction on it, not a conjunction,
    /// and לוֹ is a suffix on a preposition that has no number of its own.
    @Test(arguments: [
        // וְאֵת — H9002 is the prefixed waw, so H853 is the particle's.
        ("HC/To", "H853", "Particle · Object indicator"),
        // לוֹ — H9033 is the third masculine singular suffix itself.
        ("HRd/Sp3ms", "H9033", "Suffix · Personal · Third · Singular · Masculine"),
        ("HR/Sp2ms", "H9031", "Suffix · Personal · Second · Singular · Masculine"),
        // וְלֹא and הֲלֹא — a conjunction and an interrogative hé on לֹא.
        ("HC/Tn", "H3808", "Particle · Negative"),
        ("HTi/Tn", "H3808", "Particle · Negative"),
        // הַזֶּה — the article on a demonstrative.
        ("HTd/Tm", "H2088", "Particle · Demonstrative"),
        // וְאֶל — a conjunction on a preposition that has a number of its own.
        ("HC/R", "H413", "Preposition"),
        // שֶׁ־ is the shortened relative, a clitic as the article is.
        ("HTr/Vqi3mp", "H559", "Verb · Qal · Imperfect · Third · Plural · Masculine"),
        ("HTr/D", "H8033", "Adverb"),
    ])
    func awordOfNothingButGrammarIsReadByItsNumber(
        code: String, key: String, parsing: String
    ) {
        #expect(LampHebrewMorphology.describe(code, strongsKey: key) == parsing)
    }

    /// One code, two different morphemes, told apart by the number alone: a
    /// conjunction with אֶל and a suffix is keyed on אֶל, while a conjunction
    /// with an inseparable לְ and a suffix is keyed on the suffix, because the
    /// לְ has no number of its own. Nothing in `HC/R/Sp3ms` distinguishes them,
    /// which is why the code is not read on its own.
    @Test func onecodeTwoMorphemesToldApartByTheNumber() {
        #expect(LampHebrewMorphology.describe("HC/R/Sp3ms", strongsKey: "H413") == "Preposition")
        #expect(
            LampHebrewMorphology.describe("HC/R/Sp3ms", strongsKey: "H9033")
                == "Suffix · Personal · Third · Singular · Masculine"
        )
    }

    /// With no number to go on the code is all there is, and a suffix is the
    /// least likely of its morphemes to be the word: `HR/Sp3ms` reads as its
    /// preposition rather than as nothing at all.
    @Test func withoutAnumberTheLeastUnlikelyMorphemeIsRead() {
        #expect(LampHebrewMorphology.describe("HR/Sp3ms", strongsKey: nil) == "Preposition")
    }

    /// Where TAHOT's own numbering contradicts its codes, the code is followed.
    /// Both are the data's, and naming the words is what stops the difference
    /// looking like a defect — the courtesy the TEHMC rows below are shown.
    ///
    /// These are the whole of it. Reading all 145,688 of TAHOT's segmented
    /// words against the morpheme it braces, 145,683 agree.
    @Test(arguments: [
        // A preposition and a suffix numbered with the verb that governs them,
        // which belongs to neither morpheme: Isa 44:17 (H5456, סָגַד),
        // Hos 8:12 (H3789, כָּתַב), Psa 89:28 (H8104, שָׁמַר) and Pro 23:24
        // (H8055, שָׂמַח). Four words, each read as its preposition.
        "H5456", "H3789", "H8104", "H8055",
    ])
    func aprepositionNumberedWithItsClausesVerbReadsAsThePreposition(key: String) {
        #expect(LampHebrewMorphology.describe("HR/Sp3ms", strongsKey: key) == "Preposition")
    }

    /// 2Sa 18:20 — עַל־כֵּן is two words joined by a maqaf and carries a number
    /// each, so which is "the" morpheme has no answer. The adverb is read and
    /// the preposition is not.
    @Test func twowordsJoinedByAmaqafReadAsTheSecond() {
        #expect(LampHebrewMorphology.describe("HR//D", strongsKey: "H5921") == "Adverb")
        #expect(LampHebrewMorphology.describe("HR//D", strongsKey: "H3651") == "Adverb")
    }

    @Test(arguments: ["", "G", "X", "HZ", "HVz", "HV", "HNc", "HNcm", "V-PAI-3S", "nonsense"])
    func acodeThisDoesNotKnowReadsAsNothing(code: String) {
        #expect(LampHebrewMorphology.describe(code, strongsKey: nil) == nil)
        #expect(LampHebrewMorphology.features(of: code, strongsKey: nil).isEmpty)
    }

    /// The features come back labelled, which is what the grammar summary
    /// counts, and in the order a parsing is spoken.
    @Test func thefeaturesAreLabelledAndOrdered() {
        let features = LampHebrewMorphology.features(of: "HVqp3ms", strongsKey: nil)
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
        #expect(LampHebrewMorphology.describe(code, strongsKey: nil) == parsing)
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
