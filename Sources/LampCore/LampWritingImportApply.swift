import CryptoKit
import Foundation
import ImageIO
import LampModuleKit
import UniformTypeIdentifiers

/// Where a writing import finds what is already there, and writes what is
/// chosen: the Mac's library, or the phone's own database, which has no
/// `LampLibrary`. The plan, the apply and the undo are the same for both, so
/// the two apps decide alike what an import does.
public protocol LampWritingImportStore {
    /// The person's own writings as they stand.
    func importableWritings() async throws -> [LampDevotional]
    /// What the deletion ledger says of a writing, if anything.
    func writingDeletion(id: String) async throws -> LampPersonalDeletionLedger.Entry?
    /// Why an import must leave a writing alone, if it must: one the store
    /// holds but does not offer, such as the phone's subscription and
    /// bundled writings, which a file with the same id would otherwise
    /// overwrite. Nil lets it through.
    func writingRefusal(id: String) async throws -> String?
    /// Saves a writing exactly as given, its `lastModified` included — but
    /// only if the store's copy is still `current` (nil: it has none),
    /// checked and written in one transaction, so an edit or a sync landing
    /// meanwhile is not overwritten. Returns the stored copy as read back, or
    /// nil if it did not save.
    func saveImportedWriting(_ writing: LampDevotional, expecting current: LampDevotional?) async throws -> LampDevotional?
    /// Records writings as present now, so sync keeps them.
    func recordWritingsPresent(_ ids: [String]) async throws
    /// Deletes a writing an import made, as a deletion sync carries, if the
    /// store's copy is still `current`. Says whether it deleted.
    func deleteImportedWriting(id: String, expecting current: LampDevotional) async throws -> Bool
    /// Copies a picture or recording into a writing's media and returns the
    /// file name it is kept under there.
    func storeImportedMedia(from url: URL, writingID: String) async throws -> String
    /// Removes a file an import put in a writing's media.
    func removeImportedMedia(writingID: String, filename: String) async throws
    /// Whether this store keeps decks. The phone only shows them.
    var supportsDecks: Bool { get }
    func importableDecks() async throws -> [LampPresentationDeck]
    /// Saves a deck, and the pictures it names (by the path each is stored
    /// under), if the store's copy is still `current`. Says whether it saved.
    func saveImportedDeck(
        _ deck: LampPresentationDeck, assets: [String: URL], expecting current: LampPresentationDeck?
    ) async throws -> Bool
    /// Deletes a deck an import made, as a deletion sync carries, if the
    /// store's copy is still `current`. Says whether it deleted.
    func deleteImportedDeck(id: String, expecting current: LampPresentationDeck) async throws -> Bool
}

public extension LampWritingImportStore {
    func writingRefusal(id: String) async throws -> String? { nil }
    var supportsDecks: Bool { false }
    func importableDecks() async throws -> [LampPresentationDeck] { [] }
    func saveImportedDeck(
        _ deck: LampPresentationDeck, assets: [String: URL], expecting current: LampPresentationDeck?
    ) async throws -> Bool {
        throw LampLibraryError.invalidPersonalContent("Decks are imported on the Mac.")
    }
    func deleteImportedDeck(id: String, expecting current: LampPresentationDeck) async throws -> Bool { false }
}

/// What an import changed, kept so it can be undone: each writing and deck
/// as the import left it, and as it was before.
public struct LampWritingImportUndo: Codable, Equatable, Identifiable, Sendable {
    public struct Writing: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// The writing as the import left it in the store. One that differs
        /// now in any way was changed since, and is left.
        public var written: String
        /// The writing before the import, or nil for one it made.
        public let previous: String?
        /// Media files the import added to it.
        public let addedMedia: [String]

