import Foundation
import Testing
@testable import LampCore

/// A map figure: places found by name where OpenBible.info places them, and
/// a frame that shows them all.
struct LampPresentationMapTests {
    private func map(_ lines: [String], route: Bool? = nil) -> LampPresentationBlock {
        .init(id: "m", kind: .body, text: lines.joined(separator: "\n"), figure: .map, map: .init(route: route))
    }

    @Test func theShippedPlacesAreRead() throws {
        #expect(LampMapPlaces.all.count > 1_000)
        let ephesus = try #require(LampMapPlaces.match("Ephesus").place)
        #expect(abs(ephesus.latitude - 37.94) < 0.1)
        #expect(abs(ephesus.longitude - 27.34) < 0.1)
        #expect(!ephesus.isUncertain)
    }

    @Test func aNameSharedByTwoPlacesFindsNeitherUntilOneIsNamed() throws {
        guard case .ambiguous(let places) = LampMapPlaces.match("Antioch") else {
            Issue.record("Antioch should name more than one place")
            return
        }
        #expect(places.map(\.name).contains("Antioch 1"))
        #expect(places.map(\.name).contains("Antioch 2"))
        let syrian = try #require(LampMapPlaces.match("antioch 1").place)
        #expect(syrian.label == "Antioch")
        #expect(LampMapPlaces.match("Atlantis") == .unknown)
    }

    @Test func aLineNamesAPlaceAndMayCallItSomethingElse() {
        let stops = map(["Antioch 2 \u{2014} Pisidian Antioch", "Iconium", "Nowhere"]).mapStops
        #expect(stops.map(\.label) == ["Pisidian Antioch", "Iconium", "Nowhere"])
        #expect(stops[0].place?.name == "Antioch 2")
        #expect(stops[2].place == nil)
    }

    @Test func theFrameShowsEveryPlaceAtTheSlidesShape() throws {
        let places = ["Antioch 1", "Paphos", "Perga", "Derbe"].compactMap { LampMapPlaces.match($0).place }
        #expect(places.count == 4)
        let frame = LampMapFrame.fitting(places, ratio: 2.6)
        for place in places {
            #expect((frame.west...frame.east).contains(place.longitude))
            #expect((frame.south...frame.north).contains(place.latitude))
        }
        #expect(abs(frame.ratio - 2.6) < 0.05)
        // One place still shows a region around it, inside what Lamp draws.
        let alone = LampMapFrame.fitting([places[0]], ratio: 1.5)
        #expect(alone.north - alone.south >= LampMapFrame.closest - 0.001)
        let far = try #require(LampMapPlaces.match("Tarshish 1").place)
        let wide = LampMapFrame.fitting([far, places[0]], ratio: 0.2)
        // Too tall for Lamp's land at this shape, it keeps both places
        // rather than cutting one off.
        for place in [far, places[0]] {
            #expect((wide.west...wide.east).contains(place.longitude))
            #expect((wide.south...wide.north).contains(place.latitude))
        }
    }

    @Test func placesArriveOneAtATimeAndNamesTakeNoEmphasisStep() {
        var block = map(["Jerusalem", "Capernaum", "Nazareth"], route: true)
        block.emphasis = [.init(text: "Capernaum")]
        var slide = LampPresentationSlide(layout: .titleAndBody, blocks: [block], reveal: .stepwise)
        slide.revealsEmphasis = true
        let plan = slide.revealPlan
        #expect(plan.stepCount == 2)
        #expect(plan.isShown(.listItem(block: "m", index: 0), atStep: 0))
        #expect(!plan.isShown(.listItem(block: "m", index: 2), atStep: 1))
        #expect(!plan.emphasisStep)
        #expect(block.drawsRoute)
    }

