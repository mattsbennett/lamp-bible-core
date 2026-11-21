/// What a path in the shared library holds.
///
/// Each module is its own file, and those files are the truth: the settings
/// bundle says which belong to the library, and nothing else does.
public enum LampSyncFileKind: Hashable, Sendable {
    case module(LampSyncContentKind)
    /// A file a writing embeds.
    case devotionalMedia
    /// A file one of the reader's notes embeds.
    case noteMedia
    /// An image a book shows.
    case bookMedia
    case deck
    /// An image a deck shows. Decks share one flat folder of them, under
    /// generated names.
    case deckAsset
    /// One of the writer's own documents beside a writing, its outline or
    /// notes, in the writing's workspace (`LampWritingWorkspaceLayout`). Both
    /// apps keep these, and a deletion on either is a deletion everywhere.
    case writingDocument
    /// Any other file in a Mac workspace.
    case workspaceFile
    /// What of one writing the assistant changed that its writer has not
    /// yet cleared (`LampWritingReview`). Its own small file, apart from the
    /// writing's collection, so a clear sends a few hundred bytes rather
    /// than every writing; and listed, unlike a workspace file, so the
    /// phone sees it change.
    case writingReview

    /// Media never changes at a path: a different body gets a different
    /// name. So it is never merged, uploaded only where absent, and a
    /// different copy on the server is a conflict to report.
    public var isMedia: Bool {
        switch self {
        case .devotionalMedia, .noteMedia, .bookMedia, .deckAsset: true
        case .module, .deck, .writingDocument, .workspaceFile, .writingReview: false
        }
    }

    /// Whether it is part of a tree taken in together: a workspace's files
    /// are staged by `LampSyncPassLibrary.install` as they arrive and taken
    /// in by `finishInstalling`, which can stop partway. Such a file is
    /// recorded as installed only once that succeeds.
    public var isTakenInTogether: Bool {
        self == .workspaceFile
    }

    /// Whether a pass learns about it from a listing of its folder. Media and
    /// workspace files are never listed: media because the manifest names
    /// every file and a path never changes its bytes, and workspace files
    /// because they are an arbitrary tree the Mac checks one path at a time.
    public var isListed: Bool {
        switch self {
        case .module, .deck, .writingReview: true
        case .devotionalMedia, .noteMedia, .bookMedia, .deckAsset, .writingDocument, .workspaceFile: false
        }
    }
}

/// Where each file lives on the server, for both WebDAV and the folder
/// provider.
///
/// | What | Path |
/// |---|---|
/// | Settings bundle | `lamp-bible.lampsync` |
/// | A module | `<Kind>/<id>.lamp`, e.g. `Translations/kjv.lamp`, `Writing/writing.lamp` |
/// | Writing media | `WritingMedia/<module>/<writing>/<file>` |
/// | Note media | `NoteMedia/<module>/<verse>/<file>` |
/// | Book images | `BookMedia/<module>/<path>` |
/// | A deck | `Workspaces/Presentations/<id>.lampdeck` |
/// | A deck image | `Workspaces/Presentations/Assets/<file>` |
/// | A writing's document | `Workspaces/Writing/<folder>/Documents/<name>` |
/// | A Mac workspace file | `Workspaces/<path>` |
/// | A writing's review marks | `WritingReview/<writing>.json` |
///
/// A module's bytes are the phone's: personal modules are the
/// `LampWebDAVPersonalArchiveAdapter` output, with module IDs rewritten, and a
/// `lamp-modules` build drops into its kind folder unchanged.
///
/// Until bundle format 4, writing lived under `Devotionals/` and
/// `DevotionalMedia/`, and the writing collection was
/// `Devotionals/devotionals.lamp`. `formatFourPath(ofFormatThree:)` is the
/// one statement of that rename; `LampSyncFormatFourMove` carries a library
/// across it.
public enum LampSyncFolderLayout {
    public enum PathError: Error, Equatable {
        case unsafe(String)
    }

