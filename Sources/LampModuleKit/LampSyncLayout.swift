/// Stable paths in the shared WebDAV library. Apps may support different
/// content kinds, but directory spelling is defined here once.
///
/// The raw value is the folder the **archive** formats use, under
/// `Compatibility/`, and the one the phone's iCloud library used before the
/// bundle: it never changes, or an old archive stops reading. The per-file
/// layout's folder is `folder`, which differs for writing since bundle
/// format 4.
public enum LampSyncContentKind: String, CaseIterable, Codable, Sendable {
    case translations = "Translations"
    case dictionaries = "Dictionaries"
    case commentaries = "Commentaries"
    case books = "Books"
    case devotionals = "Devotionals"
    case notes = "Notes"
    case plans = "Plans"
    case highlights = "Highlights"
    case quizzes = "Quizzes"

    /// The folder a module of this kind lives in under the per-file layout.
    /// Writing was `Devotionals` until bundle format 4; see
    /// `LampSyncFolderLayout.formatFourPath(ofFormatThree:)`.
    public var folder: String {
        switch self {
        case .devotionals: "Writing"
        default: rawValue
        }
    }

    /// The kind whose per-file folder is `folder`, or nil.
    public init?(folder: String) {
        guard let kind = Self.allCases.first(where: { $0.folder == folder }) else { return nil }
        self = kind
    }
}

public enum LampSyncLayout {
    public static let archivePath = "lamp-bible.lampsync"
    /// Describes `archivePath`'s entries so a client can tell what changed
    /// without fetching it. Advisory: absent or stale means read the archive.
    public static let archiveIndexPath = "lamp-bible.lampsync.index.json"
    public static let userSettingsPath = "UserData/user-settings.db"
}

/// Paths inside a portable backup or a decoded sync archive.
public enum LampPortableBackupLayout {
    public static let manifestPath = "manifest.json"
    public static let modulesDirectory = "Modules"
    public static let studyDirectory = "Study"
    public static let notesDirectory = "Study/Notes"
    public static let highlightsDirectory = "Study/Highlights"
    public static let devotionalsDirectory = "Devotionals"
    public static let mediaDirectory = "Media"
    public static let compatibleDirectory = "Compatibility"
    public static let compatibilityManifestPath = "Compatibility/manifest.json"
    public static let workspacesDirectory = "Workspaces"
    public static let settingsPath = "settings.plist"
    public static let sharedPreferencesPath = "Settings/shared-preferences.json"
    /// Deletions of personal content, kept apart from the content folders so
    /// versions that predate it never mistake it for content.
    public static let deletionLedgerPath = "Deletions/ledger.json"
}
