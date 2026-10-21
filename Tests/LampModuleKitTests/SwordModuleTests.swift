import Foundation
import Testing
@testable import LampModuleKit

struct SwordModuleTests {
    // MARK: - SWORD's cipher

    /// Enciphered by SWORD's own SWCipher and Sapphire, compiled from its
    /// sources: what a locked module holds for this text and key.
    @Test func decipheringMatchesSword() throws {
        let plain = "In the beginning God created the heaven and the earth."
        let enciphered = try #require(Data(hex: "9d6b53a6b108440ca3e66c2af4d880862550354e24728cf7b754f1d7532470e0638bf47b4ebb82dd5eb99f7ede801cdb2064a5cc16f0"))
        let cipher = SapphireCipher(key: SapphireCipher.personalizedKey("MyKey2026"))
        #expect(String(decoding: cipher.decrypt(enciphered), as: UTF8.self) == plain)
        #expect(cipher.encrypt(Data(plain.utf8)) == enciphered)
    }

    /// SWORD sells some keys in a checksummed form it decodes before use.
    /// This one is SWORD's own encoding of "Lamp-Abcd-Efgh-Ijkl".
    @Test func personalizedKeysDecodeAsSwordDoes() throws {
        #expect(String(decoding: SapphireCipher.personalizedKey("Lamp-081B-6c6v-nf88-b1Y6"), as: UTF8.self) == "Abcd-Efgh-Ijkl")
        // Any other key is used as typed, a bad checksum included.
        #expect(String(decoding: SapphireCipher.personalizedKey("Lamp-081B-6c6v-nf88-b1Y7"), as: UTF8.self) == "Lamp-081B-6c6v-nf88-b1Y7")
        #expect(String(decoding: SapphireCipher.personalizedKey("MyKey2026"), as: UTF8.self) == "MyKey2026")

        let enciphered = try #require(Data(hex: "57419f7b22a76a9ee984b45d97f78042155e719063308a448f1d1d38d52fae1b81a629f5fe973886772fb7a71264e5c18d2fa91d0799"))
        let cipher = SapphireCipher(key: SapphireCipher.personalizedKey("Lamp-081B-6c6v-nf88-b1Y6"))
        #expect(String(decoding: cipher.decrypt(enciphered), as: UTF8.self) == "In the beginning God created the heaven and the earth.")
    }

    @Test func versesSitWhereSwordPutsThem() {
        // A slot for the module, the testament, the book and the chapter.
        #expect(SwordModule.position(book: 1, chapter: 1, verse: 1)! == (1, 4))
        #expect(SwordModule.position(book: 1, chapter: 2, verse: 1)! == (1, 4 + 31 + 1))
        // Genesis's book slot, its 50 chapter slots and 1,533 verses, then
        // Exodus's book slot and its first chapter's.
        #expect(SwordModule.position(book: 2, chapter: 1, verse: 0)! == (1, 2 + 50 + 1533 + 1 + 1))
        #expect(SwordModule.position(book: 40, chapter: 1, verse: 1)! == (2, 4))
        // NRSV numbers 3 John 1:15, so Jude starts a verse later.
        let kjvJude = SwordModule.position(book: 65, chapter: 1, verse: 1)!.index
        #expect(SwordModule.position(book: 65, chapter: 1, verse: 1, versification: .nrsv)!.index == kjvJude + 1)
    }

    // MARK: - Modules

