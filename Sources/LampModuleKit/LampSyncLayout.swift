/// Stable paths in the shared WebDAV library. Apps may support different
/// content kinds, but directory spelling is defined here once.
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
}

public enum LampSyncLayout {
    public static let archivePath = "lamp-bible.lampsync"
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
}
