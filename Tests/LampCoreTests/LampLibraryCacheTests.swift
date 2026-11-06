import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

struct LampLibraryCacheTests {
    private func translation(name: String = "Alpha", key: String = "G26") -> String {
        #"""
        {"meta":{"schemaVersion":"1.0","id":"T","type":"translation","name":"\#(name)","abbreviation":"T","language":"en","versification":"eng"},
         "books":[{"id":"John","name":"John","number":43,"testament":"NT","chapters":[{"chapter":1,"verses":[
           {"v":1,"content":{"text":"love","annotations":[{"type":"strongs","start":0,"end":4,"data":{"strongs":"\#(key)"}}]}}
         ]}]}]}
        """#
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func install(_ json: String, root: URL, library: LampLibrary) async throws {
        let archive = root.appendingPathComponent("T.lamp")
        _ = try LampModuleCompiler().compile(data: Data(json.utf8), sourceFilename: "T.json", destinationURL: archive)
        _ = try await library.install(from: archive)
    }

    private func database(in library: LampLibrary) throws -> URL {
        try #require(FileManager.default.contentsOfDirectory(
            at: library.rootURL.appendingPathComponent("Databases"), includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "sqlite" })
    }

    @Test func aSecondLibraryInstanceSeesAReinstallAndReusesPersistedFingerprints() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await install(translation(), root: root, library: reader)
        #expect(try await reader.installedModules().map(\.name) == ["Alpha"])
        _ = try await reader.chapter(moduleID: "T", bookNumber: 43, chapterNumber: 1)
        try await reader.buildStrongsIndexes()
        let source = try database(in: reader).resolvingSymlinksInPath()
        let index = try DatabaseQueue(path: reader.rootURL.appendingPathComponent("Indexes/StrongsIndex.sqlite").path)
        let revision = try LampDatabaseFileRevision(url: source).serialized()
        let saved = try await index.read {
            try LampStrongsIndex.cachedFingerprint(translationID: "T", databasePath: source.path, fileRevision: revision, in: $0)
        }
        #expect(saved?.hasPrefix("v\(LampStrongsIndex.formatVersion):") == true,
                "source path aliases must resolve to the same persisted digest")
        let second = LampLibrary(rootURL: reader.rootURL.resolvingSymlinksInPath())
        #expect(try await second.strongsAnalyses(key: "G26").first?.occurrenceCount == 1)
        #expect(try await second.installedModules() == reader.installedModules())

        // Another process replaces the database while the first reader keeps
        // a connection and metadata cached against the previous file.
        try await install(translation(name: "Bravo", key: "G25"), root: root, library: second)
        #expect(try await reader.installedModules().map(\.name) == ["Bravo"])
        #expect(try await reader.strongsAnalyses(key: "G26").first?.occurrenceCount == 0)
        #expect(try await reader.strongsAnalyses(key: "G25").first?.occurrenceCount == 1)
        try await second.remove(moduleID: "T")
        #expect(try await reader.installedModules().isEmpty)
    }

    @Test func sameSizeInPlaceEditsWithRestoredModificationTimeInvalidateBothCaches() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await install(translation(), root: root, library: reader)
        try await reader.buildStrongsIndexes()
        #expect(try await reader.installedModules().first?.name == "Alpha")
        #expect(try await reader.versification(moduleID: "T").scheme == .english)
        let source = try database(in: reader)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let before = try LampDatabaseFileRevision(url: source)
        let writer = try DatabaseQueue(path: source.path)
        try await writer.write { db in
            try db.execute(sql: "UPDATE translation_meta SET name = 'Bravo', versification = 'org'; UPDATE verses SET annotations_json = replace(annotations_json, 'G26', 'G25');")
        }
        try FileManager.default.setAttributes([.modificationDate: try #require(attributes[.modificationDate])], ofItemAtPath: source.path)
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int == attributes[.size] as? Int)
        #expect(try LampDatabaseFileRevision(url: source) != before)
        #expect(try await reader.versification(moduleID: "T").scheme == .original)
        #expect(try await reader.installedModules().first?.name == "Bravo")
        #expect(try await reader.strongsAnalyses(key: "G26").first?.occurrenceCount == 0)
        #expect(try await LampLibrary(rootURL: reader.rootURL).strongsAnalyses(key: "G25").first?.occurrenceCount == 1)
    }

    @Test func aWALCommitInvalidatesMetadataWithoutReplacingTheMainFile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await install(translation(), root: root, library: reader)
        let source = try database(in: reader)
        let writer = try DatabaseQueue(path: source.path)
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; PRAGMA wal_checkpoint(TRUNCATE);")
        }
        #expect(try await reader.installedModules().first?.name == "Alpha")
        let before = try LampDatabaseFileRevision(url: source)
        let mainModified = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await writer.write { try $0.execute(sql: "UPDATE translation_meta SET name = 'Bravo'") }
        #expect(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == mainModified)
        #expect(try LampDatabaseFileRevision(url: source) != before)
        #expect(try await reader.installedModules().first?.name == "Bravo")
    }

    @Test func fingerprintReuseRequiresTheSameFileRevisionPathAndAlgorithmVersion() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try LampStrongsIndex.createTables(in: db)
            try LampStrongsIndex.cacheFingerprint("digest", translationID: "T", databasePath: "/library/T", fileRevision: "revision", in: db)
        }
        let cached = try queue.read { db in
            [try LampStrongsIndex.cachedFingerprint(translationID: "T", databasePath: "/library/T", fileRevision: "revision", in: db),
             try LampStrongsIndex.cachedFingerprint(translationID: "T", databasePath: "/library/other", fileRevision: "revision", in: db),
             try LampStrongsIndex.cachedFingerprint(translationID: "T", databasePath: "/library/T", fileRevision: "changed", in: db)]
        }
        #expect(cached == ["digest", nil, nil])
        try queue.write { try $0.execute(sql: "UPDATE strongs_source_fingerprints SET format_version = ?", arguments: [LampStrongsIndex.formatVersion - 1]) }
        #expect(try queue.read { try LampStrongsIndex.cachedFingerprint(translationID: "T", databasePath: "/library/T", fileRevision: "revision", in: $0) } == nil)
    }

    @Test func bundledMetadataRefreshesAfterAnOutOfProcessReplacement() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundle.sqlite")
        let writer = try DatabaseQueue(path: source.path)
        try await writer.write { db in
            try db.execute(sql: """
                CREATE TABLE translations(id TEXT, name TEXT, abbreviation TEXT, language TEXT);
                INSERT INTO translations VALUES('T', 'Alpha', 'T', 'en');
                """)
        }
        let reader = LampLibrary(rootURL: root.appendingPathComponent("Library"), bundledModulesArchiveURL: source)
        #expect(try await reader.installedModules().map(\.name) == ["Alpha"])
        try await writer.write { try $0.execute(sql: "UPDATE translations SET name = 'Bravo'") }
        let prepared = reader.rootURL.appendingPathComponent("Bundled/bundled_modules.sqlite")
        try Data(contentsOf: source).write(to: prepared, options: .atomic)
        #expect(try await reader.installedModules().map(\.name) == ["Bravo"])
    }

    /// A bundle of a few megabytes, so that extracting and checking it take
    /// long enough for libraries opened together to overlap.
    private func bundle(at url: URL, named name: String) throws {
        let writer = try DatabaseQueue(path: url.path)
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE translations(id TEXT, name TEXT, abbreviation TEXT, language TEXT);
                CREATE TABLE padding(id INTEGER PRIMARY KEY, text TEXT);
                """)
            try db.execute(sql: "INSERT INTO translations VALUES('T', ?, 'T', 'en')", arguments: [name])
            for row in 0..<4_000 {
                try db.execute(
                    sql: "INSERT INTO padding(id, text) VALUES (?, ?)",
                    arguments: [row, String(repeating: "\(name) \(row) ", count: 60)]
                )
            }
        }
    }

    @Test func librariesPreparingOneBundleTogetherAllGetIt() async throws {
        for _ in 0..<4 {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("bundle.sqlite")
            try bundle(at: source, named: "Alpha")
            // As the app and each lamp-mcp do: libraries of their own, one root.
            let libraries = (0..<6).map { _ in
                LampLibrary(rootURL: root.appendingPathComponent("Library"), bundledModulesArchiveURL: source)
            }
            let names = try await withThrowingTaskGroup(of: [String].self) { group in
                for library in libraries {
                    group.addTask { try await library.installedModules().map(\.name) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(names == Array(repeating: ["Alpha"], count: libraries.count))
            let bundled = root.appendingPathComponent("Library/Bundled")
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: bundled.path))
                == [".prepare.lock", "bundled_modules.sqlite", "bundled_modules.version"])
        }
    }

    @Test func aBundleThatFailsItsCheckLeavesThePreparedOneInPlace() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundle.sqlite")
        try bundle(at: source, named: "Alpha")
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"), bundledModulesArchiveURL: source)
        #expect(try await library.installedModules().map(\.name) == ["Alpha"])
        let bundled = root.appendingPathComponent("Library/Bundled")
        let prepared = bundled.appendingPathComponent("bundled_modules.sqlite")
        let good = try Data(contentsOf: prepared)
        let marker = bundled.appendingPathComponent("bundled_modules.version")
        let goodMarker = try String(contentsOf: marker, encoding: .utf8)

        // A new bundle, of another size, that is no database at all: a later
        // library finds it out of date, and its extraction fails its check. A
        // URL of its own, as a later process has: a URL keeps the file size
        // it last read.
        try Data("not a database".utf8).write(to: source)
        let later = LampLibrary(
            rootURL: root.appendingPathComponent("Library"),
            bundledModulesArchiveURL: URL(fileURLWithPath: source.path)
        )
        await #expect(throws: (any Error).self) { try await later.installedModules() }
        // The prepared file and its marker stay together, the marker still
        // naming the old bundle, so the next launch tries the new one again.
        #expect(try Data(contentsOf: prepared) == good)
        #expect(try String(contentsOf: marker, encoding: .utf8) == goodMarker)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundled.path).allSatisfy {
            !$0.hasPrefix(".bundled_modules-")
        })

        // A good bundle again, of a size its own (the marker is the size), is
        // extracted over the one kept.
        try FileManager.default.removeItem(at: source)
        try bundle(at: source, named: "Bravo Bravo")
        let last = LampLibrary(
            rootURL: root.appendingPathComponent("Library"),
            bundledModulesArchiveURL: URL(fileURLWithPath: source.path)
        )
        #expect(try await last.installedModules().map(\.name) == ["Bravo Bravo"])
    }

    @Test func anExtractionLeftHalfDoneIsClearedAway() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundle.sqlite")
        try bundle(at: source, named: "Alpha")
        let bundled = root.appendingPathComponent("Library/Bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let leftover = bundled.appendingPathComponent(".bundled_modules-\(UUID().uuidString).sqlite")
        try Data("half".utf8).write(to: leftover)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"), bundledModulesArchiveURL: source)
        #expect(try await library.installedModules().map(\.name) == ["Alpha"])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}
