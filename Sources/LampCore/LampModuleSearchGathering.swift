import Foundation
import GRDB
import LampModuleKit

/// A search of every kind of module: its words, a Strong's key, highlight
/// colours or a writing's date, tags and kind, and what narrows it. Asked
/// the same way on both apps, and answered from each app's own modules
/// (`LampModuleSearch.gather`).
public struct LampModuleSearchRequest: Sendable {
    public let query: String
    /// The kinds searched; nil for every kind.
    public let kinds: Set<LampModuleKind>?
    /// The modules searched; nil for every module.
    public let moduleIDs: Set<String>?
    /// The books whose verses and highlights are searched; nil for all.
    public let bookRange: ClosedRange<Int>?
    /// A Strong's key, trimmed; nil when none was given.
    public let strongsKey: String?
    public let highlightColors: Set<String>?
    public let devotionalCriteria: LampDevotionalSearchCriteria
    /// Scripture from this translation, or from the one with the most
    /// matches where it has none (`LampScriptureChoice`), for a page of every
    /// kind. Nil for a page of Scripture alone, which wants every translation.
    public let preferredTranslationID: String?
    /// The query by the shared grammar.
    public let parsedQuery: LampSearchQuery

    public init(
        query: String,
        kinds: Set<LampModuleKind>? = nil,
        moduleIDs: Set<String>? = nil,
        bookRange: ClosedRange<Int>? = nil,
        strongsKey: String? = nil,
        highlightColors: Set<String>? = nil,
        devotionalCriteria: LampDevotionalSearchCriteria = .init(),
        preferredTranslationID: String? = nil
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        self.kinds = kinds
        self.moduleIDs = moduleIDs
        self.bookRange = bookRange
        let key = strongsKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.strongsKey = key?.isEmpty == false ? key : nil
        self.highlightColors = highlightColors
        self.devotionalCriteria = devotionalCriteria
        self.preferredTranslationID = preferredTranslationID
        self.parsedQuery = LampSearchQuery(trimmed)
    }

    /// Whether there are words to find, even ones an index can't ask for by
    /// itself, as `*faith`, whose full-text query is empty.
    public var hasWords: Bool { !parsedQuery.isEmpty && !parsedQuery.plainText.isEmpty }

    public var hasColors: Bool { highlightColors?.isEmpty == false }

    public func wants(_ kind: LampModuleKind) -> Bool { kinds?.contains(kind) ?? true }

    public func includes(moduleID: String) -> Bool { moduleIDs?.contains(moduleID) ?? true }

    /// Whether the request asks for anything at all: words, a key, colours,
    /// or a writing's date, tags or kind where writing is searched.
    public var asksForAnything: Bool {
        hasWords || strongsKey != nil || hasColors || (!devotionalCriteria.isEmpty && wants(.devotional))
    }
}

/// A database core searches with its own searches of commentary, books,
/// notes, writing and quizzes, the modules of one kind in it, and how to
/// read it. The Mac keeps a module in a file of its own and the bundled ones
/// together; the phone keeps every module it installs in one database.
public struct LampModuleSearchDatabase {
    /// Names the database to the app, as its results are made from it.
    public let id: String
    /// The modules of the kind searched in it, read from it.
    public let modules: (Database) throws -> [LampSearchedModule]
    public let read: (_ body: (Database) throws -> Void) throws -> Void

    public init(
        id: String,
        modules: @escaping (Database) throws -> [LampSearchedModule],
        read: @escaping (_ body: (Database) throws -> Void) throws -> Void
    ) {
        self.id = id
        self.modules = modules
        self.read = read
    }

    /// A database whose modules are known without reading it.
    public init(
        id: String,
        modules: [LampSearchedModule],
        read: @escaping (_ body: (Database) throws -> Void) throws -> Void
    ) {
        self.init(id: id, modules: { _ in modules }, read: read)
    }

    func reading<T>(_ body: (Database) throws -> T) throws -> T {
        var value: T?
        try read { value = try body($0) }
        guard let value else { throw NotRead(database: id) }
        return value
    }

    /// A database whose `read` returned without reading it.
    struct NotRead: Error {
        let database: String
    }
}