        public init(id: String, title: String, written: String, previous: String?, addedMedia: [String]) {
            self.id = id
            self.title = title
            self.written = written
            self.previous = previous
            self.addedMedia = addedMedia
        }
    }

    public struct Deck: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let written: LampPresentationDeck
        public let previous: LampPresentationDeck?

        public init(id: String, title: String, written: LampPresentationDeck, previous: LampPresentationDeck?) {
            self.id = id
            self.title = title
            self.written = written
            self.previous = previous
        }
    }

    public let id: String
    public let importedAt: Date
    public var writings: [Writing]
    public var decks: [Deck]

    public init(id: String, importedAt: Date, writings: [Writing], decks: [Deck]) {
        self.id = id
        self.importedAt = importedAt
        self.writings = writings
        self.decks = decks
    }

    public var isEmpty: Bool { writings.isEmpty && decks.isEmpty }

    /// This record, told that a later import's undo put writings back as
    /// they were: each that this import left as it was put back stands as
    /// this import's own again, so this one can still be undone after it.
    public func carrying(restored: [String: String]) -> LampWritingImportUndo {
        var record = self
        for index in record.writings.indices {
            guard let copy = restored[record.writings[index].id],
                  let now = LampSyncConflictPayload.devotional(from: copy),
                  let then = LampSyncConflictPayload.devotional(from: record.writings[index].written),
                  LampWritingImport.sameStoredCopy(now, then, ignoringTime: true) else { continue }
            record.writings[index].written = copy
        }
        return record
    }
}

/// What undoing an import did.
public struct LampWritingImportUndoResult: Equatable, Sendable {
    /// Titles put back as they were, or taken away.
    public let undone: [String]
    /// Titles changed since the import, so left as they are.
    public let kept: [String]
    /// Each writing put back, as now stored, for an earlier import's record
    /// (`LampWritingImportUndo.carrying(restored:)`).
    public let restored: [String: String]
}

/// One chosen item that could not be imported, and why.
public struct LampWritingImportFailure: Equatable, Sendable {
    public let item: LampWritingImportItem
    public let reason: String
}

