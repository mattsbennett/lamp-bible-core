import Foundation

/// The module families understood by Lamp Bible.
public enum LampModuleKind: String, Codable, CaseIterable, Sendable {
    case translation
    case dictionary
    case commentary
    case devotional
    case notes
    case plan
    case highlights
    case quiz

    /// JSON Schemas and older modules use a few singular or domain-specific aliases.
    public init?(schemaValue: String) {
        switch schemaValue.lowercased() {
        case "translation": self = .translation
        case "dictionary", "lexicon": self = .dictionary
        case "commentary": self = .commentary
        case "devotional": self = .devotional
        case "notes", "note": self = .notes
        case "plan": self = .plan
        case "highlights", "highlight": self = .highlights
        case "quiz": self = .quiz
        default: return nil
        }
    }
}
