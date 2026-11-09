import Foundation

/// An installed speech voice, as both platforms' speech engines describe one,
/// and which of them to speak with.
public struct LampSpeechVoice: Hashable, Sendable {
    public let identifier: String
    public let name: String
    public let language: String
    /// The engine's own report: 1 basic (compact), 2 enhanced, 3 premium.
    public let quality: Int
    public let isNovelty: Bool
    /// A Personal Voice, recorded from the reader's own speech.
    public let isPersonal: Bool

    public init(
        identifier: String, name: String, language: String, quality: Int,
        isNovelty: Bool, isPersonal: Bool = false
    ) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
    }

    /// A basic voice draws sounds out, so IPA comes out a syllable at a time
    /// and prose sounds halting; an enhanced or premium one does not.
    public var isBasic: Bool { quality <= 1 }

    /// The voice to speak `language` with: the reader's `stored` choice when
    /// it is installed and speaks that language, and otherwise the best one
    /// installed.
    ///
    /// Any voice better than basic first; among those, the reader's own
    /// variety of the language (their en-GB) before a better voice with
    /// another accent; then quality; then the one the system would pick,
    /// which keeps a device with only basic voices on the one it already
    /// used rather than, say, Eloquence's Eddy. Novelty voices are never
    /// chosen for the reader, nor a Personal Voice, nor Siri's, which
    /// neither platform lets an app use. Any language: the phone reads a
    /// Greek translation with this.
    public static func choose(
        language: String,
        stored: String?,
        among voices: [LampSpeechVoice],
        preferredLanguage: String?,
        systemDefaults: Set<String>
    ) -> LampSpeechVoice? {
        let base = baseLanguage(language)
        if let stored, let voice = voices.first(where: { $0.identifier == stored }),
           baseLanguage(voice.language) == base {
            return voice
        }
        func rank(_ voice: LampSpeechVoice) -> (Int, Int, Int, Int, Int) {
            (voice.isBasic ? 0 : 1,
             voice.language == preferredLanguage ? 1 : 0,
             voice.quality,
             systemDefaults.contains(voice.identifier) ? 1 : 0,
             voice.language == language ? 1 : 0)
        }
        return voices
            .filter {
                !$0.isNovelty && !$0.isPersonal && !$0.identifier.contains(".siri.")
                    && baseLanguage($0.language) == base
            }
            .max { rank($0) != rank($1) ? rank($0) < rank($1) : $0.identifier > $1.identifier }
    }

    private static func baseLanguage(_ code: String) -> Substring {
        code.prefix { $0 != "-" && $0 != "_" }
    }
}