public extension LampWritingImport {
    /// What importing these files would do, without writing anything.
    ///
    /// - Parameter comparingWithLibrary: false checks the files alone, for an
    ///   agent not allowed to read the person's writing: every file reads as
    ///   new, and each item says it was not compared. Lamp compares when it
    ///   shows the import for review.
    static func plan(
        _ files: [LampWritingImportFile],
        in store: some LampWritingImportStore,
        comparingWithLibrary: Bool = true
    ) async throws -> LampWritingImportPlan {
        var candidates = files.flatMap(candidates(from:))

        // One row per path: two documents given the same path would share a
        // row's key, and ticking one would import the other.
        let givenKeys = Set(candidates.map(\.key))
        var usedKeys: Set<String> = []
        for index in candidates.indices {
            let key = candidates[index].key
            guard usedKeys.contains(key) else {
                usedKeys.insert(key)
                continue
            }
            var copy = 2
            while usedKeys.contains("\(key)#copy\(copy)") || givenKeys.contains("\(key)#copy\(copy)") {
                copy += 1
            }
            candidates[index].key = "\(key)#copy\(copy)"
            usedKeys.insert(candidates[index].key)
            candidates[index].errors.append("Another file has the same path, \(candidates[index].path); only the first is imported.")
        }

        let existing = comparingWithLibrary ? Dictionary(
            try await store.importableWritings().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ) : [:]

        // A derived id finds the writing an earlier import made from a
        // longer or shorter path. A path is not proof it is the same file —
        // another folder may hold one of the same name — so a match is only
        // offered, and a file that would change it waits to be ticked. No
        // match is taken where more than one earlier writing would do, where
        // another file here would find the same one, or where another file
        // here already has that id.
        let importable = candidates.indices.filter {
            candidates[$0].errors.isEmpty && candidates[$0].writing != nil
        }
        let namedIDs = Set(importable.map { candidates[$0].writingID })
        var found: [Int: (id: String, path: String)] = [:]
        for index in importable where candidates[index].idDerived {
            let candidate = candidates[index]
            guard existing[candidate.writingID] == nil else { continue }
            let matches = earlierPaths(of: candidate.path, ancestry: candidate.ancestry)
                .map { (id: derivedID(path: $0 + candidate.identitySuffix), path: $0) }
                .filter { existing[$0.id] != nil && !namedIDs.contains($0.id) }
            if matches.count == 1 {
                found[index] = matches[0]
            } else if matches.count > 1 {
                candidates[index].warnings.append("More than one writing imported before could be this file (from \(matches.map(\.path).joined(separator: ", "))), so it is imported as new.")
            }
        }
        let claims = Dictionary(grouping: found.values.map(\.id), by: { $0 }).mapValues(\.count)
        var matched: Set<String> = []
        for (index, match) in found where claims[match.id] == 1 {
            candidates[index].writingID = match.id
            candidates[index].writing = candidates[index].writing?.withID(match.id)
            candidates[index].normalized.append("Matched the writing imported before from \(match.path).")
            matched.insert(candidates[index].key)
        }

        var idCounts: [String: Int] = [:]
        for candidate in candidates where candidate.errors.isEmpty {
            idCounts[candidate.writingID, default: 0] += 1
        }
        for index in candidates.indices where (idCounts[candidates[index].writingID] ?? 0) > 1
            && candidates[index].errors.isEmpty {
            let others = candidates.filter {
                $0.writingID == candidates[index].writingID && $0.key != candidates[index].key
            }.map(\.path)
            candidates[index].errors.append("Another file has the same id (\(others.joined(separator: ", "))).")
        }

        for index in candidates.indices where candidates[index].errors.isEmpty && candidates[index].writing != nil {
            if let reason = try await store.writingRefusal(id: candidates[index].writingID) {
                candidates[index].errors.append(reason)
            }
        }

        // Ids settled, the pictures are named, and links between writings
        // made.
        for index in candidates.indices where candidates[index].errors.isEmpty {
            nameMedia(&candidates[index])
        }
        linkWritings(&candidates, existing: Set(existing.keys))

        let existingDecks = comparingWithLibrary && store.supportsDecks
            ? Dictionary(try await store.importableDecks().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]

        var items: [LampWritingImportItem] = []
        var writings: [String: LampDevotional] = [:]
        var locals: [String: LampDevotional] = [:]
        var restored: Set<String> = []
        var media: [String: [LampWritingImportMedia]] = [:]
        var links: [String: [String: String]] = [:]
        var decks: [String: LampWritingImportPlan.PlannedDeck] = [:]
        var deckIDs: [String: String] = [:]
        for candidate in candidates {
            var warnings = candidate.warnings
            var action = LampWritingImportItem.Action.rejected
            var changes: [String] = []
            var libraryModified: Date?
            if candidate.errors.isEmpty, let writing = candidate.writing {
                // When the file was last changed, if anything says: its front
                // matter, else its own save time. A document handed in with
                // neither is dated when it is imported.
                let incoming = writing.lastModified.map { Int($0.timeIntervalSince1970) }
                if let local = existing[writing.id] {
                    locals[candidate.key] = local
                    libraryModified = local.lastModified
                    changes = local.differingAuthoredFields(from: writing)
                    if changes.isEmpty {
                        action = .unchanged
                    } else if matched.contains(candidate.key) {
                        action = .conflict
                        warnings.append("Found by its path from an earlier import; tick it if it is the same writing.")
                    } else if incoming == nil {
                        // Nothing says the file is newer, so it must not
                        // overwrite an edit made in Lamp without being chosen.
                        action = .conflict
                        warnings.append("The file does not say when it was last changed, so Lamp cannot tell which copy is newer.")
                    } else {
                        let decision = LampSyncMerge.decide(
                            localModified: local.lastModified.map { Int($0.timeIntervalSince1970) },
                            incomingModified: incoming,
                            sameContent: false
                        )
                        action = decision == .incoming ? .update : .conflict
                    }
                } else if !comparingWithLibrary {
                    action = .create
                    warnings.append("Not compared with the library: personal content is closed to agents. Lamp compares it when it shows the import for review.")
                } else {
                    action = .create
                    if try await store.writingDeletion(id: writing.id)?.isDeleted(itemModified: incoming) == true {
                        restored.insert(candidate.key)
                        warnings.append("This writing was deleted from Lamp; importing it brings it back.")
                    }
                }
                writings[candidate.key] = writing
                media[candidate.key] = candidate.media
                links[candidate.key] = candidate.links
            }
            items.append(LampWritingImportItem(
                id: candidate.key,
                path: candidate.path,
                writingID: candidate.writingID,
                idDerived: candidate.idDerived,
                title: candidate.title,
                action: action,
                changes: changes,
                errors: candidate.errors,
                warnings: warnings,
                normalized: candidate.normalized,
                libraryModified: libraryModified
            ))

            if let deckFile = candidate.deck {
                var planned = planDeck(
                    deckFile, for: candidate, writingAction: action,
                    store: store, existing: existingDecks
                )
                // Two decks with one id would each overwrite the other.
                if let deck = planned.deck {
                    if let other = deckIDs[deck.id] {
                        planned.item = planned.item.rejecting("Another deck has the same id (\(other)).")
                        planned.deck = nil
                    } else {
                        deckIDs[deck.id] = deckFile.path
                    }
                }
                items.append(planned.item)
                if let deck = planned.deck {
                    decks[planned.item.id] = .init(
                        deck: deck, assets: planned.assets, local: existingDecks[deck.id]
                    )
                }
            }
        }
        return LampWritingImportPlan(
            items: items, writings: writings, locals: locals, restored: restored,
            media: media, decks: decks, links: links
        )
    }

