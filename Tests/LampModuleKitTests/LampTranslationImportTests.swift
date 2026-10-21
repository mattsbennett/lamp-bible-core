import Foundation
import Testing
@testable import LampModuleKit

struct LampTranslationImportTests {
    // MARK: - USFM

    @Test func usfmKeepsHeadingsParagraphsAndEveryKindOfSpan() throws {
        let imported = try read(#"""
            \id GEN Test Bible
            \h Genesis
            \mt1 The First Book of Moses
            \c 1
            \s1 The Creation
            \p
            \v 1 \w In the beginning|strong="H7225"\w* \w God|strong="H430"\w* \w created|strong="H1254" x-morph="strongMorph:TH8804"\w* \w the heavens|strong="H853 H8064"\w* \w and|strong="H853"\w* the earth.
            \v 2 And the earth was without form\f + \fr 1:2 \ft Or \fq formless\f*, and void; and darkness \add was\add* upon the deep.
            \p
            \v 3 And God said, Let there be light.
            \c 2
            \v 4 In the day that the \nd LORD\nd* God made the earth,
            """#)

        #expect(imported.format == .usfm)
        #expect(imported.suggestedName == "Test Bible")
        #expect(headings(imported, book: 1, chapter: 1) == [ImportedHeading(beforeVerse: 1, level: 1, text: "The Creation")])

        let first = try #require(verse(imported, 1_001_001))
        #expect(first.text == "In the beginning God created the heavens and the earth.")
        #expect(first.paragraph)
        // H853 marks an untranslated Hebrew particle: "and" stands for
        // nothing else, so it gets no number at all.
        #expect(spans(first, "strongs") == ["In the beginning", "God", "created", "the heavens"])
        #expect(first.annotations.map(\.strongs) == ["H7225", "H430", "H1254", "H8064"])
        #expect(first.annotations[2].morphology == "TH8804")

        let second = try #require(verse(imported, 1_001_002))
        #expect(second.text == "And the earth was without form, and void; and darkness was upon the deep.")
        #expect(!second.paragraph)
        #expect(spans(second, "added") == ["was"])
        #expect(second.footnotes == [ImportedFootnote(id: "1", kind: "translation", content: "Or formless", offset: 30)])

        #expect(verse(imported, 1_001_003)?.paragraph == true)
        #expect(verse(imported, 1_002_004).map { spans($0, "divine-name") } == ["LORD"])
    }

    @Test func usfmPoetryKeepsIndentsSelahAndStanzasWithinAChapter() throws {
        let imported = try read(#"""
            \id PSA
            \c 3
            \d A Psalm of David.
            \q1
            \v 1 LORD, how are they increased that trouble me!
            \q2 many are they that rise up against me.
            \q1
            \v 2 Many there be which say of my soul,
            \q2 There is no help for him in God. \qs Selah\qs*
            \b
            \q1
            \v 3 But thou, O LORD, art a shield for me;
            \b
            \c 4
            \q1
            \v 1 Hear me when I call,
            """#)

        #expect(headings(imported, book: 19, chapter: 3) == [ImportedHeading(beforeVerse: 1, level: 2, text: "A Psalm of David.")])
        let first = try #require(verse(imported, 19_003_001))
        #expect(first.text == "LORD, how are they increased that trouble me! many are they that rise up against me.")
        #expect(first.poetryIndent == 1)
        #expect(!first.stanzaBreak)
        #expect(verse(imported, 19_003_002).map { spans($0, "selah") } == ["Selah"])
        #expect(verse(imported, 19_003_003)?.stanzaBreak == true)
        // The break after the last verse of Psalm 3 isn't a break in Psalm 4.
        #expect(verse(imported, 19_004_001)?.stanzaBreak == false)
        #expect(verse(imported, 19_004_001)?.poetryIndent == 1)
    }

    @Test func usfmWordsOfChristRunAcrossVersesAndAroundNotes() throws {
        let imported = try read(#"""
            \id MRK
            \c 1
            \p
            \v 14 Jesus came into Galilee, saying, \wj
            \v 15 “The time is fulfilled\wj*\f + \fr 1:15 \ft Or completed\f* \wj and the kingdom is at hand.”\wj*
            \v 16 He saw Simon and Andrew \f + \ft The brothers\f* .
            \v 17 \wj Come after me,
            \v 18 and I will make you fishers of men.\wj*
            """#)

        #expect(verse(imported, 41_001_014).map { spans($0, "red-letter") } == [])
        let fifteen = try #require(verse(imported, 41_001_015))
        #expect(fifteen.text == "“The time is fulfilled and the kingdom is at hand.”")
        #expect(spans(fifteen, "red-letter") == [fifteen.text])
        #expect(fifteen.footnotes.map(\.offset) == [22])
        #expect(verse(imported, 41_001_016)?.text == "He saw Simon and Andrew.")
        #expect(verse(imported, 41_001_017).map { spans($0, "red-letter") } == ["Come after me,"])
        #expect(verse(imported, 41_001_018).map { spans($0, "red-letter") } == ["and I will make you fishers of men."])
    }

    @Test func usfmNotesLeaveOutWhereTheirReferencesPoint() throws {
        let imported = try read(#"""
            \id GEN
            \c 1
            \p
            \v 3 And God said, “Let there be light,”\f + \fr 1:3 \ft Cited in \ref 2 Corinthians 4:6|2CO 4:6\ref*\f* and there was light.
            \v 4 God saw the light.\f + \fr 1:4 \ft See \ref Psalm 104:2|PSA 104:2\ref*, and \xt John 1:5|JHN 1:5\xt*.\f*
            """#)

        #expect(verse(imported, 1_001_003)?.footnotes.map(\.content) == ["Cited in 2 Corinthians 4:6"])
        #expect(verse(imported, 1_001_004)?.footnotes.map(\.content) == ["See Psalm 104:2, and John 1:5."])
    }

    @Test func aHeadingInsideAVerseGoesBeforeTheNextVerseOnlyIfItIsTheLast() throws {
        let imported = try read(#"""
            \id SNG
            \c 1
            \sp Beloved
            \q1
            \v 4 Take me away with you.
            \sp Friends
            \q1 We will be glad.
            \sp Beloved
            \q1 They are right to love you.
            \q1
            \v 5 I am dark, but lovely.
            """#)

        #expect(verse(imported, 22_001_004)?.text == "Take me away with you. We will be glad. They are right to love you.")
        #expect(headings(imported, book: 22, chapter: 1) == [
            ImportedHeading(beforeVerse: 4, level: 2, text: "Beloved"),
            ImportedHeading(beforeVerse: 5, level: 2, text: "Beloved"),
        ])
    }

    @Test func bridgesRepeatsAndOmittedVersesAreReported() throws {
        let imported = try read(#"""
            \id ROM
            \c 16
            \p
            \v 24 \f + \ft Some manuscripts add a verse.\f*
            \p
            \v 25-27 Now to him who is able to establish you.
            \c 1
            \v 1 Paul, a servant.
            \v 1 Paul again.
            """#)

        #expect(verse(imported, 45_016_024) == nil)
        #expect(verse(imported, 45_016_025)?.paragraph == true)
        #expect(verse(imported, 45_001_001)?.text == "Paul, a servant.")
        #expect(imported.report.verseBridges == [45_016_025])
        #expect(imported.report.duplicateVerses == [45_001_001])
    }

    @Test func booksOutsideTheSixtySixAreLeftOutAndNamed() throws {
        let imported = try read(#"""
            \id FRT
            \p Preface
            \id TOB
            \c 1
            \v 1 Tobit.
            \id JUD
            \c 1
            \v 1 Jude, a servant of Jesus Christ.
            """#)

        #expect(imported.report.skippedBooks == ["TOB"])
        #expect(imported.report.bookCount == 1)
        #expect(verse(imported, 65_001_001) != nil)

        #expect(throws: LampTranslationImportError.noScripture(skippedBooks: ["TOB"])) {
            try read("\\id TOB\n\\c 1\n\\v 1 Tobit.\n")
        }
    }

    /// The official BSB marks continuation paragraphs with `\vid|MRK 7:9\*`,
    /// inside verses as well as around headings.
    @Test func attributeMilestonesHoldNoTextAndEndNothing() throws {
        let imported = try read(#"""
            \id MRK
            \c 7
            \s1 What Defiles a Man
            \vid|MRK 7:9\*
            \r (\ref Matthew 15:10–20|MAT 15:10-20\ref*)
            \vid|MRK 7:9\*
            \p \v 14 \w Once again|strong="G3825"\w* Jesus called the crowd to Him
            \p \vid|MRK 7:14\* and said, “All of you, listen.”
            """#)
        #expect(headings(imported, book: 41, chapter: 7) == [ImportedHeading(beforeVerse: 14, level: 1, text: "What Defiles a Man")])
        #expect(verse(imported, 41_007_014)?.text == "Once again Jesus called the crowd to Him and said, “All of you, listen.”")
        #expect(imported.report.unrecognizedMarkup.isEmpty)
    }

    @Test func aWordAfterANoteAndPunctuationKeepsItsSpaceAndAcrosticLettersAreOneHeading() throws {
        let imported = try read(#"""
            \id PSA
            \c 119
            \q1
            \v 8 I will keep Your statutes;
            \q2 do not utterly forsake me.
            \qa ב
            \qa BETH
            \b
            \q1
            \v 9 How can a young man keep his way pure?\f + \ft Or \fqa clean\f*\wj “By guarding it”\wj*
            """#)
        #expect(verse(imported, 19_119_008)?.text == "I will keep Your statutes; do not utterly forsake me.")
        #expect(headings(imported, book: 19, chapter: 119) == [ImportedHeading(beforeVerse: 9, level: 2, text: "ב BETH")])
        let nine = try #require(verse(imported, 19_119_009))
        #expect(nine.text == "How can a young man keep his way pure? “By guarding it”")
        #expect(spans(nine, "red-letter") == ["“By guarding it”"])
    }

    @Test func unknownMarkersKeepTheirTextAndAreCounted() throws {
        let imported = try read("\\id JHN\n\\c 1\n\\p\n\\v 1 In the \\zz beginning\\zz* was the Word.\n")
        #expect(verse(imported, 43_001_001)?.text == "In the beginning was the Word.")
        #expect(imported.report.unrecognizedMarkup == ["\\zz": 1])
    }

    // MARK: - Containers

    @Test func readsUSFMFromAZipWithStoredAndDeflatedEntries() throws {
        let archive = makeZip([
            ("bible/01-GEN.usfm", Data("\\id GEN\n\\c 1\n\\v 1 In the beginning.\n".utf8), false),
            ("bible/02-EXO.SFM", Data("\\id EXO\n\\c 1\n\\v 1 Now these are the names.\n".utf8), true),
            ("__MACOSX/bible/._01-GEN.usfm", Data("\\id LEV\n\\c 1\n\\v 1 Not a book.\n".utf8), false),
        ])
        let imported = try LampTranslationImporter().read(data: archive, filename: "bible.zip")
        #expect(imported.report.bookCount == 2)
        #expect(verse(imported, 2_001_001)?.text == "Now these are the names.")
    }

    @Test func readsUSFMFromAFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("\\id MAT\n\\c 1\n\\v 1 The book of the generation.\n".utf8)
            .write(to: folder.appendingPathComponent("40-MAT.usfm"))
        try Data("\\id MRK\n\\c 1\n\\v 1 The beginning of the gospel.\n".utf8)
            .write(to: folder.appendingPathComponent("41-MRK.usfm"))
        try Data("Read me".utf8).write(to: folder.appendingPathComponent("README.md"))

        let imported = try LampTranslationImporter().read(folder)
        #expect(imported.report.bookCount == 2)
    }

    @Test func readsAnXMLBibleSplitIntoABookPerFile() throws {
        let archive = makeZip([
            ("Matt.xml", Data(#"<osis><osisText><div type="book" osisID="Matt"><chapter osisID="Matt.1"><verse osisID="Matt.1.1">The book of the generation.</verse></chapter></div></osisText></osis>"#.utf8), true),
            ("Mark.xml", Data(#"<osis><osisText><div type="book" osisID="Mark"><chapter osisID="Mark.1"><verse osisID="Mark.1.1">The beginning of the gospel.</verse></chapter></div></osisText></osis>"#.utf8), true),
        ])
        let imported = try LampTranslationImporter().read(data: archive, filename: "nt.zip")
        #expect(imported.format == .osis)
        #expect(imported.report.bookCount == 2)
    }

    @Test func somethingElseIsNotABible() {
        #expect(throws: LampTranslationImportError.unrecognizedFormat("notes.txt")) {
            try LampTranslationImporter().read(data: Data("Just some notes.".utf8), filename: "notes.txt")
        }
        #expect(throws: LampTranslationImportError.self) {
            try LampTranslationImporter().read(data: Data("<html><body/></html>".utf8), filename: "page.xml")
        }
    }

    // MARK: - OSIS

    @Test func osisMilestonesHeaderAndMarkup() throws {
        let imported = try readXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <osis xmlns="http://www.bibletechnologies.net/2003/OSIS/namespace">
            <osisText osisIDWork="Bible.en.test" xml:lang="en">
            <header><work osisWork="Bible.en.test"><title>Test Version</title><rights>Copyright Test</rights></work></header>
            <div type="book" osisID="Matt">
            <chapter sID="Matt.5" osisID="Matt.5"/>
            <title>The Beatitudes</title>
            <p><verse sID="Matt.5.1" osisID="Matt.5.1"/>And seeing the multitudes, he went up into a mountain:<verse eID="Matt.5.1"/>
            <verse sID="Matt.5.2" osisID="Matt.5.2"/>And he taught them, saying,<verse eID="Matt.5.2"/></p>
            <lg><l level="1"><verse sID="Matt.5.3" osisID="Matt.5.3"/><q who="Jesus" marker="" sID="q1"/>Blessed <transChange type="added">are</transChange> the <w lemma="strong:G4434 lemma.TR:πτωχος" morph="robinson:A-NPM">poor</w> in spirit:<note type="study">Or humble.</note></l>
            <l level="2">for theirs is the kingdom of heaven.<note type="crossReference"><reference>Luke 6:20</reference></note><verse eID="Matt.5.3"/></l>
            <l level="1"><verse sID="Matt.5.4" osisID="Matt.5.4"/>Blessed are they that mourn.<q who="Jesus" marker="" eID="q1"/><verse eID="Matt.5.4"/></l></lg>
            <chapter eID="Matt.5"/>
            </div>
            <div type="book" osisID="Tob"><chapter osisID="Tob.1"><verse osisID="Tob.1.1">Tobit.</verse></chapter></div>
            <div type="book" osisID="Ps"><chapter osisID="Ps.23"><title type="psalm" canonical="true">A Psalm of David.</title><verse osisID="Ps.23.1">The <divineName>Lord</divineName> is my shepherd.</verse></chapter></div>
            </osisText>
            </osis>
            """)

        #expect(imported.format == .osis)
        #expect(imported.suggestedName == "Test Version")
        #expect(imported.suggestedAbbreviation == "TEST")
        #expect(imported.language == "en")
        #expect(imported.copyright == "Copyright Test")
        #expect(imported.report.skippedBooks == ["Tob"])
        #expect(headings(imported, book: 40, chapter: 5) == [ImportedHeading(beforeVerse: 1, level: 1, text: "The Beatitudes")])
        #expect(verse(imported, 40_005_001)?.paragraph == true)

        let blessed = try #require(verse(imported, 40_005_003))
        #expect(blessed.text == "Blessed are the poor in spirit: for theirs is the kingdom of heaven.")
        #expect(blessed.poetryIndent == 1)
        #expect(spans(blessed, "red-letter") == [blessed.text])
        #expect(spans(blessed, "added") == ["are"])
        let word = try #require(blessed.annotations.first { $0.kind == "strongs" })
        #expect([word.strongs, word.morphology, word.lemma] == ["G4434", "A-NPM", "πτωχος"])
        #expect(blessed.footnotes.map(\.content) == ["Or humble."])
        #expect(blessed.footnotes.map(\.kind) == ["explanation"])
        #expect(verse(imported, 40_005_004).map { spans($0, "red-letter") } == ["Blessed are they that mourn."])

        #expect(headings(imported, book: 19, chapter: 23) == [ImportedHeading(beforeVerse: 1, level: 2, text: "A Psalm of David.")])
        #expect(verse(imported, 19_023_001).map { spans($0, "divine-name") } == ["Lord"])
    }

