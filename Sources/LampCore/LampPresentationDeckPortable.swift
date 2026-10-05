import Foundation
import LampModuleKit

/// Where decks live inside a portable backup, a decoded sync archive, and a
/// published sync folder.
///
/// All three use the same relative path, which is what lets a Mac publishing an
/// expanded folder and a Mac publishing a compressed archive feed the same
/// reader on another device. Spelling it once here keeps the two apps from
/// drifting apart on a string.
public enum LampPresentationDeckPortableLayout {
    public static let deckExtension = "lampdeck"
    public static let deletionsFilename = "deleted-decks.json"

    public static var directoryPath: String {
        "\(LampPortableBackupLayout.workspacesDirectory)/\(LampPresentationDeckStore.directoryName)"
    }

    public static var deletionsPath: String {
        "\(directoryPath)/\(deletionsFilename)"
    }

    /// Images live in one flat directory beside the decks, under generated
    /// filenames. Flat rather than per-deck so a sync pull needs a single
    /// listing, and because two decks may legitimately share an image.
    public static var assetsDirectoryPath: String {
        "\(directoryPath)/\(LampPresentationDeckStore.assetsDirectoryName)"
    }

    /// An image file directly inside the assets directory.
    public static func isAssetPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == Substring(LampPortableBackupLayout.workspacesDirectory),
              components[1] == Substring(LampPresentationDeckStore.directoryName),
              components[2] == Substring(LampPresentationDeckStore.assetsDirectoryName),
              let filename = components.last
        else { return false }
        return !filename.isEmpty && !filename.hasPrefix(".")
    }

    /// A deck file directly inside the presentations directory. Nested paths are
    /// rejected so a deck can never be read from a subdirectory a future format
    /// version might use for something else.
    public static func isDeckPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == Substring(LampPortableBackupLayout.workspacesDirectory),
              components[1] == Substring(LampPresentationDeckStore.directoryName),
              let filename = components.last
        else { return false }
        return filename.lowercased().hasSuffix(".\(deckExtension)") && !filename.hasPrefix(".")
    }
}

/// Records that a deck was deleted, so sync does not resurrect it from a copy
/// that predates the deletion.
///
/// A deck saved after it was deleted elsewhere survives, as the newer change.
public struct LampPresentationDeckDeletionLedger: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var deletedAt: [String: Date]

    public init(formatVersion: Int = Self.currentFormatVersion, deletedAt: [String: Date] = [:]) {
        self.formatVersion = formatVersion
        self.deletedAt = deletedAt
    }

    public var isEmpty: Bool { deletedAt.isEmpty }

    /// Unreadable or future-versioned ledgers decode as empty rather than
    /// throwing: losing a deletion record is recoverable, refusing to sync is
    /// not.
    public static func decoded(from data: Data) -> LampPresentationDeckDeletionLedger {
        guard let ledger = try? JSONDecoder().decode(Self.self, from: data),
              ledger.formatVersion == currentFormatVersion
        else { return LampPresentationDeckDeletionLedger() }
        return ledger
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public mutating func record(_ deckID: String, at date: Date = Date()) {
        deletedAt[deckID] = max(deletedAt[deckID] ?? .distantPast, date)
    }

    public mutating func merge(_ other: LampPresentationDeckDeletionLedger) {
        for (id, date) in other.deletedAt {
            record(id, at: date)
        }
    }

    /// A deck is deleted only when the deletion is at least as new as the copy
    /// in hand. Equal timestamps favour the deletion, matching folder sync.
    public func deletes(_ deckID: String, modifiedAt: Date) -> Bool {
        guard let deleted = deletedAt[deckID] else { return false }
        return deleted >= modifiedAt
    }
}

/// One stored copy of a deck: the decoded document plus the bytes and
/// modification time the merge decision needs.
public struct LampPresentationDeckRevision: Sendable {
    public let deck: LampPresentationDeck
    public let data: Data
    public let modifiedAt: Date

    public init(deck: LampPresentationDeck, data: Data, modifiedAt: Date) {
        self.deck = deck
        self.data = data
        self.modifiedAt = modifiedAt
    }

    public var id: String { deck.id }
}

/// Decides what a read-only or read-write consumer should do with a set of
/// incoming decks. Both apps share this so iOS and macOS never disagree about
/// which copy of a deck wins.
public enum LampPresentationDeckPortablePull {
    public struct Plan: Sendable {
        /// Decks to write locally, newest copy per ID.
        public let decksToSave: [LampPresentationDeckRevision]
        /// Deck IDs deleted elsewhere since the local copy was saved.
        public let deckIDsToDelete: [String]

