import Testing
@testable import LampCore

struct LampBookLibrarySearchTests {
    private let book = LampBook(
        id: "christendom-astray",
        title: "Christendom Astray",
        subtitle: "Popular Christianity Both in Faith and Practice",
        author: "Robert Roberts",
        publisher: "The Christadelphian",
        year: 1884,
        language: "en",
        tags: ["apologetics"],
        genre: "first-principles"
    )

    private func finds(_ text: String, genreName: String? = nil) -> Bool {
        book.matchesLibrarySearch(LampSearchQuery(text), genreName: genreName)
    }

    @Test func eachWordMayBeFoundInADifferentField() {
        #expect(finds("roberts christendom"))
        #expect(finds("Christadelphian 1884"))
        #expect(finds("apolog"))
        #expect(!finds("roberts eureka"))
    }

    @Test func wordsMatchWhereAWordStarts() {
        #expect(finds("astray"))
        #expect(!finds("stray"))
        #expect(finds("*stray"))
    }

    @Test func theGenreIsFoundByTheNameTheCatalogGivesIt() {
        #expect(!finds("principles"))
        #expect(finds("principles", genreName: "First Principles"))
    }

    @Test func anEmptySearchFindsEveryBook() {
        #expect(finds(""))
        #expect(finds("   "))
    }
}