    /// The archive's old path. Format 3 there is the bundle, which archive
    /// readers refuse, so an old client stops rather than reading a library
    /// with no modules in it as one that was emptied.
    public static let bundlePath = LampSyncLayout.archivePath
    public static let moduleExtension = "lamp"
    public static let devotionalMediaDirectory = "WritingMedia"
    public static let noteMediaDirectory = "NoteMedia"
    public static let bookMediaDirectory = "BookMedia"
    public static let workspacesDirectory = LampPortableBackupLayout.workspacesDirectory
    public static let decksDirectory = "\(workspacesDirectory)/Presentations"
    /// The Mac's writing workspaces, one folder each, under the workspace
    /// tree. `Workspaces/Devotionals` until bundle format 4.
    public static let writingWorkspacesDirectory = "\(workspacesDirectory)/Writing"
    public static let deckAssetsDirectory = "\(decksDirectory)/Assets"
    public static let deckExtension = "lampdeck"
    /// One file per writing whose assistant's changes are being reviewed,
    /// named by the writing's id (`reviewFilename(writingID:)`).
    public static let writingReviewDirectory = "WritingReview"
    public static let writingReviewExtension = "json"

    /// The kind folders, the deck folder and the review folder, one Depth:1
    /// listing each.
    public static let listedDirectories: [String] =
        LampSyncContentKind.allCases.map(\.folder) + [decksDirectory, writingReviewDirectory]

    public static func modulePath(kind: LampSyncContentKind, moduleID: String) throws -> String {
        try checked([kind.folder], "\(moduleID).\(moduleExtension)")
    }

    /// Where one of the reader's notes keeps a file on the server. The owner
    /// is the verse, as it is in the library — a personal note is one per
    /// verse and its id holds a colon.
    public static func noteMediaPath(
        moduleID: String, noteOwnerID: String, filename: String
    ) throws -> String {
        try checked([noteMediaDirectory, moduleID, noteOwnerID], filename)
    }

    /// Where a notes **module**'s picture sits on the server. Keyed by the
    /// module alone, as a book's is: the module declares its pictures once
    /// and its notes point at them by id, so they are not one note's.
    public static func noteModuleMediaPath(
        moduleID: String, filename: String
    ) throws -> String {
        try checked([noteMediaDirectory, moduleID], filename)
    }

    public static func devotionalMediaPath(
        moduleID: String, devotionalID: String, filename: String
    ) throws -> String {
        try checked([devotionalMediaDirectory, moduleID, devotionalID], filename)
    }

    /// `path` is the image's path inside the book, which may have folders.
    public static func bookMediaPath(moduleID: String, path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let filename = components.last else { throw PathError.unsafe(path) }
        return try checked([bookMediaDirectory, moduleID] + components.dropLast(), filename)
    }

    public static func deckPath(deckID: String) throws -> String {
        try checked([decksDirectory], "\(deckID).\(deckExtension)")
    }

    public static func deckAssetPath(filename: String) throws -> String {
        try checked([deckAssetsDirectory], filename)
    }

    /// Where a writing's review marks live, or those of one document
    /// beside it.
    ///
    /// The writing's own file keeps the name it has always had, so every
    /// record already on a server or a phone goes on being found. A
    /// document's is that name with the document's own after it, and an
    /// older app never opens one: the name it does not make is a name it
    /// refuses to read, and a file whose kind is nil is skipped by every
    /// listing. That is what makes this safe to add — not the merge,
    /// which would happily take another document's marks into the
    /// writing's.
    public static func writingReviewPath(writingID: String, document: String? = nil) throws -> String {
        try writingReviewPath(
            writingID: writingID,
            documentKey: document.map { reviewDocumentKey(writingID: writingID, document: $0) }
        )
    }

    /// The same path from a document's key rather than its name, for a
    /// caller working from the files that are there — a sweep removing the
    /// records of a writing that is gone — which has the key and may not
    /// have the name.
    public static func writingReviewPath(
        writingID: String, documentKey: String?
    ) throws -> String {
        let filename = reviewFilename(writingID: writingID, documentKey: documentKey)
        guard filename.utf8.count <= maximumReviewFilenameBytes else {
            throw PathError.unsafe("\(writingReviewDirectory)/\(filename)")
        }
        return try checked([writingReviewDirectory], filename)
    }

