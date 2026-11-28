import Foundation

/// A commentary 2.3 unit's body given as blocks: read whole and checked, and
/// stored twice — the blocks as written, for a reader that draws them, and
/// their projection, for one that draws a single annotated text
/// (`RichModulesPlan.md`, "Commentary 2.3", step 4 commit 5).
///
/// The projection is `LampBookDrawnText.projection`, a figure by its parts,
/// written in the form a current phone's `CommentaryRenderer` reads, until
/// step 6's readers draw blocks: only the annotation types it knows; a
/// scripture annotation given its passage by `refs` alone gains the first
/// as `sv`/`ev`, which is all that reader opens; an inline footnote span
/// gains its note's id as its own `id`, which is how that reader opens one;
/// and a page marked at a point is written out as its label, which that
/// reader styles but would otherwise not show, with every later offset
/// moved past it.
enum LampCommentaryBlocks {
    /// The annotation types a commentary reader of 2.2 knows.
    static let legacyTypes: Set<String> = [
        "footnote", "scripture", "strongs", "greek", "hebrew", "crossref", "abbrev",
        "page", "lexicon-ref", "bold", "italic", "emphasis", "media",
    ]

    /// A whole number as the phone's `Decodable` reads one: not a fraction,
    /// and not a JSON `true` or `false`, which Foundation would read as 1 or
    /// 0. Found by Codex.
    static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let whole = value as? Int, number.doubleValue == Double(whole) else { return nil }
        return whole
    }

    /// Whether the phone decodes an annotation, as its `CommentaryAnnotation`
    /// does — a type it knows, whole-number offsets, a word `id` and `text`,
    /// and each data field it reads of the kind it reads — or passes over it
    /// whole. A footnote span it passes over opens nothing, so is no
    /// citation. Found by Codex.
    static func phoneReads(_ annotation: [String: Any]) -> Bool {
        func absentOr<T>(_ value: Any?, _ type: T.Type) -> Bool { value == nil || value is NSNull || value is T }
        func absentOrWhole(_ value: Any?) -> Bool { value == nil || value is NSNull || wholeNumber(value) != nil }
        guard let type = annotation["type"] as? String, legacyTypes.contains(type),
              wholeNumber(annotation["start"]) != nil, wholeNumber(annotation["end"]) != nil,
              absentOr(annotation["id"], String.self), absentOr(annotation["text"], String.self),
              // A JSON boolean only: "false" is words. Found by Codex.
              annotation["implicit"] == nil || annotation["implicit"] is NSNull
                || (annotation["implicit"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true
        else { return false }
        guard let data = annotation["data"], !(data is NSNull) else { return true }
        guard let fields = data as? [String: Any] else { return false }
        let words = ["strongs", "transliteration", "expansion", "pageNum", "lexiconId", "mediaId", "mediaType",
                     "caption", "alignment", "unicode", "sourceEncoding", "style"]
        guard absentOrWhole(fields["sv"]), absentOrWhole(fields["ev"]),
              words.allSatisfy({ absentOr(fields[$0], String.self) })
        else { return false }
        if let refs = fields["refs"], !(refs is NSNull) {
            guard let list = refs as? [Any] else { return false }
            for value in list {
                guard let range = value as? [String: Any], wholeNumber(range["sv"]) != nil, absentOrWhole(range["ev"]) else { return false }
            }
        }
        return true
    }

    /// An annotation an older commentary reader draws as written: of a type
    /// it knows, and not an underline, which it draws as italic. Found by
    /// Codex. The blocks keep it.
    static func keptByOlderReaders(_ annotation: LampBookAnnotation) -> Bool {
        legacyTypes.contains(annotation.type)
            && !(annotation.type == "emphasis" && annotation.data?.style == "underline")
    }

    /// A unit's body, read from its blocks.
    struct Body {
        /// The blocks as written, keys sorted.
        let blocksJSON: String
        /// An older reader's own copy of them (Rule B2), before the
        /// additions every 2.3 text gets (B1, `writtenForOlderReaders`).
        let legacy: [String: Any]
        /// Their words, as search reads them: the projection's, before any
        /// page label is written in, so a phrase across a page still matches.
        let searchText: String
    }

    /// The body `value` gives, or nil with an error in `issues` for one that
    /// cannot be stored as given: not an array of blocks, a field the model
    /// does not read (`LampBookUnread`), a title, second line or notes on a
    /// block no reader draws them on, or an id another block of the volume
    /// holds. Links that open nothing and tables laid out short are
    /// warnings, by the rules a book's are judged by, in a commentary.
    static func body(
        _ value: Any, path: String, blockIDs: inout Set<String>, issues: inout [ModuleValidationIssue]
    ) -> Body? {
        guard let rawBlocks = value as? [Any] else {
            issues.append(.init(severity: .error, path: path, message: "Expected an array of blocks."))
            return nil
        }
        var failed = false
        var blocks: [LampBookContentBlock] = []
        for (index, raw) in rawBlocks.enumerated() {
            let blockPath = "\(path)/\(index)"
            let unread = LampBookUnread.paths(inBlock: raw, at: blockPath)
            for unreadPath in unread {
                issues.append(.init(
                    severity: .error, path: unreadPath,
                    message: "Lamp reads nothing here, and would lose it: a field the block model has no place for, or a value it cannot read."
                ))
            }
            guard unread.isEmpty,
                  let object = raw as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let block = try? JSONDecoder().decode(LampBookContentBlock.self, from: data)
            else {
                failed = true
                continue
            }
            // Every text the block is given must be one a reader draws, as
            // the walk lays it out: a field the model reads but no reader
            // shows — a title on a paragraph, a caption on a table, a
            // figure's own content — would be left out of the projection
            // and search without a word. Judged by the walk itself: the
            // field taken away, the block's lines are unchanged. Listed by
            // hand, review found one more each time. Found by Codex.
            var undrawn = undrawnFields(of: object, figures: .asParts, at: blockPath)
            if block.type == "figure" {
                for (childIndex, child) in ((object["children"] as? [Any]) ?? []).enumerated() {
                    if let child = child as? [String: Any] {
                        undrawn += undrawnFields(of: child, figures: .asParts, at: "\(blockPath)/children/\(childIndex)")
                    }
                }
            }
            for (undrawnPath, key) in undrawn {
                issues.append(.init(
                    severity: .error, path: undrawnPath,
                    message: "No reader draws a \(key) here, so its words would be lost: put it where it is drawn (a figure's title, caption or notes)."
                ))
                failed = true
            }
            for (idPath, id) in ids(in: block, at: blockPath) where !blockIDs.insert(id).inserted {
                issues.append(.init(
                    severity: .error, path: idPath,
                    message: "Another block of this volume has the id \u{201C}\(id)\u{201D}; a link to it could open either."
                ))
                failed = true
            }
            // Each text the block draws held to what every 2.3 text is held
            // to (Rule B1), as written, before the projection clips it: a
            // note span or marker outside its text was dropped there, unseen,
            // where in plain text it is refused. Found by Codex.
            for line in LampBookDrawnText.lines(of: block, figures: .asParts) {
                for field in line {
                    guard let encoded = try? JSONEncoder().encode(field.text),
                          let written = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
                    else { continue }
                    _ = writtenForOlderReaders(written, path: blockPath, issues: &issues)
                }
            }
            ModuleJSONInspector.warnAboutDeadLinks(object, path: blockPath, containingKind: "commentary", issues: &issues)
            ModuleJSONInspector.warnAboutTableLayout(object, path: blockPath, issues: &issues)
            for (childIndex, child) in ((object["children"] as? [Any]) ?? []).enumerated() where block.type == "figure" {
                ModuleJSONInspector.warnAboutTableLayout(
                    child as? [String: Any], path: "\(blockPath)/children/\(childIndex)", issues: &issues
                )
            }
            blocks.append(block)
        }
        guard !failed,
              let blocksJSON = try? JSONSupport.jsonString(rawBlocks) ?? "[]"
        else { return nil }
        let projection = LampBookDrawnText.projection(of: blocks, figures: .asParts, keeping: keptByOlderReaders)
        return Body(
            blocksJSON: blocksJSON,
            legacy: olderReadersCopy(of: projection),
            searchText: projection.text.replacingOccurrences(of: "\0", with: " ")
        )
    }

    /// The notes an annotated text cites, each once, in the order it cites
    /// them: by a marker, then by an inline span's `id` or its data's note.
    /// The one reading of what a row's text needs its row to carry, for a
    /// 2.3 unit whether its body is blocks or written as today: read by its
    /// markers alone, a note cited by a span went to another row, where the
    /// span could not open it. Found by Codex, over several reviews.
    static func citedFootnoteIDs(in text: [String: Any]?) -> [String] {
        guard let text, let words = text["text"] as? String else { return [] }
        let length = words.unicodeScalars.count
        // Each at its place in the text, and only one the phone draws: a
        // marker within the text, a span over words. Counted otherwise, a
        // marker past the end or a span over nothing stood for a citation
        // no reader could open. Found by Codex. In reading order, so the
        // notes a row carries are too.
        var placed: [(at: Int, kind: Int, index: Int, id: String)] = []
        for (index, reference) in ((text["footnote_refs"] as? [Any]) ?? []).enumerated() {
            guard let marker = reference as? [String: Any], let id = marker["id"] as? String,
                  let offset = wholeNumber(marker["offset"]), offset >= 0, offset <= length else { continue }
            placed.append((offset, 0, index, id))
        }
        for (index, value) in ((text["annotations"] as? [Any]) ?? []).enumerated() {
            guard let annotation = value as? [String: Any], annotation["type"] as? String == "footnote",
                  phoneReads(annotation),
                  let start = wholeNumber(annotation["start"]), let end = wholeNumber(annotation["end"]),
                  start >= 0, start < end, end <= length else { continue }
            // Both, where a span gives an id and a note that differ.
            for id in [annotation["id"] as? String, (annotation["data"] as? [String: Any])?["footnoteId"] as? String] {
                if let id { placed.append((start, 1, index, id)) }
            }
        }
        var cited: [String] = []
        var seen = Set<String>()
        for entry in placed.sorted(by: { ($0.at, $0.kind, $0.index) < ($1.at, $1.kind, $1.index) })
        where seen.insert(entry.id).inserted {
            cited.append(entry.id)
        }
        return cited
    }

    /// The ids a block's readers find it, and a figure's children, by.
    private static func ids(in block: LampBookContentBlock, at path: String) -> [(String, String)] {
        [block.id.map { ("\(path)/id", $0) }].compactMap { $0 }
            + block.children.enumerated().flatMap { ids(in: $1, at: "\(path)/children/\($0)") }
    }

    /// The text fields of a block, as written, that its lines do not draw:
    /// each taken away in turn, and the block laid out again by the walk.
    /// A figure's children are checked as the walk reads them, by their parts.
    private static func undrawnFields(
        of object: [String: Any], figures: LampBookDrawnText.Figures, at path: String
    ) -> [(String, String)] {
        func lines(_ value: [String: Any]) -> [[LampBookDrawnText.Field]]? {
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let block = try? JSONDecoder().decode(LampBookContentBlock.self, from: data)
            else { return nil }
            return LampBookDrawnText.lines(of: block, figures: figures)
        }
        guard let drawn = lines(object) else { return [] }
        var undrawn: [(String, String)] = []
        for key in ["content", "caption", "title", "subtitle", "notes", "items", "rows", "children", "legend"] {
            guard let value = object[key], holdsSomething(value) else { continue }
            var without = object
            without.removeValue(forKey: key)
            // A figure's children are blocks of their own, each checked; the
            // figure draws them, so they are drawn.
            if key == "children", JSONSupport.string(object["type"]) == "figure" { continue }
            if lines(without) == drawn { undrawn.append(("\(path)/\(key)", key)) }
        }
        return undrawn
    }

    private static func holdsSomething(_ value: Any) -> Bool {
        !(value is NSNull)
            && (value as? String)?.isEmpty != true
            && (value as? [Any])?.isEmpty != true
            && (value as? [String: Any])?.isEmpty != true
    }

    /// Rule B1: a 2.3 text as an older commentary reader opens it,
    /// additions only — a `scripture` or `crossref` given only `refs` gains
    /// the first as `sv`/`ev`, all that reader opens; a footnote span given
    /// `data.footnoteId` gains it as `id`, how that reader opens one —
    /// nothing removed, moved or reordered, so it is the same given twice,
    /// and a text written as 2.2 writes it comes out as it went in. What
    /// would blank the text on that reader is refused at `path`: `text` not
    /// words, or a marker without a word `id` and a whole-number `offset`.
    static func writtenForOlderReaders(
        _ text: [String: Any], path: String, issues: inout [ModuleValidationIssue]
    ) -> [String: Any] {
        var text = text
        if !(text["text"] is String) {
            issues.append(.init(severity: .error, path: path, message: "A text's words must be a string; an older reader shows none otherwise."))
        }
        if let references = text["footnote_refs"], !(references is NSNull), !(references is [Any]) {
            issues.append(.init(severity: .error, path: path, message: "A text's footnote markers must be a list; an older reader shows none of this text otherwise."))
        }
        let length = (text["text"] as? String)?.unicodeScalars.count ?? 0
        for reference in (text["footnote_refs"] as? [Any]) ?? [] {
            let marker = reference as? [String: Any]
            // Within its text: past it, one reader hides it and another
            // draws a marker at the end that opens nothing. Found by Codex.
            if let offset = wholeNumber(marker?["offset"]), offset < 0 || offset > length {
                issues.append(.init(severity: .error, path: path, message: "A footnote marker falls outside its text (offset \(offset) in \(length))."))
            }
            // A whole number as the phone reads one: 1.5 is not one, though
            // read loosely it was taken as 1. Found by Codex.
            if !(marker?["id"] is String) || wholeNumber(marker?["offset"]) == nil {
                issues.append(.init(
                    severity: .error, path: path,
                    message: "A footnote marker needs an id, as words, and a whole-number offset; an older reader shows none of this text otherwise."
                ))
            }
        }
        // A list, or the phone reads none of it. Found by Codex.
        if let given = text["annotations"], !(given is NSNull), !(given is [Any]) {
            issues.append(.init(severity: .error, path: path, message: "A text's annotations must be a list; an older reader reads none otherwise."))
        }
        guard var annotations = text["annotations"] as? [Any] else { return text }
        for index in annotations.indices {
            guard var annotation = annotations[index] as? [String: Any] else { continue }
            // One note per span: an `id` and a `data.footnoteId` that differ
            // open one note on an older reader and another on a newer.
            // Found by Codex.
            if annotation["type"] as? String == "footnote",
               let id = annotation["id"] as? String,
               let note = (annotation["data"] as? [String: Any])?["footnoteId"] as? String, id != note {
                issues.append(.init(
                    severity: .error, path: path,
                    message: "A footnote span names two notes, \u{201C}\(id)\u{201D} and \u{201C}\(note)\u{201D}; readers would open different ones."
                ))
            }
            // A note span over words of its own text: one running past it is
            // skipped by one reader and cut short by another. Found by Codex.
            if annotation["type"] as? String == "footnote",
               let start = wholeNumber(annotation["start"]), let end = wholeNumber(annotation["end"]),
               !(start >= 0 && start < end && end <= length) {
                issues.append(.init(severity: .error, path: path, message: "A footnote span covers no words of its text (\(start)–\(end) in \(length))."))
            }
            if annotation["type"] as? String == "footnote", !phoneReads(annotation) {
                issues.append(.init(
                    severity: .error, path: path,
                    message: "A footnote span here is one an older reader cannot read, so its note would not open: its offsets, id and data must be of the kinds that reader reads."
                ))
            }
            var payload = annotation["data"] as? [String: Any] ?? [:]
            switch annotation["type"] as? String {
            // A `null` is none. Found by Codex.
            case "scripture" where payload["sv"] == nil || payload["sv"] is NSNull,
                 "crossref" where payload["sv"] == nil || payload["sv"] is NSNull:
                // Added, never changed: an `ev` written with no `sv` is an end
                // with no start, refused rather than replaced. Found by Codex.
                if let end = payload["ev"], !(end is NSNull) {
                    issues.append(.init(severity: .error, path: path, message: "A passage gives where it ends (ev) but not where it starts (sv)."))
                } else if let first = (payload["refs"] as? [[String: Any]])?.first, let start = first["sv"] {
                    payload["sv"] = start
                    if let end = first["ev"] { payload["ev"] = end }
                    annotation["data"] = payload
                }
            case "footnote" where annotation["id"] == nil || annotation["id"] is NSNull:
                if let id = payload["footnoteId"] as? String {
                    annotation["id"] = id
                } else {
                    // A note span naming no note in words opens nothing on
                    // any reader. Found by Codex.
                    issues.append(.init(severity: .error, path: path, message: "A footnote span names no note, as words, in its id or data.footnoteId."))
                }
            default:
                break
            }
            // A tap the phone would lose: an annotation that opens a note, a
            // passage or a word, which it passes over whole if any field is
            // not of the kind it reads, as an unreadable `refs` entry. Judged
            // after the fill-ins above, which add and never rewrite. Found by
            // Codex.
            // An offset no text reaches, which the phone's reading of an
            // encoded span moves by adding to it, past `Int.max`: the phone
            // traps, in its offset reader in iOS ModuleModels.swift. Found
            // by Codex.
            if [annotation["start"], annotation["end"]].contains(where: { (wholeNumber($0) ?? 0) > Int(Int32.max) }) {
                issues.append(.init(
                    severity: .error, path: path,
                    message: "An annotation's offset is past any text's length (\(Int32.max)); an older reader cannot move it."
                ))
            }
            let tapping: Set<String> = ["footnote", "scripture", "crossref", "strongs", "lexicon-ref", "greek", "hebrew"]
            if let type = annotation["type"] as? String, tapping.contains(type), type != "footnote", !phoneReads(annotation) {
                issues.append(.init(
                    severity: .error, path: path,
                    message: "A \(type) annotation here is one an older reader cannot read, so it would open nothing: its offsets, id and data must be of the kinds that reader reads."
                ))
            }
            annotations[index] = annotation
        }
        text["annotations"] = annotations
        return text
    }

    /// Rule B2: an older reader's own copy of a blocks body, whose original
    /// is kept beside it: the projection, already held to the types that
    /// reader knows (`keptByOlderReaders`), with a page marked at a point
    /// written as its label where the resolver draws it, spaced as it spaces
    /// it, by an offset map — a span's start moved past labels at or before
    /// it, its end past those before it, split at any strictly inside it; a
    /// marker moved past labels before it — and markers at one place written
    /// in reverse, which that reader inserts by descending offset, so it
    /// shows them in the order written. Offsets count Unicode scalars.
    static func olderReadersCopy(of projection: LampBookAnnotatedText) -> [String: Any] {
        let scalars = Array(projection.text.unicodeScalars)
        /// A label as written in: its spacing either side, and its own
        /// `[p. N]`, which the page annotation covers.
        struct Label { let offset: Int; let order: Int; let leading: Int; let core: Int; let scalars: [Unicode.Scalar] }
        var labels: [Label] = []
        for (order, annotation) in projection.annotations.enumerated()
        where annotation.type == "page" && annotation.start == annotation.end {
            guard let marker = LampBookTextResolver.pageMarker(annotation, length: scalars.count) else { continue }
            let offset = marker.offset
            let before = offset > 0 && !scalars[offset - 1].properties.isWhitespace ? " " : ""
            let after = offset < scalars.count && !scalars[offset].properties.isWhitespace ? " " : ""
            let core = "[p. \(marker.page)]".unicodeScalars.count
            labels.append(Label(
                offset: offset, order: order, leading: before.unicodeScalars.count, core: core,
                scalars: Array("\(before)[p. \(marker.page)]\(after)".unicodeScalars)
            ))
        }
        labels.sort { ($0.offset, $0.order) < ($1.offset, $1.order) }
        // Shifts read from prefix sums by binary search, not by every label
        // each time: a long body with many pages took time growing as their
        // square. Found by Codex.
        let offsets = labels.map(\.offset)
        var sums = [0]
        for label in labels { sums.append(sums.last! + label.scalars.count) }
        func shift(before point: Int, including: Bool) -> Int {
            var low = 0, high = offsets.count
            while low < high {
                let middle = (low + high) / 2
                if including ? offsets[middle] <= point : offsets[middle] < point { low = middle + 1 } else { high = middle }
            }
            return sums[low]
        }
        let orderIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1.order, $0) })

        var text: [Unicode.Scalar] = []
        var cursor = 0
        for label in labels {
            text += scalars[cursor..<label.offset]
            text += label.scalars
            cursor = label.offset
        }
        text += scalars[cursor...]

        var annotations: [[String: Any]] = []
        for (order, annotation) in projection.annotations.enumerated() {
            guard let encoded = try? JSONEncoder().encode(annotation),
                  var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
            else { continue }
            // Bold and italic as their own types, which the oldest phone that
            // reads 2.3 (iOS 22b59eb) knows where it skips `emphasis`. Found
            // by Codex. The blocks keep the emphasis as written.
            // An emphasis with no style is italic, as the resolver draws it.
            // Found by Codex.
            if annotation.type == "emphasis", annotation.data?.style != "underline" {
                object["type"] = annotation.data?.style == "bold" ? "bold" : "italic"
                object["data"] = nil
            }
            if let position = orderIndex[order] {
                let label = labels[position]
                // Its own label, after any written before it at its place:
                // the labels before it in sorted order are those before its
                // place and those earlier at it.
                let start = label.offset + sums[position] + label.leading
                object["start"] = start
                object["end"] = start + label.core
                annotations.append(object)
                continue
            }
            // The labels strictly inside the span, found by search.
            var cuts: [Int] = []
            if annotation.start < annotation.end {
                var low = 0, high = offsets.count
                while low < high {
                    let middle = (low + high) / 2
                    if offsets[middle] <= annotation.start { low = middle + 1 } else { high = middle }
                }
                while low < offsets.count, offsets[low] < annotation.end {
                    if cuts.last != offsets[low] { cuts.append(offsets[low]) }
                    low += 1
                }
            }
            let bounds = [annotation.start] + cuts + [annotation.end]
            for (lower, upper) in zip(bounds, bounds.dropFirst()) {
                var piece = object
                piece["start"] = lower + shift(before: lower, including: true)
                piece["end"] = upper + shift(before: upper, including: false)
                // Split, neither piece is the words the span was.
                if !cuts.isEmpty { piece["text"] = nil }
                annotations.append(piece)
            }
        }
        var references = projection.footnoteReferences.enumerated().map { index, reference in
            (index, ["id": reference.id, "offset": reference.offset + shift(before: reference.offset, including: false)] as [String: Any])
        }
        // At one place, in reverse: inserted from the highest offset down,
        // each at its place, the last written of two would land first.
        references.sort {
            let a = $0.1["offset"] as! Int, b = $1.1["offset"] as! Int
            return a != b ? a < b : $0.0 > $1.0
        }
        var object: [String: Any] = ["text": String(String.UnicodeScalarView(text))]
        if !annotations.isEmpty { object["annotations"] = annotations }
        if !references.isEmpty { object["footnote_refs"] = references.map(\.1) }
        return object
    }

    /// Both rules together, as a blocks body's copy for an older reader is
    /// written: B2, then B1.
    static func legacyForm(of projection: LampBookAnnotatedText) -> [String: Any] {
        var ignored: [ModuleValidationIssue] = []
        return writtenForOlderReaders(olderReadersCopy(of: projection), path: "", issues: &ignored)
    }
}
