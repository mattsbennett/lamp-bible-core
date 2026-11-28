import Foundation

/// Detects Lamp module JSON and performs fast structural and semantic checks.
///
/// JSON Schema remains canonical in this package's `Schemas/`. This inspector
/// adds checks that JSON Schema cannot express well, such as BBCCCVVV consistency
/// and duplicate entry keys.
public struct ModuleJSONInspector: Sendable {
    /// The commentary versions this build compiles: `meta.schemaVersion`'s
    /// enum in `Schemas/commentary_schema.json`, as far as it is supported.
    static let commentaryVersions: Set<String> = ["1.0", "2.0", "2.1", "2.2"]

    public init() {}

    /// `sourceFilename` is the file the JSON came from, where there is one.
    /// A module that declares no ID takes that filename's stem as its ID
    /// (`LampModuleCompiler.compile`), so without it an inspection cannot
    /// say what the module will be called, nor whether that is storable.
    public func inspect(_ data: Data, sourceFilename: String? = nil) throws -> ModuleInspection {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModuleInspectionError.invalidJSON(error.localizedDescription)
        }

        guard let root = json as? [String: Any] else {
            throw ModuleInspectionError.rootMustBeObject
        }
        return inspect(root: root, sourceFilename: sourceFilename)
    }

    func inspect(root: [String: Any], sourceFilename: String? = nil) -> ModuleInspection {
        let meta = object(root["meta"]) ?? root
        let declaredType = string(meta["type"]) ?? string(root["type"])
        let kind = declaredType.flatMap(LampModuleKind.init(schemaValue:)) ?? inferKind(root: root, meta: meta)
        let metadata = ModuleMetadataSummary(
            id: string(meta["id"]) ?? string(root["id"]),
            name: string(meta["name"]) ?? string(meta["title"]) ?? string(root["name"]),
            schemaVersion: string(meta["schemaVersion"]),
            declaredType: declaredType
        )

        var issues: [ModuleValidationIssue] = []
        if kind == nil {
            issues.append(.init(
                severity: .error,
                path: declaredType == nil ? "/meta/type" : "/meta/type",
                message: declaredType.map { "Unsupported module type ‘\($0)’." }
                    ?? "Could not detect the module type."
            ))
        }

        if let kind {
            validateRequiredStructure(kind: kind, root: root, meta: meta, issues: &issues)
            validateIdentifier(metadata.id, sourceFilename: sourceFilename, issues: &issues)
            validateSemantics(kind: kind, root: root, issues: &issues)
        }

        return ModuleInspection(
            kind: kind,
            metadata: metadata,
            statistics: statistics(kind: kind, root: root),
            issues: issues.sorted(by: issueSort)
        )
    }

    private func inferKind(root: [String: Any], meta: [String: Any]) -> LampModuleKind? {
        if root["books"] is [Any] { return .translation }
        if root["entries"] is [Any] { return .dictionary }

        if root["days"] is [Any] {
            if meta["planId"] != nil || meta["ageGroups"] != nil { return .quiz }
            return .plan
        }

        if root["verses"] is [Any], meta["translationId"] != nil { return .highlights }
        if root["sections"] is [Any], meta["title"] != nil { return .book }
        if root["content"] != nil, meta["title"] != nil { return .devotional }

        if root["chapters"] is [Any], root["book"] != nil {
            if meta["seriesFull"] != nil || meta["seriesAbbrev"] != nil || meta["title"] != nil {
                return .commentary
            }
            return .notes
        }

        return nil
    }

    private func validateRequiredStructure(
        kind: LampModuleKind,
        root: [String: Any],
        meta: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        requireObject(root, key: "meta", issues: &issues)

        switch kind {
        case .translation:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "name", "abbreviation", "language"], issues: &issues)
            requireArray(root, key: "books", issues: &issues)
        case .dictionary:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "name"], issues: &issues)
            requireArray(root, key: "entries", issues: &issues)
        case .commentary:
            requireStrings(meta, keys: ["schemaVersion", "seriesAbbrev", "seriesFull"], issues: &issues)
            // A version this compiler does not know is refused, not read as
            // the nearest one it does: a 2.3 note given as `blocks` alone
            // compiled to an empty unit that looked valid. Found by the
            // converter's run of today's tools.
            if let version = string(meta["schemaVersion"]),
               !Self.commentaryVersions.contains(version) {
                issues.append(.init(
                    severity: .error,
                    path: "/meta/schemaVersion",
                    message: "Commentary version \(version) is not one this build reads (\(Self.commentaryVersions.sorted().joined(separator: ", "))); building it would lose what it adds."
                ))
            }
            if (string(meta["title"]) ?? string(meta["name"]))?.isEmpty != false {
                issues.append(.init(
                    severity: .error,
                    path: "/meta/title",
                    message: "Expected a non-empty title or name."
                ))
            }
            requireInteger(root, key: "bookNumber", issues: &issues)
            requireString(root, key: "book", basePath: "", issues: &issues)
            requireArray(root, key: "chapters", issues: &issues)
            warnAboutMixedSourceOrder(root: root, issues: &issues)
        case .book:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "title", "language"], issues: &issues)
            requireArray(root, key: "sections", issues: &issues)
        case .devotional:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "title"], issues: &issues)
            if root["content"] == nil {
                issues.append(.init(severity: .error, path: "/content", message: "Missing required content."))
            }
        case .notes:
            requireStrings(meta, keys: ["id", "type"], issues: &issues)
            requireInteger(root, key: "bookNumber", issues: &issues)
            requireString(root, key: "book", basePath: "", issues: &issues)
            requireArray(root, key: "chapters", issues: &issues)
        case .plan:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "name"], issues: &issues)
            requireArray(root, key: "days", issues: &issues)
        case .highlights:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "translationId"], issues: &issues)
            requireArray(root, key: "verses", issues: &issues)
        case .quiz:
            requireStrings(meta, keys: ["schemaVersion", "id", "type", "planId", "name"], issues: &issues)
            guard meta["ageGroups"] is [Any] else {
                issues.append(.init(severity: .error, path: "/meta/ageGroups", message: "Expected an array."))
                return
            }
            requireArray(root, key: "days", issues: &issues)
        }
    }

    private func validateIdentifier(
        _ declared: String?,
        sourceFilename: String?,
        issues: inout [ModuleValidationIssue]
    ) {
        // The ID the module will actually be built with, not the one it
        // wrote. Two things this used to miss:
        //
        // `LampModuleCompiler.compile` uses `metadata.id ?? sourceStem`, so
        // a module declaring no ID takes its filename — and that was checked
        // nowhere, while the Mac's installer refused it. A commentary volume
        // usually declares none, so its filename *is* its ID.
        //
        // And commentary was skipped outright, on the reasoning that its
        // `/meta/id` is not the module's ID. But a commentary that declares
        // one is built with it, like every other kind, so skipping it hid a
        // real fault rather than avoiding a false one.
        //
        // A warning, not an error: the compiler deliberately does not refuse
        // an unsafe ID, because the iPhone compiles a JSON book through it
        // and a book whose ID holds "+" imports there today (core 978eb6a).
        // This is where an author is told; the installer is where it stops.
        let stem = sourceFilename.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
        guard let effective = declared ?? stem,
              !effective.isEmpty,
              !LampModuleIdentifier.isValid(effective)
        else { return }

        issues.append(.init(
            severity: .warning,
            path: declared == nil ? "/" : "/meta/id",
            message: declared == nil
                ? "This module declares no ID, so it is built as ‘\(effective)’, after the file it came from. Name the file with \(LampModuleIdentifier.advice)."
                : "Use \(LampModuleIdentifier.advice)."
        ))
    }

    private func validateSemantics(
        kind: LampModuleKind,
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        switch kind {
        case .translation:
            validateTranslationReferences(root: root, issues: &issues)
        case .dictionary:
            validateDictionaryKeys(root: root, issues: &issues)
        case .book:
            validateBook(root: root, issues: &issues)
        case .devotional:
            if let content = root["content"], !JSONSupport.isMeaningful(content) {
                issues.append(.init(
                    severity: .error,
                    path: "/content",
                    message: "Expected non-empty devotional content."
                ))
            }
        case .plan:
            validatePlanDays(root: root, issues: &issues)
        case .notes:
            validateNotes(root: root, issues: &issues)
        case .highlights:
            validateHighlights(root: root, issues: &issues)
        case .quiz:
            validateQuiz(root: root, issues: &issues)
        case .commentary:
            validateRichCommentary(root: root, issues: &issues)
        }
    }

    /// What building a 2.3 volume finds — a body given twice, a block the
    /// model does not read whole, an id given twice, a link that opens
    /// nothing — told by the builder itself, dry, so the inspector reads a
    /// unit no way the compiler does not. A volume of an earlier version is
    /// built as it always was, and finds nothing new.
    private func validateRichCommentary(root: [String: Any], issues: inout [ModuleValidationIssue]) {
        // Read without its chapters too, where they are no list: its front
        // matter and media are apart from them. Found by Codex.
        // And without a book number it can use, whose fault is told where
        // the volume's fields are. Found by Codex.
        guard object(root["meta"]).flatMap({ string($0["schemaVersion"]) }) == "2.3" else { return }
        // A whole book number, 1 to 66, told once, and only such a number
        // used: `43.5` was read as 43, and 67.5 told twice. Found by Codex.
        let given = JSONSupport.integer(root["bookNumber"])
        let whole = LampCommentaryBlocks.wholeNumber(root["bookNumber"])
        let bookNumber = whole.flatMap { (1...66).contains($0) ? $0 : nil }
        if given != nil, bookNumber == nil {
            issues.append(.init(severity: .error, path: "/bookNumber", message: "A 2.3 volume's book is a whole number, 1 to 66."))
        }
        let chapters = bookNumber == nil ? nil : array(root["chapters"])
        var builder = CommentaryUnitBuilder(
            moduleID: "inspect",
            bookNumber: bookNumber ?? 0,
            footnotes: array(root["footnotes"]) ?? [],
            sourceOrdered: object(root["extraction"])?["sourceTracked"] as? Bool == true,
            rich: true
        )
        builder.hasTopLevelFootnoteIDs = root["footnoteIds"] != nil
        // The notes a 2.3 volume defines are one list. Found by Codex.
        if let given = root["footnotes"], !(given is NSNull), !(given is [Any]) {
            issues.append(.init(severity: .error, path: "/footnotes", message: "Expected a list of notes."))
        }
        do {
            if let chapters { try builder.append(chapters: chapters) }
        } catch ModuleCompilationError.missingValue(let path) {
            issues.append(.init(severity: .error, path: path, message: "Expected a value here."))
        } catch ModuleCompilationError.invalidValue(let path, let expected) {
            issues.append(.init(severity: .error, path: path, message: "Expected \(expected)."))
        } catch {
            issues.append(.init(severity: .error, path: "/chapters", message: "The volume's units cannot be built."))
        }
        // Read whether or not the units could be: their faults and these are
        // apart, and told in one inspection. Found by Codex.
        builder.append(frontMatter: root["frontMatter"], media: root["media"])
        issues += builder.issues
    }

    /// A warning for a block whose link or scripture targets a reader of the
    /// module will not follow — one written wrong, a passage whose range runs
    /// backwards, a commentary named without its module, a scripture note
    /// that is not a passage — so it is found before the module ships, not as
    /// words that link nowhere. Judged by the resolver's own rule
    /// (`LampBookTextResolver.usableTarget`), in the module's own kind, on
    /// the texts a reader reads: the block's lines as `LampBookDrawnText`
    /// walks them, a figure by its parts — what a reader that knows figures
    /// draws, and what a compiler projects — and by its stored `content`,
    /// which today's readers draw. Read its own way, the check took
    /// a title, second line or notes on any block, which no reader draws.
    /// Found by Codex, over three reviews, and in planning step 4.
    static func warnAboutDeadLinks(
        _ block: [String: Any]?, path: String, containingKind: String, issues: inout [ModuleValidationIssue]
    ) {
        guard let block,
              let data = try? JSONSerialization.data(withJSONObject: block),
              let decoded = try? JSONDecoder().decode(LampBookContentBlock.self, from: data)
        else { return }
        // A figure both ways: by its parts, as a reader that knows figures
        // draws it and a compiler projects it, and by the `content` stored
        // beside them, which today's readers draw. Found by Codex.
        let readings: [LampBookDrawnText.Figures] = decoded.type == "figure" ? [.asParts, .asContent] : [.asParts]
        let texts = readings.flatMap { LampBookDrawnText.lines(of: decoded, figures: $0).joined().map(\.text) }
        Self.warnAboutDeadLinks(in: texts, path: path, containingKind: containingKind, issues: &issues)
    }

    static func warnAboutDeadLinks(
        in texts: [LampBookAnnotatedText], path: String, containingKind: String,
        strictBounds: Bool = false, issues: inout [ModuleValidationIssue]
    ) {
        // A link is dead when it is tapped on no words, or names nowhere a
        // reader opens. Each case found by Codex:
        // - a target the resolver will not follow;
        // - a passage naming none, whose first passage (the one opened, read
        //   directly rather than by gathering every one) ends before it
        //   starts, or lies in no Bible book's chapter (verse 0, a psalm's
        //   title, is one);
        // - a web link naming nothing a URL can be made of, or with no scheme
        //   to be read without a base.
        // A text's length is counted once, not once per link. Found by Codex.
        var dead = 0
        for text in texts where !text.annotations.isEmpty {
            let length = text.text.unicodeScalars.count
            let covers = { (annotation: LampBookAnnotation) in
                strictBounds
                    ? annotation.start >= 0 && annotation.start < annotation.end && annotation.end <= length
                    : LampBookTextResolver.coveredScalars(annotation.start, annotation.end, length: length) != nil
            }
            let real = { (reference: Int) in (1...66).contains(reference / 1_000_000) && reference / 1_000 % 1_000 > 0 }
            dead += text.annotations.filter { annotation in
                let passage = annotation.type == "scripture" || annotation.type == "crossref"
                let first = annotation.data?.startReference.map { ($0, annotation.data?.endReference) }
                    ?? annotation.data?.references.first.map { ($0.startReference, $0.endReference) }
                let deadPassage = first.map { start, end in (end ?? start) < start || !real(start) || !(end.map(real) ?? true) } ?? true
                if annotation.data?.hasTargetField == true {
                    // Its passage too, which a reader that ignores targets
                    // opens. Found by Codex.
                    return LampBookTextResolver.usableTarget(for: annotation, containingKind: containingKind) == nil
                        || !covers(annotation) || (passage && first != nil && deadPassage)
                }
                if passage { return !covers(annotation) || deadPassage }
                // A media annotation is none of these: placed at a point, as
                // the schema's inline form is, it is drawn by its id. Warned
                // of as over no words, a working picture was called dead.
                // Found by Codex.
                return annotation.type == "link"
                    && (!covers(annotation) || annotation.data?.url.flatMap(URL.init(string:)).flatMap(\.scheme) == nil)
            }.count
        }
        guard dead > 0 else { return }
        issues.append(.init(
            severity: .warning,
            path: path,
            message: "\(dead) link\(dead == 1 ? "" : "s") here name\(dead == 1 ? "s" : "") no place a reader of this \(containingKind) can open."
        ))
    }

    /// A warning for a source-tracked commentary whose pericopae give a
    /// `sourceOrder` some of the time: one without is read at its place among
    /// all of them, where the modules repository's Python read it as 0, so
    /// the two writers ordered such a volume differently. No volume there
    /// mixes them; the warning says where one does. Found by Codex,
    /// reviewing the series compiler.
    private func warnAboutMixedSourceOrder(root: [String: Any], issues: inout [ModuleValidationIssue]) {
        guard object(root["extraction"])?["sourceTracked"] as? Bool == true else { return }
        var given = 0
        var omitted = 0
        for chapter in array(root["chapters"]) ?? [] {
            for pericope in array(object(chapter)?["pericopae"]) ?? [] {
                // An order the builder can use; one that is null, or a
                // string, is read at its place like none at all. Found by
                // Codex.
                if JSONSupport.integer(object(pericope)?["sourceOrder"]) == nil { omitted += 1 } else { given += 1 }
            }
        }
        guard given > 0, omitted > 0 else { return }
        issues.append(.init(
            severity: .warning,
            path: "/chapters",
            message: "\(omitted) of \(given + omitted) pericopae give no sourceOrder, and are read at their place among the rest; give every one an order, or none."
        ))
    }

    /// A warning for a table wider than readers lay out, with a cell at a
    /// column no reader shows, or with a cell reaching down fewer rows than
    /// it says.
    ///
    /// A warning, not an error: the module can be stored, and readers show it
    /// clipped to `LampBookTableLayout.maximumColumnCount`. Refusing it would
    /// make a book that opens on one device open on none, which the
    /// repository has already tried for IDs and undone
    /// (`LampModuleCompiler.compile`).
    static func warnAboutTableLayout(
        _ block: [String: Any]?, path: String, issues: inout [ModuleValidationIssue]
    ) {
        guard let block, JSONSupport.string(block["type"]) == "table" else { return }
        // Read as the readers read it, so the warning describes what they
        // show: a span of 65.5 is not clipped to 64, it makes the table
        // unreadable, and the readers leave the whole of it out. Found by
        // Codex.
        guard let data = try? JSONSerialization.data(withJSONObject: block),
              let table = try? JSONDecoder().decode(LampBookContentBlock.self, from: data)
        else {
            issues.append(.init(
                severity: .warning,
                path: path,
                message: "Readers cannot read this table, and leave it out."
            ))
            return
        }
        let bound = LampBookTableLayout.maximumColumnCount
        let cells = table.rows.flatMap(\.cells)
        let widest = max(
            table.columnCount ?? 0,
            cells.filter { $0.column >= 0 }.map(LampBookTableLayout.reach(of:)).max() ?? 0
        )
        if widest > bound {
            issues.append(.init(
                severity: .warning,
                path: path,
                message: "This table reaches \(widest == .max ? "past every" : "\(widest)") columns; readers show the first \(bound), and leave out any cell past them."
            ))
        }
        // A cell with words the layout does not place — under another's
        // span, or a second at one column — is drawn by no reader, its words
        // lost from search and a projection. Found by Codex.
        let columnCount = LampBookTableLayout.resolvedColumnCount(declared: table.columnCount, rows: table.rows)
        let hidden = table.rows.reduce(0) { count, row in
            let placed = LampBookTableLayout.placements(of: row, columnCount: columnCount).compactMap(\.cell)
            var unplaced = placed
            return count + row.cells.filter { cell in
                // Judged as the layout judges a cell holding nothing: a
                // footnote marker alone is something. Found by Codex.
                guard cell.column >= 0, cell.column < columnCount, !LampBookTableLayout.isBlank(cell) else { return false }
                if let index = unplaced.firstIndex(of: cell) {
                    unplaced.remove(at: index)
                    return false
                }
                return true
            }.count
        }
        if hidden > 0 {
            issues.append(.init(
                severity: .warning,
                path: path,
                message: "\(hidden) cell\(hidden == 1 ? "" : "s") in this table holding words or a marker \(hidden == 1 ? "is" : "are") covered by another's colSpan or share\(hidden == 1 ? "s" : "") its column; readers show neither the cell nor what it holds."
            ))
        }
        if cells.contains(where: { $0.column < 0 }) {
            issues.append(.init(
                severity: .warning,
                path: path,
                message: "A cell in this table names a negative column; readers leave it out."
            ))
        }
        // A rowSpan the grid cuts short: a cell with words below, kept
        // rather than hidden, the table's end, or a blank cell's own span
        // under another's. Not laid out at all for a table spanning no rows.
        // Found by Codex.
        let shortened = cells.contains { $0.rowSpan > 1 }
            ? LampBookTableLayout.shortenedSpans(
                of: table.rows,
                columnCount: LampBookTableLayout.resolvedColumnCount(declared: table.columnCount, rows: table.rows)
            )
            : 0
        if shortened > 0 {
            issues.append(.init(
                severity: .warning,
                path: path,
                message: "\(shortened) cell\(shortened == 1 ? "" : "s") in this table reach\(shortened == 1 ? "es" : "") down fewer rows than \(shortened == 1 ? "its" : "their") rowSpan: laid out by rows, a span stops above a cell that holds anything and at the table's end, and a blank cell under another's span is left out."
            ))
        }
    }

    private func validateBook(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        // A footnote's links, read and judged as a paragraph's are. Found by
        // Codex.
        for (index, value) in (array(root["footnotes"]) ?? []).enumerated() {
            guard let data = object(value).flatMap({ try? JSONSerialization.data(withJSONObject: $0) }),
                  let note = try? JSONDecoder().decode(LampBookFootnote.self, from: data)
            else { continue }
            Self.warnAboutDeadLinks(
                in: [note.content.annotatedText], path: "/footnotes/\(index)/content",
                containingKind: "book", issues: &issues
            )
        }
        guard let sections = array(root["sections"]) else { return }
        if sections.isEmpty {
            issues.append(.init(
                severity: .error,
                path: "/sections",
                message: "Expected at least one book section."
            ))
            return
        }

        let allowedTypes: Set<String> = [
            "front-matter", "part", "chapter", "section",
            "appendix", "back-matter", "other",
        ]
        var firstPathByID: [String: String] = [:]

        func validateSections(_ values: [Any], path: String) {
            for (index, value) in values.enumerated() {
                let sectionPath = "\(path)/\(index)"
                guard let section = object(value) else {
                    issues.append(.init(severity: .error, path: sectionPath, message: "Expected an object."))
                    continue
                }

                guard let id = string(section["id"]), !id.isEmpty else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/id",
                        message: "Expected a non-empty section ID."
                    ))
                    continue
                }
                if let firstPath = firstPathByID[id] {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/id",
                        message: "Duplicate section ID ‘\(id)’; it first appears at \(firstPath)/id."
                    ))
                } else {
                    firstPathByID[id] = sectionPath
                }

                if string(section["title"])?.isEmpty != false {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/title",
                        message: "Expected a non-empty section title."
                    ))
                }
                if let type = string(section["type"]), allowedTypes.contains(type) {
                    // Valid.
                } else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/type",
                        message: "Expected a supported book section type."
                    ))
                }

                let content = array(section["content"])
                let children = array(section["sections"])
                if section["content"] != nil, content == nil {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/content",
                        message: "Expected an array."
                    ))
                }
                if section["sections"] != nil, children == nil {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/sections",
                        message: "Expected an array."
                    ))
                }
                for (blockIndex, block) in (content ?? []).enumerated() {
                    let blockPath = "\(sectionPath)/content/\(blockIndex)"
                    Self.warnAboutTableLayout(object(block), path: blockPath, issues: &issues)
                    Self.warnAboutDeadLinks(object(block), path: blockPath, containingKind: "book", issues: &issues)
                    // And a figure's tables, laid out within the same bound —
                    // a figure's only: another block's `children` is never
                    // drawn. Found by Codex.
                    if string(object(block)?["type"]) == "figure" {
                        for (childIndex, child) in (array(object(block)?["children"]) ?? []).enumerated() {
                            Self.warnAboutTableLayout(
                                object(child), path: "\(blockPath)/children/\(childIndex)", issues: &issues
                            )
                        }
                        // Until a compiler writes a figure's words into its
                        // `content`, the readers draw that and nothing else.
                        // Found by Codex.
                        // Read as the readers read it: a figure whose fallback
                        // cannot be decoded is dropped whole. Found by Codex.
                        let decoded = object(block).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                            .flatMap { try? JSONDecoder().decode(LampBookContentBlock.self, from: $0) }
                        if decoded?.content?.text.isEmpty != false {
                            issues.append(.init(
                                severity: .warning,
                                path: blockPath,
                                message: "Readers draw a figure as its content, which this one has none of; give it the words to show."
                            ))
                        }
                    }
                }
                if (content?.isEmpty ?? true) && (children?.isEmpty ?? true) {
                    issues.append(.init(
                        severity: .error,
                        path: sectionPath,
                        message: "A book section needs content or child sections."
                    ))
                }

                if let orderValue = section["order"],
                   integer(orderValue).map({ $0 >= 0 }) != true {
                    issues.append(.init(
                        severity: .error,
                        path: "\(sectionPath)/order",
                        message: "Expected a non-negative integer."
                    ))
                }

                if let scriptureValues = section["keyScriptures"] {
                    guard let scriptures = array(scriptureValues) else {
                        issues.append(.init(
                            severity: .error,
                            path: "\(sectionPath)/keyScriptures",
                            message: "Expected an array."
                        ))
                        continue
                    }
                    for (scriptureIndex, scriptureValue) in scriptures.enumerated() {
                        let scripturePath = "\(sectionPath)/keyScriptures/\(scriptureIndex)"
                        guard let scripture = object(scriptureValue),
                              let start = integer(scripture["sv"]) else {
                            issues.append(.init(
                                severity: .error,
                                path: scripturePath,
                                message: "Expected an object with an integer sv reference."
                            ))
                            continue
                        }
                        if let endValue = scripture["ev"] {
                            guard let end = integer(endValue) else {
                                issues.append(.init(
                                    severity: .error,
                                    path: "\(scripturePath)/ev",
                                    message: "Expected an integer BBCCCVVV reference."
                                ))
                                continue
                            }
                            if end < start {
                                issues.append(.init(
                                    severity: .error,
                                    path: "\(scripturePath)/ev",
                                    message: "End reference \(end) precedes start reference \(start)."
                                ))
                            }
                        }
                    }
                }

                if let children {
                    validateSections(children, path: "\(sectionPath)/sections")
                }
            }
        }

        validateSections(sections, path: "/sections")
    }

    private func validateQuiz(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        validatePlanDays(root: root, issues: &issues)
        let meta = object(root["meta"])
        let ageGroups = array(meta?["ageGroups"]) ?? []
        var ageGroupIDs: Set<String> = []
        for (index, value) in ageGroups.enumerated() {
            let path = "/meta/ageGroups/\(index)"
            guard let group = object(value),
                  let id = string(group["id"]), !id.isEmpty,
                  let label = string(group["label"]), !label.isEmpty,
                  let ageRange = string(group["ageRange"]), !ageRange.isEmpty else {
                issues.append(.init(
                    severity: .error,
                    path: path,
                    message: "Expected non-empty id, label, and ageRange values."
                ))
                continue
            }
            if !ageGroupIDs.insert(id).inserted {
                issues.append(.init(
                    severity: .error,
                    path: "\(path)/id",
                    message: "Duplicate age-group ID ‘\(id)’."
                ))
            }
        }

        for (dayIndex, dayValue) in (array(root["days"]) ?? []).enumerated() {
            guard let day = object(dayValue) else { continue }
            for (readingIndex, readingValue) in (array(day["readings"]) ?? []).enumerated() {
                let readingPath = "/days/\(dayIndex)/readings/\(readingIndex)"
                guard let reading = object(readingValue),
                      let quizzes = object(reading["quizzes"]) else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(readingPath)/quizzes",
                        message: "Expected an object keyed by age-group ID."
                    ))
                    continue
                }
                for (ageGroupID, questionValue) in quizzes {
                    let path = "\(readingPath)/quizzes/\(ageGroupID)"
                    if !ageGroupIDs.contains(ageGroupID) {
                        issues.append(.init(
                            severity: .error,
                            path: path,
                            message: "Quiz questions use undefined age group ‘\(ageGroupID)’."
                        ))
                    }
                    guard let questions = array(questionValue) else {
                        issues.append(.init(severity: .error, path: path, message: "Expected an array."))
                        continue
                    }
                    for (questionIndex, value) in questions.enumerated() {
                        let questionPath = "\(path)/\(questionIndex)"
                        guard let question = object(value) else {
                            issues.append(.init(severity: .error, path: questionPath, message: "Expected an object."))
                            continue
                        }
                        for key in ["question", "answer"] where question[key].map(isMeaningfulText) != true {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/\(key)",
                                message: "Expected a string or annotated text."
                            ))
                        }
                        if string(question["theme"])?.isEmpty != false {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/theme",
                                message: "Expected a non-empty theme."
                            ))
                        }
                        if !(question["christFocused"] is Bool) {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/christFocused",
                                message: "Expected a Boolean."
                            ))
                        }
                        if array(question["references"]) == nil {
                            issues.append(.init(
                                severity: .error,
                                path: "\(questionPath)/references",
                                message: "Expected an array of verse references."
                            ))
                        }
                    }
                }
            }
        }
    }

    private func isMeaningfulText(_ value: Any) -> Bool {
        if let string = string(value) { return !string.isEmpty }
        return object(value).flatMap { string($0["text"]) }?.isEmpty == false
    }

    private func validateTranslationReferences(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let books = array(root["books"]) else { return }

        for (bookIndex, value) in books.enumerated() {
            guard let book = object(value), let bookNumber = integer(book["number"]),
                  let chapters = array(book["chapters"]) else { continue }

            for (chapterIndex, value) in chapters.enumerated() {
                guard let chapter = object(value), let chapterNumber = integer(chapter["chapter"]),
                      let verses = array(chapter["verses"]) else { continue }

                for (verseIndex, value) in verses.enumerated() {
                    guard let verse = object(value), let verseNumber = integer(verse["v"]),
                          let reference = integer(verse["ref"]) else { continue }
                    let expected = bookNumber * 1_000_000 + chapterNumber * 1_000 + verseNumber
                    if reference != expected {
                        issues.append(.init(
                            severity: .error,
                            path: "/books/\(bookIndex)/chapters/\(chapterIndex)/verses/\(verseIndex)/ref",
                            message: "Reference \(reference) does not match book \(bookNumber), chapter \(chapterNumber), verse \(verseNumber); expected \(expected)."
                        ))
                    }
                }
            }
        }
    }

    private func validateDictionaryKeys(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let entries = array(root["entries"]) else { return }
        var firstIndexByKey: [String: Int] = [:]

        for (index, value) in entries.enumerated() {
            guard let entry = object(value), let key = string(entry["key"]), !key.isEmpty else { continue }
            if let firstIndex = firstIndexByKey[key] {
                issues.append(.init(
                    severity: .error,
                    path: "/entries/\(index)/key",
                    message: "Duplicate entry key ‘\(key)’; it first appears at /entries/\(firstIndex)/key."
                ))
            } else {
                firstIndexByKey[key] = index
            }
        }
    }

    private func validatePlanDays(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let days = array(root["days"]) else { return }
        var firstIndexByDay: [Int: Int] = [:]

        for (dayIndex, value) in days.enumerated() {
            guard let day = object(value) else {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)",
                    message: "Expected an object."
                ))
                continue
            }
            guard let dayNumber = integer(day["day"]), (1...366).contains(dayNumber) else {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)/day",
                    message: "Expected a day number from 1 through 366."
                ))
                continue
            }
            if let firstIndex = firstIndexByDay[dayNumber] {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)/day",
                    message: "Duplicate day \(dayNumber); it first appears at /days/\(firstIndex)/day."
                ))
            } else {
                firstIndexByDay[dayNumber] = dayIndex
            }

            guard let readings = array(day["readings"]) else {
                issues.append(.init(
                    severity: .error,
                    path: "/days/\(dayIndex)/readings",
                    message: "Expected an array."
                ))
                continue
            }
            for (readingIndex, value) in readings.enumerated() {
                let path = "/days/\(dayIndex)/readings/\(readingIndex)"
                guard let reading = object(value),
                      let start = integer(reading["sv"]),
                      let end = integer(reading["ev"]) else {
                    issues.append(.init(
                        severity: .error,
                        path: path,
                        message: "Expected integer sv and ev references."
                    ))
                    continue
                }
                if start > end {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/ev",
                        message: "End reference \(end) precedes start reference \(start)."
                    ))
                }
            }
        }
    }

    private func validateNotes(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let bookNumber = integer(root["bookNumber"]),
              let chapters = array(root["chapters"]) else { return }
        if !(1...66).contains(bookNumber) {
            issues.append(.init(
                severity: .error,
                path: "/bookNumber",
                message: "Expected a canonical book number from 1 through 66."
            ))
        }
        if let media = root["media"], array(media) == nil {
            issues.append(.init(
                severity: .error,
                path: "/media",
                message: "Expected an array."
            ))
        }

        var chapterIndexes: [Int: Int] = [:]
        var verseIndexes: [Int: String] = [:]
        for (chapterIndex, chapterValue) in chapters.enumerated() {
            let chapterPath = "/chapters/\(chapterIndex)"
            guard let chapter = object(chapterValue) else {
                issues.append(.init(severity: .error, path: chapterPath, message: "Expected an object."))
                continue
            }
            guard let chapterNumber = integer(chapter["chapter"]), chapterNumber > 0 else {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/chapter",
                    message: "Expected a positive chapter number."
                ))
                continue
            }
            if let firstIndex = chapterIndexes[chapterNumber] {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/chapter",
                    message: "Duplicate chapter \(chapterNumber); it first appears at /chapters/\(firstIndex)/chapter."
                ))
            } else {
                chapterIndexes[chapterNumber] = chapterIndex
            }

            if let introduction = chapter["introduction"] {
                validateTextContent(
                    introduction,
                    path: "\(chapterPath)/introduction",
                    issues: &issues
                )
            }
            if let footnotes = chapter["footnotes"], array(footnotes) == nil {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/footnotes",
                    message: "Expected an array."
                ))
            }
            guard let versesValue = chapter["verses"] else { continue }
            guard let verses = array(versesValue) else {
                issues.append(.init(
                    severity: .error,
                    path: "\(chapterPath)/verses",
                    message: "Expected an array."
                ))
                continue
            }
            for (verseIndex, verseValue) in verses.enumerated() {
                let versePath = "\(chapterPath)/verses/\(verseIndex)"
                guard let verse = object(verseValue) else {
                    issues.append(.init(severity: .error, path: versePath, message: "Expected an object."))
                    continue
                }
                guard let reference = integer(verse["sv"]) else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/sv",
                        message: "Expected an integer BBCCCVVV reference."
                    ))
                    continue
                }
                let expectedBook = reference / 1_000_000
                let expectedChapter = (reference / 1_000) % 1_000
                let expectedVerse = reference % 1_000
                if expectedBook != bookNumber || expectedChapter != chapterNumber || expectedVerse < 1 {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/sv",
                        message: "Reference \(reference) does not belong to book \(bookNumber), chapter \(chapterNumber)."
                    ))
                }
                if let firstPath = verseIndexes[reference] {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/sv",
                        message: "Duplicate note reference \(reference); it first appears at \(firstPath)."
                    ))
                } else {
                    verseIndexes[reference] = "\(versePath)/sv"
                }
                if let endValue = verse["ev"] {
                    if let endReference = integer(endValue) {
                        if endReference < reference {
                            issues.append(.init(
                                severity: .error,
                                path: "\(versePath)/ev",
                                message: "End reference \(endReference) precedes start reference \(reference)."
                            ))
                        }
                    } else {
                        issues.append(.init(
                            severity: .error,
                            path: "\(versePath)/ev",
                            message: "Expected an integer BBCCCVVV reference."
                        ))
                    }
                }
                if let commentary = verse["commentary"] {
                    validateTextContent(commentary, path: "\(versePath)/commentary", issues: &issues)
                } else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/commentary",
                        message: "Missing required note content."
                    ))
                }
                if let footnotes = verse["footnotes"], array(footnotes) == nil {
                    issues.append(.init(
                        severity: .error,
                        path: "\(versePath)/footnotes",
                        message: "Expected an array."
                    ))
                }
            }
        }
    }

    private func validateHighlights(
        root: [String: Any],
        issues: inout [ModuleValidationIssue]
    ) {
        guard let verses = array(root["verses"]) else { return }
        var verseIndexes: [Int: Int] = [:]
        for (verseIndex, verseValue) in verses.enumerated() {
            let versePath = "/verses/\(verseIndex)"
            guard let verse = object(verseValue) else {
                issues.append(.init(severity: .error, path: versePath, message: "Expected an object."))
                continue
            }
            guard let reference = integer(verse["ref"]) else {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/ref",
                    message: "Expected an integer BBCCCVVV reference."
                ))
                continue
            }
            let book = reference / 1_000_000
            let chapter = (reference / 1_000) % 1_000
            let verseNumber = reference % 1_000
            if !(1...66).contains(book) || chapter < 1 || verseNumber < 1 {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/ref",
                    message: "Expected a valid BBCCCVVV verse reference."
                ))
            }
            if let firstIndex = verseIndexes[reference] {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/ref",
                    message: "Duplicate highlight reference \(reference); it first appears at /verses/\(firstIndex)/ref."
                ))
            } else {
                verseIndexes[reference] = verseIndex
            }
            guard let highlights = array(verse["highlights"]) else {
                issues.append(.init(
                    severity: .error,
                    path: "\(versePath)/highlights",
                    message: "Expected an array."
                ))
                continue
            }
            for (highlightIndex, highlightValue) in highlights.enumerated() {
                let path = "\(versePath)/highlights/\(highlightIndex)"
                guard let highlight = object(highlightValue) else {
                    issues.append(.init(severity: .error, path: path, message: "Expected an object."))
                    continue
                }
                guard let start = integer(highlight["sc"]), start >= 0 else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/sc",
                        message: "Expected a nonnegative start offset."
                    ))
                    continue
                }
                guard let end = integer(highlight["ec"]), end > start else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/ec",
                        message: "Expected an end offset greater than the start offset."
                    ))
                    continue
                }
                guard let style = integer(highlight["style"]), (0...3).contains(style) else {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/style",
                        message: "Expected style 0, 1, 2, or 3."
                    ))
                    continue
                }
                if let color = highlight["color"], !(color is String) {
                    issues.append(.init(
                        severity: .error,
                        path: "\(path)/color",
                        message: "Expected a color name or hex string."
                    ))
                }
            }
        }

        let meta = object(root["meta"])
        if let themesValue = meta?["themes"], array(themesValue) == nil {
            issues.append(.init(
                severity: .error,
                path: "/meta/themes",
                message: "Expected an array."
            ))
        }
        let themes = meta.flatMap { array($0["themes"]) } ?? []
        var themeKeys: Set<String> = []
        for (themeIndex, themeValue) in themes.enumerated() {
            let path = "/meta/themes/\(themeIndex)"
            guard let theme = object(themeValue),
                  let color = string(theme["color"]), !color.isEmpty,
                  let style = integer(theme["style"]), (0...3).contains(style),
                  let name = string(theme["name"]), !name.isEmpty else {
                issues.append(.init(
                    severity: .error,
                    path: path,
                    message: "Expected color, style 0 through 3, and a non-empty theme name."
                ))
                continue
            }
            let key = "\(color.uppercased()):\(style)"
            if !themeKeys.insert(key).inserted {
                issues.append(.init(
                    severity: .error,
                    path: path,
                    message: "Duplicate theme for color \(color) and style \(style)."
                ))
            }
        }
    }

    private func validateTextContent(
        _ value: Any,
        path: String,
        issues: inout [ModuleValidationIssue]
    ) {
        if let text = string(value) {
            if text.isEmpty {
                issues.append(.init(severity: .error, path: path, message: "Expected non-empty text."))
            }
            return
        }
        if let value = object(value), let text = string(value["text"]), !text.isEmpty {
            return
        }
        issues.append(.init(
            severity: .error,
            path: path,
            message: "Expected a string or an annotated-text object with non-empty text."
        ))
    }

    private func statistics(kind: LampModuleKind?, root: [String: Any]) -> [String: Int] {
        guard let kind else { return [:] }

        switch kind {
        case .translation:
            let books = array(root["books"]) ?? []
            let chapters = books.flatMap { object($0).flatMap { array($0["chapters"]) } ?? [] }
            let verses = chapters.flatMap { object($0).flatMap { array($0["verses"]) } ?? [] }
            return ["books": books.count, "chapters": chapters.count, "verses": verses.count]
        case .dictionary:
            return ["entries": array(root["entries"])?.count ?? 0]
        case .commentary:
            return ["chapters": array(root["chapters"])?.count ?? 0]
        case .book:
            func counts(_ values: [Any]) -> (sections: Int, blocks: Int) {
                values.reduce(into: (sections: 0, blocks: 0)) { result, value in
                    guard let section = object(value) else { return }
                    result.sections += 1
                    result.blocks += array(section["content"])?.count ?? 0
                    let childCounts = counts(array(section["sections"]) ?? [])
                    result.sections += childCounts.sections
                    result.blocks += childCounts.blocks
                }
            }
            let result = counts(array(root["sections"]) ?? [])
            return ["sections": result.sections, "contentBlocks": result.blocks]
        case .notes:
            let chapters = array(root["chapters"]) ?? []
            let notes = chapters.reduce(into: 0) { count, value in
                guard let chapter = object(value) else { return }
                if chapter["introduction"] != nil { count += 1 }
                count += array(chapter["verses"])?.count ?? 0
            }
            return ["chapters": chapters.count, "notes": notes]
        case .devotional:
            return ["contentBlocks": array(root["content"])?.count ?? (root["content"] == nil ? 0 : 1)]
        case .plan, .quiz:
            return ["days": array(root["days"])?.count ?? 0]
        case .highlights:
            let verses = array(root["verses"]) ?? []
            let highlights = verses.reduce(into: 0) { count, value in
                count += object(value).flatMap { array($0["highlights"]) }?.count ?? 0
            }
            return ["verses": verses.count, "highlights": highlights]
        }
    }

    private func requireStrings(
        _ object: [String: Any],
        keys: [String],
        issues: inout [ModuleValidationIssue]
    ) {
        for key in keys {
            requireString(object, key: key, basePath: "/meta", issues: &issues)
        }
    }

    private func requireString(
        _ object: [String: Any],
        key: String,
        basePath: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard let value = string(object[key]), !value.isEmpty else {
            issues.append(.init(severity: .error, path: "\(basePath)/\(key)", message: "Expected a non-empty string."))
            return
        }
    }

    private func requireObject(
        _ root: [String: Any],
        key: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard object(root[key]) != nil else {
            issues.append(.init(severity: .error, path: "/\(key)", message: "Expected an object."))
            return
        }
    }

    private func requireArray(
        _ root: [String: Any],
        key: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard array(root[key]) != nil else {
            issues.append(.init(severity: .error, path: "/\(key)", message: "Expected an array."))
            return
        }
    }

    private func requireInteger(
        _ root: [String: Any],
        key: String,
        issues: inout [ModuleValidationIssue]
    ) {
        guard integer(root[key]) != nil else {
            issues.append(.init(severity: .error, path: "/\(key)", message: "Expected an integer."))
            return
        }
    }

    private func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private func issueSort(_ lhs: ModuleValidationIssue, _ rhs: ModuleValidationIssue) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity == .error }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.message < rhs.message
    }
}
