import Foundation

/// What a module's ID may hold.
///
/// An ID becomes a filename — `<id>.lamp` for an authored module, and on the
/// Mac a storage key derived from it — so which characters it may hold is a
/// storage question, not a matter of taste.
///
/// **The rule was written twice and the two did not agree** (found by a Codex
/// review of the module interfaces, 2026-11-11). `ModuleJSONInspector` only
/// *warned*, and over a character set that left out the space the Mac allows;
/// `LampLibrary.install(from:)` *threw*. So `study+one` compiled happily into
/// `study+one.lamp` and then failed to install with `unsafeModuleIdentifier`,
/// while an ID with a space was warned about at authoring and installed
/// without complaint. One rule here, used at every stage; only the severity
/// differs, and it differs on purpose:
///
/// - **authoring** (`ModuleJSONInspector`): a warning, because an inspection
///   reports everything it finds rather than stopping at the first fault;
/// - **building** (`LampModuleCompiler`): thrown, because a module that
///   cannot be installed should not be produced — and the ID it checks is the
///   *effective* one, after the fallback to the source filename, which is
///   what a commentary volume uses and what nothing checked before;
/// - **installing** (`LampLibrary`): thrown, as the last line, since an
///   archive may arrive from anywhere.
public enum LampModuleIdentifier {
    /// Letters, numbers, period, underscore, hyphen and space.
    ///
    /// The space is here because the installer has always allowed it, and
    /// modules named with one install today; taking it away would refuse an
    /// ID that already works, which is the one change this unification must
    /// not make.
    public static let allowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: " ._-"))

    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    /// One sentence, shared, so the warning at authoring time and the error
    /// at install time describe the same rule rather than two.
    public static let advice = """
        only letters, numbers, spaces, periods, underscores, and hyphens, \
        so the ID is safe as a .lamp filename
        """
}
