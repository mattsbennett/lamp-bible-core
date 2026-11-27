import Foundation

/// A place in an installed module that a link names: by the module's kind
/// and declared ID, and a passage, a unit, a section or an anchor in it —
/// never a stored row ID, which the phone renames on import and a rebuild
/// renumbers (`Documentation/RichModulesPlan.md`, "Link address").
///
/// A target carries `data.target` on a `link` annotation, or on a `scripture`
/// annotation that also opens a passage: a reader that knows targets opens the
/// note on the passage, one that does not opens the passage itself.
public struct LampLinkTarget: Codable, Hashable, Sendable {
    /// `commentary` or `book`; with `module` omitted, the module the link is in.
    public let kind: String?
    public let module: String?
    public let startReference: Int?
    public let endReference: Int?
    public let suffix: String?
    /// The declared ID of a section or pericope that starts at the passage.
    public let unit: String?
    /// A commentary volume's Bible book, for its front matter.
    public let book: Int?
    public let section: String?
    /// A block's `id` inside the unit or section the rest of the target finds.
    public let anchor: String?

    enum CodingKeys: String, CodingKey {
        case kind, module
        case startReference = "sv"
        case endReference = "ev"
        case suffix, unit, book, section, anchor
    }

    public init(
        kind: String? = nil, module: String? = nil,
        startReference: Int? = nil, endReference: Int? = nil, suffix: String? = nil,
        unit: String? = nil, book: Int? = nil, section: String? = nil, anchor: String? = nil
    ) {
        // As given: any field given empty is written wrong, and the target
        // names nowhere (`destination(in:)`), as one read from JSON would not
        // be read at all. Taken as absent, an empty `unit` or `anchor` sent it
        // to a different note or the section's top. Found by Codex.
        self.kind = kind
        self.module = module
        self.startReference = startReference
        self.endReference = endReference
        // But an empty suffix is none, both here and when read, as the
        // compiler stores it: so it means the same written and read back.
        self.suffix = suffix?.isEmpty == true ? nil : suffix
        self.unit = unit
        self.book = book
        self.section = section
        self.anchor = anchor
    }

    /// Every field given must be what it says: a target with one written
    /// wrong is no target. Read as absent, a wrong `kind` or `module` sent it
    /// to this module, and a wrong `ev` or `unit` to a different note at the
    /// same verse; kept with a flag, the flag was lost on being written again.
    /// Found by Codex, over several reviews. The annotation it is on still
    /// reads, without it, as does a scripture annotation's own passage.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) throws -> String? {
            guard container.contains(key) else { return nil }
            guard let value = try? container.decode(String.self, forKey: key), !value.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected words.")
            }
            return value
        }
        func integer(_ key: CodingKeys) throws -> Int? {
            guard container.contains(key) else { return nil }
            guard let value = try? container.decode(Int.self, forKey: key) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected a whole number.")
            }
            return value
        }
        kind = try string(.kind)
        module = try string(.module)
        startReference = try integer(.startReference)
        endReference = try integer(.endReference)
        // An empty suffix is none, as the compiler stores it. Found by Codex.
        suffix = container.contains(.suffix) && (try? container.decode(String.self, forKey: .suffix)) == ""
            ? nil : try string(.suffix)
        unit = try string(.unit)
        book = try integer(.book)
        section = try string(.section)
        anchor = try string(.anchor)
    }

    /// Where the target goes, read in a module of `containingKind` — what an
    /// omitted `kind` means — or nil for one that names no single place.
    ///
    /// Exactly one route per target: a commentary passage (`sv`, perhaps
    /// with `ev`, `suffix` and `unit`); a commentary volume's front matter
    /// (`book` and `section`); or a book's section (`section`, in a book).
    /// A target mixing them — a book target with a passage, a commentary
    /// target with a section but no `book` — names none.
    public func destination(in containingKind: String) -> Destination? {
        // Another module's kind is never assumed to be this one's, and a
        // kind other than this module's names another module, which must
        // then be named: a book cannot hold a commentary passage of its own.
        // Found by Codex.
        if [kind, module, unit, section, anchor].contains(where: { $0?.isEmpty == true }) { return nil }
        if module != nil, self.kind == nil { return nil }
        if let kind = self.kind, kind != containingKind, module == nil { return nil }
        // Addresses as the schemas bound them: a Bible book 1 to 66, and a
        // verse reference in one, with a chapter (a verse 0 is a psalm's
        // title). Found by Codex.
        if let book, !(1...66).contains(book) { return nil }
        for reference in [startReference, endReference].compactMap({ $0 })
        where !(1...66).contains(reference / 1_000_000) || reference / 1_000 % 1_000 == 0 {
            return nil
        }
        let kind = self.kind ?? containingKind
        switch kind {
        case "commentary":
            if let startReference {
                // A range that ends before it begins names no note. Found by
                // Codex.
                guard book == nil, section == nil, (endReference ?? startReference) >= startReference
                else { return nil }
                return .commentaryPassage(
                    start: startReference, end: endReference, suffix: suffix, unit: unit, anchor: anchor
                )
            }
            guard endReference == nil, suffix == nil, unit == nil, let book, let section else { return nil }
            return .commentaryFrontMatter(book: book, section: section, anchor: anchor)
        case "book":
            guard startReference == nil, endReference == nil, suffix == nil, unit == nil, book == nil,
                  let section
            else { return nil }
            return .bookSection(section: section, anchor: anchor)
        default:
            return nil
        }
    }

    public enum Destination: Hashable, Sendable {
        case commentaryPassage(start: Int, end: Int?, suffix: String?, unit: String?, anchor: String?)
        case commentaryFrontMatter(book: Int, section: String, anchor: String?)
        case bookSection(section: String, anchor: String?)
    }
}

/// One entry of a block's legend: a label rows or cells carry, and what it
/// stands for, such as `good-king` and "Good".
public struct LampBookLegendEntry: Codable, Equatable, Hashable, Sendable {
    public let label: String
    public let title: String

    public init(label: String, title: String) {
        self.label = label
        self.title = title
    }
}
