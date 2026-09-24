import CoreFoundation
import Foundation

/// A versioned record of preferences that have the same meaning on both apps.
/// Each field carries an identity so a client can compare remote changes with
/// the last version it applied, rather than guessing from sync time.
public struct LampSharedPreferenceLedger: Codable, Equatable, Sendable {
    public enum Value: Codable, Equatable, Sendable {
        case string(String)
        case number(Double)
        case integer(Int)
        case boolean(Bool)
    }

    public struct Field: Codable, Equatable, Sendable {
        public let value: Value?
        public let revision: String

        public init(value: Value?, revision: String = UUID().uuidString) {
            self.value = value
            self.revision = revision
        }
    }

    public enum LedgerError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case invalidRevision(String)
        case invalidValue(String)
        case conflictingField(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Unsupported shared preferences version: \(version)."
            case .invalidRevision(let key):
                "Shared preference has an invalid revision: \(key)."
            case .invalidValue(let key):
                "Shared preference has an invalid value: \(key)."
            case .conflictingField(let key):
                "Shared preference changed on both devices: \(key)."
            }
        }
    }

    private enum Kind {
        case string, number, integer, boolean
    }

    private static let kinds: [String: Kind] = [
        "reader.fontSize": .number,
        "reader.defaultTranslationID": .string,
        "reader.showStrongsHints": .boolean,
        "devotional.fontSize": .number,
        "plans.reminder.enabled": .boolean,
        "plans.reminder.hour": .integer,
        "plans.reminder.minute": .integer,
    ]

    public static let currentFormatVersion = 1
    public static let sharedKeys: Set<String> = Set(kinds.keys)

    public let formatVersion: Int
    public let fields: [String: Field]

    public init(fields: [String: Field] = [:]) {
        self.formatVersion = Self.currentFormatVersion
        self.fields = fields
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw LedgerError.unsupportedVersion(formatVersion)
        }
        for (key, field) in fields {
            guard UUID(uuidString: field.revision) != nil else {
                throw LedgerError.invalidRevision(key)
            }
            guard let value = field.value else { continue }
            switch value {
            case .number(let number) where !number.isFinite:
                throw LedgerError.invalidValue(key)
            case .number where Self.kinds[key] == .number,
                 .integer where Self.kinds[key] == .integer,
                 .string where Self.kinds[key] == .string,
                 .boolean where Self.kinds[key] == .boolean:
                break
            default:
                if Self.kinds[key] != nil { throw LedgerError.invalidValue(key) }
            }
            if key == "reader.fontSize" || key == "devotional.fontSize" {
                if case .number(let number) = value, !(1...200).contains(number) {
                    throw LedgerError.invalidValue(key)
                }
            }
            if key == "plans.reminder.hour" {
                if case .integer(let hour) = value, !(0...23).contains(hour) {
                    throw LedgerError.invalidValue(key)
                }
            }
            if key == "plans.reminder.minute" {
                if case .integer(let minute) = value, !(0...59).contains(minute) {
                    throw LedgerError.invalidValue(key)
                }
            }
            if key == "reader.defaultTranslationID" {
                if case .string(let identifier) = value, identifier.isEmpty {
                    throw LedgerError.invalidValue(key)
                }
            }
        }
    }

    public static func explicitValues(
        from defaults: UserDefaults,
        storedIn domainName: String? = nil
    ) throws -> [String: Value] {
        var values: [String: Value] = [:]
        let stored = domainName.flatMap { defaults.persistentDomain(forName: $0) }
        for (key, kind) in kinds {
            let raw = domainName == nil ? defaults.object(forKey: key) : stored?[key]
            guard let raw else { continue }
            guard let number = raw as? NSNumber else {
                if kind == .string, let string = raw as? String {
                    values[key] = .string(string)
                    continue
                }
                throw LedgerError.invalidValue(key)
            }
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            switch kind {
            case .string:
                guard let string = raw as? String else { throw LedgerError.invalidValue(key) }
                if key == "reader.defaultTranslationID" && string.isEmpty { continue }
                values[key] = .string(string)
            case .number:
                guard !isBoolean, number.doubleValue.isFinite else {
                    throw LedgerError.invalidValue(key)
                }
                values[key] = .number((number.doubleValue * 1000).rounded() / 1000)
            case .integer:
                guard !isBoolean, number.doubleValue.isFinite,
                      number.doubleValue == Double(number.intValue) else {
                    throw LedgerError.invalidValue(key)
                }
                values[key] = .integer(number.intValue)
            case .boolean:
                guard isBoolean else { throw LedgerError.invalidValue(key) }
                values[key] = .boolean(number.boolValue)
            }
        }
        return values
    }

    /// Merge local values against the version this device last applied.
    /// Concurrent edits to the same field report a conflict; edits to separate
    /// fields are retained. Unknown remote fields survive an older client.
    public static func merge(
        local: [String: Value],
        base: Self?,
        remote: Self?
    ) throws -> Self {
        try base?.validate()
        try remote?.validate()
        var fields = base?.fields ?? [:]
        fields.merge(remote?.fields ?? [:]) { _, incoming in incoming }

        for key in sharedKeys {
            let previous = base?.fields[key]
            let incoming = remote?.fields[key] ?? previous
            let localValue = local[key]
            let localChanged = localValue != previous?.value
            let remoteChanged = incoming?.revision != previous?.revision

            if localChanged && remoteChanged && localValue != incoming?.value {
                throw LedgerError.conflictingField(key)
            }
            if localChanged && !remoteChanged {
                fields[key] = Field(value: localValue)
            } else if let incoming {
                fields[key] = incoming
            }
        }
        let merged = Self(fields: fields)
        try merged.validate()
        return merged
    }

    public func apply(to defaults: UserDefaults) throws {
        try validate()
        for key in Self.sharedKeys {
            guard let field = fields[key] else { continue }
            switch field.value {
            case .string(let value): defaults.set(value, forKey: key)
            case .number(let value): defaults.set(value, forKey: key)
            case .integer(let value): defaults.set(value, forKey: key)
            case .boolean(let value): defaults.set(value, forKey: key)
            case nil: defaults.removeObject(forKey: key)
            }
        }
    }
}
