import Foundation
import LampCore
import Testing

struct LampPronunciationTests {
    /// Erasmian, from the Greek itself: the accent places the stress, a
    /// rough breathing is an "h" even on a diphthong's second vowel, γγ is
    /// "ng", a doubled letter is said once, and χ is "k" — an English voice
    /// has no "ch" of Bach.
    @Test(arguments: [
        ("ἀγάπη", "ɑˈɡɑpeɪ"),
        ("λόγος", "ˈlɔɡɔs"),
        ("ἱλασμός", "hilɑˈsmɔs"),
        ("Χριστός", "kɹiˈstɔs"),
        ("ἄγγελος", "ˈɑŋɡɛlɔs"),
        ("οὗτος", "ˈhuːtɔs"),
        ("υἱός", "hwiˈɔs"),
        ("ἐκκλησία", "ɛkleɪˈsiɑ"),
        ("πνεῦμα", "ˈpnjuːmɑ"),
        ("ἀλληλουϊα", "ɑleɪluːiɑ"),
        ("ἀγάπη, ης, ἡ", "ɑˈɡɑpeɪ"),
    ])
    func greekIsSaidFromItsOwnLetters(word: String, ipa: String) {
        #expect(LampPronunciation.greek(word) == ipa)
    }

    @Test func aWordWithNoGreekHasNone() {
        #expect(LampPronunciation.greek("agápē") == nil)
    }

    /// From Strong's respelling: its apostrophe places the stress, the
    /// vowels it tells apart stay apart ("kheh'-sed", where the
    /// transliteration has "chêçêd"), "kh" is "h" to begin a syllable and
    /// "k" to end one, a doubled letter is said once, a consonant left on
    /// the syllable before a vowel moves onto it, English's silent e
    /// lengthens, and only the first of two readings is said.
    @Test(arguments: [
        ("kaw-far'", "kɑˈfɑɹ"),
        ("el-o-heem'", "ɛloʊˈhiːm"),
        ("kheh'-sed", "ˈhɛsɛd"),
        ("roo'-akh", "ˈɹuːɑk"),
        ("tsad-deek'", "tsɑˈdiːk"),
        ("shel-ee'", "ʃɛˈliː"),
        ("shaw-lome'", "ʃɑˈloʊm"),
        ("haw-mawce'", "hɑˈmɑs"),
        ("ray-sheeth'", "ɹeɪˈʃiːt"),
        ("ab-ee' ghib-one'", "ɑˈbiː ɡɪˈboʊn"),
        ("zek-oo-keeth", "zɛkuːˈkiːt"),
        ("yaw-no'-akh or (with enclitic) Yanowchah yaw-no'-khaw", "jɑˈnoʊɑk"),
    ])
    func hebrewIsSaidFromStrongsRespelling(respelling: String, ipa: String) {
        #expect(LampPronunciation.hebrew(respelling: respelling) == ipa)
    }

    /// A key is said from an entry for that key: the Greek headword of any
    /// lexicon, or the respelling of the one that has it.
    @Test func aKeyIsSaidFromAnEntryThatCanSayIt() {
        let greek = [
            entry(key: "G26", lemma: "agapē (no Greek)"),
            entry(key: "G0026", lemma: "ἀγάπη"),
            entry(key: "G25", lemma: "ἀγαπάω"),
        ]
        #expect(LampPronunciation.ipa(forKey: "G26", entries: greek) == "ɑˈɡɑpeɪ")
        let hebrew = [
            entry(key: "H3722", lemma: "כָּפַר"),
            entry(key: "H3722", lemma: "כָּפַר", pronunciation: "kaw-far'"),
        ]
        #expect(LampPronunciation.ipa(forKey: "H3722", entries: hebrew) == "kɑˈfɑɹ")
        #expect(LampPronunciation.ipa(forKey: "H3722", entries: Array(hebrew.prefix(1))) == nil)
    }

    @Test func theSpeechEngineIsHandedTheIPA() {
        let spoken = LampPronunciation.spoken("ἀγάπη", ipa: "ɑˈɡɑpeɪ")
        let key = NSAttributedString.Key("AVSpeechSynthesisIPANotationAttribute")
        #expect(spoken.string == "ἀγάπη")
        #expect(spoken.attribute(key, at: 0, effectiveRange: nil) as? String == "ɑˈɡɑpeɪ")
    }

    private func entry(key: String, lemma: String, pronunciation: String? = nil) -> LampDictionaryResult {
        LampDictionaryResult(
            entryID: UUID().uuidString, moduleID: "lex", moduleName: "Lexicon", key: key,
            lemma: lemma, transliteration: nil, pronunciation: pronunciation, senses: []
        )
    }
}
