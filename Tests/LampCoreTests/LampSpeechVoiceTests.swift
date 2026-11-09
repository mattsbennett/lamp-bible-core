import LampCore
import Testing

struct LampSpeechVoiceTests {
    private let voices = [
        voice("com.apple.voice.compact.en-US.Samantha", "en-US", 1),
        voice("com.apple.eloquence.en-US.Eddy", "en-US", 1),
        voice("com.apple.siri.natural.Nora", "en-US", 2),
        voice("com.apple.voice.enhanced.en-US.Ava", "en-US", 2),
        voice("com.apple.voice.enhanced.en-US.Zoe", "en-US", 2),
        voice("com.apple.voice.enhanced.en-GB.Jamie", "en-GB", 2),
        voice("com.apple.speech.synthesis.voice.Bells", "en-US", 3, novelty: true),
        voice("com.apple.voice.compact.el-GR.Melina", "el-GR", 1),
        voice("com.apple.voice.premium.en-AU.Lee", "en-AU", 3),
        voice("personal.Reader", "en-US", 3, personal: true),
    ]
    private let defaults: Set<String> = ["com.apple.voice.compact.en-US.Samantha"]

    /// With nothing chosen, the best voice: never a novelty, Personal or Siri
    /// one; the reader's own variety before a better voice with another
    /// accent; a stable choice between equals.
    @Test func theBestVoiceSpeaksWhenNoneIsChosen() {
        #expect(choose("en-US", nil, voices, "en-US")?.name == "Ava")
        #expect(choose("en-US", nil, voices, "en-GB")?.name == "Jamie")
        #expect(choose("en-US", "", voices, nil)?.name == "Lee")
        #expect(choose("en-US", nil, voices, "en-AU")?.name == "Lee")
        #expect(choose("el-GR", nil, voices, "en-US")?.name == "Melina")
        #expect(choose("el-GR", nil, voices.filter { $0.name != "Melina" }, "en-US") == nil)
    }

    /// Among basic voices alone, the one the system would pick, not the
    /// first by name, which would be Eloquence's Eddy.
    @Test func amongBasicVoicesTheSystemsOwnIsKept() {
        let basic = voices.filter(\.isBasic)
        #expect(choose("en-US", nil, basic, "en-US")?.name == "Samantha")
    }

    /// The reader's choice wins, even a basic or novelty voice, when it is
    /// installed and speaks the language; otherwise the best is chosen.
    @Test func theReadersChoiceWins() {
        #expect(choose("en-US", "com.apple.voice.compact.en-US.Samantha", voices, "en-US")?.name == "Samantha")
        #expect(choose("en-US", "com.apple.speech.synthesis.voice.Bells", voices, "en-US")?.name == "Bells")
        #expect(choose("en-US", "uninstalled", voices, "en-US")?.name == "Ava")
        #expect(choose("el-GR", "com.apple.voice.compact.en-US.Samantha", voices, "en-US")?.name == "Melina")
    }

    @Test func onlyBasicQualityIsBasic() {
        #expect(voices.filter(\.isBasic).map(\.name) == ["Samantha", "Eddy", "Melina"])
    }

    private func choose(
        _ language: String, _ stored: String?, _ voices: [LampSpeechVoice], _ preferred: String?
    ) -> LampSpeechVoice? {
        LampSpeechVoice.choose(
            language: language, stored: stored, among: voices,
            preferredLanguage: preferred, systemDefaults: defaults)
    }

    private static func voice(_ id: String, _ language: String, _ quality: Int, novelty: Bool = false, personal: Bool = false) -> LampSpeechVoice {
        let name = id.split(whereSeparator: { $0 == "." || $0 == "_" })
            .first { ["Samantha", "Eddy", "Nora", "Ava", "Zoe", "Jamie", "Bells", "Melina", "Lee", "Reader"].contains(String($0)) }
            .map(String.init) ?? id
        return LampSpeechVoice(identifier: id, name: name, language: language, quality: quality, isNovelty: novelty, isPersonal: personal)
    }
}