    @Test func zTextOSISKeepsMarkupAcrossVersesAndTheConfDescribesIt() throws {
        let module = try SwordFixture(conf: """
            [TestOSIS]
            DataPath=./modules/texts/ztext/testosis/
            ModDrv=zText
            SourceType=OSIS
            Encoding=UTF-8
            CompressType=ZIP
            BlockType=BOOK
            Lang=en
            Description=Test OSIS Bible
            DistributionLicense=Public Domain
            """, verses: [
                (1, 1, 1, #"<div type="x-p" sID="p1"/><w lemma="strong:H07225">In the beginning</w> <w lemma="strong:H0430">God</w> created."#),
                (1, 1, 2, #"<transChange type="added">he made</transChange><w lemma="strong:H853">the</w> stars also."#),
                (19, 3, 0, #"<title type="psalm" canonical="true">A Psalm of David.</title>"#),
                (19, 3, 1, "LORD, how are they increased that trouble me!"),
                (40, 5, 3, #"<q who="Jesus" marker="" sID="q1"/>Blessed are the poor in spirit:"#),
                (40, 5, 4, #"Blessed are they that mourn.<q who="Jesus" marker="" eID="q1"/>"#),
            ])
        defer { module.remove() }

        let imported = try LampTranslationImporter().read(module.root)
        #expect(imported.format == .sword)
        #expect(imported.suggestedName == "Test OSIS Bible")
        #expect(imported.suggestedAbbreviation == "TestOSIS")
        #expect(imported.language == "en")
        #expect(imported.copyright == "Public Domain")

        let first = try #require(verse(imported, 1_001_001))
        #expect(first.text == "In the beginning God created.")
        #expect(first.paragraph)
        #expect(first.annotations.compactMap(\.strongs) == ["H7225", "H430"])
        // The source runs the added words into the next one.
        #expect(verse(imported, 1_001_002)?.text == "he made the stars also.")
        #expect(headings(imported, 19, 3) == [ImportedHeading(beforeVerse: 1, level: 2, text: "A Psalm of David.")])
        #expect(verse(imported, 40_005_003).map { spans($0, "red-letter") } == ["Blessed are the poor in spirit:"])
        #expect(verse(imported, 40_005_004).map { spans($0, "red-letter") } == ["Blessed are they that mourn."])
    }

    @Test func aLockedModuleAsksForItsKeyAndKnowsAWrongOne() throws {
        let module = try SwordFixture(conf: """
            [Locked]
            DataPath=./modules/texts/ztext/locked/
            ModDrv=zText
            SourceType=OSIS
            Encoding=UTF-8
            CompressType=ZIP
            CipherKey=
            UnlockURL=https://example.org/unlock
            Description=Locked Bible
            """, verses: [(43, 3, 16, "For God so loved the world.")], cipherKey: "Open-Sesame")
        defer { module.remove() }

        #expect(throws: LampTranslationImportError.needsUnlockKey(moduleName: "Locked Bible", unlockURL: "https://example.org/unlock")) {
            try LampTranslationImporter().read(module.root)
        }
        #expect(throws: LampTranslationImportError.wrongUnlockKey(moduleName: "Locked Bible")) {
            try LampTranslationImporter().read(module.root, unlockKey: "Wrong")
        }
        #expect(LampTranslationImportError.needsUnlockKey(moduleName: "Locked Bible", unlockURL: "https://example.org/unlock").unlockPrompt
            == "“Locked Bible” is locked. Enter the unlock key you received for it. Keys for it are available from https://example.org/unlock.")
        #expect(LampTranslationImportError.noScripture(skippedBooks: []).unlockPrompt == nil)
        let imported = try LampTranslationImporter().read(module.root, unlockKey: " Open-Sesame ")
        #expect(verse(imported, 43_003_016)?.text == "For God so loved the world.")
    }

    @Test func rawTextGBFKeepsStrongsWordsOfChristAddedWordsNotesAndParagraphs() throws {
        let module = try SwordFixture(conf: """
            [TestGBF]
            DataPath=./modules/texts/rawtext/testgbf/
            ModDrv=RawText
            SourceType=GBF
            Encoding=UTF-8
            """, verses: [
                (1, 1, 1, "In the beginning<WH7225> God<WH430> created<WH1254><WTH8804> the heaven.<CM>"),
                (1, 1, 2, "And the earth was without form."),
                (40, 5, 3, "<FR>Blessed <FI>are<Fi> the poor in spirit<Fr><RF>Or humble<Rf>:"),
            ], driver: .rawText)
        defer { module.remove() }

        let imported = try LampTranslationImporter().read(module.root)
        let first = try #require(verse(imported, 1_001_001))
        #expect(first.text == "In the beginning God created the heaven.")
        #expect(spans(first, "strongs") == ["beginning", "God", "created"])
        #expect(verse(imported, 1_001_002)?.paragraph == true)
        let blessed = try #require(verse(imported, 40_005_003))
        #expect(blessed.text == "Blessed are the poor in spirit:")
        #expect(spans(blessed, "red-letter") == ["Blessed are the poor in spirit"])
        #expect(spans(blessed, "added") == ["are"])
        #expect(blessed.footnotes.map(\.content) == ["Or humble"])
    }

    @Test func zText4ThMLAndRawText4PlainLatin1() throws {
        let thml = try SwordFixture(conf: """
            [TestThML]
            DataPath=./modules/texts/ztext/testthml/
            ModDrv=zText4
            SourceType=ThML
            Encoding=UTF-8
            """, verses: [
                (40, 11, 28, #"<font color="red">Come unto me</font><note>Or to me</note>, <i>all</i> ye<sync type="Strongs" value="G3956"/> that labour &amp; are heavy laden.<br/>"#),
            ], driver: .zText4)
        defer { thml.remove() }
        let comeUnto = try #require(verse(try LampTranslationImporter().read(thml.root), 40_011_028))
        #expect(comeUnto.text == "Come unto me, all ye that labour & are heavy laden.")
        #expect(spans(comeUnto, "red-letter") == ["Come unto me"])
        #expect(comeUnto.footnotes.map(\.content) == ["Or to me"])
        #expect(comeUnto.annotations.first { $0.kind == "strongs" }?.strongs == "G3956")

        let plain = try SwordFixture(conf: """
            [TestPlain]
            DataPath=./modules/texts/rawtext/testplain/
            ModDrv=RawText4
            """, latin1Verses: [(43, 1, 1, "Au commencement \u{E9}tait la Parole.")], driver: .rawText4)
        defer { plain.remove() }
        #expect(verse(try LampTranslationImporter().read(plain.root), 43_001_001)?.text == "Au commencement était la Parole.")
    }

    @Test func modulesLampCantReadSaySo() throws {
        for (conf, reason) in [
            ("ModDrv=zCom\nSourceType=OSIS", "is a commentary, not a Bible"),
            ("ModDrv=zText\nCompressType=BZIP2", "is compressed with BZIP2, which Lamp can’t read yet"),
            ("ModDrv=zText\nVersification=Synodal", "numbers its verses the Synodal way, which Lamp can’t map yet"),
        ] {
            let module = try SwordFixture(conf: "[Odd]\nDataPath=./modules/texts/ztext/odd/\n\(conf)", verses: [])
            defer { module.remove() }
            #expect(throws: LampTranslationImportError.unsupportedSwordModule(moduleName: "Odd", reason: reason)) {
                try LampTranslationImporter().read(module.root)
            }
        }
    }

    @Test func aFolderOfSeveralBiblesAsksForOne() throws {
        let module = try SwordFixture(conf: "[First]\nDataPath=./modules/texts/ztext/first/\nModDrv=zText", verses: [(1, 1, 1, "In the beginning.")])
        defer { module.remove() }
        try Data("[Second]\nModDrv=RawText\n".utf8).write(to: module.root.appendingPathComponent("mods.d/second.conf"))
        try Data("[Notes]\nModDrv=zCom\n".utf8).write(to: module.root.appendingPathComponent("mods.d/notes.conf"))
        #expect(throws: LampTranslationImportError.severalSwordModules(["First", "Second"])) {
            try LampTranslationImporter().read(module.root)
        }
        // Its conf chosen on its own, the one module is read.
        let conf = module.root.appendingPathComponent("mods.d/test.conf")
        #expect(verse(try LampTranslationImporter().read(conf), 1_001_001)?.text == "In the beginning.")
    }

    @Test func aConfWithoutItsVerseFilesSaysWhatToChoose() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sword-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conf = folder.appendingPathComponent("alone.conf")
        try Data("[Alone]\nDataPath=./modules/texts/ztext/alone/\nModDrv=zText\n".utf8).write(to: conf)
        #expect(throws: LampTranslationImportError.unsupportedSwordModule(
            moduleName: "Alone",
            reason: "has no verse files beside its conf. Choose the module’s zip or its whole folder"
        )) {
            try LampTranslationImporter().read(conf)
        }
    }

    @Test func aZippedModuleIsReadFromTheZip() throws {
        let module = try SwordFixture(conf: "[Zipped]\nDataPath=./modules/texts/ztext/zipped/\nModDrv=zText", verses: [(66, 22, 21, "The grace of our Lord be with you all.")])
        defer { module.remove() }
        let files = try FileManager.default.subpathsOfDirectory(atPath: module.root.path)
            .filter { !$0.hasSuffix("/") }
            .compactMap { path -> (String, Data, Bool)? in
                var isDirectory: ObjCBool = false
                let url = module.root.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
                return ("Zipped/\(path)", try Data(contentsOf: url), true)
            }
        let imported = try LampTranslationImporter().read(data: makeZip(files), filename: "Zipped.zip")
        #expect(verse(imported, 66_022_021)?.text == "The grace of our Lord be with you all.")
    }

    // MARK: - Helpers

    private func verse(_ imported: LampImportedTranslation, _ reference: Int) -> ImportedVerse? {
        imported.books.first { $0.number == reference / 1_000_000 }?
            .chapters.first { $0.number == reference / 1_000 % 1_000 }?
            .verses.first { $0.number == reference % 1_000 }
    }

    private func headings(_ imported: LampImportedTranslation, _ book: Int, _ chapter: Int) -> [ImportedHeading] {
        imported.books.first { $0.number == book }?.chapters.first { $0.number == chapter }?.headings ?? []
    }

    private func spans(_ verse: ImportedVerse, _ kind: String) -> [String] {
        let characters = Array(verse.text)
        return verse.annotations.filter { $0.kind == kind }.map { String(characters[$0.start..<$0.end]) }
    }
}

