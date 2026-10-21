import Foundation
import LampCore
import LampModuleKit
import Testing

/// An imported translation, read back the way the apps read it: the offsets
/// the importer counted must pick out the same words the reader shows.
struct LampTranslationImportReaderTests {
    @Test func anImportedTranslationReadsBackWithItsSpansNotesAndHeadings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-import-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let imported = try LampTranslationImporter().read(data: Data(#"""
            \id PSA Test Psalter
            \c 23
            \d A Psalm of David.
            \q1
            \v 1 The \nd LORD\nd* is my shepherd;\f + \ft Or \fq pastor\f* I shall not want.
            \q2
            \v 2 He maketh me to lie down in green pastures: \qs Selah\qs*
            """#.utf8), filename: "psalter.usfm")
        let moduleID = LampTranslationImporter.moduleID(forAbbreviation: "TPS")
        let result = try imported.compile(into: root, id: moduleID, name: "Test Psalter", abbreviation: "TPS")

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let module = try await library.install(from: result.outputURL)
        #expect(module.kind == .translation)
        #expect(module.name == "Test Psalter")

        let chapter = try await library.chapter(moduleID: moduleID, bookNumber: 19, chapterNumber: 23)
        #expect(chapter.headings.map(\.text) == ["A Psalm of David."])
        #expect(chapter.verses.map(\.text) == [
            "The LORD is my shepherd; I shall not want.",
            "He maketh me to lie down in green pastures: Selah",
        ])
        #expect(chapter.verses.map { $0.poetry?.indent } == [1, 2])

        let first = try #require(chapter.verses.first)
        #expect(first.annotations.map { "\($0.kind):\($0.text ?? "")" } == ["divine-name:LORD"])
        #expect(first.hasFootnotes)
        let study = try #require(try await library.verseStudyData(moduleID: moduleID, reference: 19_023_001))
        #expect(study.footnotes.map(\.content) == ["Or pastor"])
        #expect(study.footnoteReferences.map(\.offset) == [Array("The LORD is my shepherd;").count])

        let second = try #require(chapter.verses.last)
        #expect(second.annotations.map { "\($0.kind):\($0.text ?? "")" } == ["selah:Selah"])
    }
}
