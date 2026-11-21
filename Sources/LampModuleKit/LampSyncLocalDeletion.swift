import Foundation

/// What deleting a path from this device's library removes, decided the same
/// way on every client, on both sides: whether a removal here may be recorded
/// as a deletion, and whether one recorded elsewhere is carried out. A removal
/// recorded only where every client carries it out is what stops a tombstone
/// one client obeys and another refuses on every pass.
///
/// `Notes/notes.lamp` and `Writing/writing.lamp` are collections: one
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
    /// The review marks of a writing, or of one of the documents beside
    /// it. Deleted with what they are the marks of, and on a device that
    /// deletes it, everywhere: a file only removed here would be fetched
    /// again from the server's copy.
    ///
    /// The document is its key in the file's name, which is its name
    /// unless that was too long to keep — then the record inside holds
    /// the name, and the caller that needs it reads it there. Without
    /// this, deleting a document's marks deleted the writing's own.
    case writingReview(writingID: String, documentKey: String?)
    /// One of a writing's documents, by its workspace folder and its name
    /// in NFC. Deleted on any device, deleted everywhere, so an outline the
    /// writer removed does not come back from another device's copy.
    case writingDocument(folder: String, name: String)
    /// The notes or writing collection, refused.
    case collection
    /// Nothing a pass deletes locally: media goes with the module that shows
    /// it, any other workspace file's removal travels inside its tree, and a
    /// path outside the layout is never acted on.
    case unsupported

    /// The module ID of the collection every note is published in.
    public static let notesCollectionID = "notes"
    /// The module ID of the collection every writing is published in. It
    /// was `devotionals` until bundle format 4
    /// (`LampSyncFolderLayout.FormatThree.writingCollectionID`).
    public static let writingCollectionID = "writing"

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
        case .writingReview:
            guard let target = LampSyncFolderLayout.reviewTarget(ofPath: path) else { return .unsupported }
            return .writingReview(writingID: target.writingID, documentKey: target.documentKey)
        case .writingDocument:
            return LampWritingWorkspaceLayout.document(ofPath: path).map(Self.writingDocument) ?? .unsupported
        case .devotionalMedia, .noteMedia, .bookMedia, .workspaceFile:
            return .unsupported
        }
    }

    /// Whether a library carries this deletion out, and so whether a removal
    /// here may be recorded as one. The plan never asks for one it refuses: a
    /// tombstone an older client recorded on such a path is superseded by the
    /// copy going back up (`thePlanNeverAsksForARefusedDeletion`).
    public var isAllowed: Bool {
        switch self {
        case .module, .deck, .deckAsset, .writingReview, .writingDocument: true
        case .collection, .unsupported: false
        }
    }

    private static func filename(of path: String) -> String? {
        path.split(separator: "/").last.map(String.init)
    }
}
