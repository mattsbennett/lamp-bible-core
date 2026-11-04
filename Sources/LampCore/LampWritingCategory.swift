import Foundation

/// A writing's kind, as its writer names it.
///
/// The vocabulary is open. `suggestions` is what the editors offer; a writer
/// who needs a kind that is not there types it, and it is stored, shown,
/// filtered and grouped like any other. The filter lists and the group-by are
/// built from the kinds a library actually holds, so nothing has to be added
/// here for a new kind to work — which is the point, because a closed list
/// cannot hold the kinds real writing comes in.
///
/// A kind is **stored as it was written** and **compared folded**. Those are
/// two jobs and two functions: `canonical(_:)` tidies a kind without taking
/// the writer's capitals off it, so "Q&A" and "ClassDiscussion_1" survive the
/// round trip, while `foldedKey(_:)` is what tells one kind from another, so
/// "Handout" and "handout" never become two. Folding on the way in would be
/// irreversible — capitals cannot be put back once saved — and nobody asked
/// for it. Tags already work this way.
public enum LampWritingCategory {
    /// The kinds the editors offer, in the order they offer them.
    ///
    /// Writing already carrying a kind that is not here keeps it: dropping a
    /// suggestion is not dropping a value.
    public static let suggestions = [
        "devotional", "exhortation", "reflection", "study", "prayer",
    ]

    /// The spelling a kind is stored in: whitespace tidied, and the two kinds
    /// that have one right spelling snapped to it — a suggestion keeps the
    /// spelling it is offered in, and `sermon` reads as the `exhortation` it
    /// was renamed to. Any other kind keeps the writer's own capitals. Blank
    /// is no kind at all rather than an empty one.
    public static func canonical(_ written: String?) -> String? {
        guard let written else { return nil }
        let tidied = written.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !tidied.isEmpty else { return nil }
        if tidied.caseInsensitiveCompare("sermon") == .orderedSame { return "exhortation" }
        return suggestions.first { $0.caseInsensitiveCompare(tidied) == .orderedSame } ?? tidied
    }

    /// What tells one kind from another. Two writings share a kind when their
    /// folded keys match, so a filter, a group-by and a search all agree
    /// whatever case each was typed in.
    public static func foldedKey(_ stored: String?) -> String? {
        canonical(stored)?.lowercased()
    }

    /// The kind as shown: canonical first, so a stored `sermon` reads as
    /// Exhortation on every platform rather than only where a view remembers
    /// to map it, then the first letter raised and **the rest left as typed**.
    /// "handout" shows as "Handout"; "Q&A" and "ClassDiscussion_1" show as
    /// themselves.
    public static func displayName(_ stored: String?) -> String? {
        guard let kind = canonical(stored), let first = kind.first else { return nil }
        return first.uppercased() + kind.dropFirst()
    }

    /// Every kind a library holds, each once, in order.
    ///
    /// This is what a filter lists, and no more: offering a filter for a kind
    /// nobody has written is noise. Where a library holds two spellings of one
    /// kind, the earlier in order wins, which is the one that kept its
    /// capital — the deliberate spelling, and the one `displayName` would have
    /// produced anyway.
    ///
    /// Ordered on the folded key, not the spelling: sorting the spellings puts
    /// every capital first, so a list of Handout, Exhortation, Lament, Study
    /// reads as though it were unsorted.
    public static func kindsHeld(_ stored: [String?]) -> [String] {
        var byKey: [String: String] = [:]
        for kind in stored.compactMap(canonical) {
            guard let key = foldedKey(kind) else { continue }
            if let held = byKey[key], held <= kind { continue }
            byKey[key] = kind
        }
        return byKey.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The kinds to offer a writer whose library already holds `stored`: every
    /// suggestion, then every other kind they have used, so the list grows
    /// with their writing rather than with releases.
    public static func offered(forLibraryHolding stored: [String?]) -> [String] {
        let suggested = Set(suggestions.compactMap(foldedKey))
        return suggestions + kindsHeld(stored).filter {
            guard let key = foldedKey($0) else { return false }
            return !suggested.contains(key)
        }
    }

    /// The kind to store, given what an editor is showing and what the library
    /// already holds.
    ///
    /// An editor shows a kind the way the rest of the app does — Exhortation,
    /// not exhortation — so what is shown nearly always differs from what is
    /// stored, and writing it back blindly would rename a kind nobody touched.
    /// A Mac editor autosaves every 1.5 seconds, so that is not a rare event:
    /// it is every save of every writing.
    ///
    /// So where what is shown still names the kind the library holds, the
    /// library's own spelling stays — a shared module's `sermon` is not
    /// renamed, and a writer's `handout` is not recapitalised for having been
    /// displayed. Where they differ, the writer meant it, and their spelling
    /// is tidied and kept.
    public static func kindToStore(shown: String?, held: String?) -> String? {
        foldedKey(shown) == foldedKey(held) ? held : canonical(shown)
    }

    /// The stored values a request for `requested` should match. A library an
    /// older build wrote still holds `sermon`, so a request for an exhortation
    /// asks for both names; case is folded by the comparison itself rather
    /// than here, because the stored spelling is the writer's.
    public static func storedValuesMatching(_ requested: some Collection<String>) -> [String] {
        var wanted: Set<String> = []
        for kind in requested.compactMap(canonical) {
            wanted.insert(kind)
            if kind == "exhortation" { wanted.insert("sermon") }
        }
        return wanted.sorted()
    }
}