    @Test func osisLineGroupsOfOneLineAreNotStanzas() throws {
        let oneLineGroups = try readXML("""
            <osis><osisText><div type="book" osisID="Ps"><chapter osisID="Ps.1">
            <lg><l level="1"><verse osisID="Ps.1.1">Blessed is the man.</verse></l></lg>
            <lg><l level="1"><verse osisID="Ps.1.2">But his delight is in the law.</verse></l></lg>
            </chapter></div></osisText></osis>
            """)
        #expect(verse(oneLineGroups, 19_001_002)?.stanzaBreak == false)

        let stanzas = try readXML("""
            <osis><osisText><div type="book" osisID="Ps"><chapter osisID="Ps.1">
            <lg><l><verse sID="Ps.1.1" osisID="Ps.1.1"/>Blessed is the man</l><l>who walks not astray.<verse eID="Ps.1.1"/></l></lg>
            <lg><l><verse sID="Ps.1.2" osisID="Ps.1.2"/>But his delight is in the law.<verse eID="Ps.1.2"/></l></lg>
            </chapter></div></osisText></osis>
            """)
        #expect(verse(stanzas, 19_001_001)?.text == "Blessed is the man who walks not astray.")
        #expect(verse(stanzas, 19_001_002)?.stanzaBreak == true)
    }

