import Testing
import LampModuleKit
@testable import LampCore

/// The Septuagint section's working-out, which both apps share.
@Suite struct LampSeptuagintSectionWorkTests {
    private let hebrew = LampVersification.standard(.english)
    private let septuagint = LampVersification.standard(.septuagint)

    private func word(
        _ id: String, _ printed: String, references: [Int], occurrences: [Int: Int] = [:]
    ) -> LampSeptuagintSection.CrossingWord {
        LampSeptuagintSection.CrossingWord(
            id: id, printed: printed, references: references, occurrences: occurrences
        )
    }

    private func span(_ start: Int, _ end: Int) -> LampSeptuagintSection.Span {
        LampSeptuagintSection.Span(start: start, end: end)
    }

    /// A verse is the word's when the Septuagint renders it with this Greek
    /// word, by the Septuagint's own numbering, and is marked where it stands.
    @Test func crossingKeepsTheVersesTheGreekWordStandsIn() {
        // Genesis 1:1 lines up; the English Psalm 51:5 is the Septuagint's
        // 50:7, so a crossing on raw numbers would lose it.
        let genesis = 1_001_001
        let psalm = 19_051_005
        let elsewhere = 1_002_002
        let mapped = try! #require(hebrew.opens(psalm, in: septuagint))
        let crossing = LampSeptuagintSection.cross(
            words: [word("w1", "\u{05D3}\u{05B8}\u{05D1}\u{05B8}\u{05E8}",
                         references: [genesis, psalm, elsewhere])],
            greekForm: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}",
            septuagintReferences: [1_001_001, mapped],
            greekOccurrences: [1_001_001: [span(0, 5)], mapped: [span(10, 15)]],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint
        )
        #expect(crossing.rendered["w1"] == [genesis, psalm], "in the Hebrew's own order")
        #expect(crossing.marks[psalm] == [span(10, 15)], "marked by the Septuagint's number")
        #expect(crossing.marks[elsewhere] == nil, "not one of the word's verses")
        // One of each and nothing competing: the strongest case says nothing.
        #expect(crossing.doubts["w1"]?[genesis] == nil)
    }

    /// A verse the Greek word stands in twice says so, and keeps what it was
    /// said for, so settling can rewrite the note rather than drop it.
    @Test func crossingRecordsWhatADoubtWasMadeOf() {
        let verse = 1_001_001
        let crossing = LampSeptuagintSection.cross(
            words: [
                word("w1", "A", references: [verse], occurrences: [verse: 2]),
                word("w2", "B", references: [verse]),
            ],
            greekForm: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}",
            septuagintReferences: [verse],
            greekOccurrences: [verse: [span(0, 5), span(20, 25)]],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint
        )
        let doubt = try! #require(crossing.doubts["w1"]?[verse])
        #expect(doubt.contains("twice in this verse"))
        #expect(doubt.contains("twice in the Greek"))
        #expect(doubt.contains("which stands here too"), "B stands in it as well")
        #expect(crossing.competing["w1"]?[verse]?.words == ["B"])
    }

    /// A psalm title answers to two Greek verses. The word may stand only in
    /// the second — which cannot be marked, but is still an ambiguity.
    @Test func aTitleKeepsItsDoubtEvenWhereItCannotBeMarked() {
        let title = 19_051_000
        let halves = hebrew.counterparts(of: title, in: septuagint)
        #expect(halves.count == 2, "the title is two verses in the Greek")
        let crossing = LampSeptuagintSection.cross(
            words: [word("w1", "A", references: [title], occurrences: [title: 2])],
            greekForm: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}",
            septuagintReferences: Set(halves),
            // The Greek word stands only in the second half.
            greekOccurrences: [halves[1]: [span(0, 5), span(20, 25)]],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint
        )
        #expect(crossing.rendered["w1"] == [title], "the verse is the word's")
        #expect(crossing.marks[title] == nil, "nothing to mark in the joined line")
        let doubt = try! #require(
            crossing.doubts["w1"]?[title],
            "the ambiguity is known even where the mark is not"
        )
        #expect(doubt.contains("twice in this verse"))
        #expect(doubt.contains("twice in the Greek"))
    }

    /// Settling takes away only what position answers.
    @Test func settlingKeepsWhatPositionCannotAnswer() {
        let verse = 1_001_001
        // One Hebrew word at the start, two Greek occurrences, one of them
        // right beside it: the counts are settled.
        let changed = LampSeptuagintSection.settle(
            verses: [verse],
            hebrewWord: "A",
            hebrewSpans: [verse: [span(0, 10)]],
            hebrewLengths: [verse: 100],
            greekSpans: [verse: [span(0, 10), span(80, 90)]],
            greekLengths: [verse: 100],
            competing: [:]
        )
        #expect(changed[verse] == .some(nil), "nothing left to say")

        // The same, but another Hebrew word stands in the verse too. Position
        // says which occurrence is this word's; it says nothing about that.
        let withCompeting = LampSeptuagintSection.settle(
            verses: [verse],
            hebrewWord: "A",
            hebrewSpans: [verse: [span(0, 10)]],
            hebrewLengths: [verse: 100],
            greekSpans: [verse: [span(0, 10), span(80, 90)]],
            greekLengths: [verse: 100],
            competing: [verse: .init(greek: "\u{03bb}\u{03cc}\u{03b3}\u{03bf}\u{03c2}", words: ["B"])]
        )
        let kept = try! #require(withCompeting[verse])
        let note = try! #require(kept)
        #expect(note.contains("which stands here too"))
        #expect(!note.contains("twice"), "the counts were settled, and only those")
    }

    /// Where position cannot choose, the row is left exactly as it was.
    @Test func settlingLeavesAnUnclearVerseAlone() {
        let verse = 1_001_001
        let changed = LampSeptuagintSection.settle(
            verses: [verse],
            hebrewWord: "A",
            hebrewSpans: [verse: [span(0, 10)]],
            hebrewLengths: [verse: 100],
            // Both occurrences sit near the Hebrew word: nothing is settled.
            greekSpans: [verse: [span(0, 10), span(14, 24)]],
            greekLengths: [verse: 100],
            competing: [:]
        )
        #expect(changed.isEmpty, "no row changed")
        // A verse whose text was never read cannot be settled either.
        #expect(LampSeptuagintSection.settle(
            verses: [verse], hebrewWord: "A",
            hebrewSpans: [verse: [span(0, 10)]], hebrewLengths: [:],
            greekSpans: [verse: [span(0, 10)]], greekLengths: [verse: 100],
            competing: [:]
        ).isEmpty)
    }

    /// Only doubted rows are read, and only those with one Septuagint verse.
    @Test func onlyTheRowsThatCanBeSettledAreRead() {
        let plain = 1_001_001
        let title = 19_051_000
        let undoubted = 1_001_002
        #expect(hebrew.counterparts(of: title, in: septuagint).count == 2, "a psalm title")
        let wanted = LampSeptuagintSection.versesNeedingHebrew(
            among: [plain, title, undoubted],
            doubted: [plain, title],
            hebrewNumbering: hebrew,
            septuagintNumbering: septuagint
        )
        #expect(wanted == [plain], "the title cannot be settled, the third has no doubt")
        // Nothing doubted is nothing to read.
        #expect(LampSeptuagintSection.versesNeedingHebrew(
            among: [plain, undoubted], doubted: [],
            hebrewNumbering: hebrew, septuagintNumbering: septuagint
        ).isEmpty)
    }

    /// Each English reading is named by the text it is.
    @Test func theEnglishChoiceIsNamedByItsModule() {
        let named = LampSeptuagintSection.EnglishChoice.titles(
            septuagintInEnglish: "ABP", readersBible: "BSB"
        )
        #expect(named.direct == "ABP")
        #expect(named.indirect == "BSB")
        // Without a name there is still something to press.
        let unnamed = LampSeptuagintSection.EnglishChoice.titles(
            septuagintInEnglish: nil, readersBible: "  "
        )
        #expect(unnamed.direct == "Septuagint in English")
        #expect(unnamed.indirect == "Your Bible")
    }

    /// An interlinear's word-order numbers are told apart from numbers the
    /// verse means, by whether a letter follows them with no space.
    @Test func interlinearMarkersAreToldApartFromRealNumbers() {
        let runs = LampSeptuagintSection.interlinearRuns(in: "And [2said 3to her 1Amnon], Rise")
        #expect(runs.filter(\.isMarker).map(\.text) == ["2", "3", "1"])
        // Put back together it is the verse again, marker or not.
        #expect(runs.map(\.text).joined() == "And [2said 3to her 1Amnon], Rise")

        // A number the verse means keeps its place in the prose.
        let plain = LampSeptuagintSection.interlinearRuns(in: "after 70 years in 1 Samuel 18")
        #expect(plain.filter(\.isMarker).isEmpty)
        #expect(plain.map(\.text).joined() == "after 70 years in 1 Samuel 18")

        // A verse with no numbers at all is one run.
        let none = LampSeptuagintSection.interlinearRuns(in: "Bring me into the house of wine")
        #expect(none.count == 1 && none[0].isMarker == false)
        // And nothing at all is nothing.
        #expect(LampSeptuagintSection.interlinearRuns(in: "").isEmpty)
    }

    /// A marker belongs to the word after it, and a snippet is cut between
    /// the two — the tag marks the word, never the number before it. So the
    /// piece before the marked word ends in digits with nothing in that
    /// piece to be glued to.
    @Test func aMarkerAtTheCutStillBelongsToTheWordAfterIt() {
        // Song of Songs 2:5 in the ABP, cut where the tagged word begins.
        let before = "Pile me with apples, for [2being pierced 3"
        let word = "of love"

        // Read alone, the trailing 3 is a number the verse means —
        // correctly, for a line that truly ends there. The 2 inside the
        // piece is glued to "being" and is a marker either way.
        #expect(LampSeptuagintSection
            .interlinearRuns(in: before).filter(\.isMarker).map(\.text) == ["2"])

        // Told what follows, it is the marker it is.
        let cut = LampSeptuagintSection.interlinearRuns(in: before, followedBy: word)
        #expect(cut.filter(\.isMarker).map(\.text) == ["2", "3"])
        #expect(cut.map(\.text).joined() == before, "and nothing of the text is lost")

        // Only a letter glues it: digits before a space, or before nothing,
        // are still a number.
        #expect(LampSeptuagintSection
            .interlinearRuns(in: before, followedBy: " of love")
            .filter(\.isMarker).map(\.text) == ["2"])
        #expect(LampSeptuagintSection
            .interlinearRuns(in: before, followedBy: "")
            .filter(\.isMarker).map(\.text) == ["2"])
    }

    /// The Septuagint in English is found by what it tags, and asked of each
    /// key on its own.
    @Test func theSeptuagintInEnglishIsFoundByWhatItTags() async {
        func analysis(_ id: String, books: [(Int, Int)]) -> LampStrongsAnalysis {
            LampStrongsAnalysis(
                key: "G26", translationID: id, translationName: id, translationAbbreviation: id,
                wordCount: 1_000, taggedVerseCount: 10,
                occurrences: [], references: [], renderings: [], forms: [],
                parsings: [], grammar: [],
                books: books.map {
                    LampStrongsAnalysis.Division(
                        id: $0.0, name: "Book \($0.0)", bookRange: $0.0...$0.0,
                        occurrenceCount: $0.1, verseCount: $0.1, wordCount: 100,
                        expectedCount: 0, keyness: 0, chapters: []
                    )
                },
                sections: [], companions: []
            )
        }
        let installed: [(id: String, tagsStrongs: Bool, isOriginalLanguage: Bool)] = [
            ("BSBs", true, false),   // an English Bible: Greek keys in the NT only
            ("LXX", true, true),     // the Greek itself, not a rendering of it
            ("WEBs", false, false),  // untagged, never asked
            ("ABPs", true, false),   // the Greek Old Testament in English
        ]
        var asked: [String] = []
        let found = try! await LampSeptuagintSection.septuagintInEnglish(
            among: installed, key: "G26"
        ) { id in
            asked.append(id)
            switch id {
            case "BSBs": return analysis(id, books: [(43, 8)])
            case "ABPs": return analysis(id, books: [(22, 11)])
            default: return nil
            }
        }
        #expect(found == "ABPs")
        #expect(!asked.contains("WEBs"), "an untagged text is never analysed")
        #expect(!asked.contains("LXX"), "nor an original-language one")

        // A Hebrew key says nothing about the Greek Old Testament.
        let none = try! await LampSeptuagintSection.septuagintInEnglish(
            among: installed, key: "H160"
        ) { _ in analysis("ABPs", books: [(22, 11)]) }
        #expect(none == nil)

        // A read that failed is not an answer. Swallowed, it would read as
        // "this text is not a Septuagint in English", and a caller caching
        // that would hide the choice until the app restarted.
        struct ReadFailed: Error {}
        await #expect(throws: ReadFailed.self) {
            _ = try await LampSeptuagintSection.septuagintInEnglish(
                among: installed, key: "G26"
            ) { _ in throw ReadFailed() }
        }
    }
}
