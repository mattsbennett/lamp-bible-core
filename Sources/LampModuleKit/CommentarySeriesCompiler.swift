import Foundation
import GRDB

/// A commentary series, compiled to one module: its own record in
/// `series_meta`, and each volume's book and units beside it.
///
/// Until now a series was written only by the modules repository's Python
/// (`commentary_series_to_sqlite.py`, with its units from a port of
/// `CommentaryUnitBuilder` in `commentary_units.py`), so every change to how
/// a commentary is stored had to be made twice and could drift. A study
/// Bible is a series of 66 volumes, and the richer commentary format
/// (Documentation/RichModulesPlan.md, step 2) is written once, here.
///
/// The file is the one the Python writes, table for table and column for
/// column, so the phone's series import and every reader take it unchanged:
/// no `module_id` columns, a volume's book keyed `book_<number>`, a unit named
/// for its volume's series abbreviation. Held to it row by row on a two-volume
/// series, three things differed, each the Python port having fallen behind
/// core's builder, and each is core's here:
///
/// - **Unit IDs.** Core's name a verse by its passage too
///   (`TWO:1:verse:1:4:1001001`) and a chapter's introduction as such
///   (`TWO:1:chapter_intro:1`). No reader stores a unit's ID — a search hit
///   finds its unit in the same read, and the Mac's caches are rebuilt — so a
///   series rebuilt here breaks nothing that names one.
/// - **A pericope's own `commentary`.** The Python stored it; the schema has
///   no such field and no volume in the modules repository uses one.
/// - **Search text** is joined with spaces, as every volume core compiles
///   joins it, where the Python joined it with newlines. The full-text index
///   reads both the same.
extension LampModuleCompiler {
    /// Compiles `seriesURL`, a `commentary-series` file, with its volumes
    /// from `volumesDirectory`.
    ///
    /// Entries in the series' `volumes` list that give an `id` name the
    /// files to build, `<id>.json` in the folder, each for the book its entry
    /// names. Where none gives one, the list only describes the printed
    /// volumes — "informational", the schema calls it — and every commentary
    /// volume in the folder is built, as the Python built them: NIC lists
    /// sixty-one printed volumes with no IDs, and the cross-reference series
    /// list none. Either way, one volume to a book. Found by Codex, reviewing
    /// the first form, which refused every existing manifest but the
    /// converter's.
    ///
    /// Volumes are read one at a time, to find them and again to write them,
    /// so the most held at once is the largest volume rather than the series:
    /// a commentary's sources run to hundreds of megabytes.
    public func compileSeries(
        seriesURL: URL,
        volumesDirectory: URL,
        destinationURL requestedDestinationURL: URL? = nil
    ) throws -> ModuleCompilationResult {
        // Inputs a sandboxed app was handed by a picker, as `compile` takes
        // them. Found by Codex.
        let scopes = [seriesURL, volumesDirectory].filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }

        let series = try Self.object(at: seriesURL)
        // The manifest is checked in one pass, every problem reported with
        // where it is, before anything is chosen by it: checked a field at a
        // time as each was reached, a malformed one was read as absent — a
        // list that was not one, an entry that was not an object, an `id` or
        // `bookNumber` of the wrong type — and the build went on without it.
        // Found by Codex, over four reviews.
        let manifestIssues = Self.seriesManifestIssues(series)
        guard !manifestIssues.contains(where: { $0.severity == .error }) else {
            throw ModuleCompilationError.validationFailed(manifestIssues)
        }
        let meta = JSONSupport.object(series["meta"])!
        let seriesID = JSONSupport.string(meta["id"])!
        let listed = (JSONSupport.array(series["volumes"]) ?? []).enumerated().map { index, value in
            (index: index, entry: JSONSupport.object(value)!)
        }
        let named = listed.filter { JSONSupport.string($0.entry["id"]) != nil }
        var chosen: [Volume] = []
        if named.isEmpty {
            // The list describes the printed volumes, as the schema says, and
            // the folder holds the files: NIC lists Hamilton's Genesis as two
            // volumes and keeps it in one file. So every commentary volume in
            // the folder is the series', as the Python always took them.
            chosen = try Self.volumes(in: volumesDirectory, besides: seriesURL)
        } else {
            // Some named and some not would leave the rest to be guessed at,
            // and building only the named ones published a series without
            // them. Found by Codex.
            // (Every entry has one: the manifest's check refuses a list
            // naming only some.)
            for (index, entry) in named {
                let path = "/volumes/\(index)"
                let volumeID = JSONSupport.string(entry["id"])!
                // Read where it is named, and nowhere else: a search of the
                // folder let an unrelated file stop the build, or an archived
                // copy deeper in it win. Found by Codex.
                let url = volumesDirectory.appendingPathComponent("\(volumeID).json")
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ModuleCompilationError.missingValue(path: "\(path): \(volumeID).json")
                }
                var volume = try Self.volume(at: url, in: volumesDirectory, required: true)!
                volume.expectedID = volumeID
                // A file swapped for another book's would leave the series
                // listing one book and holding another. Found by Codex.
                // A file replaced by another commentary on the same book would
                // pass the name and the book; the ID it gives itself, where it
                // gives one, must be the entry's. Found by Codex.
                if let declared = volume.declaredID, declared != volumeID {
                    throw ModuleCompilationError.invalidValue(
                        path: "\(path)/id",
                        expected: "\(volumeID), the ID \(volume.url.lastPathComponent) gives itself (\(declared))"
                    )
                }
                if let book = Self.bookNumber(entry["bookNumber"]), volume.bookNumber != book {
                    throw ModuleCompilationError.invalidValue(
                        path: "\(path)/bookNumber",
                        expected: "\(book), the book \(volume.url.lastPathComponent) is for (\(volume.bookNumber))"
                    )
                }
                chosen.append(volume)
            }
        }
        guard !chosen.isEmpty else {
            throw ModuleCompilationError.missingValue(path: "\(volumesDirectory.lastPathComponent): a commentary volume")
        }
        var firstByBook: [Int: String] = [:]
        for volume in chosen {
            if let first = firstByBook[volume.bookNumber] {
                throw ModuleCompilationError.invalidValue(
                    path: volume.url.lastPathComponent,
                    expected: "one volume per book; book \(volume.bookNumber) is \(first)'s already"
                )
            }
            firstByBook[volume.bookNumber] = volume.url.lastPathComponent
        }
        // In canonical order, whatever order the series lists them in.
        chosen.sort { $0.bookNumber < $1.bookNumber }

        let destinationURL = requestedDestinationURL
            ?? seriesURL.deletingLastPathComponent()
                .appendingPathComponent(seriesID)
                .appendingPathExtension("lamp")
        var warnings = manifestIssues
        return try writeModule(
            kind: .commentary, moduleID: seriesID, destinationURL: destinationURL, warnings: warnings
        ) { databaseURL in
            try compileSeriesDatabase(
                series: series, volumes: chosen, seriesID: seriesID, databaseURL: databaseURL,
                warnings: &warnings
            )
        }
    }

    /// Everything wrong with a series manifest, by where it is: the shape
    /// `Schemas/commentary_series_schema.json` gives it, and what this
    /// compiler needs of it besides.
    static func seriesManifestIssues(_ series: [String: Any]) -> [ModuleValidationIssue] {
        var issues: [ModuleValidationIssue] = []
        func error(_ path: String, _ message: String) {
            issues.append(.init(severity: .error, path: path, message: message))
        }
        guard let meta = JSONSupport.object(series["meta"]) else {
            error("/meta", "Expected an object.")
            return issues
        }
        if JSONSupport.string(meta["type"]) != "commentary-series" {
            error("/meta/type", "Expected ‘commentary-series’.")
        }
        if JSONSupport.string(meta["schemaVersion"]) != "1.0" {
            error("/meta/schemaVersion", "Expected ‘1.0’, the series version this build reads.")
        }
        for key in ["id", "name", "abbreviation"] where (meta[key] as? String)?.isEmpty != false {
            error("/meta/\(key)", "Expected a non-empty string.")
        }
        // The rest, when given, as words: one of another type was stored as
        // nothing, without a word. Found by Codex.
        for key in ["description", "editor", "publisher", "testament", "language", "website"] {
            if let value = meta[key], !(value is NSNull), !(value is String) {
                error("/meta/\(key)", "Expected a string.")
            }
        }
        // The portable importer's rule for a module's identity, so a build
        // that succeeds is one an app can install.
        if let id = meta["id"] as? String, id.contains("/") || id.contains("\\") || id.contains("\0") {
            error("/meta/id", "Expected an ID with no slash, backslash or NUL.")
        }
        // An ID the Mac's installer refuses still builds, for the phone takes
        // it, but is said to. Found by Codex.
        if let id = meta["id"] as? String, !id.isEmpty, !LampModuleIdentifier.isValid(id) {
            issues.append(.init(
                severity: .warning, path: "/meta/id",
                message: "A Mac will not install a module with this ID. Use \(LampModuleIdentifier.advice)."
            ))
        }
        // Shared abbreviations and bibliography, as the schema types them: the
        // phone reads each list whole or not at all, so one mistyped entry
        // lost the rest. Checked whether or not the series lists its volumes.
        // Found by Codex.
        func checkList(_ key: String, _ check: ([String: Any], String) -> Void) {
            guard let value = series[key], !(value is NSNull) else { return }
            guard let items = value as? [Any] else {
                error("/\(key)", "Expected an array.")
                return
            }
            for (index, item) in items.enumerated() {
                guard let object = item as? [String: Any] else {
                    error("/\(key)/\(index)", "Expected an object.")
                    continue
                }
                check(object, "/\(key)/\(index)")
            }
        }
        checkList("abbreviations") { entry, path in
            for key in ["abbrev", "expansion"] where (entry[key] as? String)?.isEmpty != false {
                error("\(path)/\(key)", "Expected a non-empty string.")
            }
            if let category = entry["category"], !(category is String) {
                error("\(path)/category", "Expected a string.")
            }
        }
        checkList("bibliography") { entry, path in
            if !(entry["subsection"] is String) {
                error("\(path)/subsection", "Expected a string.")
            }
            if !((entry["content"] as? [String: Any])?["text"] is String) {
                error("\(path)/content", "Expected annotated text, an object with its `text`.")
            }
        }

        // A preface or introduction is words, or annotated text with its
        // words; an object without them was stored as one the phone could not
        // read. Found by Codex.
        for key in ["editorPreface", "introduction"] {
            guard let value = series[key], !(value is NSNull), !(value is String) else { continue }
            if !((value as? [String: Any])?["text"] is String) {
                error("/\(key)", "Expected words, or annotated text with its `text`.")
            }
        }
        // Absent is no list; `null` is a malformed one, which would otherwise
        // send the build to take the whole folder. Found by Codex.
        guard let value = series["volumes"] else { return issues }
        guard let entries = value as? [Any] else {
            error("/volumes", "Expected an array of volumes.")
            return issues
        }
        var named = 0
        var unnamed: Int?
        for (index, value) in entries.enumerated() {
            let path = "/volumes/\(index)"
            guard let entry = value as? [String: Any] else {
                error(path, "Expected a volume object.")
                continue
            }
            if let id = entry["id"] {
                // A volume ID names a file in the folder, and must not climb
                // out of it. Only that: existing volumes are named like
                // "NIC_3 John".
                if let id = id as? String, !id.isEmpty {
                    named += 1
                    if id.contains("/") || id.contains("\\") || id.hasPrefix(".") {
                        error("\(path)/id", "Expected a file name in the volumes folder.")
                    }
                } else {
                    error("\(path)/id", "Expected a non-empty string.")
                }
            } else if unnamed == nil {
                unnamed = index
            }
            // The schema requires every entry's book, and a named entry's is
            // what its file is checked against. Found by Codex.
            if Self.bookNumber(entry["bookNumber"]) == nil {
                error("\(path)/bookNumber", "Expected a book number from 1 to 66.")
            }
            // The rest of the entry as the schema types it: the list is stored
            // as written, and the phone reads all of it or none of it, so one
            // year in quotes lost every volume's details. Found by Codex.
            if (entry["book"] as? String)?.isEmpty != false {
                error("\(path)/book", "Expected the book's abbreviation.")
            }
            for key in ["title", "author", "isbn", "edition"] {
                if let value = entry[key], !(value is String) {
                    error("\(path)/\(key)", "Expected a string.")
                }
            }
            if let year = entry["year"], Self.wholeNumber(year) == nil {
                error("\(path)/year", "Expected a whole year.")
            }
        }
        // Some named and some not would leave the rest to be guessed at, and
        // building only the named ones published a series without them.
        if named > 0, let unnamed {
            error("/volumes/\(unnamed)/id", "Expected an ID, as the other volumes give; name every volume or none.")
        }
        return issues
    }

    /// A commentary volume found in the folder, by its file and its book.
    private struct Volume {
        let url: URL
        let folder: URL
        let bookNumber: Int
        /// The ID the volume gives itself, if it gives one.
        let declaredID: String?
        /// The ID its series entry names it by, if it was named.
        var expectedID: String? = nil
    }

    /// The ID a volume gives itself, where the inspector finds one.
    private static func declaredID(of root: [String: Any]) -> String? {
        JSONSupport.string(JSONSupport.object(root["meta"])?["id"]) ?? JSONSupport.string(root["id"])
    }

    /// The commentary volumes in a folder and the folders inside it, read
    /// one at a time and let go: any JSON file there, but the series file,
    /// that is a commentary. Into its folders because a series may keep its
    /// testaments apart, as NIC keeps `NICOT/` and `NICNT/`.
    private static func volumes(in directory: URL, besides seriesURL: URL) throws -> [Volume] {
        // A folder that cannot be read in full is an error: the series would
        // be published from what could be. Found by Codex.
        var unreadable: Error?
        guard let walk = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                if unreadable == nil { unreadable = error }
                return false
            }
        ) else {
            throw ModuleCompilationError.missingValue(path: directory.path)
        }
        var files: [URL] = []
        for case let url as URL in walk {
            // A linked folder is not searched, so it is refused rather than
            // passed over: its volumes would be missing from the series
            // without a word. Found by Codex.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
               (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                throw ModuleCompilationError.invalidValue(
                    path: url.lastPathComponent,
                    expected: "a folder, not a link to one; name the series' volumes to read them from where they are"
                )
            }
            guard url.pathExtension.lowercased() == "json" else { continue }
            // A link is taken as the file it names, if that is inside the
            // folder, and refused if not: skipped, a linked volume left the
            // series without a word. Found by Codex.
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true,
                  url.standardizedFileURL != seriesURL.standardizedFileURL
            else { continue }
            files.append(url)
        }
        if let unreadable { throw unreadable }
        return try files.sorted { $0.path < $1.path }
            .compactMap { try volume(at: $0, in: directory, required: false) }
    }

    /// A book number as written: an integer from 1 to 66, not a Boolean,
    /// a fraction, or a string. Read loosely, `2.5` was filed under Exodus
    /// and `true` under Genesis. Found by Codex.
    /// A whole number as JSON writes one: `2001`, `2001.0` or `2.001e3`,
    /// which Foundation may read as floating point, but not a fraction or a
    /// Boolean. Found by Codex.
    static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) < 9.0e15
        else { return nil }
        return Int(number.doubleValue)
    }

    static func bookNumber(_ value: Any?) -> Int? {
        // Whole, as JSON's integers are: `2.0` and `2e0` are 2, which
        // Foundation reads as floating point. Found by Codex.
        guard let book = wholeNumber(value), (1...66).contains(book) else { return nil }
        return book
    }

    /// Whether a file says it is a commentary volume, before any of what it
    /// is required to hold: one missing its `book` or `chapters` was not
    /// recognised as one, and left out of the series without a word. Found
    /// by Codex.
    ///
    /// A kind the file declares, or one the inspector recognises, decides
    /// first: a dictionary may carry `seriesAbbrev` too, and taken for a
    /// commentary it stopped the build. Found by Codex, with `wsd_greek.json`.
    private static func saysItIsACommentary(_ root: [String: Any]) -> Bool {
        let meta = JSONSupport.object(root["meta"]) ?? [:]
        // Read as every kind is read, so `Commentary` is one as it is when
        // built alone. Found by Codex.
        // A type it does not recognise is no answer, and the file is judged
        // by its shape, as the inspector judges it: `"commentary "` was left
        // out of the series without a word. Found by Codex.
        if let declared = JSONSupport.string(meta["type"]), let kind = LampModuleKind(schemaValue: declared) {
            return kind == .commentary
        }
        if let kind = ModuleJSONInspector().inspect(root: root, sourceFilename: nil).kind {
            return kind == .commentary
        }
        return meta["seriesAbbrev"] != nil || meta["seriesFull"] != nil
    }

    /// The volume a file holds, read and let go. A file that is not a
    /// commentary is nil while searching a folder and an error where it was
    /// named; one that is a commentary must say its book, or it would be left
    /// out of the series without a word. Found by Codex.
    /// Read only from inside the folder given: a file there that is a link to
    /// one elsewhere would put that file in the series. Checked on every
    /// read, the second as well as the first, so a link changed in between
    /// cannot either. Found by Codex.
    private static func requireInside(_ url: URL, _ directory: URL) throws {
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") else {
            throw ModuleCompilationError.invalidValue(
                path: url.lastPathComponent, expected: "a file inside \(directory.lastPathComponent)"
            )
        }
    }

    private static func volume(at url: URL, in directory: URL, required: Bool) throws -> Volume? {
        try requireInside(url, directory)
        return try autoreleasepool {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw ModuleInspectionError.invalidJSON("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            guard let root = value as? [String: Any], saysItIsACommentary(root) else {
                if required {
                    throw ModuleCompilationError.invalidValue(path: url.lastPathComponent, expected: "a commentary volume")
                }
                return nil
            }
            guard let book = bookNumber(root["bookNumber"]) else {
                throw ModuleCompilationError.invalidValue(
                    path: "\(url.lastPathComponent): /bookNumber", expected: "a book number from 1 to 66"
                )
            }
            return Volume(
                url: url, folder: directory, bookNumber: book,
                declaredID: declaredID(of: root)
            )
        }
    }

    private func compileSeriesDatabase(
        series: [String: Any],
        volumes: [Volume],
        seriesID: String,
        databaseURL: URL,
        warnings: inout [ModuleValidationIssue]
    ) throws -> [String: Int] {
        let meta = try JSONSupport.requiredObject(series["meta"], path: "/meta")
        let queue = try makeDatabaseQueue(at: databaseURL)
        var unitCount = 0
        try queue.write { db in
            try createSeriesSchema(in: db)
            try createFormatMetadata(in: db, kind: .commentary, moduleID: seriesID)
            try db.execute(
                sql: """
                    INSERT INTO series_meta (
                        id, name, abbreviation, description, editor, publisher,
                        testament, language, website,
                        editor_preface_json, introduction_json,
                        abbreviations_json, bibliography_json, volumes_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    seriesID,
                    JSONSupport.string(meta["name"]),
                    JSONSupport.string(meta["abbreviation"]),
                    JSONSupport.string(meta["description"]),
                    JSONSupport.string(meta["editor"]),
                    JSONSupport.string(meta["publisher"]),
                    JSONSupport.string(meta["testament"]),
                    JSONSupport.string(meta["language"]),
                    JSONSupport.string(meta["website"]),
                    try Self.annotatedJSON(series["editorPreface"]),
                    try Self.annotatedJSON(series["introduction"]),
                    try JSONSupport.jsonString(series["abbreviations"]),
                    try JSONSupport.jsonString(series["bibliography"]),
                    try JSONSupport.jsonString(series["volumes"]),
                ]
            )

            for volume in volumes {
                unitCount += try autoreleasepool {
                    try writeVolume(volume, in: db, warnings: &warnings)
                }
            }
            try db.execute(sql: "INSERT INTO commentary_units_fts(commentary_units_fts) VALUES('rebuild')")
        }
        try optimize(queue)
        return ["series_meta": 1, "commentary_books": volumes.count, "commentary_units": unitCount]
    }

    /// One volume's book and units, read from its file, checked as a volume
    /// on its own is, and let go when written.
    private func writeVolume(
        _ volume: Volume, in db: Database, warnings: inout [ModuleValidationIssue]
    ) throws -> Int {
        let url = volume.url
        try Self.requireInside(url, volume.folder)
        let root = try Self.object(at: url)
        let inspection = ModuleJSONInspector().inspect(root: root, sourceFilename: url.lastPathComponent)
        // Each issue named for its file, so a series' build says which volume
        // stopped it, and what a volume was warned about reaches whoever
        // built it. Found by Codex.
        // Less the standalone ID warning: a volume is installed under the
        // series' ID, never its own, so advice to rename it is no advice.
        // Found by Codex.
        let issues = inspection.issues
            .filter { !($0.severity == .warning && ($0.path == "/" || $0.path == "/meta/id")) }
            .map {
                ModuleValidationIssue(severity: $0.severity, path: "\(url.lastPathComponent): \($0.path)", message: $0.message)
            }
        guard !issues.contains(where: { $0.severity == .error }) else {
            throw ModuleCompilationError.validationFailed(issues)
        }
        warnings += issues
        let volumeMeta = try JSONSupport.requiredObject(root["meta"], path: "\(url.lastPathComponent): /meta")
        let bookNumber = Self.bookNumber(root["bookNumber"])
        // Read again to be written, the file must still be the volume that
        // was chosen: one replaced in between would enter under another
        // book's entry. Found by Codex.
        // And still the volume its entry names, where it was named. Found by
        // Codex.
        if let expected = volume.expectedID, let declared = Self.declaredID(of: root), declared != expected {
            throw ModuleCompilationError.invalidValue(
                path: "\(url.lastPathComponent): /meta/id",
                expected: "\(expected), as its series entry names it"
            )
        }
        guard inspection.kind == .commentary, let bookNumber, bookNumber == volume.bookNumber else {
            throw ModuleCompilationError.invalidValue(
                path: "\(url.lastPathComponent): /bookNumber",
                expected: "\(volume.bookNumber), as when the series was read"
            )
        }
        try db.execute(
            sql: """
                INSERT INTO commentary_books (
                    id, book_number, title, author, editor, publisher, year,
                    abbreviations_json, front_matter_json, indices_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                "book_\(bookNumber)",
                bookNumber,
                // A volume may give a name in place of a title, which the
                // schema says to show: as a volume compiled alone keeps it.
                // Found by Codex.
                // The first of them that is words, as the inspector takes it:
                // a mistyped title lost the name. Found by Codex.
                JSONSupport.string(volumeMeta["title"]) ?? JSONSupport.string(volumeMeta["name"]),
                JSONSupport.string(volumeMeta["author"]),
                JSONSupport.string(volumeMeta["editor"]),
                JSONSupport.string(volumeMeta["publisher"]),
                JSONSupport.integer(volumeMeta["year"]),
                try JSONSupport.jsonString(root["abbreviations"]),
                try Self.annotatedJSON(root["frontMatter"]),
                try JSONSupport.jsonString(root["indices"]),
            ]
        )

        // A unit is named for its volume's series abbreviation, as the
        // Python names it.
        var builder = CommentaryUnitBuilder(
            moduleID: JSONSupport.string(volumeMeta["seriesAbbrev"]) ?? "commentary",
            bookNumber: bookNumber,
            footnotes: JSONSupport.array(root["footnotes"]) ?? [],
            sourceOrdered: JSONSupport.object(root["extraction"])?["sourceTracked"] as? Bool == true
        )
        // The builder's errors named for the volume too, so a series' build
        // says where a verse lacks its `sv`. Found by Codex.
        do {
            try builder.append(chapters: try JSONSupport.requiredArray(root["chapters"], path: "/chapters"))
        } catch ModuleCompilationError.missingValue(let path) {
            throw ModuleCompilationError.missingValue(path: "\(url.lastPathComponent): \(path)")
        } catch ModuleCompilationError.invalidValue(let path, let expected) {
            throw ModuleCompilationError.invalidValue(path: "\(url.lastPathComponent): \(path)", expected: expected)
        }
        for row in builder.units {
            try db.execute(
                sql: """
                    INSERT INTO commentary_units (
                        id, book, chapter, sv, ev, unit_type, level, parent_id,
                        title, suffix, introduction_json, translation_json, commentary_json,
                        footnotes_json, search_text, order_index, footnotes_text
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    row.id, bookNumber, row.chapter, row.startVerse, row.endVerse,
                    row.unitType, row.level, row.parentID, row.title, row.suffix,
                    row.introductionJSON, row.translationJSON, row.commentaryJSON,
                    row.footnotesJSON, row.searchText, row.orderIndex, row.footnotesText,
                ]
            )
        }
        return builder.units.count
    }

    /// The tables `commentary_series_to_sqlite.py` creates, as it creates
    /// them: what the phone's series import and the readers expect of a
    /// series file.
    private func createSeriesSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE series_meta (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                abbreviation TEXT NOT NULL,
                description TEXT,
                editor TEXT,
                publisher TEXT,
                testament TEXT,
                language TEXT,
                website TEXT,
                editor_preface_json TEXT,
                introduction_json TEXT,
                abbreviations_json TEXT,
                bibliography_json TEXT,
                volumes_json TEXT
            );
            CREATE TABLE commentary_books (
                id TEXT PRIMARY KEY,
                book_number INTEGER NOT NULL,
                title TEXT,
                author TEXT,
                editor TEXT,
                publisher TEXT,
                year INTEGER,
                abbreviations_json TEXT,
                front_matter_json TEXT,
                indices_json TEXT
            );
            CREATE INDEX idx_books_number ON commentary_books(book_number);
            CREATE TABLE commentary_units (
                id TEXT PRIMARY KEY,
                book INTEGER NOT NULL,
                chapter INTEGER,
                sv INTEGER NOT NULL,
                ev INTEGER,
                unit_type TEXT NOT NULL,
                level INTEGER NOT NULL DEFAULT 1,
                parent_id TEXT,
                title TEXT,
                suffix TEXT,
                introduction_json TEXT,
                translation_json TEXT,
                commentary_json TEXT,
                footnotes_json TEXT,
                search_text TEXT NOT NULL DEFAULT '',
                order_index INTEGER NOT NULL DEFAULT 0,
                footnotes_text TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX idx_units_verse ON commentary_units(sv, ev);
            CREATE INDEX idx_units_book_chapter ON commentary_units(book, chapter);
            CREATE INDEX idx_units_parent ON commentary_units(parent_id);
            CREATE INDEX idx_units_type ON commentary_units(unit_type);
            CREATE VIRTUAL TABLE commentary_units_fts USING fts5(
                title, search_text, footnotes_text,
                content='commentary_units',
                content_rowid='rowid'
            );
            """)
    }

    /// An object stored as it is, or words stored as annotated text with
    /// none: the series writer's rule for a preface, an introduction and
    /// front matter.
    private static func annotatedJSON(_ value: Any?) throws -> String? {
        if let text = value as? String {
            return text.isEmpty ? nil : try JSONSupport.jsonString(["text": text])
        }
        return try JSONSupport.jsonString(value)
    }

    private static func object(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModuleInspectionError.invalidJSON("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let root = value as? [String: Any] else { throw ModuleInspectionError.rootMustBeObject }
        return root
    }
}
