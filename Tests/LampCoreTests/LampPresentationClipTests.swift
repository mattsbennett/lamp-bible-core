import Foundation
import Testing
@testable import LampCore

/// A clip: a video the talk stops to watch, from a file in the deck or from
/// YouTube or Vimeo, played on a click or when its slide arrives.
struct LampPresentationClipTests {
    private typealias Origin = LampPresentationClip.Origin

    @Test func everyFormTheSitesHandOutIsRead() {
        let id = "dQw4w9WgXcQ"
        for address in [
            "https://www.youtube.com/watch?v=\(id)",
            "https://youtube.com/watch?v=\(id)&t=42s",
            "https://m.youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)?si=abc",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/live/\(id)",
        ] {
            #expect(LampPresentationClip.origin(of: address) == .youtube(id), "\(address)")
        }
        #expect(LampPresentationClip.origin(of: "https://vimeo.com/76979871") == .vimeo("76979871", hash: nil))
        #expect(LampPresentationClip.origin(of: "https://vimeo.com/76979871/abc123ef") == .vimeo("76979871", hash: "abc123ef"))
        #expect(LampPresentationClip.origin(of: "https://player.vimeo.com/video/76979871?h=abc123ef") == .vimeo("76979871", hash: "abc123ef"))
        #expect(LampPresentationClip.origin(of: "https://vimeo.com/channels/staffpicks/76979871") == .vimeo("76979871", hash: nil))
        // A private link's key can be all digits.
        #expect(LampPresentationClip.origin(of: "https://vimeo.com/76979871/1234567890") == .vimeo("76979871", hash: "1234567890"))
        #expect(LampPresentationClip.origin(of: "https://vimeo.com/showcase/9/video/76979871") == .vimeo("76979871", hash: nil))
        #expect(LampPresentationClip.origin(of: "Assets/interview.mp4") == .file("Assets/interview.mp4"))
        // Nothing Lamp can play: another site, a short id, a path that
        // climbs out, a format Lamp does not play.
        for source in [
            "https://example.com/watch?v=\(id)", "https://youtu.be/short", "../interview.mp4",
            "Assets/interview.webm", "https://vimeo.com/channels/staffpicks", "",
        ] {
            #expect(LampPresentationClip.origin(of: source) == .unplayable, "\(source)")
        }
        #expect(LampPresentationClip(source: "https://youtu.be/\(id)").isStreamed)
        #expect(LampPresentationClip(source: "Assets/a.mp4").assetPath == "Assets/a.mp4")
        #expect(LampPresentationClip(source: "https://youtu.be/\(id)").assetPath == nil)
    }

    private func clipSlide(_ clip: LampPresentationClip, kind: LampPresentationBlockKind = .image,
                           reveal: LampPresentationReveal? = nil) -> LampPresentationSlide {
        .init(layout: .titleAndBody, blocks: [
            .init(id: "t", kind: .title, text: "Watch"),
            .init(id: "b", kind: .body, text: "First\nSecond", listStyle: .unordered),
            .init(id: "p", kind: kind, text: kind == .image ? "" : "Words", assetPath: kind == .image ? "Assets/still.jpg" : nil,
                  altText: kind == .image ? "Still" : nil, clip: clip),
        ], reveal: reveal)
    }

    @Test func aClipThatWaitsForAClickIsTheSlidesLastStep() {
        let slide = clipSlide(.init(source: "Assets/a.mp4"))
        let plan = slide.revealPlan
        #expect(plan.stepCount == 1)
        let picture = slide.blocks[2]
        #expect(!plan.isPlaying(picture, atStep: 0))
        #expect(plan.isPlaying(picture, atStep: 1))
        // Nobody presenting: never playing.
        #expect(!plan.isPlaying(picture, atStep: nil))

        // After the list's items, when the slide reveals them.
        let stepwise = clipSlide(.init(source: "Assets/a.mp4"), reveal: .stepwise)
        #expect(stepwise.revealPlan.stepCount == 2)
        #expect(!stepwise.revealPlan.isPlaying(stepwise.blocks[2], atStep: 1))
        #expect(stepwise.revealPlan.isPlaying(stepwise.blocks[2], atStep: 2))

        // With emphasis that lights on a step of its own, the clip still
        // plays last.
        var lit = clipSlide(.init(source: "Assets/a.mp4"))
        lit.blocks[1].emphasis = [.init(text: "First")]
        lit.revealsEmphasis = true
        #expect(lit.revealPlan.stepCount == 2)
        #expect(lit.revealPlan.isEmphasisLit(atStep: 1))
        #expect(!lit.revealPlan.isPlaying(lit.blocks[2], atStep: 1))
        #expect(lit.revealPlan.isPlaying(lit.blocks[2], atStep: 2))

        // On arrival: no step, playing from the start.
        let arriving = clipSlide(.init(source: "Assets/a.mp4", starts: .arrival))
        #expect(arriving.revealPlan.stepCount == 0)
        #expect(arriving.revealPlan.isPlaying(arriving.blocks[2], atStep: 0))
    }