/// A SWORD module written to a temporary folder: a conf in `mods.d` and its
/// verses under the conf's DataPath, compressed and enciphered as SWORD does.
private struct SwordFixture {
    enum Driver { case zText, zText4, rawText, rawText4 }

    let root: URL

    init(conf: String, verses: [(Int, Int, Int, String)], driver: Driver = .zText, cipherKey: String? = nil) throws {
        try self.init(conf: conf, encoded: verses.map { ($0.0, $0.1, $0.2, Data($0.3.utf8)) }, driver: driver, cipherKey: cipherKey)
    }

    init(conf: String, latin1Verses: [(Int, Int, Int, String)], driver: Driver) throws {
        try self.init(conf: conf, encoded: latin1Verses.map { ($0.0, $0.1, $0.2, $0.3.data(using: .isoLatin1)!) }, driver: driver, cipherKey: nil)
    }

    private init(conf: String, encoded verses: [(Int, Int, Int, Data)], driver: Driver, cipherKey: String?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sword-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mods.d"), withIntermediateDirectories: true)
        try Data(conf.utf8).write(to: root.appendingPathComponent("mods.d/test.conf"))
        let dataPath = conf.split(separator: "\n").first { $0.hasPrefix("DataPath=") }
            .map { String($0.dropFirst("DataPath=./".count)) } ?? "modules/texts/ztext/test/"
        let folder = root.appendingPathComponent(dataPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cipher = cipherKey.map { SapphireCipher(key: SapphireCipher.personalizedKey($0)) }

        for testament in 1...2 {
            let placed = verses.compactMap { book, chapter, verse, text -> (Int, Data)? in
                guard let position = SwordModule.position(book: book, chapter: chapter, verse: verse),
                      position.testament == testament else { return nil }
                return (position.index, text)
            }
            guard let last = placed.map(\.0).max() else { continue }
            let byIndex = Dictionary(placed, uniquingKeysWith: { first, _ in first })
            let name = testament == 1 ? "ot" : "nt"
            var text = Data()
            var index = Data()
            switch driver {
            case .zText, .zText4:
                for slot in 0...last {
                    let bytes = byIndex[slot] ?? Data()
                    index.appendLittleEndian(UInt32(0))
                    index.appendLittleEndian(UInt32(bytes.isEmpty ? 0 : text.count))
                    driver == .zText ? index.appendLittleEndian(UInt16(bytes.count)) : index.appendLittleEndian(UInt32(bytes.count))
                    text.append(bytes)
                }
                var block = Data([0x78, 0x9C]) + (try (text as NSData).compressed(using: .zlib) as Data)
                if let cipher { block = cipher.encrypt(block) }
                var blocks = Data()
                blocks.appendLittleEndian(UInt32(0))
                blocks.appendLittleEndian(UInt32(block.count))
                blocks.appendLittleEndian(UInt32(text.count))
                try index.write(to: folder.appendingPathComponent("\(name).bzv"))
                try blocks.write(to: folder.appendingPathComponent("\(name).bzs"))
                try block.write(to: folder.appendingPathComponent("\(name).bzz"))
            case .rawText, .rawText4:
                for slot in 0...last {
                    var bytes = byIndex[slot] ?? Data()
                    if let cipher, !bytes.isEmpty { bytes = cipher.encrypt(bytes) }
                    index.appendLittleEndian(UInt32(text.count))
                    driver == .rawText ? index.appendLittleEndian(UInt16(bytes.count)) : index.appendLittleEndian(UInt32(bytes.count))
                    text.append(bytes)
                }
                try index.write(to: folder.appendingPathComponent("\(name).vss"))
                try text.write(to: folder.appendingPathComponent(name))
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