    // MARK: - Zefania and plain XML

    @Test func zefaniaInformationCaptionsStrongsStylesAndNotes() throws {
        let imported = try readXML("""
            <?xml version="1.0" encoding="utf-8"?>
            <XMLBIBLE biblename="Zefania Test" type="x-bible">
            <INFORMATION><identifier>ZTB</identifier><language>GER</language><rights>Public Domain</rights></INFORMATION>
            <BIBLEBOOK bnumber="1" bname="Genesis"><CHAPTER cnumber="1">
            <CAPTION vref="1">Die Schöpfung</CAPTION>
            <VERS vnumber="1"><gr str="7225">Im Anfang</gr> schuf Gott<NOTE type="x-studynote">Elohim</NOTE> Himmel und Erde.</VERS>
            <VERS vnumber="2">Und die Erde<BR art="x-nl"/>war wüst.</VERS>
            </CHAPTER></BIBLEBOOK>
            <BIBLEBOOK bnumber="43" bname="Johannes"><CHAPTER cnumber="3">
            <VERS vnumber="16"><STYLE css="color:#FF0000">Also hat Gott die Welt geliebt</STYLE>, daß er seinen <gr str="3439">eingeborenen</gr> Sohn gab.</VERS>
            </CHAPTER></BIBLEBOOK>
            <BIBLEBOOK bnumber="67" bname="Tobias"><CHAPTER cnumber="1"><VERS vnumber="1">Tobias.</VERS></CHAPTER></BIBLEBOOK>
            </XMLBIBLE>
            """)

        #expect(imported.format == .zefania)
        #expect(imported.suggestedName == "Zefania Test")
        #expect(imported.suggestedAbbreviation == "ZTB")
        #expect(imported.language == "de")
        #expect(imported.report.skippedBooks == ["Tobias"])
        #expect(headings(imported, book: 1, chapter: 1) == [ImportedHeading(beforeVerse: 1, level: 1, text: "Die Schöpfung")])

        let first = try #require(verse(imported, 1_001_001))
        #expect(first.text == "Im Anfang schuf Gott Himmel und Erde.")
        #expect(first.annotations.map(\.strongs) == ["H7225"])
        #expect(first.footnotes.map(\.content) == ["Elohim"])
        #expect(verse(imported, 1_001_002)?.text == "Und die Erde war wüst.")

        let john = try #require(verse(imported, 43_003_016))
        #expect(spans(john, "red-letter") == ["Also hat Gott die Welt geliebt"])
        #expect(john.annotations.compactMap(\.strongs) == ["G3439"])
    }

