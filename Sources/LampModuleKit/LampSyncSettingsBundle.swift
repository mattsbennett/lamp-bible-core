import Foundation

/// Settings, ledgers and membership in one small object.
///
/// They are not independent of each other the way modules are, so they are
/// read, merged and written together through `LampSyncSettingsStore.update`.
/// It lives at the archive's old path as format 3: zlib JSON shaped like an
/// archive with no entries, `{"formatVersion":3,"entries":[],"bundle":{…}}`.
/// An archive reader decodes that far, checks the version and refuses it, so
/// an old client stops with "Unsupported sync archive version: 3" rather than
/// reading a library with no modules in it as one that was emptied.
public struct LampSyncSettingsBundle: Equatable, Sendable {
    public static let formatVersion = 3

    /// iOS's settings database, today's `UserData/user-settings.db` entry.
    public var userSettings: Data?
    /// The Mac's `settings.plist`. Load-bearing for the Mac's sync, not just
    /// its look: it maps each highlight set to its module.
    public var macSettings: Data?
    public var preferences: LampSharedPreferenceLedger
    /// An encoded `LampPersonalDeletionLedger`, per note, writing and
    /// highlight. Kept apart from `manifest`, which is per file: deleting a
    /// note doesn't remove the notes module.
    public var personalDeletions: Data?
    /// An encoded `LampPresentationDeckDeletionLedger`.
    public var deckDeletions: Data?
    public var manifest: LampSyncLibraryManifest

    public init(
        userSettings: Data? = nil,
        macSettings: Data? = nil,
        preferences: LampSharedPreferenceLedger = .init(),
        personalDeletions: Data? = nil,
        deckDeletions: Data? = nil,
        manifest: LampSyncLibraryManifest = .init()
    ) {
        self.userSettings = userSettings
        self.macSettings = macSettings
        self.preferences = preferences
        self.personalDeletions = personalDeletions
        self.deckDeletions = deckDeletions
        self.manifest = manifest
    }

    public enum BundleError: Error, Equatable {
        /// An archive, format 1 or 2: the Mac hasn't migrated this library.
        case isArchive
        /// A bundle from a later version.
        case unsupportedVersion(Int)
        case damaged
    }

    /// What a body at the bundle path holds, judged from its first bytes, so
    /// an archive the size of the whole library is never unpacked to find
    /// out it is one. (`Verification/SyncMerge.lean`: `bundlePathHolds`.)
    public enum Contents: Equatable, Sendable {
        case bundle
        case archive
        case newerBundle(Int)
        case damaged
    }

    public static func contents(ofHeader header: Data) -> Contents {
        let text = String(decoding: header, as: UTF8.self)
        if let version = text.prefixMatch(of: #/\s*\{\s*"formatVersion"\s*:\s*(\d+)/#)
            .flatMap({ Int($0.1) }) {
            return contents(ofVersion: version)
        }
        // An archive from an encoder that wrote its entries first.
        return text.prefixMatch(of: #/\s*\{\s*"entries"\s*:/#) != nil ? .archive : .damaged
    }

    static func contents(ofVersion version: Int) -> Contents {
        switch version {
        case 1, 2: .archive
        case formatVersion: .bundle
        case let later where later > formatVersion: .newerBundle(later)
        default: .damaged
        }
    }

    /// Enough of the unpacked body to hold the header.
    static let headerLength = 64

    private struct Payload: Codable {
        var userSettings: Data?
        var macSettings: Data?
        var preferences: LampSharedPreferenceLedger
        var personalDeletions: Data?
        var deckDeletions: Data?
        var manifest: LampSyncLibraryManifest
    }

    private struct File: Decodable {
        let formatVersion: Int
        let bundle: Payload
    }

    /// The same bundle always encodes to the same bytes.
    public func encoded() throws -> Data {
        try preferences.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(Payload(
            userSettings: userSettings, macSettings: macSettings, preferences: preferences,
            personalDeletions: personalDeletions, deckDeletions: deckDeletions, manifest: manifest
        ))
        // Written by hand so the version comes first, where `contents`
        // looks for it.
        var json = Data(#"{"formatVersion":\#(Self.formatVersion),"entries":[],"bundle":"#.utf8)
        json.append(payload)
        json.append(Data("}".utf8))
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    public static func decode(_ data: Data) throws -> Self {
        switch contents(ofHeader: try header(of: data)) {
        case .bundle: break
        case .archive: throw BundleError.isArchive
        case .newerBundle(let version): throw BundleError.unsupportedVersion(version)
        case .damaged: throw BundleError.damaged
        }
        let file: File
        do {
            file = try JSONDecoder().decode(
                File.self, from: (data as NSData).decompressed(using: .zlib) as Data
            )
        } catch {
            throw BundleError.damaged
        }
        guard file.formatVersion == formatVersion else { throw BundleError.damaged }
        let payload = file.bundle
        try payload.preferences.validate()
        return Self(
            userSettings: payload.userSettings, macSettings: payload.macSettings,
            preferences: payload.preferences, personalDeletions: payload.personalDeletions,
            deckDeletions: payload.deckDeletions, manifest: payload.manifest
        )
    }

    static func header(of data: Data) throws -> Data {
        do {
            return try LampZlib.decompressedPrefix(of: data, count: headerLength)
        } catch {
            throw BundleError.damaged
        }
    }
}
