import Foundation
import GRDB
import LampModuleKit
import Testing
@testable import LampCore

/// Phase 0 of `Documentation/ScalabilityPlan.md`: what the library costs at
/// size, measured rather than reasoned about.
///
/// Skipped unless `LAMP_SCALE=1`, because each test builds a corpus and the
/// largest take minutes. Run them in Release — the point is the numbers, and a
/// Debug build flatters SQLite and zlib while penalising everything Swift:
///
///     swift test -c release --filter LampScaleMeasurementTests
///
/// The sizes are environment variables so a run can be widened or narrowed
/// without a rebuild: `LAMP_SCALE_WRITINGS=250,1000,4000`,
/// `LAMP_SCALE_DECKS=25,100,400`, `LAMP_SCALE_MODULES=50,200`,
/// `LAMP_SCALE_COLLECTION_ENTRIES=365`.
///
/// Every line of output begins `SCALE` so a run can be read with grep. Nothing
/// here asserts a timing: a measurement that fails the build on a busy machine
/// teaches a session to ignore it. The expectations are only that the corpus
/// was really built.
struct LampScaleMeasurementTests {
    // MARK: - Running

    private static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["LAMP_SCALE"] == "1"
    }

    private func sizes(_ variable: String, _ fallback: [Int]) -> [Int] {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return fallback }
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? fallback : parsed.sorted()
    }

    private func count(_ variable: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[variable].flatMap(Int.init) ?? fallback
    }

    /// Milliseconds for one call, and its answer.
    private func timed<T>(_ body: () async throws -> T) async rethrows -> (value: T, ms: Double) {
        let clock = ContinuousClock()
        var result: T?
        let elapsed = try await clock.measure { result = try await body() }
        return (result!, Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1_000)
    }

    /// The best of three, which is what a quiet machine's floor looks like.
    private func best<T>(_ runs: Int = 3, _ body: () async throws -> T) async rethrows -> Double {
        var least = Double.greatestFiniteMagnitude
        for _ in 0..<runs { least = min(least, try await timed(body).ms) }
        return least
    }

    private func report(_ line: String) {
        print("SCALE \(line)")
    }

    private func openFileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    private func root(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-scale-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Corpus

    /// A writing of about `kilobytes` of prose, with the metadata a list row
    /// draws, so a projection has something to project.
    private func writing(index: Int, kilobytes: Int = 10) -> LampDevotional {
        let paragraph = "Grace and peace to you from God our Father and the Lord Jesus Christ. "
        let body = String(repeating: paragraph, count: max(1, kilobytes * 1_024 / paragraph.utf8.count))
        return LampDevotional(
            id: "scale-writing-\(index)",
            moduleID: LampPersonalModule.writing.id,
            moduleName: LampPersonalModule.writing.name,
            title: "Writing number \(index)",
            subtitle: index % 3 == 0 ? "A subtitle" : nil,
            author: "The Author",
            date: "2026-01-\(String(format: "%02d", index % 28 + 1))",
            tags: ["scale", index % 2 == 0 ? "morning" : "evening"],
            category: index % 4 == 0 ? "devotional" : "study",
            seriesName: index % 10 == 0 ? "A Series" : nil,
            seriesOrder: index % 10 == 0 ? index : nil,
            summary: "What writing number \(index) is about.",
            content: "# Writing number \(index)\n\n" + body,
            isEditable: true
        )
    }

    /// A book module of roughly `sections` × 2 KB, which is what makes
    /// inspecting and opening one cost something.
    private func bookModuleJSON(id: String, sections: Int) -> String {
        let text = String(repeating: "The word of the Lord stands for ever and is a lamp to the feet. ", count: 32)
        let body = (0..<sections).map { section in
            """
            {"id":"s\(section)","type":"chapter","title":"Section \(section)",
             "content":[{"type":"paragraph","content":{"text":"\(text)"}}]}
            """
        }.joined(separator: ",")
        return """
            {"meta":{"schemaVersion":"1.0","id":"\(id)","type":"book","title":"Book \(id)","language":"en"},
             "sections":[\(body)]}
            """
    }

    private func deck(index: Int, slides slideCount: Int = 40) -> LampPresentationDeck {
        let notes = String(repeating: "A line of speaker notes for this slide. ", count: 16)
        let body = String(repeating: "A sentence of slide prose a reader can take in. ", count: 6)
        return LampPresentationDeck(
            id: "scale-deck-\(index)",
            title: "Deck \(index)",
            slides: (0..<slideCount).map { slide in
                LampPresentationSlide(
                    layout: .titleAndBody,
                    blocks: [
                        LampPresentationBlock(kind: .title, text: "Slide \(slide) of deck \(index)"),
                        LampPresentationBlock(kind: .body, text: body),
                    ],
                    speakerNotes: notes
                )
            }
        )
    }

    // MARK: - Writings: the list read, and the archive a pass compiles

    /// `devotionals()` is what every save reloads (`decisions/0004`) and
    /// `personalArchive` is what every sync pass rebuilds
    /// (`decisions/0002`). Measured on the same corpus so the two can be
    /// compared, with the digest of the archive beside them — hashing is the
    /// cost `decisions/0001` decided to keep, and it is the yardstick.
    @Test(.enabled(if: enabled()))
    func measuresTheWritingsListAndTheSyncArchive() async throws {
        let root = try root("writings")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let steps = sizes("LAMP_SCALE_WRITINGS", [250, 1_000, 4_000])

        // An installed collection as well as this device's own writings: those
        // rows are the ones whose content JSON `devotionals()` decodes per row.
        let entries = count("LAMP_SCALE_COLLECTION_ENTRIES", 365)
        if entries > 0 {
            let collection = try LampPersonalWritingFile.archive(
                (0..<entries).map { writing(index: 1_000_000 + $0, kilobytes: 6) },
                moduleID: "scale-collection",
                name: "A Collection"
            )
            let file = root.appendingPathComponent("scale-collection.lamp")
            try collection.write(to: file)
            _ = try await library.install(from: file)
            report("collection entries=\(entries) file=\(collection.count / 1_024)KB")
        }

        var made = 0
        for target in steps {
            let building = ContinuousClock().now
            while made < target {
                _ = try await library.savePersonalDevotional(writing(index: made))
                made += 1
            }
            let built = ContinuousClock().now - building

            let listed = try await timed { try await library.devotionals() }
            let ids = try await timed { try await library.personalDevotionalIDs() }
            let one = try await timed { try await library.personalDevotional(id: "scale-writing-\(target / 2)") }
            let archive = try await timed {
                try await library.personalArchive(.writing, moduleID: LampPersonalModule.writing.id)
            }
            // The same call again, which `decisions/0002` makes a cache hit:
            // what a pass costs when this collection did not change.
            let cached = try await timed {
                try await library.personalArchive(.writing, moduleID: LampPersonalModule.writing.id)
            }
            let bytes = archive.value
            let digest = await best { LampSyncContentRevision.digest(for: bytes) }
            #expect(cached.value == bytes)

            #expect(listed.value.count >= target)
            #expect(one.value != nil)
            report("""
                writings=\(target) built=\(String(format: "%.1f", Double(built.components.seconds)))s \
                devotionals()=\(String(format: "%.0f", listed.ms))ms \
                ids()=\(String(format: "%.0f", ids.ms))ms \
                one()=\(String(format: "%.1f", one.ms))ms \
                archive=\(String(format: "%.0f", archive.ms))ms \
                archiveCached=\(String(format: "%.2f", cached.ms))ms \
                archiveBytes=\(bytes.count / 1_024)KB \
                digestOfArchive=\(String(format: "%.0f", digest))ms \
                rows=\(listed.value.count)
                """)
        }
    }

    // MARK: - Decks: listing, and what a cache would leave

    /// `decks()` reads, decodes and validates every deck
    /// (`decisions/0003`). Beside it: decoding without validating, and the
    /// listing-and-stat that a cache keyed on file identity would be left
    /// paying.
    @Test(.enabled(if: enabled()))
    func measuresDeckListing() async throws {
        let root = try root("decks")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        var made = 0
        for target in sizes("LAMP_SCALE_DECKS", [25, 100, 400]) {
            while made < target {
                _ = try store.save(deck(index: made))
                made += 1
            }
            let urls = try FileManager.default.contentsOfDirectory(
                at: store.decksDirectoryURL, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == LampPresentationDeckPortableLayout.deckExtension }
            let bytes = urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

            let listing = await best { try? store.decks() }
            let decodeOnly = await best {
                for url in urls {
                    _ = try? LampPresentationDeckStore.decodeUnvalidated(Data(contentsOf: url))
                }
            }
            let statOnly = await best {
                for url in urls {
                    _ = try? url.resourceValues(forKeys: [
                        .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
                    ])
                }
            }

            #expect(try store.decks().count == target)
            report("""
                decks=\(target) bytes=\(bytes / 1_024)KB \
                decks()=\(String(format: "%.0f", listing))ms \
                decodeOnly=\(String(format: "%.0f", decodeOnly))ms \
                statOnly=\(String(format: "%.1f", statOnly))ms
                """)
        }
    }

    // MARK: - Modules: what a launch pays per module

    /// `installedModules()` stats every module and inspects the ones whose
    /// metadata it has not cached — and the cache is in memory, so a launch
    /// inspects all of them (`decisions/0005`). A fresh `LampLibrary` on the
    /// same folder is what a launch looks like. `bookSections` across every
    /// module stands in for what the Mac's launch does when it reads book
    /// names from every translation: one database open each.
    @Test(.enabled(if: enabled()))
    func measuresModuleListingAndOpening() async throws {
        let root = try root("modules")
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        var made = 0
        for target in sizes("LAMP_SCALE_MODULES", [50, 200]) {
            let installer = LampLibrary(rootURL: libraryRoot)
            while made < target {
                let id = "SCALE\(made)"
                let archive = root.appendingPathComponent("\(id).lamp")
                _ = try LampModuleCompiler().compile(
                    data: Data(bookModuleJSON(id: id, sections: 24).utf8),
                    sourceFilename: "\(id).json",
                    destinationURL: archive
                )
                _ = try await installer.install(from: archive)
                try? FileManager.default.removeItem(at: archive)
                made += 1
            }

            let openedBefore = openFileCount()
            // A launch: nothing cached in memory yet.
            let cold = LampLibrary(rootURL: libraryRoot)
            let first = try await timed { try await cold.installedModules() }
            let warm = await best { try? await cold.installedModules() }
            let ids = first.value.map(\.id)
            let opening = await timed {
                var sections = 0
                for id in ids { sections += (try? await cold.bookSections(moduleID: id))?.count ?? 0 }
                return sections
            }
            let openedAfter = openFileCount()
            let databases = (try? FileManager.default.contentsOfDirectory(
                at: libraryRoot.appendingPathComponent("Databases"), includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let bytes = databases.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

            #expect(first.value.count >= target)
            report("""
                modules=\(target) bytes=\(bytes / 1_024)KB \
                installedModules()cold=\(String(format: "%.0f", first.ms))ms \
                warm=\(String(format: "%.1f", warm))ms \
                openEachAndRead=\(String(format: "%.0f", opening.ms))ms \
                sections=\(opening.value) \
                fdBefore=\(openedBefore) fdAfter=\(openedAfter)
                """)
        }
    }
}
