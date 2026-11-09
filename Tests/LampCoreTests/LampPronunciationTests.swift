import Foundation
import LampCore
import Testing

struct LampPronunciationTests {
    /// Erasmian, from the Greek itself: the accent places the stress, a
    /// rough breathing is an "h" even on a diphthong's second vowel, γγ is
    /// "ng", a doubled letter is said once, χ is "k" — an English voice
    /// has no "ch" of Bach — and υ is short, so πνεῦμα has two syllables.
    @Test(arguments: [
        ("ἀγάπη", "ɑˈɡɑpeɪ"),
        ("λόγος", "ˈlɔɡɔs"),
        ("ἱλασμός", "hilɑˈsmɔs"),
        ("Χριστός", "kɹiˈstɔs"),
        ("ἄγγελος", "ˈɑŋɡɛlɔs"),
        ("οὗτος", "ˈhuːtɔs"),
        ("υἱός", "hwiˈɔs"),
        ("ἐκκλησία", "ɛkleɪˈsiɑ"),
        ("πνεῦμα", "ˈpnjumɑ"),
        ("ἀλληλουϊα", "ɑleɪluːiɑ"),
        ("ψυχή", "psuˈkeɪ"),
        ("κύριος", "ˈkuɹiɔs"),
        ("εὐαγγέλιον", "juɑŋˈɡɛliɔn"),
        ("ἰσχύς", "iˈskus"),
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

    /// The modern reading hands a Greek voice the headword itself, read to
    /// its first comma; the classroom one hands an English voice IPA.
    /// Hebrew has the one reading whichever is chosen.
    @Test func aGreekWordIsSaidTheWayTheReaderChose() {
        let greek = [entry(key: "G26", lemma: "agapē"), entry(key: "G0026", lemma: "ἀγάπη, ης, ἡ")]
        let modern = LampPronunciation.utterance(forKey: "G26", entries: greek, greekReading: .modern)
        #expect(modern == .init(word: "ἀγάπη", ipa: nil, voiceLanguage: "el-GR", greekReading: .modern))
        #expect(modern?.text.string == "ἀγάπη")
        let classroom = LampPronunciation.utterance(forKey: "G26", entries: greek, greekReading: .classroom)
        #expect(classroom == .init(word: "ἀγάπη", ipa: "ɑˈɡɑpeɪ", voiceLanguage: "en-US", greekReading: .classroom))

        let hebrew = [entry(key: "H2617", lemma: "חֶסֶד", pronunciation: "kheh'-sed")]
        for reading in LampPronunciation.GreekReading.allCases {
            #expect(LampPronunciation.utterance(forKey: "H2617", entries: hebrew, greekReading: reading)
                == .init(word: "חֶסֶד", ipa: "ˈhɛsɛd", voiceLanguage: "en-US", greekReading: nil))
        }
        #expect(LampPronunciation.utterance(forKey: "G26", entries: [entry(key: "G26", lemma: "agapē")], greekReading: .modern) == nil)
    }

    /// Modern Greek without a Greek voice is said the classroom way, and
    /// labelled so, rather than not said at all.
    @Test func modernGreekNeedsAGreekVoice() {
        typealias Reading = LampPronunciation.GreekReading
        #expect(Reading.resolved(nil, hasGreekVoice: true) == .classroom)
        #expect(Reading.resolved("modern", hasGreekVoice: true) == .modern)
        #expect(Reading.resolved("modern", hasGreekVoice: false) == .classroom)
        #expect(Reading.resolved("unknown", hasGreekVoice: true) == .classroom)
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
