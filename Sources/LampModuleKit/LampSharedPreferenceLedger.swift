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
        /// When it was set, in milliseconds, and always later than the field
        /// it replaced. Joining two copies needs it: without a base, one
        /// device's edit and the other's unchanged value look alike. Older
        /// fields have none and count as earliest.
        public let modifiedAt: Int64?

        public init(value: Value?, revision: String = UUID().uuidString, modifiedAt: Int64? = nil) {
            self.value = value
            self.revision = revision
            self.modifiedAt = modifiedAt
        }

        /// A field set at `now` in place of `replaced`.
        static func setting(_ value: Value?, replacing replaced: Field?, at now: Int64) -> Field {
            let after = replaced?.modifiedAt.map { $0 < .max ? $0 + 1 : $0 }
            return Field(value: value, modifiedAt: Swift.max(now, after ?? now))
        }
    }

    public enum LedgerError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case invalidRevision(String)
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "Unsupported shared preferences version: \(version)."
            case .invalidRevision(let key):
                "Shared preference has an invalid revision: \(key)."
            case .invalidValue(let key):
                "Shared preference has an invalid value: \(key)."
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

    /// The result of a merge, kept apart because a field the two devices
    /// disagree about belongs in a different place in each.
    public struct Merge: Equatable, Sendable {
        /// What the server should hold. A disputed field keeps the server's
        /// own value, so publishing this changes nothing for it and the
        /// other device's edit survives.
        public let publishable: LampSharedPreferenceLedger
        /// What to apply here. A disputed field is left out, so this device
        /// keeps what its user set rather than having it overwritten.
        public let applicable: LampSharedPreferenceLedger
        /// What to record as agreed. A disputed field keeps the value the
        /// two devices last agreed on, so the disagreement is still visible
        /// next time instead of being quietly settled in someone's favour.
        public let baseline: LampSharedPreferenceLedger
        /// Fields each device changed differently since they last agreed.
        public let disputed: [String]
    }

    /// Merge local values against the version this device last applied.
    ///
    /// Edits to separate fields are retained, and unknown remote fields
    /// survive an older client. A field both devices changed differently
    /// used to throw, which aborted the whole sync — on the Mac that meant
    /// one disputed translation name stopped the library, the modules and
    /// everything else from syncing at all, with no way to resolve it and
    /// nothing that could. A disagreement about one preference is not a
    /// reason to stop carrying everything else, so it is reported and set
    /// aside: neither value is published, neither is overwritten, and the
    /// two devices settle it by being given the same value once more.
    public static func merge(
        local: [String: Value],
        base: Self?,
        remote: Self?,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> Merge {
        try base?.validate()
        try remote?.validate()
        var fields = base?.fields ?? [:]
        fields.merge(remote?.fields ?? [:]) { _, incoming in incoming }
        var disputed: [String] = []

        for key in sharedKeys {
            let previous = base?.fields[key]
            let incoming = remote?.fields[key] ?? previous
            let localValue = local[key]

            guard base != nil else {
                // Nothing has been agreed yet, so "changed" has no meaning
                // here: against an absent baseline every local value looks
                // new, and so every difference looked like two people
                // editing at once. Refusing it left a client unable to
                // record the baseline that would have given the word
                // meaning — it failed the same way on every pass, silently,
                // and its preferences never synced at all.
                //
                // These two have simply never met. The server's value stands
                // where it has one, since a local value may be nothing more
                // than this client's default; a value only this client holds
                // is contributed rather than dropped.
                if incoming == nil, let localValue {
                    fields[key] = Field.setting(localValue, replacing: nil, at: now)
                }
                continue
            }

            let localChanged = localValue != previous?.value
            let remoteChanged = incoming?.revision != previous?.revision

            if localChanged && remoteChanged && localValue != incoming?.value {
                disputed.append(key)
                continue
            }
            if localChanged && !remoteChanged {
                fields[key] = Field.setting(localValue, replacing: previous, at: now)
            } else if let incoming {
                fields[key] = incoming
            }
        }
        let merged = Self(fields: fields)
        try merged.validate()
        guard !disputed.isEmpty else {
            return Merge(
                publishable: merged, applicable: merged,
                baseline: merged, disputed: []
            )
        }
        var applicableFields = merged.fields
        var baselineFields = merged.fields
        for key in disputed {
            // Publishing keeps the server's value, which `fields` already
            // holds; applying leaves this device alone; the baseline keeps
            // what both last agreed, so the disagreement persists until the
            // two are given the same value.
            applicableFields.removeValue(forKey: key)
            if let agreed = base?.fields[key] {
                baselineFields[key] = agreed
            } else {
                baselineFields.removeValue(forKey: key)
            }
        }
        let applicable = Self(fields: applicableFields)
        let baseline = Self(fields: baselineFields)
        try applicable.validate()
        try baseline.validate()
        return Merge(
            publishable: merged, applicable: applicable,
            baseline: baseline, disputed: disputed.sorted()
        )
    }

    /// Both copies joined, field by field: the later of each by time, then
    /// revision. Order doesn't matter, so the result is the same whichever
    /// copy a store kept as current. This is how two copies written at once
    /// are put together, with no base: a device that lost an iCloud write
    /// has recorded its own write as the base, which the other copy never
    /// saw. (`Verification/SyncMerge.lean`: `preferenceJoin`.)
    public func joined(with other: Self) -> Self {
        var fields = self.fields
        for (key, theirs) in other.fields {
            guard let ours = fields[key] else {
                fields[key] = theirs
                continue
            }
            fields[key] = Self.later(ours, theirs)
        }
        return Self(fields: fields)
    }

    static func later(_ a: Field, _ b: Field) -> Field {
        let stamp = LampSyncLibraryManifest.Entry.later((a.modifiedAt, a.revision), (b.modifiedAt, b.revision))
        return stamp.0 == b.modifiedAt && stamp.1 == b.revision ? b : a
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
