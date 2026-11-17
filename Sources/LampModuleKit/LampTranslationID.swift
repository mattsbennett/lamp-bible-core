import Foundation

/// The translations whose module IDs were renamed, and how an ID written
/// under either name is read.
///
/// The bundled and imported translations carried an "s" for their Strong's
/// tags (`BSBs`, `KJVs`, `ESVs`); their IDs drop it. Their abbreviations never
/// had it. A library meets both spellings for a long while: a bundle still
/// built with the old IDs, a translation imported before the change beside
/// one imported again after it, and saved and synced data written under
/// either.
///
/// Two rules keep that safe, and both apps follow them:
///
/// - **A reference resolves; nothing is merged.** A stored or synced
///   translation ID is read as the module it names when that module is held,
///   and otherwise as the module its name now belongs to (`held(_:among:)`).
///   With `ESVs` and `ESV` both installed, each stays its own module, and a
///   reference to either goes to exactly that one.
/// - **An identity keeps the first ID.** What other devices compare to know
///   two things are the same, a highlight set's ID and the translation it
///   records, is built from `original(_:)`, which every device, built before
///   the change or after, computes alike. Nothing synced is rewritten.
public enum LampTranslationID {
    /// Old ID to new.
    public static let renamed: [String: String] = [
        "ASVs": "ASV",
        "BSBs": "BSB",
        "KJVs": "KJV",
        "WEBs": "WEB",
        "ESVs": "ESV",
        "NETs": "NET",
        "ABPs": "ABP",
    ]

    private static let earlier: [String: [String]] = Dictionary(
        grouping: renamed.keys.sorted(), by: { renamed[$0]! }
    )

    /// The ID a translation goes by now: an old ID's new one, and any other
    /// ID as it is.
    public static func current(_ id: String) -> String {
        renamed[id] ?? id
    }

    /// Whether `id` is one a translation no longer goes by.
    public static func isEarlier(_ id: String) -> Bool {
        renamed[id] != nil
    }

    /// The ID a translation had first: an identity built on a translation
    /// keeps it, so every device, before the change or after, builds the same
    /// one. `BSB` and `BSBs` are both `BSBs`; an ID never renamed is itself.
    public static func original(_ id: String) -> String {
        let now = current(id)
        return earlier[now]?.first ?? now
    }

    /// Every ID the translation `id` names has gone by: its current ID first,
    /// then the old ones.
    public static func equivalents(of id: String) -> [String] {
        let now = current(id)
        return [now] + (earlier[now] ?? [])
    }

    /// The ID among `held` that a reference to `id` reads as: `id` itself
    /// when it is held, so two modules held side by side are never confused;
    /// otherwise the first of its equivalents held, its current ID first;
    /// nil when none is.
    public static func held(_ id: String, among held: some Collection<String>) -> String? {
        let held = Set(held)
        if held.contains(id) { return id }
        return equivalents(of: id).first(where: held.contains)
    }

    /// A list of references, each read as `held(_:among:)` reads one, in its
    /// order, those nothing holds left out, and each held translation once.
    /// A list can name one translation under both names, a companion set up
    /// before an import and again after it, and once the old module goes
    /// both resolve to the new one, which a reader would otherwise draw
    /// twice. The first place a translation was named is the one it keeps.
    public static func held(_ ids: [String], among held: some Collection<String>) -> [String] {
        let held = Set(held)
        var seen: Set<String> = []
        return ids.compactMap { id in
            guard let found = Self.held(id, among: held), seen.insert(found).inserted else { return nil }
            return found
        }
    }

    /// Whether two IDs name one translation, under either name.
    public static func sameTranslation(_ a: String, _ b: String) -> Bool {
        current(a) == current(b)
    }
}