/// What a search needs of an app's kind of result: where it came from, what
/// it is ranked by, and how its snippet is set once cut.
public struct LampModuleSearchResultShape<Result> {
    public let kind: (Result) -> LampModuleKind
    public let module: (Result) -> String
    /// The texts that name the result and the texts that show it, and
    /// whether its text holds the query's words together
    /// (`LampModuleSearch.mergeRank`).
    public let named: (Result) -> [String]
    public let shown: (Result) -> [String]
    public let holdsPhrase: (Result) -> Bool
    public let withSnippet: (Result, String) -> Result

    public init(
        kind: @escaping (Result) -> LampModuleKind,
        module: @escaping (Result) -> String,
        named: @escaping (Result) -> [String],
        shown: @escaping (Result) -> [String],
        holdsPhrase: @escaping (Result) -> Bool,
        withSnippet: @escaping (Result, String) -> Result
    ) {
        self.kind = kind
        self.module = module
        self.named = named
        self.shown = shown
        self.holdsPhrase = holdsPhrase
        self.withSnippet = withSnippet
    }
}

extension LampModuleSearchResultShape where Result == LampModuleSearchResult {
    /// Core's own results, ranked as `LampModuleSearch.ranked` ranks them.
    public static var core: Self {
        Self(
            kind: \.kind,
            module: \.moduleID,
            // A quiz result's title is its question, a sentence rather than a
            // name: it counts as what the result shows.
            named: { $0.kind == .quiz ? [$0.subtitle ?? ""] : [$0.title, $0.subtitle ?? ""] },
            shown: { $0.kind == .quiz ? [$0.title, $0.snippet] : [$0.snippet] },
            holdsPhrase: \.holdsPhrase,
            withSnippet: { $0.withSnippet($1) }
        )
    }
}

/// An app's modules, as a search reads them. Core decides which are asked,
/// for what and for how many; each closure answers for the request the app
/// built its sources for.
public struct LampModuleSearchSources<Result> {
    public let shape: LampModuleSearchResultShape<Result>
    /// The databases searched for one kind: commentary, books, notes,
    /// writing or quizzes, in the order searched. Asked only for the kinds a
    /// search covers.
    public let databases: (LampModuleKind) throws -> [LampModuleSearchDatabase]
    /// Core's results from one database as the app's own, one for each hit
    /// and in its order, made while the database is open, for anything else
    /// the app shows of them.
    public let results: (
        _ hits: [LampModuleSearchResult], _ kind: LampModuleKind,
        _ database: LampModuleSearchDatabase, _ db: Database
    ) throws -> [Result]
    /// The translations searched, in the order they are listed: what the
    /// Scripture choice breaks ties by.
    public let translations: () throws -> [String]
    /// The verses matching the words, or the key where there are none, from
    /// the translations named, at most `limit`. Nil names every translation.
    public let verses: ((_ translationIDs: [String]?, _ limit: Int) throws -> [Result])?
    /// The dictionary entries matching the words or the key.
    public let dictionaries: ((_ limit: Int) throws -> [Result])?
    /// The reading plans matching the words.
    public let plans: ((_ limit: Int) throws -> [Result])?
    /// The highlights of the colours, whose verses hold the words where
    /// there are words.
    public let highlights: ((_ limit: Int) throws -> [Result])?

    public init(
        shape: LampModuleSearchResultShape<Result>,
        databases: @escaping (LampModuleKind) throws -> [LampModuleSearchDatabase],
        results: @escaping (
            _ hits: [LampModuleSearchResult], _ kind: LampModuleKind,
            _ database: LampModuleSearchDatabase, _ db: Database
        ) throws -> [Result],
        translations: @escaping () throws -> [String],
        verses: ((_ translationIDs: [String]?, _ limit: Int) throws -> [Result])?,
        dictionaries: ((_ limit: Int) throws -> [Result])?,
        plans: ((_ limit: Int) throws -> [Result])?,
        highlights: ((_ limit: Int) throws -> [Result])?
    ) {
        self.shape = shape
        self.databases = databases
        self.results = results
        self.translations = translations
        self.verses = verses
        self.dictionaries = dictionaries
        self.plans = plans
        self.highlights = highlights
    }
}

/// A search's results from every kind, unmerged, each kind's asked for
/// `perKind`: for `ranked` or `rankedByKind` to merge.
public struct LampModuleSearchGathering<Result> {
    public let request: LampModuleSearchRequest
    /// Where Scripture came from, where a translation was preferred and
    /// there were others to choose from.
    public let scripture: LampScriptureChoice?
    let shape: LampModuleSearchResultShape<Result>
    let found: [Found]
    let databases: [LampModuleSearchDatabase]