        public var isEmpty: Bool { decksToSave.isEmpty && deckIDsToDelete.isEmpty }

        public init(decksToSave: [LampPresentationDeckRevision], deckIDsToDelete: [String]) {
            self.decksToSave = decksToSave
            self.deckIDsToDelete = deckIDsToDelete
        }
    }

    public static func plan(
        incoming: [LampPresentationDeckRevision],
        deletions: LampPresentationDeckDeletionLedger,
        local: [LampPresentationDeckRevision]
    ) -> Plan {
        var resolved: [String: LampPresentationDeckRevision] = [:]
        for revision in local {
            resolved[revision.id] = revision
        }

        var decksToSave: [LampPresentationDeckRevision] = []
        for candidate in incoming.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            if deletions.deletes(candidate.id, modifiedAt: candidate.modifiedAt) { continue }
            if let current = resolved[candidate.id] {
                guard LampSyncMerge.shouldReplaceFile(
                    currentData: current.data,
                    currentDate: current.modifiedAt,
                    incomingData: candidate.data,
                    incomingDate: candidate.modifiedAt
                ) else { continue }
            }
            resolved[candidate.id] = candidate
            decksToSave.removeAll { $0.id == candidate.id }
            decksToSave.append(candidate)
        }

        let deckIDsToDelete = resolved.values
            .filter { deletions.deletes($0.id, modifiedAt: $0.modifiedAt) }
            .map(\.id)
            .sorted()

        return Plan(
            decksToSave: decksToSave.filter { !deckIDsToDelete.contains($0.id) },
            deckIDsToDelete: deckIDsToDelete
        )
    }
}

public extension LampPresentationDeck {
    /// Filenames in the assets directory this deck's image blocks point at.
    var referencedAssetNames: Set<String> {
        Set(
            slides
                .flatMap(\.blocks)
                .compactMap(\.assetPath)
                .filter { LampPresentationDeckValidator.isSafeAssetPath($0) }
                .compactMap { $0.split(separator: "/").last.map(String.init) }
        )
    }
}

public extension Collection where Element == LampPresentationDeck {
    /// Every asset these decks still use.
    ///
    /// Assets carry no deletion ledger of their own: an image is kept for as
    /// long as some deck names it, which is what lets sync union-merge them
    /// without a deletion racing a deck that still needs the file.
    var referencedAssetNames: Set<String> {
        reduce(into: Set<String>()) { $0.formUnion($1.referencedAssetNames) }
    }
}

/// One image file travelling with the decks that reference it.
public struct LampPresentationAssetRevision: Sendable {
    /// Filename inside the assets directory.
    public let name: String
    public let data: Data
    public let modifiedAt: Date

    public init(name: String, data: Data, modifiedAt: Date) {
        self.name = name
        self.data = data
        self.modifiedAt = modifiedAt
    }
}

public extension LampSyncArchive {
    /// Deck files carried by a decoded sync archive, skipping any copy this
    /// build cannot validate rather than failing the whole sync.
    func presentationDeckRevisions() -> [LampPresentationDeckRevision] {
        entries.compactMap { entry in
            guard LampPresentationDeckPortableLayout.isDeckPath(entry.path),
                  let deck = try? LampPresentationDeckStore.decode(entry.data)
            else { return nil }
            return LampPresentationDeckRevision(
                deck: deck,
                data: entry.data,
                modifiedAt: entry.modifiedAt
            )
        }
    }

    /// Images carried alongside the decks.
    func presentationAssetRevisions() -> [LampPresentationAssetRevision] {
        entries.compactMap { entry in
            guard LampPresentationDeckPortableLayout.isAssetPath(entry.path),
                  let name = entry.path.split(separator: "/").last
            else { return nil }
            return LampPresentationAssetRevision(
                name: String(name),
                data: entry.data,
                modifiedAt: entry.modifiedAt
            )
        }
    }

    func presentationDeckDeletions() -> LampPresentationDeckDeletionLedger {
        guard let entry = entries.first(where: {
            $0.path == LampPresentationDeckPortableLayout.deletionsPath
        }) else { return LampPresentationDeckDeletionLedger() }
        return LampPresentationDeckDeletionLedger.decoded(from: entry.data)
    }
}
