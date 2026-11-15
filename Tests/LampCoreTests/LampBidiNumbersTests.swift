import Foundation
import Testing
@testable import LampCore

struct LampBidiNumbersTests {
    private let lrm = "\u{200E}"

    /// BDB H5603, as the owner reported it: the "1" of "1Kgs" was drawn on
    /// the far side of the Hebrew.
    @Test func marksTheNumberedBookAfterHebrew() {
        let text = "Qal Imperfect וַיִּסְפֹּן אֶתהַֿבַּיִת גֵּבִים 1Kgs 6:9 and he covered"
        #expect(LampBidiNumbers.holdingLeftToRight(text)
            == "Qal Imperfect וַיִּסְפֹּן אֶתהַֿבַּיִת גֵּבִים \(lrm)1Kgs 6:9 and he covered")
    }

    @Test func marksASpacedReferenceAndEachOneAfterHebrew() {
        let text = "פֶּה mouth, פִּיּוֹת 1 Sam 13:21; גַּם 2 Kgs 1:1"
        #expect(LampBidiNumbers.holdingLeftToRight(text)
            == "פֶּה mouth, פִּיּוֹת \(lrm)1 Sam 13:21; גַּם \(lrm)2 Kgs 1:1")
    }

    /// A number between two Hebrew words is the phrase's own, and brackets,
    /// a number after English, and a number ending the text are left as the
    /// bidi algorithm draws them.
    @Test func leavesEverythingElseAlone() {
        for text in [
            "",
            "Gen 1:1",
            "λόγος 1Cor 1:18",
            "cf. אֶת־הַשָּׁמַיִם 3 וְאֵת",
            "see (אב) (גד) end",
            "see אב (גד) end",
            "בְּרֵאשִׁית בָּרָא 1",
            "Hebrew בַּיִת, 12",
            "a \u{2068}בַּיִת\u{2069} 2Kgs 1:1",
            "a בַּיִת \u{202B}2Kgs\u{202C}",
        ] {
            #expect(LampBidiNumbers.holdingLeftToRight(text) == text)
        }
    }

    /// A currency or percent sign written onto the number goes behind the
    /// mark with it; a plus or minus, which only joins between digits, does
    /// not; and a separator in the number is not a letter that splits it.
    @Test func keepsANumbersOwnSignsAndSeparatorsWithIt() {
        #expect(LampBidiNumbers.holdingLeftToRight("מחיר $12 USD") == "מחיר \(lrm)$12 USD")
        #expect(LampBidiNumbers.holdingLeftToRight("אב -3 to 4") == "אב -\(lrm)3 to 4")
        #expect(LampBidiNumbers.holdingLeftToRight("אב-1Kgs") == "אב-\(lrm)1Kgs")
        #expect(LampBidiNumbers.holdingLeftToRight("אב \u{058F}12 USD") == "אב \(lrm)\u{058F}12 USD")
        #expect(LampBidiNumbers.holdingLeftToRight("אב \u{2213}12 units") == "אב \(lrm)\u{2213}12 units")
        #expect(LampBidiNumbers.holdingLeftToRight("מחיר $<mark>12</mark> USD", ignoring: ["<mark>", "</mark>"])
            == "מחיר \(lrm)$<mark>12</mark> USD")
        #expect(LampBidiNumbers.holdingLeftToRight("English אב 1\u{060C}000 means")
            == "English אב \(lrm)1\u{060C}000 means")
    }

    /// A paragraph starts afresh: Hebrew ending one does not reach a number
    /// opening the next, and a number ending one does not look into the next.
    @Test func stopsAtTheEndOfAParagraph() {
        #expect(LampBidiNumbers.holdingLeftToRight("English אב\n1Kgs 6:9") == "English אב\n1Kgs 6:9")
        #expect(LampBidiNumbers.holdingLeftToRight("English אב 12\nNext") == "English אב 12\nNext")
        #expect(LampBidiNumbers.holdingLeftToRight("A\nEnglish אב 1Kgs") == "A\nEnglish אב \(lrm)1Kgs")
    }

    /// Search's marks are not letters: a hit on the reference still gets its
    /// mark, inside the highlight.
    @Test func passesOverTagsItIsTold() {
        let text = "גֵּבִים <mark>1Kgs</mark> 6:9"
        #expect(LampBidiNumbers.holdingLeftToRight(text, ignoring: ["<mark>", "</mark>"])
            == "גֵּבִים <mark>\(lrm)1Kgs</mark> 6:9")
        #expect(LampBidiNumbers.holdingLeftToRight("<mark>גֵּבִים</mark> 1Kgs", ignoring: ["<mark>", "</mark>"])
            == "<mark>גֵּבִים</mark> \(lrm)1Kgs")
    }

    /// The mark takes the digit's attributes, so it sits inside the link.
    @Test func attributedMarkTakesTheDigitsAttributes() {
        var value = AttributedString("see גֵּבִים ")
        var reference = AttributedString("1Kgs 6:9")
        reference.link = URL(string: "lamp://passage/11006009")
        value.append(reference)
        LampBidiNumbers.holdLeftToRight(in: &value)

        #expect(String(value.characters) == "see גֵּבִים \(lrm)1Kgs 6:9")
        let runs = value.runs.map { (String(value[$0.range].characters), $0.link) }
        #expect(runs.count == 2)
        #expect(runs[1].0 == "\(lrm)1Kgs 6:9")
        #expect(runs[1].1 == URL(string: "lamp://passage/11006009"))
    }

    /// The NSAttributedString form counts in UTF-16, which a pointed word and
    /// anything outside the Basic Multilingual Plane make differ from scalars.
    @Test func mutableAttributedMarkLandsInUTF16() {
        let key = NSAttributedString.Key("LampTestLink")
        let value = NSMutableAttributedString(string: "😀 גֵּבִים 1Kgs")
        value.addAttribute(key, value: "1Kgs", range: NSRange(location: value.length - 4, length: 4))
        LampBidiNumbers.holdLeftToRight(in: value)
        #expect(value.string == "😀 גֵּבִים \(lrm)1Kgs")
        let markAt = (value.string as NSString).range(of: lrm).location
        #expect(value.attribute(key, at: markAt, effectiveRange: nil) as? String == "1Kgs")
    }
}
