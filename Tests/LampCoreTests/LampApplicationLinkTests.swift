import Foundation
import Testing
@testable import LampCore
import LampModuleKit

struct LampApplicationLinkTests {
    @Test func preservesLegacyAndModernScriptureLinks() throws {
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://verse/43003016/43003018?translation=KJV"
        ))) == .verse(reference: 43_003_016, endReference: 43_003_018, translationID: "KJV"))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://john3:16"
        ))) == .verse(reference: 43_003_016, endReference: nil, translationID: nil))

        let encoded = try #require(LampApplicationLink.verseURL(
            reference: 43_003_016, endReference: 43_003_018,
            translationID: "My Bible"
        ))
        #expect(encoded.absoluteString ==
            "lampbible://reference/john3:16-18?translation=My%20Bible")
        #expect(LampApplicationLink(url: encoded) ==
            .verse(reference: 43_003_016, endReference: 43_003_018,
                   translationID: "My Bible"))
    }

    @Test func readsBothAppsRoutesWithoutDiscardingArguments() throws {
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://reading/43003016/43003018?external=1"
        ))) == .reading(reference: 43_003_016, endReference: 43_003_018,
                       openExternal: true))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://strongs/G1234"
        ))) == .strongs("G1234"))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://read?reference=43003016&translation=KJV"
        ))) == .reader(reference: 43_003_016, translationID: "KJV"))
        #expect(LampApplicationLink(url: try #require(URL(
            string: "lampbible://books?module=BOOK&section=one"
        ))) == .book(moduleID: "BOOK", sectionID: "one", anchor: nil))
        #expect(LampApplicationLink(url: URL(fileURLWithPath: "/tmp/test.lamp")) ==
            .moduleFile(URL(fileURLWithPath: "/tmp/test.lamp")))
    }

    private func link(_ string: String) throws -> LampApplicationLink? {
        LampApplicationLink(url: try #require(URL(string: string)))
    }

    /// A place in a module, as a link target names one
    /// (`Documentation/RichModulesPlan.md`, "Link address").
    @Test func readsAPlaceInACommentaryOrABook() throws {
        #expect(try link("lampbible://commentary?module=ESVSB&sv=43003016&ev=43003018&suffix=b&unit=jn-3-16&anchor=fig-2")
            == .commentaryPassage(moduleID: "ESVSB", reference: 43_003_016, endReference: 43_003_018,
                                  suffix: "b", unit: "jn-3-16", anchor: "fig-2"))
        #expect(try link("lampbible://commentary?module=ESVSB&sv=19003000")
            == .commentaryPassage(moduleID: "ESVSB", reference: 19_003_000, endReference: nil,
                                  suffix: nil, unit: nil, anchor: nil))
        #expect(try link("lampbible://commentary?module=ESVSB&book=43&section=intro-author&anchor=p3")
            == .commentaryFrontMatter(moduleID: "ESVSB", book: 43, sectionID: "intro-author", anchor: "p3"))
        #expect(try link("lampbible://book?module=LIB&section=weights&anchor=table-1")
            == .book(moduleID: "LIB", sectionID: "weights", anchor: "table-1"))
        #expect(try link("lampbible://book?module=LIB") == .book(moduleID: "LIB", sectionID: nil, anchor: nil))
        #expect(try link("lampbible://book") == .section(.books))
        // Without an anchor, a module or section given empty is none, as it
        // always was. Found by Codex.
        #expect(try link("lampbible://books?module=LIB&section=") == .book(moduleID: "LIB", sectionID: nil, anchor: nil))
        #expect(try link("lampbible://book?module=&section=weights") == .book(moduleID: nil, sectionID: "weights", anchor: nil))
        #expect(try link("lampbible://book?module=&section=") == .section(.books))
        // And one given with no value at all. Found by Codex.
        #expect(try link("lampbible://books?module=LIB&section") == .book(moduleID: "LIB", sectionID: nil, anchor: nil))
        // An ID is read as written, not trimmed: `table-1 ` is not
        // `table-1`. Found by Codex. Given twice alike, it is one.
        #expect(try link("lampbible://book?module=LIB&section=weights&anchor=table-1%20")
            == .book(moduleID: "LIB", sectionID: "weights", anchor: "table-1 "))
        #expect(try link("lampbible://commentary?module=ESVSB&sv=43003016&unit=%20u&unit=%20u")
            == .commentaryPassage(moduleID: "ESVSB", reference: 43_003_016, endReference: nil,
                                  suffix: nil, unit: " u", anchor: nil))
        // But for a suffix, given empty, which is none as the compiler
        // stores it.
        #expect(try link("lampbible://commentary?module=ESVSB&sv=43003016&suffix=")
            == .commentaryPassage(moduleID: "ESVSB", reference: 43_003_016, endReference: nil,
                                  suffix: nil, unit: nil, anchor: nil))
    }

    /// A commentary link written wrong opens nothing, rather than somewhere
    /// near what it meant: the rules a link target is read by.
    @Test func aCommentaryLinkWrittenWrongOpensNothing() throws {
        for string in [
            "lampbible://commentary?sv=43003016",                               // no module
            "lampbible://commentary?module=ESVSB",                              // no place
            "lampbible://commentary?module=ESVSB&sv=John",                      // not a number
            "lampbible://commentary?module=ESVSB&sv=43003016&ev=x",             // nor this
            "lampbible://commentary?module=ESVSB&sv=43003018&ev=43003016",      // ends before it begins
            "lampbible://commentary?module=ESVSB&sv=67001001",                  // no such book
            "lampbible://commentary?module=ESVSB&sv=43000001",                  // no chapter
            "lampbible://commentary?module=ESVSB&sv=43003016&book=43&section=i", // two routes
            "lampbible://commentary?module=ESVSB&book=43",                      // no section
            "lampbible://commentary?module=ESVSB&book=0&section=intro",         // no such book
            "lampbible://commentary?module=ESVSB&book=43&section=i&unit=u",     // unit is a passage's
            "lampbible://commentary?module=ESVSB&section=intro",                // whose front matter?
            // A selector undecodable, without a value, or given twice
            // differently: read as none or the first, each opened another
            // note at the passage. Found by Codex.
            "lampbible://commentary?module=ESVSB&sv=43003016&unit=%FF",
            "lampbible://commentary?module=ESVSB&sv=43003016&unit",
            "lampbible://commentary?module=ESVSB&sv=43003016&unit=a&unit=b",
            "lampbible://commentary?module=ESVSB&sv=43003016&sv=43003017",
            "lampbible://book?module=LIB&section=weights&anchor=%FF",
            "lampbible://book?module=LIB&section=weights&anchor=a&anchor=b",
            // Given empty, as a target's field given empty is wrong.
            "lampbible://commentary?module=ESVSB&sv=43003016&unit=",
            "lampbible://commentary?module=ESVSB&sv=43003016&ev=",
            "lampbible://commentary?module=ESVSB&sv=43003016&anchor=",
            "lampbible://book?module=LIB&section=weights&anchor=",
            // Two spellings of one name, alike as `String`s but not as the
            // bytes a module is looked up by. Found by Codex.
            "lampbible://book?module=Caf%C3%A9&module=Cafe%CC%81",
            // A name that does not decode, which Foundation reads as an
            // empty one, so the field it meant went unread. Found by Codex.
            "lampbible://book?module=LIB&section=weights&an%FFchor=table-1",
            "lampbible://commentary?module=ESVSB&sv=43003016&un%FFit=u",
            // A suffix with no value, or one that does not decode, which
            // Foundation reads alike as no value. Only `suffix=` is none.
            // Found by Codex.
            "lampbible://commentary?module=ESVSB&sv=43003016&suffix",
            "lampbible://commentary?module=ESVSB&sv=43003016&suffix=%FF",
            "lampbible://book?module=LIB&section=%FF",
            // An anchor is a block in a section, so with none it is wrong.
            "lampbible://book?module=LIB&anchor=table-1",
            // A commentary's selector on a book, anchored or not, as a
            // target in a book refuses; and an anchor in no named book.
            // Found by Codex.
            "lampbible://book?module=LIB&section=weights&anchor=table-1&sv=43003016",
            "lampbible://book?module=LIB&section=weights&unit=u",
            "lampbible://book?section=weights&anchor=table-1",
        ] {
            #expect(try link(string) == nil, "\(string)")
        }
    }

    /// A place link and a link target say the same: each set of fields,
    /// given as a URL's parameters and as a target's JSON in a module of the
    /// same kind, opens the same place or none. Two reviews in turn found the
    /// URL read more loosely than the target. Found by Codex.
    @Test func aPlaceLinkReadsAsTheTargetItWrites() throws {
        let cases: [[String: String]] = [
            ["sv": "43003016"],
            ["sv": "43003016", "ev": "43003018", "suffix": "b", "unit": "u", "anchor": "a"],
            ["sv": "43003016", "unit": ""], ["sv": "43003016", "ev": ""], ["sv": "43003016", "anchor": ""],
            ["sv": "43003016", "suffix": ""], ["sv": "43003016", "unit": " u "], ["sv": "", "unit": "u"],
            ["sv": "43003016", "ev": "43003015"], ["sv": "x"], ["sv": "43003016", "ev": "4300301.5"],
            ["sv": "43003016", "book": "43", "section": "s"], ["book": "43", "section": "s"],
            ["book": "43", "section": " s "], ["book": "43", "section": ""], ["book": "67", "section": "s"],
            ["book": "43"], ["section": "s"], ["book": "43", "section": "s", "unit": "u"], [:],
        ]
        // A book's, each naming a section or an anchor: one naming neither
        // is the older link to a whole book, which no target is.
        let bookCases: [[String: String]] = [
            ["section": "s"], ["section": "s", "anchor": "a"], ["section": " s", "anchor": "a "],
            ["section": "s", "anchor": ""], ["section": "", "anchor": "a"], ["anchor": "a"],
            ["section": "s", "anchor": "a", "sv": "43003016"], ["section": "s", "unit": "u"],
            ["section": "s", "book": "43"], ["section": "s", "suffix": ""], ["section": "s", "suffix": "b"],
        ]
        for (kind, module, fields) in ["NIC", " NIC "].flatMap({ module in
            cases.map { ("commentary", module, $0) } + bookCases.map { ("book", module, $0) }
        }) {
            var json: [String: Any] = ["kind": kind, "module": module]
            for (name, value) in fields {
                json[name] = ["sv", "ev", "book"].contains(name) ? (Int(value).map { $0 as Any } ?? value) : value
            }
            let target = try? JSONDecoder().decode(
                LampLinkTarget.self, from: JSONSerialization.data(withJSONObject: json)
            )
            let fromTarget = target.flatMap {
                LampApplicationLink(target: $0, containingKind: kind, containingModuleID: "other")
            }
            var components = URLComponents()
            components.scheme = "lampbible"
            components.host = kind
            let allowed = CharacterSet.alphanumerics
            components.percentEncodedQuery = (["module": module].merging(fields) { a, _ in a })
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
                .joined(separator: "&")
            let fromURL = LampApplicationLink(url: try #require(components.url))
            #expect(fromURL == fromTarget, "\(kind) \(module) \(fields)")
        }
    }

    /// A target becomes the link a reader opens, in the module it names or
    /// the reader's own; and each place writes back as the link it was read
    /// from, whatever its IDs hold.
    @Test func aTargetIsALinkAndALinkItsURL() throws {
        let passage = LampLinkTarget(startReference: 43_003_016, unit: "u1")
        #expect(LampApplicationLink(target: passage, containingKind: "commentary", containingModuleID: "NIC")
            == .commentaryPassage(moduleID: "NIC", reference: 43_003_016, endReference: nil,
                                  suffix: nil, unit: "u1", anchor: nil))
        let elsewhere = LampLinkTarget(kind: "book", module: "LIB", section: "weights", anchor: "t1")
        #expect(LampApplicationLink(target: elsewhere, containingKind: "commentary", containingModuleID: "NIC")
            == .book(moduleID: "LIB", sectionID: "weights", anchor: "t1"))
        // A book holds no passage of its own, and a reader with no ID of its
        // own cannot stand in for the module a target leaves out.
        #expect(LampApplicationLink(target: passage, containingKind: "book", containingModuleID: "LIB") == nil)
        #expect(LampApplicationLink(target: passage, containingKind: "commentary", containingModuleID: "") == nil)
        // The reader's own ID as it is, spaces and all: trimmed, it named
        // another module. Found by Codex.
        #expect(LampApplicationLink(target: passage, containingKind: "commentary", containingModuleID: "NIC ")
            == .commentaryPassage(moduleID: "NIC ", reference: 43_003_016, endReference: nil,
                                  suffix: nil, unit: "u1", anchor: nil))

        let odd = "a&b=c+d e/é?#"
        for place: LampApplicationLink in [
            .commentaryPassage(moduleID: odd, reference: 43_003_016, endReference: 43_003_018,
                               suffix: "b", unit: " \(odd) ", anchor: odd),
            .commentaryPassage(moduleID: "ESVSB", reference: 1_001_001, endReference: nil,
                               suffix: nil, unit: nil, anchor: nil),
            .commentaryFrontMatter(moduleID: odd, book: 66, sectionID: odd, anchor: nil),
            .book(moduleID: " \(odd)", sectionID: "appendix ", anchor: odd),
            .book(moduleID: "LIB", sectionID: nil, anchor: nil),
        ] {
            let url = try #require(place.placeURL)
            #expect(LampApplicationLink(url: url) == place, "\(url)")
        }
        #expect(LampApplicationLink.strongs("G1").placeURL == nil)
        // A place no URL reads back as has none: a book naming neither book
        // nor section is the shelf, a passage ending before it begins is
        // nothing. Found by Codex.
        #expect(LampApplicationLink.book(moduleID: nil, sectionID: nil, anchor: nil).placeURL == nil)
        #expect(LampApplicationLink.commentaryPassage(
            moduleID: "ESVSB", reference: 43_003_018, endReference: 43_003_016,
            suffix: nil, unit: nil, anchor: nil
        ).placeURL == nil)
    }
}