    @Test func plainBookChapterVerseXML() throws {
        let named = try readXML("""
            <bible><b n="Genesis"><c n="1"><v n="1">In the beginning.</v></c></b><b n="Bel and the Dragon"><c n="1"><v n="1">Bel.</v></c></b></bible>
            """)
        #expect(named.format == .xmlBible)
        #expect(verse(named, 1_001_001)?.text == "In the beginning.")
        #expect(named.report.skippedBooks == ["Bel and the Dragon"])

        let beblia = try readXML("""
            <bible translation="Beblia Test"><testament name="New"><book number="43"><chapter number="3">
            <verse number="16">For God so loved the world.</verse></chapter></book></testament></bible>
            """)
        #expect(beblia.suggestedName == "Beblia Test")
        #expect(verse(beblia, 43_003_016)?.text == "For God so loved the world.")
    }

    // MARK: - Module identity

    @Test func moduleIDsCannotCollideWithBundledModulesOrEachOther() {
        #expect(LampTranslationImporter.moduleID(forAbbreviation: "NASB 2020") == "imported-NASB-2020")
        #expect(LampTranslationImporter.moduleID(forAbbreviation: "NASB 2020", avoiding: ["imported-nasb-2020"]) == "imported-NASB-2020-2")
        #expect(LampTranslationImporter.moduleID(forAbbreviation: "/É/") == "imported-translation")
    }

