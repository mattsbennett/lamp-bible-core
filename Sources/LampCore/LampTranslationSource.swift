import Foundation
import GRDB

/// Where part of a translation's tagging came from, when its source text did
/// not print it: Strong's numbers matched to the words by machine, or the
/// Greek and Hebrew spellings carried onto a translation whose source tags
/// only numbers.
///
/// A module declares these in its `sourceTexts` (stored as
/// `source_texts_json`), and the apps say so wherever the part is shown, so
/// a reader can tell what a text prints from what was matched to it when
/// the module was built. Nothing is matched while reading: by owner decision
/// (2026-11-09), Lamp shows what a source says, and discloses what was
/// matched at build time rather than leave it looking printed.
public struct LampTranslationSource: Equatable, Sendable {
    public enum Part: String, Sendable {
        /// The Strong's numbers themselves.
        case strongs
        /// The original-language spelling each tag carries.
        case forms
    }

    public var part: Part
    /// The origin, named as it would be cited.
    public var source: String
    /// How it was matched to the text, as one clause a reader can follow.
    public var method: String?

    public init(part: Part, source: String, method: String? = nil) {
        self.part = part
        self.source = source
        self.method = method
    }

    /// The sources a module's `sourceTexts` declares for its tagging.
    ///
    /// Read loosely: `sourceTexts` is free-form in an imported module, and
    /// may list a source's name alone. Only entries naming a known part and a
    /// source are kept, so nothing is said about a part no entry describes.
    public static func parsed(_ json: String?) -> [LampTranslationSource] {
        guard let data = json?.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        // A list of entries, or the schema's object of manuscript texts
        // ({"ot": […], "nt": […]}) with the tagging's sources under
        // "annotations".
        let entries = parsed as? [Any] ?? (parsed as? [String: Any])?["annotations"] as? [Any] ?? []
        return entries.compactMap { entry in
            guard let entry = entry as? [String: Any],
                  let part = (entry["part"] as? String).flatMap(Part.init(rawValue:)),
                  let source = (entry["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty
            else { return nil }
            let method = (entry["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LampTranslationSource(part: part, source: source, method: method?.isEmpty == false ? method : nil)
        }
    }

    /// The sources `translationID` declares, from an imported module's
    /// `translation_meta` or the bundle's `translations` table.
    public static func declared(in db: Database, translationID: String) throws -> [LampTranslationSource] {
        let tables = try LampModuleText.tableNames(in: db)
        if tables.contains("translation_meta") {
            let columns = try LampModuleText.columnNames(in: db, table: "translation_meta")
            guard columns.contains("source_texts_json") else { return [] }
            return parsed(try Row.fetchOne(db, sql: "SELECT source_texts_json FROM translation_meta LIMIT 1")?["source_texts_json"])
        }
        if tables.contains("translations") {
            let columns = try LampModuleText.columnNames(in: db, table: "translations")
            guard columns.contains("source_texts_json") else { return [] }
            return parsed(try Row.fetchOne(
                db,
                sql: "SELECT source_texts_json FROM translations WHERE id = ?",
                arguments: [translationID]
            )?["source_texts_json"])
        }
        return []
    }

    /// The sentence that says it, where the part is shown: "Greek spellings
    /// in BSBs come from …, matched by each verse's Strong's numbers when the
    /// module was built."
    public func disclosure(translationName: String, strongsKey: String) -> String {
        "\(Self.subject(part, strongsKey: strongsKey)) in \(translationName) come from \(origin)."
    }

    /// What a text's sources say, one paragraph to a part, in the order the
    /// module declares them. A part with one source is `disclosure`'s
    /// sentence. A part with several is said once, then each source on a
    /// line of its own, so a reader sees two origins rather than the same
    /// sentence begun twice, as the tagged Septuagint's word and name tags
    /// read when each had its own paragraph (owner, Nov 2026):
    ///
    ///     Strong’s numbers in LXX come from two sources:
    ///     • STEPBible’s tagged Greek New Testament …, matched to each word …
    ///     • STEPBible’s tagged Hebrew Old Testament …, for names …
    public static func disclosures(
        _ sources: [LampTranslationSource],
        translationName: String,
        strongsKey: String
    ) -> [String] {
        var parts: [Part] = []
        for source in sources where !parts.contains(source.part) {
            parts.append(source.part)
        }
        return parts.map { part in
            let own = sources.filter { $0.part == part }
            guard own.count > 1 else {
                return own[0].disclosure(translationName: translationName, strongsKey: strongsKey)
            }
            let lead = "\(subject(part, strongsKey: strongsKey)) in \(translationName) come from "
                + "\(count(own.count)) sources:"
            return ([lead] + own.map { "• \($0.origin)." }).joined(separator: "\n")
        }
    }

    /// The source, and how it was matched where the module says.
    private var origin: String {
        source + (method.map { ", \($0)" } ?? "")
    }

    private static func subject(_ part: Part, strongsKey: String) -> String {
        switch part {
        case .strongs: "Strong’s numbers"
        case .forms: LampStrongsKey.normalized(strongsKey).first == "H" ? "Hebrew spellings" : "Greek spellings"
        }
    }

    private static func count(_ count: Int) -> String {
        let words = ["two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return (2...9).contains(count) ? words[count - 2] : String(count)
    }
}