    /// A document's part of its review file's name.
    ///
    /// Its escaped name, where that fits. A name may be 255 bytes and the
    /// escape writes three for every byte that is not an ASCII letter,
    /// digit or hyphen, so a document named in Hebrew or Greek runs past
    /// what a name may be — and the path would then throw, which the
    /// writer that asks for it does not look at: the document would simply
    /// never have marks, and nothing would say why. Such a name is written
    /// as a digest of itself instead, behind `_ZZ`, which the escape can
    /// never produce. What the digest cost — reading the name back out of
    /// the file's name — the record inside gives back: it carries the
    /// document's name itself.
    public static func reviewDocumentKey(writingID: String, document: String) -> String {
        let escaped = escapedForReviewName(document)
        let filename = reviewFilename(writingID: writingID, documentKey: escaped)
        guard filename.utf8.count > maximumReviewFilenameBytes else { return escaped }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in document.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(opaqueDocumentKeyMarker)\(String(hash, radix: 16))"
    }

    /// Opens the key of a document whose name was too long to keep. Two
    /// underscores part the id from the document, and `Z` is no hex digit,
    /// so no escaped name is ever mistaken for one of these.
    static let opaqueDocumentKeyMarker = "_ZZ"

    /// The writing a review file is for, or nil for any other path. A
    /// document's file answers with its writing.
    public static func writingID(ofReviewPath path: String) -> String? {
        reviewTarget(ofPath: path)?.writingID
    }