    @Test func compilesIntoATranslationModule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imported = try read("\\id JHN\n\\c 3\n\\p\n\\v 16 \\wj For God so loved the world.\\wj*\n")
        let result = try imported.compile(into: directory, id: "imported-TST", name: "Test", abbreviation: "TST")
        #expect(result.kind == .translation)
        #expect(result.outputURL.lastPathComponent == "imported-TST.lamp")
        #expect(result.tableCounts["verses"] == 1)
    }

    // MARK: - Helpers

    private func read(_ usfm: String) throws -> LampImportedTranslation {
        try LampTranslationImporter().read(data: Data(usfm.utf8), filename: "test.usfm")
    }

    private func readXML(_ xml: String) throws -> LampImportedTranslation {
        try LampTranslationImporter().read(data: Data(xml.utf8), filename: "test.xml")
    }

    private func verse(_ imported: LampImportedTranslation, _ reference: Int) -> ImportedVerse? {
        imported.books.first { $0.number == reference / 1_000_000 }?
            .chapters.first { $0.number == reference / 1_000 % 1_000 }?
            .verses.first { $0.number == reference % 1_000 }
    }

    private func headings(_ imported: LampImportedTranslation, book: Int, chapter: Int) -> [ImportedHeading] {
        imported.books.first { $0.number == book }?.chapters.first { $0.number == chapter }?.headings ?? []
    }

    private func spans(_ verse: ImportedVerse, _ kind: String) -> [String] {
        let characters = Array(verse.text)
        return verse.annotations.filter { $0.kind == kind }.map { String(characters[$0.start..<$0.end]) }
    }
}
