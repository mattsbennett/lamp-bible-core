import Testing
@testable import LampCore

/// Every verse in Lamp is one packed integer — `book * 1_000_000 +
/// chapter * 1_000 + verse` — and every reference the reader, a plan, a deck,
/// a highlight or a widget displays comes back out through here. Fifteen call
/// sites across the Mac and iOS apps rely on it, and none of them could have
/// told you it was wrong: a shifted book table would simply name the wrong
/// book, and a deep link into another Bible app would simply open the wrong
/// page.
struct LampBibleReferenceFormatterTests {
    // MARK: - The packing

    @Test func aReferenceSplitsIntoBookChapterAndVerse() {
        let components = LampBibleReferenceFormatter.components(of: 43_003_016)
        #expect(components.book == 43)
        #expect(components.chapter == 3)
        #expect(components.verse == 16)
    }

    /// Three digits each for chapter and verse. Psalm 119:176 is the longest
    /// chapter in the Bible and the one that would overflow a narrower field.
    @Test func theLongestChapterInTheBibleStillFits() {
        let components = LampBibleReferenceFormatter.components(of: 19_119_176)
        #expect(components == (book: 19, chapter: 119, verse: 176))
        #expect(LampBibleReferenceFormatter.bookName(components.book) == "Psalms")
    }

    // MARK: - What a range reads as

    @Test func oneVerseIsNamedWithoutARange() {
        #expect(
            LampBibleReferenceFormatter.describeRange(from: 43_003_016, to: 43_003_016)
                == "John 3:16"
        )
    }

    @Test func versesWithinOneChapterShareTheChapterNumber() {
        #expect(
            LampBibleReferenceFormatter.describeRange(from: 43_003_016, to: 43_003_017)
                == "John 3:16–17"
        )
    }

    /// Verse 1 to verse 999 is how a whole chapter is stored, so it must read
    /// as the chapter rather than as "Psalms 23:1–999".
    @Test func aWholeChapterIsNamedAsTheChapter() {
        #expect(
            LampBibleReferenceFormatter.describeRange(from: 19_023_001, to: 19_023_999)
                == "Psalms 23"
        )
    }

    @Test func wholeChaptersInARunAreNamedAsAChapterRange() {
        #expect(
            LampBibleReferenceFormatter.describeRange(from: 19_023_001, to: 19_024_999)
                == "Psalms 23–24"
        )
    }

    /// A span that starts or ends mid-chapter has to carry both verses, or the
    /// reading it describes would be wrong at both ends.
    @Test func aSpanAcrossChaptersKeepsBothVerses() {
        #expect(
            LampBibleReferenceFormatter.describeRange(from: 19_023_002, to: 19_024_003)
                == "Psalms 23:2–24:3"
        )
    }

    @Test func aSpanAcrossBooksNamesBothBooks() {
        #expect(
            LampBibleReferenceFormatter.describeRange(from: 39_004_006, to: 40_001_001)
                == "Malachi 4:6–Matthew 1:1"
        )
    }

    /// An en dash, not a hyphen: these strings are read, not parsed.
    @Test func rangesAreJoinedWithAnEnDash() {
        let range = LampBibleReferenceFormatter.describeRange(from: 43_003_016, to: 43_003_017)
        #expect(range.contains("\u{2013}"))
        #expect(!range.contains("-"))
    }

    // MARK: - The book tables

    /// The canon in order. A single insertion or deletion anywhere in either
    /// table silently renames every book after it, so the ends and the seam
    /// between the testaments are all checked.
    @Test(arguments: [
        (1, "Genesis", "Gen"),
        (19, "Psalms", "Ps"),
        (39, "Malachi", "Mal"),
        (40, "Matthew", "Matt"),
        (43, "John", "John"),
        (46, "1 Corinthians", "1Cor"),
        (66, "Revelation", "Rev"),
    ])
    func bookNumbersNameTheirBook(number: Int, name: String, abbreviation: String) {
        #expect(LampBibleReferenceFormatter.bookName(number) == name)
        #expect(LampBibleReferenceFormatter.bookAbbreviation(number) == abbreviation)
    }

    /// Both tables must run out at the same book, or a reference past the end
    /// of one would be answered from the other.
    @Test func bothTablesEndAtRevelation() {
        #expect(LampBibleReferenceFormatter.bookName(66) == "Revelation")
        #expect(LampBibleReferenceFormatter.bookAbbreviation(66) == "Rev")
        #expect(LampBibleReferenceFormatter.bookName(67) == "Book 67")
        #expect(LampBibleReferenceFormatter.bookAbbreviation(67) == "Book67")
    }

    /// A number outside the canon says so rather than trapping. Module data is
    /// not always well formed, and a malformed reference must not end the
    /// reader's session.
    @Test(arguments: [0, -1, 67, 9_999])
    func aBookOutsideTheCanonIsNamedRatherThanCrashing(number: Int) {
        #expect(LampBibleReferenceFormatter.bookName(number).hasPrefix("Book"))
        #expect(LampBibleReferenceFormatter.bookAbbreviation(number).hasPrefix("Book"))
    }
}