    /// A result, and for one found without its snippet, the database it
    /// came from and core's result, to cut the snippet from once kept.
    struct Found {
        let result: Result
        let deferred: (database: Int, kind: LampModuleKind, hit: LampModuleSearchResult)?
    }

    /// Every result found, unmerged.
    public var results: [Result] { found.map(\.result) }

    /// The results as one list, best first (`LampModuleSearch.ranked`), at
    /// most `limit`, with their snippets.
    public func ranked(limit: Int) throws -> [Result] {
        try filled(ordered(limit: limit))
    }

    /// The results ranked, then shared among their kinds
    /// (`LampModuleSearch.sharedByKind`): at most `limit`, each kind's best,
    /// a kind's together, and the kinds that had more than they kept. Ask
    /// each kind for at least `limit + 1`, so that a kind alone on the page
    /// still says it has more.
    public func rankedByKind(limit: Int) throws -> LampModuleSearchPage<Result> {
        let share = LampModuleSearch.sharedByKind(
            ordered(limit: found.count), limit: limit, kind: { shape.kind($0.result).rawValue }
        )
        return LampModuleSearchPage(
            results: try filled(share.results),
            moreIn: Set(share.moreIn.compactMap(LampModuleKind.init(rawValue:))),
            scripture: scripture
        )
    }

    /// Without words to rank by, every result ranks alike, and the modules
    /// of a kind take turns, each in the order it gave its own.
    private func ordered(limit: Int) -> [Found] {
        LampModuleSearch.ranked(
            found, by: request.parsedQuery, limit: limit,
            named: { shape.named($0.result) },
            shown: { shape.shown($0.result) },
            holdingPhrase: { shape.holdsPhrase($0.result) },
            from: { (shape.kind($0.result).rawValue, shape.module($0.result)) }
        )
    }

    /// The results with the snippets they were found without, cut in the
    /// databases they came from.
    private func filled(_ kept: [Found]) throws -> [Result] {
        var waiting: [Int: [LampModuleKind: [LampModuleSearchResult]]] = [:]
        var order: [Int] = []
        for entry in kept {
            guard let deferred = entry.deferred else { continue }
            if waiting[deferred.database] == nil { order.append(deferred.database) }
            waiting[deferred.database, default: [:]][deferred.kind, default: []].append(deferred.hit)
        }
        var snippets: [Int: [String: String]] = [:]
        for database in order {
            try Task.checkCancellation()
            let kinds = waiting[database] ?? [:]
            snippets[database] = try databases[database].reading { db in
                var cut: [String: String] = [:]
                for (kind, hits) in kinds {
                    let query = request.parsedQuery
                    let snipped: [LampModuleSearchResult] = switch kind {
                    case .commentary: try LampModuleSearch.commentarySnippets(for: hits, in: db, query: query)
                    case .book: try LampModuleSearch.bookSnippets(for: hits, in: db, query: query)
                    case .notes: try LampModuleSearch.noteSnippets(for: hits, in: db, query: query)
                    case .devotional: try LampModuleSearch.devotionalSnippets(for: hits, in: db, query: query)
                    default: hits
                    }
                    for hit in snipped { cut[hit.id] = hit.snippet }
                }
                return cut
            }
        }
        return kept.map { entry in
            guard let deferred = entry.deferred else { return entry.result }
            let snippet = snippets[deferred.database]?[deferred.hit.id] ?? deferred.hit.snippet
            return shape.withSnippet(entry.result, snippet)
        }
    }
}

/// A page of results shared among the kinds that matched.
public struct LampModuleSearchPage<Result> {
    /// The kept results, a kind's together, the kinds in
    /// `LampModuleSearch.kindOrder`. Shown by `shelfOrder`.
    public let results: [Result]
    /// The kinds that had more than they kept. Scripture from one
    /// translation offers the others besides (`scripture.alsoIn`), apart
    /// from this: its own verses may all be here.
    public let moreIn: Set<LampModuleKind>
    public let scripture: LampScriptureChoice?
}

