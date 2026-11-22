import Foundation
import Testing

@testable import LampCore

struct LampBareLinksTests {
    private func found(_ text: String) -> [String] {
        LampBareLinks.addresses(in: text).map { ($0.url.absoluteString) }
    }

    private func written(_ text: String) -> [String] {
        LampBareLinks.addresses(in: text).map { (text as NSString).substring(with: $0.range) }
    }

    @Test("an address written out is found, and what it opens")
    func addressesWrittenOut() {
        #expect(found("See https://example.com/news for more.") == ["https://example.com/news"])
        #expect(found("Or http://example.com.") == ["http://example.com"])
        #expect(found("Try www.example.com today") == ["http://www.example.com"])
        #expect(found("Write to alice@example.com.") == ["mailto:alice@example.com"])
        #expect(written("(see https://example.com/x)") == ["https://example.com/x"])
    }

    @Test("what an address opens is what it says")
    func destinationsAreWhatIsWritten() {
        #expect(found("See www.youtube.com/@jane.doe now") == ["http://www.youtube.com/@jane.doe"])
        #expect(found("Email +support@example.com") == ["mailto:+support@example.com"])
        #expect(found("Write www.first.last@example.com") == ["mailto:www.first.last@example.com"])
        #expect(found("Write _support@example.com") == ["mailto:_support@example.com"])
        #expect(found("Write ~support@example.com") == [], "not shortened to support@")
        #expect(found("「https://example.com」を参照") == ["https://example.com"])
        #expect(found("参照：https://example.com/help。を見る") == ["https://example.com/help"])
        #expect(found("詳細(https://example.com/help)を参照") == ["https://example.com/help"])
        #expect(found("'https://example.com/O'Reilly'") == ["https://example.com/O'Reilly"])
        #expect(found("\"https://example.com/a\"—\"details\"") == ["https://example.com/a"])
        #expect(found("https://example.com./guide") == ["https://example.com./guide"])
        #expect(found("参照：https://example.com/İstanbul").count == 1)
        #expect(found("<https://example.com/help> and {https://example.com}") == ["https://example.com/help", "https://example.com"])
        #expect(found("https://example.com/search?q=commonmark&hl;") == ["https://example.com/search?q=commonmark"])
        #expect(written("See (https://en.wikipedia.org/wiki/Bible_(disambiguation))") == ["https://en.wikipedia.org/wiki/Bible_(disambiguation)"])
        #expect(found("Write www.alice@example.com") == ["mailto:www.alice@example.com"])
        #expect(found("See ‘https://example.com/page’ today") == ["https://example.com/page"])
        #expect(found("Contact 'alice@example.com'.") == ["mailto:alice@example.com"])
        #expect(found("www.example.com?x=1 here") == ["http://www.example.com?x=1"])
        #expect(found("www.example.com?email=alice@example.org") == ["http://www.example.com?email=alice@example.org"])
        #expect(found("参照：https://example.com/help。") == ["https://example.com/help"])
        let long = "https://example.com/download?token=" + String(repeating: "a1", count: 600)
        #expect(found("Get \(long) now") == [long])
    }

    @Test("what isn't plainly an address is left as words")
    func doubtfulOnesAreWords() {
        // Part of a longer name, or a link already written out.
        #expect(found("Ask a?b@example.com") == [])
        #expect(found("Ask a/b@example.com") == [])
        #expect(found("Or mailto:alice@example.com") == [])
        #expect(found("Not alice@example.com_") == [])
        #expect(found("Write o'connor@example.com") == [])
        #expect(found("Write alice@example.cóm") == [])
        #expect(found("https://example.com_extra/") == [])
        #expect(found("a!www.alice@example.com") == [])
        #expect(found("https://example.com/help<next") == [])
        #expect(found("alice@example.com-") == [])
        #expect(found("ftp://files.example.org/archive(https://example.com)") == [])
        #expect(found("mailto:alice@example.com?body=Try%20(https://example.org)") == [])
        #expect(found("https://www.example.com。au/guide") == [])
        #expect(found("''support@example.com'") == [])
        #expect(found("https://www.example.com。例/guide") == [])
        #expect(found("//files.example.org/archive(https://example.com)") == [])
        // Text around an address no scalar of which breaks the reading.
        #expect(found("https://example.com\n\u{0301}Next line") == ["https://example.com"])
        #expect(found("😀https://example.com") == ["https://example.com"])
    }

    @Test("a long run with no address in it is read quickly")
    func longRunsAreQuick() {
        let run = String(repeating: "a.b-c_d+", count: 10_000) + " " + String(repeating: ")", count: 20_000)
            + " " + String(repeating: ";", count: 20_000) + " " + String(repeating: "(", count: 40_000)
        let began = Date()
        #expect(LampBareLinks.addresses(in: run + " https://example.com" + String(repeating: ")", count: 20_000)).count == 1)
        #expect(Date().timeIntervalSince(began) < 1)
        let words = String(repeating: "plain words here and there ", count: 3_000)
        let wordsBegan = Date()
        #expect(LampBareLinks.addresses(in: words).isEmpty)
        #expect(Date().timeIntervalSince(wordsBegan) < 1)
    }

    @Test("a name with a dot that isn't an address is words")
    func namesWithADotAreWords() {
        #expect(found("Read outline.md first.") == [])
        #expect(found("John 3.16 and v1.2") == [])
        #expect(found("example.com") == [])
        #expect(found("ftp://example.com/file") == [])
    }

    @Test("ranges spoken for split the text, and an address against one is left")
    func takenRangesSplitTheText() {
        let text = "Go to https://example.com/new today, or https://example.org."
        let source = text as NSString
        let new = source.range(of: "new")
        // Cut by a mark: not linked, rather than linked to part of it.
        #expect(LampBareLinks.links(in: text, excluding: [new]).map(\.url.absoluteString) == ["https://example.org"])
        // Cut after punctuation the sentence would have had: still cut.
        let query = "https://example.com/?q=test"
        #expect(LampBareLinks.links(in: query, excluding: [(query as NSString).range(of: "q=test")]).isEmpty)
        // A footnote's number drawn against its end: not taken into it.
        let footnoted = "See https://example.com/report1 now"
        let number = (footnoted as NSString).range(of: "1 ")
        #expect(LampBareLinks.links(in: footnoted, excluding: [NSRange(location: number.location, length: 1)]).isEmpty)
        // Spoken-for ranges elsewhere leave it whole.
        #expect(LampBareLinks.links(in: text, excluding: [NSRange(location: 0, length: 2)]).map(\.url.absoluteString)
            == ["https://example.com/new", "https://example.org"])
    }

}