    /// A deck delivered beside a writing, as its own row. Its pictures are
    /// stored under names of their own — the deck's id and the picture's
    /// bytes — so a picture of the same name another deck shows is never
    /// overwritten, and a replaced picture is a new file an undo can step
    /// back from.
    private static func planDeck(
        _ file: LampWritingImportDeckFile,
        for candidate: Candidate,
        writingAction: LampWritingImportItem.Action,
        store: some LampWritingImportStore,
        existing: [String: LampPresentationDeck]
    ) -> (item: LampWritingImportItem, deck: LampPresentationDeck?, assets: [String: URL]) {
        var errors: [String] = []
        var title = (file.path as NSString).lastPathComponent
        var action = LampWritingImportItem.Action.rejected
        var planned: LampPresentationDeck?
        var assets: [String: URL] = [:]
        if !store.supportsDecks {
            errors.append("Decks are imported on the Mac.")
        } else if writingAction == .rejected {
            errors.append("Its writing cannot be imported, so neither can its deck.")
        } else {
            do {
                var deck = try LampPresentationDeckStore.decodeUnvalidated(file.data)
                title = deck.title
                // The deck belongs to the writing it was delivered beside,
                // whatever its file said.
                deck.source = LampPresentationSource(kind: .writing, id: candidate.writingID)
                var renamed: [String: String] = [:]
                var missing: [String] = []
                for path in Set(deck.slides.flatMap(\.blocks).compactMap(\.assetPath)).sorted() {
                    guard LampPresentationDeckValidator.isSafeAssetPath(path) else { continue }
                    guard let directory = file.assetsDirectory,
                          isFile(directory.appendingPathComponent(path), inside: directory),
                          let bytes = try? Data(contentsOf: directory.appendingPathComponent(path)) else {
                        missing.append(path)
                        continue
                    }
                    let fingerprint = SHA256.hash(data: bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
                    let name = "\(LampPresentationDeckStore.assetsDirectoryName)/\(deck.id)-\(fingerprint)-\((path as NSString).lastPathComponent)"
                    renamed[path] = name
                    assets[name] = directory.appendingPathComponent(path)
                }
                for slide in deck.slides.indices {
                    for block in deck.slides[slide].blocks.indices {
                        if let path = deck.slides[slide].blocks[block].assetPath, let name = renamed[path] {
                            deck.slides[slide].blocks[block].assetPath = name
                        }
                    }
                }
                errors += LampPresentationDeckValidator.errors(in: deck).map { "\($0.path): \($0.message)" }
                if !missing.isEmpty {
                    errors.append("The deck's pictures are not beside it: \(missing.joined(separator: ", ")).")
                }
                if errors.isEmpty {
                    planned = deck
                    if let local = existing[deck.id] {
                        // Edited in Slide Studio or not, only the person can
                        // say the file's copy should replace it.
                        action = local == deck ? .unchanged : .conflict
                    } else {
                        action = .create
                    }
                }
            } catch {
                errors.append("The deck is not a Lamp deck: \(error.localizedDescription)")
            }
        }
        return (LampWritingImportItem(
            id: candidate.key + "#deck",
            kind: .deck,
            path: file.path,
            writingID: candidate.writingID,
            idDerived: candidate.idDerived,
            title: title,
            action: action,
            changes: action == .conflict ? ["deck"] : [],
            errors: errors,
            warnings: [],
            normalized: [],
            libraryModified: nil
        ), planned, planned == nil ? [:] : assets)
    }

    /// A regular file, inside `folder` once links are followed.
    private static func isFile(_ url: URL, inside folder: URL) -> Bool {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
            && (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Links between files of the same import become links between their
    /// writings, and so does a link to a file an earlier import brought in,
    /// found by the id its path gives. A link to anything else stays as
    /// written and is warned about.
    internal static func linkWritings(_ candidates: inout [Candidate], existing: Set<String>) {
        var byPath: [String: String] = [:]
        for candidate in candidates where candidate.errors.isEmpty && candidate.writing != nil {
            let path = candidate.path.precomposedStringWithCanonicalMapping.lowercased()
            if byPath[path] == nil { byPath[path] = candidate.writingID }
        }
        for index in candidates.indices {
            guard let writing = candidates[index].writing else { continue }
            var unresolved: [String] = []
            var made: [String: String] = [:]
            let candidate = candidates[index]
            let content = rewritingLinks(in: writing.content) { isImage, _, target in
                guard !isImage, isRelativeLink(target) else { return nil }
                let file = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
                guard ["md", "markdown"].contains((file as NSString).pathExtension.lowercased()) else {
                    return nil
                }
                let resolved = resolve(file, from: candidate.path)
                let earlier = ([resolved] + earlierPaths(of: resolved, ancestry: candidate.ancestry))
                    .map { derivedID(path: $0) }
                    .first(where: existing.contains)
                guard let id = byPath[resolved.precomposedStringWithCanonicalMapping.lowercased()] ?? earlier else {
                    if !unresolved.contains(target) { unresolved.append(target) }
                    return nil
                }
                made[id] = target
                return LampApplicationLink.writingURL(id: id).absoluteString
            }
            candidates[index].links = made
            if content != writing.content {
                candidates[index].writing = writing.withContent(content)
                candidates[index].normalized.append("Links to other writings of this import open them in Lamp.")
            }
            if !unresolved.isEmpty {
                candidates[index].warnings.append("Links to files not in this import will not open in Lamp: \(unresolved.prefix(5).joined(separator: ", "))\(unresolved.count > 5 ? ", and \(unresolved.count - 5) more" : "").")
            }
        }
    }

    /// Whether two stored copies of a writing are the same: every field a
    /// person writes, its blocks, its media and, unless asked not to, when it
    /// was last saved.
    static func sameStoredCopy(_ a: LampDevotional, _ b: LampDevotional, ignoringTime: Bool = false) -> Bool {
        a.differingAuthoredFields(from: b).isEmpty
            && LampSyncJSONComparison.sameValue(a.contentJSON, b.contentJSON)
            && LampSyncJSONComparison.sameValue(a.mediaJSON, b.mediaJSON)
            && (ignoringTime || a.lastModified.map { Int($0.timeIntervalSince1970) }
                == b.lastModified.map { Int($0.timeIntervalSince1970) })
    }

    /// Writes the chosen items of a plan. Each is checked again first: one
    /// whose copy in the store changed after the plan was made is refused
    /// rather than overwritten, since the plan no longer describes what would
    /// happen. One that fails is reported, and the rest go on, so what was
    /// written can still be undone.
    ///
    /// Importing is the person's choice, so it counts as a fresh save for
    /// sync. A chosen conflict is stamped newer than both copies, so the
    /// other devices take it too (`LampSyncMerge.resolutionTimestamp`); a
    /// writing brought back after a deletion is dated after that deletion,
    /// and one whose file gave no time is dated now.
    static func apply(
        _ plan: LampWritingImportPlan,
        selecting itemIDs: Set<String>,
        to store: some LampWritingImportStore
    ) async throws -> LampWritingImportResult {
        let existing = Dictionary(
            try await store.importableWritings().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var imported: [LampWritingImportItem] = []
        var refused: [LampWritingImportItem] = []
        var failed: [LampWritingImportFailure] = []
        var saved: [String] = []
        var undo = LampWritingImportUndo(id: UUID().uuidString, importedAt: Date(), writings: [], decks: [])
        let now = Date()
        let chosen = plan.items.filter { $0.kind == .writing && itemIDs.contains($0.id) && $0.canImport }
        // The writings there will be: a link to one that will not be is put
        // back as it was written.
        let available = Set(existing.keys).union(chosen.map(\.writingID))
        for item in chosen {
            guard let planned = plan.writings[item.id] else { continue }
            let local = existing[planned.id]
            // The whole copy, not only what an import compares: an edit in
            // the editor may change the structured body or media alone, in
            // the same second.
            guard local == plan.locals[item.id] else {
                refused.append(item)
                continue
            }
            var writing = planned
            for (id, target) in plan.links[item.id] ?? [:] where !available.contains(id) {
                writing = writing.withContent(writing.content.replacingOccurrences(
                    of: "](\(LampApplicationLink.writingURL(id: id).absoluteString))", with: "](\(target))"
                ))
            }
            switch item.action {
            case .conflict:
                let resolved = LampSyncMerge.resolutionTimestamp(
                    localModified: local?.lastModified.map { Int($0.timeIntervalSince1970) },
                    incomingModified: writing.lastModified.map { Int($0.timeIntervalSince1970) },
                    now: Int(now.timeIntervalSince1970)
                ) ?? Int(now.timeIntervalSince1970)
                writing = writing.withLastModified(Date(timeIntervalSince1970: TimeInterval(resolved)))
            case .create where plan.restored.contains(item.id):
                // After the deletion, as well as now: a copy another device
                // kept is no later than the deletion, give or take its clock.
                let deleted = try await store.writingDeletion(id: writing.id)?.deletedAt
                    .map { Int(($0 + 999) / 1_000) } ?? 0
                writing = writing.withLastModified(Date(timeIntervalSince1970: TimeInterval(
                    max(Int(now.timeIntervalSince1970), deleted + 1)
                )))
            case .create where writing.lastModified == nil:
                writing = writing.withLastModified(now)
            default:
                break
            }

            // Pictures and recordings: copied in, and listed with the
            // writing, under the ids its text already names. One already
            // listed is the same file, since its id holds its bytes.
            var added: [String] = []
            do {
                var mediaJSON = local?.mediaJSON
                let listed = Set((local?.mediaReferences ?? []).map(\.id))
                for file in plan.media[item.id] ?? [] where !listed.contains(file.id) {
                    let filename = try await store.storeImportedMedia(from: file.url, writingID: writing.id)
                    added.append(filename)
                    mediaJSON = try LampPortableDevotionalMedia.appending(
                        file.reference(storedAs: filename), to: mediaJSON
                    )
                }
                writing.mediaJSON = mediaJSON
                guard let stored = try await store.saveImportedWriting(writing, expecting: local) else {
                    // Changed while this ran: the copy stays, and so must
                    // not the files brought for it.
                    for filename in added {
                        try? await store.removeImportedMedia(writingID: writing.id, filename: filename)
                    }
                    refused.append(item)
                    continue
                }
                saved.append(writing.id)
                imported.append(item)
                undo.writings.append(.init(
                    id: writing.id,
                    title: writing.title,
                    written: try LampSyncConflictPayload.encode(stored),
                    previous: try local.map(LampSyncConflictPayload.encode),
                    addedMedia: added
                ))
            } catch {
                for filename in added {
                    try? await store.removeImportedMedia(writingID: writing.id, filename: filename)
                }
                failed.append(.init(item: item, reason: error.localizedDescription))
            }
        }
        try await store.recordWritingsPresent(saved)

        let deckItems = plan.items.filter { $0.kind == .deck && itemIDs.contains($0.id) && $0.canImport }
        if !deckItems.isEmpty, store.supportsDecks {
            let present = Set(try await store.importableWritings().map(\.id))
            for item in deckItems {
                guard let planned = plan.decks[item.id] else { continue }
                // A deck goes in only beside its writing, and only over the
                // copy the plan saw.
                guard present.contains(item.writingID) else {
                    refused.append(item)
                    continue
                }
                do {
                    guard try await store.saveImportedDeck(
                        planned.deck, assets: planned.assets, expecting: planned.local
                    ) else {
                        refused.append(item)
                        continue
                    }
                    imported.append(item)
                    undo.decks.append(.init(
                        id: planned.deck.id, title: planned.deck.title,
                        written: planned.deck, previous: planned.local
                    ))
                } catch {
                    failed.append(.init(item: item, reason: error.localizedDescription))
                }
            }
        }
        return LampWritingImportResult(imported: imported, refused: refused, failed: failed, undo: undo)
    }

    /// Puts back what an import changed: a writing or deck it made goes, and
    /// one it changed is restored. Anything changed since the import, in any
    /// way, is left as it is, and said.
    static func undo(
        _ record: LampWritingImportUndo,
        in store: some LampWritingImportStore
    ) async throws -> LampWritingImportUndoResult {
        let current = Dictionary(
            try await store.importableWritings().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var undone: [String] = []
        var kept: [String] = []
        var restoredIDs: [String] = []
        var restored: [String: String] = [:]
        let now = Int(Date().timeIntervalSince1970)
        for entry in record.writings.reversed() {
            guard let writing = current[entry.id] else { continue }
            guard let written = LampSyncConflictPayload.devotional(from: entry.written),
                  sameStoredCopy(writing, written) else {
                kept.append(entry.title)
                continue
            }
            let done: Bool
            if let payload = entry.previous,
               let previous = LampSyncConflictPayload.devotional(from: payload) {
                // Dated after the import, so sync carries the undoing too.
                let stamp = max(now, Int((written.lastModified ?? Date()).timeIntervalSince1970) + 1)
                if let stored = try await store.saveImportedWriting(
                    previous.withLastModified(Date(timeIntervalSince1970: TimeInterval(stamp))),
                    expecting: writing
                ) {
                    restoredIDs.append(entry.id)
                    restored[entry.id] = try LampSyncConflictPayload.encode(stored)
                    done = true
                } else {
                    done = false
                }
            } else {
                done = try await store.deleteImportedWriting(id: entry.id, expecting: writing)
            }
            guard done else {
                kept.append(entry.title)
                continue
            }
            for filename in entry.addedMedia {
                try? await store.removeImportedMedia(writingID: entry.id, filename: filename)
            }
            undone.append(entry.title)
        }
        try await store.recordWritingsPresent(restoredIDs)

        if !record.decks.isEmpty, store.supportsDecks {
            let decks = Dictionary(
                try await store.importableDecks().map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for entry in record.decks.reversed() {
                guard let deck = decks[entry.id] else { continue }
                guard deck == entry.written else {
                    kept.append(entry.title)
                    continue
                }
                // The pictures the earlier copy named are still there: an
                // import stores a changed picture under a new name.
                let done = if let previous = entry.previous {
                    try await store.saveImportedDeck(previous, assets: [:], expecting: deck)
                } else {
                    try await store.deleteImportedDeck(id: entry.id, expecting: deck)
                }
                if done { undone.append(entry.title) } else { kept.append(entry.title) }
            }
        }
        return LampWritingImportUndoResult(undone: undone, kept: kept, restored: restored)
    }
}

extension LampWritingImportItem {
    /// The same row, refused for `reason`.
    func rejecting(_ reason: String) -> LampWritingImportItem {
        LampWritingImportItem(
            id: id, kind: kind, path: path, writingID: writingID, idDerived: idDerived,
            title: title, action: .rejected, changes: [], errors: errors + [reason],
            warnings: warnings, normalized: normalized, libraryModified: libraryModified
        )
    }
}

/// A picture or recording a writing's text names, found beside its file.
public struct LampWritingImportMedia: Equatable, Sendable {
    /// The id the writing's text names it by (`media/<id>`).
    public let id: String
    public let url: URL
    public let type: LampMediaType
    public let alt: String?

    func reference(storedAs filename: String) -> LampDevotionalMediaReference {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        var width: Int?
        var height: Int?
        if type == .image,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int
            height = properties[kCGImagePropertyPixelHeight] as? Int
        }
        return LampDevotionalMediaReference(
            id: id,
            type: type,
            filename: filename,
            mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream",
            size: (attributes?[.size] as? NSNumber)?.intValue,
            width: width,
            height: height,
            alt: type == .image ? alt : nil
        )
    }
}

extension LampLibrary: LampWritingImportStore {
    public func importableWritings() throws -> [LampDevotional] {
        try personalDevotionals()
    }

    public func saveImportedWriting(
        _ writing: LampDevotional, expecting current: LampDevotional?
    ) throws -> LampDevotional? {
        try savePersonalDevotional(writing, preserveLastModified: true, onlyOver: current)
    }

    public func recordWritingsPresent(_ ids: [String]) throws {
        try recordPersonalDevotionalsPresent(ids)
    }

    public func deleteImportedWriting(id: String, expecting current: LampDevotional) throws -> Bool {
        try deletePersonalDevotional(id: id, onlyIf: current)
    }

    public func storeImportedMedia(from url: URL, writingID: String) throws -> String {
        try storePersonalDevotionalMedia(from: url, devotionalID: writingID).lastPathComponent
    }

    public func removeImportedMedia(writingID: String, filename: String) throws {
        guard LampPortableDevotionalMedia.isSafePathComponent(filename),
              let folder = LampPortableDevotionalMedia.folderURL(
                rootURL: rootURL, scope: .devotional, ownerID: writingID
              ) else { return }
        let file = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public nonisolated var supportsDecks: Bool { true }

    public func importableDecks() throws -> [LampPresentationDeck] {
        try LampPresentationDeckStore(rootURL: rootURL).decks()
    }

    /// Checked and saved within one call on the library's actor; decks are
    /// files, which only the app's own windows write besides.
    public func saveImportedDeck(
        _ deck: LampPresentationDeck, assets: [String: URL], expecting current: LampPresentationDeck?
    ) throws -> Bool {
        let store = LampPresentationDeckStore(rootURL: rootURL)
        guard try store.deck(id: deck.id) == current else { return false }
        for (path, source) in assets.sorted(by: { $0.key < $1.key }) {
            guard LampPresentationDeckValidator.isSafeAssetPath(path) else { continue }
            let destination = store.decksDirectoryURL.appendingPathComponent(path)
            // Named by the deck and the picture's bytes, so a file already
            // there is this very picture.
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try store.save(deck)
        return true
    }

    /// Removes the deck's file only. A deletion other Macs must hear of is
    /// recorded by the app, which keeps the deck ledger.
    public func deleteImportedDeck(id: String, expecting current: LampPresentationDeck) throws -> Bool {
        let store = LampPresentationDeckStore(rootURL: rootURL)
        guard try store.deck(id: id) == current else { return false }
        try store.delete(id: id)
        return true
    }

    /// What importing these files would do, without writing anything.
    public func planWritingImport(
        _ files: [LampWritingImportFile],
        comparingWithLibrary: Bool = true
    ) async throws -> LampWritingImportPlan {
        try await LampWritingImport.plan(files, in: self, comparingWithLibrary: comparingWithLibrary)
    }

    /// Writes the chosen items of a plan: see `LampWritingImport.apply`.
    @discardableResult
    public func applyWritingImport(
        _ plan: LampWritingImportPlan,
        selecting itemIDs: Set<String>
    ) async throws -> LampWritingImportResult {
        try await LampWritingImport.apply(plan, selecting: itemIDs, to: self)
    }

    /// Puts back what an import changed: see `LampWritingImport.undo`.
    public func undoWritingImport(_ record: LampWritingImportUndo) async throws -> LampWritingImportUndoResult {
        try await LampWritingImport.undo(record, in: self)
    }
}