extension LampModuleSearch {
    /// Every kind's results for `request` from one app's `sources`, each
    /// kind asked for `perKind`, unmerged. Nil when the request asks for
    /// nothing.
    ///
    /// Which kinds are searched for which request is decided here, once for
    /// both apps:
    /// - Scripture and dictionaries for words or a Strong's key. Scripture
    ///   comes from the preferred translation where one is given and there
    ///   are others (`LampScriptureChoice`).
    /// - Commentary, books, notes, reading plans and quizzes for words.
    /// - Writing for words, or for its date, tags and kind alone.
    /// - Highlights for words or colours.
    ///
    /// Each database is asked for the whole of `perKind` and the merge makes
    /// the cut: its rows come best first, so giving the first database every
    /// place would leave the rest unsearched. Commentary, books, notes and
    /// writing are found without their snippets, cut once the merge has kept
    /// them: cutting one for every row each database offered, most of them
    /// then dropped, was most of a search's time.
    public static func gather<Result>(
        _ request: LampModuleSearchRequest,
        perKind: Int,
        from sources: LampModuleSearchSources<Result>
    ) throws -> LampModuleSearchGathering<Result>? {
        guard request.asksForAnything else { return nil }
        let limit = max(perKind, 1)
        let query = request.parsedQuery
        var found: [LampModuleSearchGathering<Result>.Found] = []
        var databases: [LampModuleSearchDatabase] = []
        func add(_ results: [Result]) {
            found += results.map { .init(result: $0, deferred: nil) }
        }

        var scripture: LampScriptureChoice?
        if (request.hasWords || request.strongsKey != nil) && request.wants(.translation),
           let verses = sources.verses {
            let order = try sources.translations().filter { request.includes(moduleID: $0) }
            if let preferred = request.preferredTranslationID, order.count > 1 {
                if let chosen = try LampScriptureChoice.choose(
                    preferred: preferred, order: order, limit: limit,
                    verses: { id, limit in
                        try Task.checkCancellation()
                        return try verses([id], limit)
                    }
                ) {
                    add(chosen.matches)
                    scripture = chosen.choice
                }
            } else if !order.isEmpty {
                add(try verses(request.moduleIDs == nil ? nil : order, limit))
            }
        }

        if (request.hasWords || request.strongsKey != nil) && request.wants(.dictionary),
           let dictionaries = sources.dictionaries {
            try Task.checkCancellation()
            add(try dictionaries(limit))
        }

        let searchedInDatabases: [(kind: LampModuleKind, searched: Bool)] = [
            (.commentary, request.hasWords),
            (.book, request.hasWords),
            (.notes, request.hasWords),
            (.devotional, request.hasWords || !request.devotionalCriteria.isEmpty),
            (.quiz, request.hasWords),
        ]
        for (kind, searched) in searchedInDatabases where searched && request.wants(kind) {
            for database in try sources.databases(kind) {
                try Task.checkCancellation()
                let index = databases.count
                databases.append(database)
                found += try database.reading { db in
                    let modules = try database.modules(db)
                    guard !modules.isEmpty else { return [] }
                    let hits: [LampModuleSearchResult] = switch kind {
                    case .commentary:
                        try commentary(in: db, modules: modules, query: query, limit: limit, snippets: false)
                    case .book:
                        try books(in: db, modules: modules, query: query, limit: limit, snippets: false)
                    case .notes:
                        try notes(in: db, modules: modules, query: query, limit: limit, snippets: false)
                    case .devotional:
                        try devotionals(
                            in: db, modules: modules, query: query, criteria: request.devotionalCriteria,
                            limit: limit, snippets: false
                        )
                    default:
                        try quizzes(in: db, modules: modules, query: query, limit: limit)
                    }
                    guard !hits.isEmpty else { return [] }
                    let results = try sources.results(hits, kind, database, db)
                    // Quizzes carry their snippets; the rest wait for the cut.
                    return zip(results, hits).map { result, hit in
                        .init(result: result, deferred: kind == .quiz ? nil : (index, kind, hit))
                    }
                }
            }
        }

        if request.hasWords && request.wants(.plan), let plans = sources.plans {
            add(try plans(limit))
        }

        if (request.hasWords || request.hasColors) && request.wants(.highlights),
           let highlights = sources.highlights {
            try Task.checkCancellation()
            add(try highlights(limit))
        }

        return LampModuleSearchGathering(
            request: request, scripture: scripture, shape: sources.shape, found: found, databases: databases
        )
    }
}
