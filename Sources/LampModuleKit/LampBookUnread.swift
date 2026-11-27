import Foundation

/// What an author wrote in a block that the book model does not carry.
///
/// A block is read field by field, and a field the model has no place for —
/// a key the schema does not name, a list item's sub-items written as
/// `items`, an annotation's `lexiconId` — is dropped without a word: a
/// reader, search and a projection then never see it. So a 2.3 commentary's
/// blocks are read whole or refused (`RichModulesPlan.md`, step 4, commit
/// 3): the block is decoded, encoded back, and every key or array entry the
/// author wrote that the encoded block lacks is named.
///
/// Judged by what the model kept, not by a list of the fields it reads, so a
/// field added to the model is read here the moment it is read anywhere,
/// and one the schema adds before the model does is caught. Values are
/// never compared or reported — only where the lost ones are — so nothing
/// an author wrote reaches a message: a path is made of keys and indexes.
public enum LampBookUnread {
    /// The JSON pointer paths, under `path`, of every key or array entry in
    /// a block `raw` that the model does not carry: `path` itself if `raw` does not
    /// decode as one at all. A key given `null`, an empty string, an empty
    /// array or an empty object holds nothing to lose. An array the model keeps fewer entries
    /// of — one it could not read, a `null` among them, dropped — is named
    /// itself, its entries then not compared one by one, which a dropped
    /// entry would misalign.
    public static func paths(inBlock raw: Any, at path: String = "") -> [String] {
        paths(in: raw, as: LampBookContentBlock.self, at: path)
    }

    /// For the book models only, which keep an array's entries in the order
    /// written: compared entry by entry, a type that reordered them — a
    /// `Set` — would be read as losing what it kept. Found by Codex.
    static func paths<T: Codable>(in raw: Any, as type: T.Type, at path: String = "") -> [String] {
        guard JSONSerialization.isValidJSONObject(raw) || isScalar(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
              let decoded = try? JSONDecoder().decode(type, from: data),
              let encoded = try? JSONEncoder().encode(decoded),
              let kept = try? JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        else { return [path] }
        var out: [String] = []
        missing(raw, kept, path: path, into: &out)
        return out
    }

    /// A value JSON can write on its own: a number only if finite, since
    /// Foundation parses `-1e500` as an infinity, which its writer meets
    /// with an exception no `try?` catches. Found by Codex. (Inside an
    /// array or object, `isValidJSONObject` refuses one.)
    private static func isScalar(_ value: Any) -> Bool {
        if let number = value as? NSNumber { return number.doubleValue.isFinite }
        return value is String || value is NSNull
    }

    /// Nothing to lose: `null`, an empty string — a target's `suffix: ""`,
    /// which the model reads as none (found by Codex) — or an empty array
    /// or object.
    private static func holdsNothing(_ value: Any) -> Bool {
        value is NSNull
            || (value as? String)?.isEmpty == true
            || (value as? [Any])?.isEmpty == true
            || (value as? [String: Any])?.isEmpty == true
    }

    private static func missing(_ raw: Any, _ kept: Any?, path: String, into out: inout [String]) {
        if holdsNothing(raw) { return }
        guard let kept, !(kept is NSNull) else {
            out.append(path)
            return
        }
        // As Foundation parsed it, each key looked up literally: as a Swift
        // dictionary, `café` and `cafe\u{301}` were one key, and, as they
        // fell, the one the model dropped was read through the other's
        // value. Found by Codex.
        if let object = raw as? NSDictionary {
            guard let keptObject = kept as? NSDictionary else {
                out.append(path)
                return
            }
            let keys = object.allKeys.compactMap { $0 as? String }
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for key in keys {
                missing(object[key]!, keptObject[key], path: path + "/" + escaped(key), into: &out)
            }
        } else if let array = raw as? [Any] {
            guard let keptArray = kept as? [Any] else {
                out.append(path)
                return
            }
            // An entry given as `null` is one the model cannot read either.
            guard keptArray.count >= array.count else {
                out.append(path)
                return
            }
            for (index, entry) in array.enumerated() {
                missing(entry, keptArray[index], path: path + "/\(index)", into: &out)
            }
        } else if kept is NSDictionary || kept is [Any] {
            // A word or number where a list or an object belongs, read as an
            // empty one. Found by Codex.
            out.append(path)
        }
        // Otherwise a scalar is carried if it is there at all, as an integer
        // page number is read as its string: values are not judged.
    }

    /// A key as a JSON pointer writes it (RFC 6901).
    private static func escaped(_ key: String) -> String {
        // Literally: compared as Characters, a `/` before a combining mark
        // was not found, and the pointer split the key. Found by Codex.
        key.replacingOccurrences(of: "~", with: "~0", options: .literal)
            .replacingOccurrences(of: "/", with: "~1", options: .literal)
    }
}