    /// The writing and the document a review file is for: nil document for
    /// the writing's own prose, which is the only kind of file that existed
    /// before. The document is its key, which is its name unless the name
    /// was too long to keep — the record inside holds the name itself.
    public static func reviewTarget(ofPath path: String) -> (writingID: String, documentKey: String?)? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == writingReviewDirectory else { return nil }
        return reviewTarget(filename: String(components[1]))
    }

    /// A writing's id as its review file's name. An id stays as it is where
    /// it is ASCII letters, digits and hyphens, as every id Lamp makes is;
    /// any other byte of its UTF-8 is written `_` and two uppercase hex
    /// digits. A writing's id can come from the front matter of a file the
    /// writer imported, which may begin with a period, hold a space or a
    /// letter that is spelled two ways in Unicode: none of those may reach
    /// a file name as it is, since a hidden or renormalised name is a file
    /// no pass would find again.
    static func reviewFilename(writingID: String, documentKey: String? = nil) -> String {
        let id = escapedForReviewName(writingID)
        guard let documentKey else { return "\(id).\(writingReviewExtension)" }
        // Two underscores part them, which no escaped name can hold: a
        // bare underscore is always written `_5F`.
        return "\(id)__\(documentKey).\(writingReviewExtension)"
    }

    private static func escapedForReviewName(_ text: String) -> String {
        var name = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
                name.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                name += String(format: "_%02X", byte)
            }
        }
        return name
    }

    private static func unescapedFromReviewName(_ name: Substring) -> String? {
        var bytes: [UInt8] = []
        var rest = name.utf8[...]
        while let byte = rest.first {
            rest = rest.dropFirst()
            guard byte == UInt8(ascii: "_") else {
                bytes.append(byte)
                continue
            }
            guard rest.count >= 2,
                  let value = UInt8(String(decoding: rest.prefix(2), as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(value)
            rest = rest.dropFirst(2)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The id a review file's name was made from, or nil for a name
    /// `reviewFilename` does not make: one name for each id, read back
    /// exactly.
    static func writingID(reviewFilename filename: String) -> String? {
        reviewTarget(filename: filename)?.writingID
    }

    static func reviewTarget(filename: String) -> (writingID: String, documentKey: String?)? {
        let suffix = ".\(writingReviewExtension)"
        guard filename.hasSuffix(suffix), filename.utf8.count > suffix.utf8.count,
              filename.utf8.count <= maximumReviewFilenameBytes else { return nil }
        let body = Substring(filename.dropLast(suffix.count))
        let parts = body.components(separatedBy: "__")
        guard parts.count <= 2, !parts.contains(where: \.isEmpty) else { return nil }
        guard let id = unescapedFromReviewName(Substring(parts[0])) else { return nil }
        let key: String? = parts.count == 2 ? parts[1] : nil
        if let key, !key.hasPrefix(opaqueDocumentKeyMarker),
           unescapedFromReviewName(Substring(key)) == nil {
            return nil
        }
        // Read back exactly: one name for each pair, and nothing else.
        guard reviewFilename(writingID: id, documentKey: key) == filename else { return nil }
        return (id, key)
    }

    /// A document's name from its key, or nil where the key is a digest of
    /// a name too long to keep — then the record inside holds the name.
    public static func documentName(fromReviewKey key: String) -> String? {
        guard !key.hasPrefix(opaqueDocumentKeyMarker) else { return nil }
        return unescapedFromReviewName(Substring(key))
    }

    /// Within what every file system and server Lamp syncs through takes
    /// for a name.
    static let maximumReviewFilenameBytes = 240

    public static func workspaceFilePath(relativePath: String) throws -> String {
        let path = "\(workspacesDirectory)/\(relativePath)"
        guard kind(of: path) == .workspaceFile else { throw PathError.unsafe(path) }
        return path
    }

    /// What a path holds, or nil for one outside the layout: a hidden file
    /// such as an iCloud placeholder, a legacy module format, a retired
    /// alias, the bundle, or anything unsafe.
    public static func kind(of path: String) -> LampSyncFileKind? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(isSafeComponent) else { return nil }
        let head = components[0]
        if components.count == 2, let kind = LampSyncContentKind(folder: head) {
            return isModuleFilename(components[1]) && !isRetiredAlias(path) ? .module(kind) : nil
        }
        if head == devotionalMediaDirectory {
            return components.count == 4 ? .devotionalMedia : nil
        }
        if head == noteMediaDirectory {
            // Four for one of the reader's own notes, keyed by its verse;
            // three for a notes module's, keyed by the module, which
            // declares its pictures once and whose notes point at them by
            // id. The count tells them apart, not the look of the segment.
            return (3...4).contains(components.count) ? .noteMedia : nil
        }
        if head == bookMediaDirectory {
            return components.count >= 3 ? .bookMedia : nil
        }
        if head == writingReviewDirectory {
            return writingID(ofReviewPath: path) == nil ? nil : .writingReview
        }
        guard head == workspacesDirectory else { return nil }
        if components[1] == "Presentations" {
            if components.count == 3 {
                return components[2].lowercased().hasSuffix(".\(deckExtension)")
                    && components[2].count > deckExtension.count + 1 ? .deck : nil
            }
            // Anything else under the deck folder belongs to the deck format.
            return components.count == 4 && components[2] == "Assets" ? .deckAsset : nil
        }
        return LampWritingWorkspaceLayout.document(ofPath: path) == nil ? .workspaceFile : .writingDocument
    }

    /// A copy the old sync left under an ID it has since renamed:
    /// `Notes/bible-notes.lamp`, merged into `notes` long ago. Outside the
    /// layout, so it is never listed, adopted or installed. Adopted, it would
    /// arrive as a second notes module holding old copies of notes, and bring
    /// back any deleted before the deletion ledger existed.
    public static func isRetiredAlias(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == Substring(LampSyncContentKind.notes.folder),
              let id = LampSyncModuleFiles.moduleID(from: String(components[1])),
              components[1].lowercased().hasSuffix(".\(moduleExtension)")
        else { return false }
        return LampSyncModuleFiles.canonicalIdentity(id, isNotes: true) != id
    }

    /// The module ID the *server* knows a module or its media by, taken from
    /// the path. It is not the ID an app uses locally: a personal module's
    /// path holds the adapter's rewritten ID (`Notes/notes.lamp` is `notes`,
    /// never the Mac's own), and a highlight module's holds the per-set ID the
    /// Mac maps it to.
    public static func remoteModuleID(of path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch kind(of: path) {
        case .module: return String(components[1].dropLast(moduleExtension.count + 1))
        case .devotionalMedia, .noteMedia, .bookMedia: return components[1]
        default: return nil
        }
    }

    // MARK: - Bundle format 3

    /// Writing's names under bundle format 3.
    public enum FormatThree {
        public static let writingFolder = "Devotionals"
        public static let writingMediaDirectory = "DevotionalMedia"
        /// The writing collection's module ID, `Devotionals/devotionals.lamp`.
        public static let writingCollectionID = "devotionals"
        /// The Mac's writing workspaces.
        public static let writingWorkspacesDirectory = "\(workspacesDirectory)/Devotionals"
    }

    /// Where a path of the format-3 layout lives in format 4. A writing module
    /// moves from `Devotionals/` to `Writing/`, its media from
    /// `DevotionalMedia/` to `WritingMedia/`, the writing collection's ID from
    /// `devotionals` to `writing`, in its file name and in its media's folder,
    /// and the Mac's writing workspaces from `Workspaces/Devotionals/` to
    /// `Workspaces/Writing/`. Every other path of the format-3 layout is the
    /// same in format 4. Nil for one that layout didn't hold, `Writing/` and
    /// `Workspaces/Writing/` among them.
    ///
    /// Nil too for a writing module whose ID is already `writing`, and its
    /// media: its new path is the collection's, so it is not carried, and
    /// stays at its old path. No two paths land on one. A device that has it
    /// installed keeps it, and says it cannot sync it.
    /// (`Verification/SyncMerge.lean`: `formatFourPath`.)
    public static func formatFourPath(ofFormatThree path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(isSafeComponent) else { return nil }
        let head = components[0]
        let collection = LampSyncLocalDeletion.writingCollectionID
        func renamed(_ id: String) -> String? {
            switch id {
            case FormatThree.writingCollectionID: collection
            case collection: nil
            default: id
            }
        }
        if head == FormatThree.writingFolder {
            guard components.count == 2, isModuleFilename(components[1]),
                  let id = LampSyncModuleFiles.moduleID(from: components[1]),
                  let newID = renamed(id) else { return nil }
            let renamedPath = "\(LampSyncContentKind.devotionals.folder)/\(newID).\(moduleExtension)"
            return kind(of: renamedPath) == nil ? nil : renamedPath
        }
        if head == FormatThree.writingMediaDirectory {
            guard components.count == 4, let newID = renamed(components[1]) else { return nil }
            let renamedPath = ([devotionalMediaDirectory, newID] + components[2...]).joined(separator: "/")
            return kind(of: renamedPath) == nil ? nil : renamedPath
        }
        if head == workspacesDirectory, components.count >= 3 {
            let workspaceFolder = "\(head)/\(components[1])"
            if workspaceFolder == FormatThree.writingWorkspacesDirectory {
                let renamedPath = ([writingWorkspacesDirectory] + components[2...]).joined(separator: "/")
                return kind(of: renamedPath) == nil ? nil : renamedPath
            }
            if workspaceFolder == writingWorkspacesDirectory { return nil }
        }
        // Folders format 4 added held nothing of format 3's.
        if head == LampSyncContentKind.devotionals.folder || head == devotionalMediaDirectory { return nil }
        return kind(of: path) == nil ? nil : path
    }

    /// The format-3 path a format-4 writing path was moved from, the inverse
    /// of `formatFourPath(ofFormatThree:)`; the path itself for any other in
    /// format 4's layout, and nil for one outside it.
    public static func formatThreePath(ofFormatFour path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard kind(of: path) != nil else { return nil }
        func original(_ id: String) -> String {
            id == LampSyncLocalDeletion.writingCollectionID ? FormatThree.writingCollectionID : id
        }
        if components[0] == LampSyncContentKind.devotionals.folder,
           let id = LampSyncModuleFiles.moduleID(from: components[1]) {
            return "\(FormatThree.writingFolder)/\(original(id)).\(moduleExtension)"
        }
        if components[0] == devotionalMediaDirectory {
            return ([FormatThree.writingMediaDirectory, original(components[1])] + components[2...])
                .joined(separator: "/")
        }
        if components.count >= 3, "\(components[0])/\(components[1])" == writingWorkspacesDirectory {
            return ([FormatThree.writingWorkspacesDirectory] + components[2...]).joined(separator: "/")
        }
        return path
    }

    private static func isModuleFilename(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".\(moduleExtension)") && name.count > moduleExtension.count + 1
    }

    /// No empty, relative or hidden component. Hidden covers iCloud's
    /// `.name.icloud` placeholders and Finder's `.DS_Store`.
    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && !component.hasPrefix(".")
            && !component.contains("\\") && !component.contains("\0")
    }

    private static func checked(_ directories: [String], _ filename: String) throws -> String {
        let path = (directories + [filename]).joined(separator: "/")
        guard kind(of: path) != nil else { throw PathError.unsafe(path) }
        return path
    }
}

extension LampSyncContentKind {
    /// The folder a module of this kind lives in.
    public init(_ kind: LampModuleKind) {
        switch kind {
        case .translation: self = .translations
        case .dictionary: self = .dictionaries
        case .commentary: self = .commentaries
        case .book: self = .books
        case .devotional: self = .devotionals
        case .notes: self = .notes
        case .plan: self = .plans
        case .highlights: self = .highlights
        case .quiz: self = .quizzes
        }
    }
}
