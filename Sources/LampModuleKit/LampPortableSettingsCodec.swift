import Foundation

/// The legacy portable backup settings.plist format. The allowlist is shared
/// so archive readers accept the same preferences that the writer exports.
public enum LampPortableSettingsCodec {
    public enum CodecError: Error, LocalizedError {
        case invalidRoot
        case invalidValue

        public var errorDescription: String? {
            switch self {
            case .invalidRoot: "Portable settings must be a property list dictionary."
            case .invalidValue: "Portable settings contain a value that cannot be stored in a property list."
            }
        }
    }

    public static let syncedKeys: [String] = [
        "reader.fontSize", "reader.lineSpacing", "reader.typeface", "reader.defaultTranslationID",
        "reader.readAloud.voice", "reader.readAloud.rate", "reader.readAloud.followAlong",
        "reader.showStrongsHints", "reader.crossReferences.canonicalOrder",
        "commentary.fontSize", "commentary.lineSpacing", "commentary.typeface",
        "studyInspector.greekDictionaryModuleID", "studyInspector.hebrewDictionaryModuleID",
        "studyInspector.commentaryModuleID",
        "plans.wordsPerMinute", "plans.externalBibleApp", "plans.reminder.enabled",
        "plans.reminder.hour", "plans.reminder.minute", "devotional.fontSize",
        "quiz.defaultAgeGroup", "quiz.alwaysShowAnswers", "quiz.fontSize",
        "quiz.lineSpacing", "quiz.typeface", "modules.hiddenIDs",
        "writing.preview.placement", "writing.preview.width", "writing.preview.fontSize",
        "writing.preview.lineSpacing", "writing.preview.typeface",
        "writing.preview.followsEditorScrolling", "devotional.editor.fontSize",
        "devotional.lineSpacing", "devotional.typeface",
        "writing.sortOrder", "writing.groupBy",
        "books.fontSize", "books.lineSpacing", "books.typeface", "books.readerState",
    ]

    public static func encode(from defaults: UserDefaults) throws -> Data {
        var settings: [String: Any] = [:]
        for key in syncedKeys {
            if let value = defaults.object(forKey: key) {
                settings[key] = value
            }
        }
        guard PropertyListSerialization.propertyList(settings, isValidFor: .binary) else {
            throw CodecError.invalidValue
        }
        return try PropertyListSerialization.data(
            fromPropertyList: settings,
            format: .binary,
            options: 0
        )
    }

    /// Unknown keys are ignored so newer archives stay readable by older apps.
    public static func decode(_ data: Data) throws -> [String: Any] {
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let settings = value as? [String: Any] else {
            throw CodecError.invalidRoot
        }
        return settings.filter { syncedKeys.contains($0.key) }
    }

    public static func apply(
        _ data: Data,
        to defaults: UserDefaults,
        excluding excludedKeys: Set<String> = []
    ) throws {
        let settings = try decode(data)
        for (key, value) in settings where !excludedKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
    }
}
