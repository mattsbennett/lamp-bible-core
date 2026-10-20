import Foundation

/// What deleting a path from this device's library removes, decided the same
/// way on every client, on both sides: whether a removal here may be recorded
/// as a deletion, and whether one recorded elsewhere is carried out. A removal
/// recorded only where every client carries it out is what stops a tombstone
/// one client obeys and another refuses on every pass.
///
/// `Notes/notes.lamp` and `Devotionals/devotionals.lamp` are collections: one
/// file holds every note, or every writing, so deleting it would delete them
/// all, from a pass nobody is watching. Items are deleted through their own
/// ledger instead, and those two paths are never deleted as files. An
/// installed module's ID can equal a collection's — import an exported notes
/// file and its ID may well be `notes` — so removing that module is local and
/// harmless, but recording it would tombstone the file every note lives in.
/// The rule keys on the ID for that reason, not the folder. Any other
/// notes or writing module is a module like any other, and so is a highlight
/// set: one file per set, so deleting a set on one device deletes it on the
/// others. (`Verification/SyncMerge.lean`: `deleteTarget`.)
public enum LampSyncLocalDeletion: Equatable, Sendable {
    /// The installed module with the ID the path carries.
    case module(String)
    /// The deck file with this name.
    case deck(String)
    /// The deck asset with this name.
    case deckAsset(String)
    /// The notes or writing collection, refused.
    case collection
    /// Nothing a pass deletes locally: media goes with the module that shows
    /// it, a workspace file's removal travels inside its tree, and a path
    /// outside the layout is never acted on.
    case unsupported

    /// The module ID of the collection every note is published in.
    public static let notesCollectionID = "notes"
    /// The module ID of the collection every writing is published in.
    public static let writingCollectionID = "devotionals"

    public static func target(of path: String) -> LampSyncLocalDeletion {
        guard let kind = LampSyncFolderLayout.kind(of: path) else { return .unsupported }
        let moduleID = LampSyncFolderLayout.remoteModuleID(of: path)
        switch kind {
        case .module(.notes) where moduleID == notesCollectionID,
             .module(.devotionals) where moduleID == writingCollectionID:
            return .collection
        case .module:
            return moduleID.map(Self.module) ?? .unsupported
        case .deck:
            return filename(of: path).map(Self.deck) ?? .unsupported
        case .deckAsset:
            return filename(of: path).map(Self.deckAsset) ?? .unsupported
        case .devotionalMedia, .bookMedia, .workspaceFile:
            return .unsupported
        }
    }

    /// Whether a library carries this deletion out, and so whether a removal
    /// here may be recorded as one. A tombstone from an older client can still
    /// name a path this refuses; the plan asks to delete it regardless
    /// (`aTombstonedCollectionIsAskedForAndRefused`).
    public var isAllowed: Bool {
        switch self {
        case .module, .deck, .deckAsset: true
        case .collection, .unsupported: false
        }
    }

    private static func filename(of path: String) -> String? {
        path.split(separator: "/").last.map(String.init)
    }
}