/// The abbreviations above are OSIS identifiers, and they are what Lamp hands
/// to most of these apps when the reader asks to open a passage there. A wrong
/// one does not fail — it opens that app at the wrong passage. YouVersion is
/// the exception and takes USFM codes.
struct LampExternalBibleLinkFormatTests {
    @Test func installedBookMetadataCanOverrideCanonicalCatalog() {
        let link = LampExternalBibleApplication.accordance.url(
            startReference: 43_003_016, endReference: 43_003_018
        ) { number in
            LampExternalBibleBook(number: number, name: "John", osisID: "Jn")
        }
        #expect(link?.absoluteString == "accord://read/Jn_3:16-Jn_3:18")
        #expect(LampExternalBibleApplication.logos.url(
            startReference: 43_003_016
        ) { _ in nil } == nil)
    }

    /// YouVersion references books by USFM code, not by the OSIS identifier
    /// the other apps take. They differ for most books, so an OSIS one opens
    /// YouVersion at the wrong passage, or at none.
    @Test func youVersionIsGivenUSFMCodes() {
        #expect(
            LampExternalBibleApplication.youVersion.url(
                startReference: 43_003_016, endReference: 43_003_018
            )?.absoluteString == "youversion://bible?reference=JHN.3.16-18"
        )
        #expect(
            LampExternalBibleApplication.youVersion.url(startReference: 19_023_001)?
                .absoluteString == "youversion://bible?reference=PSA.23.1-1",
            "Psalms is Ps in OSIS and PSA in USFM"
        )
    }

    /// Book metadata supplied by a caller may know an OSIS identifier and not a
    /// USFM code. A link then keeps what it has rather than building a
    /// reference out of an empty string.
    @Test func ayouVersionLinkFallsBackWhenNoUSFMCodeIsKnown() {
        let link = LampExternalBibleApplication.youVersion.url(
            startReference: 43_003_016
        ) { number in
            LampExternalBibleBook(number: number, name: "John", osisID: "Jn")
        }
        #expect(link?.absoluteString == "youversion://bible?reference=Jn.3.16-16")
    }

    /// A plan's daily reading is usually whole chapters, which a reference
    /// ends at verse 999 — its way of saying "to the end" rather than a verse
    /// anybody has. Sent on as a verse number it asked YouVersion for
    /// 2 Chronicles 25:1-999, which it has no application for.
    @Test func awholeChapterAsksForTheChapterAndNotVerse999() {
        let wholeChapter = LampExternalBibleApplication.youVersion.url(
            startReference: 14_025_001, endReference: 14_025_999
        )
        #expect(wholeChapter?.absoluteString == "youversion://bible?reference=2CH.25")

        #expect(
            LampExternalBibleApplication.accordance.url(
                startReference: 14_025_001, endReference: 14_025_999
            )?.absoluteString == "accord://read/2Chr_25"
        )
    }

    /// Several whole chapters keep both ends, without the sentinel.
    @Test func aspanOfWholeChaptersNamesBothChapters() {
        #expect(
            LampExternalBibleApplication.accordance.url(
                startReference: 14_025_001, endReference: 14_027_999
            )?.absoluteString == "accord://read/2Chr_25-2Chr_27"
        )
    }

    @Test func accordanceTakesBothEndsOfTheRange() {
        #expect(
            LampExternalBibleApplication.accordance.url(
                startReference: 43_003_016, endReference: 43_003_017
            )?.absoluteString == "accord://read/John_3:16-John_3:17"
        )
    }

    @Test func youVersionNumbersTheVersesWithinOneChapter() {
        #expect(
            LampExternalBibleApplication.youVersion.url(
                startReference: 43_003_016, endReference: 43_003_017
            )?.absoluteString == "youversion://bible?reference=JHN.3.16-17"
        )
    }

    /// YouVersion's scheme cannot express a span of chapters, so a range that
    /// crosses one opens at the chapter it starts in rather than at a passage
    /// the app would read as something else.
    @Test func youVersionFallsBackToTheChapterWhenTheRangeCrossesOne() {
        #expect(
            LampExternalBibleApplication.youVersion.url(
                startReference: 43_003_016, endReference: 43_004_002
            )?.absoluteString == "youversion://bible?reference=JHN.3"
        )
    }

    /// e-Sword and Logos are addressed by the spelled-out book name with its
    /// spaces closed up, which is why "1 Samuel" has to arrive as "1samuel".
    @Test func eSwordAndLogosUseTheClosedUpBookName() {
        #expect(
            LampExternalBibleApplication.eSword.url(startReference: 9_001_001)?
                .absoluteString == "e-sword://1samuel.1:1"
        )
        #expect(
            LampExternalBibleApplication.logos.url(startReference: 46_013_004)?
                .absoluteString == "https://ref.ly/1corinthians13:4"
        )
    }

    @Test func oliveTreeIsAddressedByBookNumber() {
        #expect(
            LampExternalBibleApplication.oliveTree.url(startReference: 43_003_016)?
                .absoluteString == "olivetree://bible/43.3.16"
        )
    }

    /// Nothing is offered for a book Lamp cannot name. Sending a malformed
    /// link would open the other app at whatever it made of it.
    @Test func aReferenceOutsideTheCanonProducesNoLink() {
        for application in LampExternalBibleApplication.allCases {
            #expect(application.url(startReference: 70_001_001) == nil)
            #expect(application.url(startReference: 0) == nil)
        }
    }

    /// Every app in the picker must have a scheme to test for installation and
    /// a root to build on, or its row cannot be shown correctly.
    @Test func everyApplicationCanBeOfferedAndAddressed() {
        for application in LampExternalBibleApplication.allCases {
            #expect(!application.scheme.isEmpty)
            #expect(!application.urlRoot.isEmpty)
            #expect(application.id == application.rawValue)
            #expect(application.url(startReference: 43_003_016) != nil)
        }
    }
}