    @Test func theValidatorNamesPlacesItCannotDrawOrIsUnsureOf() {
        func messages(_ block: LampPresentationBlock) -> [String] {
            LampPresentationDeckValidator.validate(
                LampPresentationDeck(title: "D", slides: [.init(layout: .titleAndBody, blocks: [block])])
            ).filter { $0.path == "slides[0].blocks[0].figure" }.map(\.message)
        }
        #expect(messages(map(["Jerusalem", "Ephesus"])).isEmpty)
        let unknown = messages(map(["Jerusalem", "Atlantis"]))
        #expect(unknown.count == 1 && unknown[0].contains("Atlantis"))
        let shared = messages(map(["Antioch"]))
        #expect(shared.count == 1 && shared[0].contains("Antioch 1"))
        let unsure = messages(map(["Gog"]))
        #expect(unsure.count == 1 && unsure[0].contains("uncertain"))
        #expect(messages(map((1...17).map { _ in "Jerusalem" })).contains { $0.contains("crowded") })
        // Map options on anything but a map are said to do nothing.
        var list = LampPresentationBlock(kind: .body, text: "A", map: .init(route: true))
        list.figure = nil
        let issues = LampPresentationDeckValidator.validate(
            LampPresentationDeck(title: "D", slides: [.init(layout: .titleAndBody, blocks: [list])])
        )
        #expect(issues.contains { $0.path == "slides[0].blocks[0].map" })
    }

    @Test func mapOptionsWrittenWronglyStillOpen() throws {
        let json = #"{"id":"m","kind":"body","text":"Jerusalem","figure":"map","map":{"route":"yes"}}"#
        let block = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(json.utf8))
        #expect(block.map == .init(route: nil))
        // An older Lamp, which knows no map, draws the lines as text.
        let unknown = #"{"id":"m","kind":"body","text":"Jerusalem","figure":"atlas"}"#
        let older = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(unknown.utf8))
        #expect(older.drawnFigure == .none)
    }

    @Test func aNameOtherBiblesUseForAnotherPlaceIsAmbiguous() {
        // Kadesh 1 and 2, and Kadesh-barnea, which English Bibles also call
        // Kadesh; Carmel the town, and Mount Carmel.
        for name in ["Kadesh", "Carmel"] {
            guard case .ambiguous(let places) = LampMapPlaces.match(name) else {
                Issue.record("\(name) should be ambiguous")
                continue
            }
            #expect(places.count > 1)
        }
    }

    @Test func aLineLeftOffTheMapTakesNoClick() {
        let block = map(["Jerusalem", "Atlantis", "Capernaum"])
        let plan = LampPresentationSlide(layout: .titleAndBody, blocks: [block], reveal: .stepwise).revealPlan
        #expect(plan.stepCount == 1)
        #expect(plan.isShown(.listItem(block: "m", index: 0), atStep: 0))
        #expect(!plan.isShown(.listItem(block: "m", index: 2), atStep: 0))
        #expect(plan.revealsItems(of: "m"))
        // Starting with one, the first place found arrives with the map.
        let first = map(["Atlantis", "Jerusalem", "Capernaum"])
        let later = LampPresentationSlide(layout: .titleAndBody, blocks: [first], reveal: .stepwise).revealPlan
        #expect(later.isShown(.listItem(block: "m", index: 1), atStep: 0))
    }

    @Test func placesTooFarApartForTheShapeStayOnTheMap() throws {
        let tarshish = try #require(LampMapPlaces.match("Tarshish 1").place)
        let india = LampMapPlace(id: "x", name: "India", otherNames: [], longitude: 67.43, latitude: 24.0,
                                 confidence: 1000, kind: .region, firstVerse: "Esth 1:1")
        let frame = LampMapFrame.fitting([tarshish, india], ratio: 520.0 / 660)
        #expect(frame.west <= tarshish.longitude && frame.east >= india.longitude)
    }

    @Test func placesTooCloseToDrawApartAreSaidToBe() {
        let issues = LampPresentationDeckValidator.validate(
            LampPresentationDeck(title: "D", slides: [.init(layout: .titleAndBody, blocks: [map(["Jerusalem", "Ophel", "Capernaum"])])])
        ).filter { $0.message.contains("too close") }
        #expect(issues.count == 1)
        #expect(issues.first?.message.contains("Jerusalem and Ophel") == true)
    }
}