    @Test func aClipIsCheckedAndOlderDecksOpen() throws {
        func paths(_ clip: LampPresentationClip, kind: LampPresentationBlockKind = .image) -> [(String, LampPresentationDeckIssue.Severity)] {
            let deck = LampPresentationDeck(title: "D", slides: [clipSlide(clip, kind: kind)])
            return LampPresentationDeckValidator.validate(deck).filter { $0.path.hasSuffix(".clip") }.map { ($0.path, $0.severity) }
        }
        #expect(paths(.init(source: "Assets/a.mp4")).isEmpty)
        #expect(paths(.init(source: "https://youtu.be/dQw4w9WgXcQ", start: 30, end: 90)).isEmpty)
        #expect(paths(.init(source: "")).map(\.1) == [.error])
        #expect(paths(.init(source: "../a.mp4")).map(\.1) == [.error])
        #expect(paths(.init(source: "https://example.com/a")).map(\.1) == [.warning])
        #expect(paths(.init(source: "Assets/a.mp4", start: -1)).map(\.1) == [.error])
        #expect(paths(.init(source: "Assets/a.mp4", start: 20, end: 10)).map(\.1) == [.error])
        #expect(paths(.init(source: "Assets/a.mp4"), kind: .body).map(\.1) == [.warning])

        // A newer app's clip, with fields of the wrong kind and a way of
        // starting this app does not know, still opens.
        let json = #"{"id":"p","kind":"image","text":"","assetPath":"Assets/s.jpg","clip":{"source":"Assets/a.mp4","start":"soon","starts":"on-a-nod"}}"#
        let block = try JSONDecoder().decode(LampPresentationBlock.self, from: Data(json.utf8))
        #expect(block.clip?.source == "Assets/a.mp4")
        #expect(block.clip?.start == nil)
        #expect(block.clip?.starts == .click)
        #expect(block.assetPaths == ["Assets/s.jpg", "Assets/a.mp4"])
        // And says how it is read.
        #expect(block.clip?.unrecognisedStarts == "on-a-nod")
        let read = LampPresentationDeckValidator.validate(LampPresentationDeck(title: "D", slides: [.init(layout: .image, blocks: [block])]))
            .filter { $0.path.hasSuffix(".clip") }
        #expect(read.map(\.message) == ["Lamp starts a clip on click or on arrival; 'on-a-nod' is read as click."])
        #expect(read.map(\.severity) == [.warning])
        // A known way says nothing, and the order of a clip's times is said
        // as the rule it is.
        let known = try JSONDecoder().decode(LampPresentationClip.self, from: Data(#"{"source":"Assets/a.mp4","starts":"arrival"}"#.utf8))
        #expect(known.unrecognisedStarts == nil)
        #expect(paths(.init(source: "Assets/a.mp4", start: 20, end: 10)).count == 1)
        let backwards = LampPresentationDeckValidator.validate(
            LampPresentationDeck(title: "D", slides: [clipSlide(.init(source: "Assets/a.mp4", start: 20, end: 10))])
        ).filter { $0.path.hasSuffix(".clip") }.map(\.message)
        #expect(backwards == ["A clip's end must come after its start."])

        // Choosing how it starts answers the unknown way; and the unknown
        // way, never written back, does not make a saved clip differ from
        // itself read again.
        var chosen = try #require(block.clip)
        chosen.starts = .arrival
        #expect(chosen.unrecognisedStarts == nil)
        let saved = try #require(block.clip)
        let reread = try JSONDecoder().decode(LampPresentationClip.self, from: try JSONEncoder().encode(saved))
        #expect(reread.unrecognisedStarts == nil)
        #expect(reread == saved)
    }

    @Test func aSlidePlaysOneClipTheOneBehindItFirst() {
        let deck = LampPresentationDeck(title: "D", slides: [.init(layout: .titleAndBody, blocks: [
            .init(id: "t", kind: .title, text: "Watch"),
            .init(id: "f", kind: .image, assetPath: "Assets/f.jpg", altText: "F", clip: .init(source: "Assets/f.mp4")),
            .init(id: "g", kind: .image, assetPath: "Assets/g.jpg", altText: "G", placement: .background,
                  clip: .init(source: "Assets/g.mp4")),
        ])])
        #expect(deck.slides[0].playedClip?.id == "g")
        let warnings = LampPresentationDeckValidator.validate(deck).filter { $0.path.hasSuffix(".clip") }
        #expect(warnings.map(\.path) == ["slides[0].blocks[1].clip"])
    }
}
