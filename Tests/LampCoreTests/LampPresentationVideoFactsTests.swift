import Foundation
import Testing
@testable import LampCore

/// A deck's validator reads a named video's size and codec from its boxes,
/// and warns, pointing to `prepare_video`, where it is over a deck's limit
/// or in a codec not every iPhone and iPad plays.
struct LampPresentationVideoFactsTests {
    /// A box: size, type, body.
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + body.count)
        return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + body
    }

    /// A movie whose tracks are `handler`/`codec` pairs, with `padding`
    /// bytes of media after its boxes. `largeHeader` writes moov's size in
    /// the 64-bit form.
    /// A sample entry: its code, then for H.264 a visual entry's 78 bytes of
    /// fields and an `avcC` naming `profile`.
    static func entry(_ code: String, profile: UInt8? = nil) -> [UInt8] {
        let body: [UInt8] = profile.map { [UInt8](repeating: 0, count: 78) + box("avcC", [1, $0, 0, 30]) }
            ?? [UInt8](repeating: 0, count: 8)
        return withUnsafeBytes(of: UInt32(8 + body.count).bigEndian, Array.init) + Array(code.utf8) + body
    }

    static func movie(
        _ tracks: [(handler: String, codec: String)], padding: Int = 0, moovLast: Bool = false,
        largeHeader: Bool = false, disabled: Set<Int> = [], entries: [[UInt8]]? = nil
    ) -> Data {
        let traks = tracks.enumerated().flatMap { index, track -> [UInt8] in
            let handler = box("hdlr", [0, 0, 0, 0] + [0, 0, 0, 0] + Array(track.handler.utf8) + [UInt8](repeating: 0, count: 12) + [0])
            let listed = entries ?? [entry(track.codec)]
            let stsd = box("stsd", [0, 0, 0, 0] + withUnsafeBytes(of: UInt32(listed.count).bigEndian, Array.init) + listed.flatMap { $0 })
            let flags: [UInt8] = [0, 0, 0, disabled.contains(index) ? 0 : 1]
            return box("trak", box("tkhd", flags + [UInt8](repeating: 0, count: 80)) + box("mdia", box("mdhd", [UInt8](repeating: 0, count: 24)) + handler + box("minf", box("stbl", stsd))))
        }
        var moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 100)) + traks)
        if largeHeader {
            let body = Array(moov.dropFirst(8))
            moov = withUnsafeBytes(of: UInt32(1).bigEndian, Array.init) + Array("moov".utf8)
                + withUnsafeBytes(of: UInt64(16 + body.count).bigEndian, Array.init) + body
        }
        let ftyp = box("ftyp", Array("isom".utf8) + [0, 0, 2, 0] + Array("isomiso2".utf8))
        let mdat = box("mdat", [UInt8](repeating: 7, count: padding))
        return Data(ftyp + (moovLast ? mdat + moov : moov + mdat))
    }

    /// Where a box's type is in `bytes`: four after its size.
    static func index(of type: String, in bytes: [UInt8]) -> Int? {
        let pattern = Array(type.utf8)
        return (0...(bytes.count - 4)).first { Array(bytes[$0..<($0 + 4)]) == pattern }
    }

    private func facts(_ data: Data) throws -> LampPresentationVideoFacts? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facts-\(UUID().uuidString).mp4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return LampPresentationVideoFacts.read(at: url)
    }

    @Test func theFirstVideoTracksCodecIsReadWhereverTheMovieBoxIs() throws {
        let plain = Self.movie([("soun", "mp4a"), ("vide", "hvc1")], padding: 1000)
        #expect(try facts(plain) == LampPresentationVideoFacts(byteCount: Int64(plain.count), videoCodec: "hvc1"))
        #expect(try facts(Self.movie([("vide", "av01")], padding: 5000, moovLast: true))?.videoCodec == "av01")
        #expect(try facts(Self.movie([("vide", "apcn")], largeHeader: true))?.videoCodec == "apcn")
        // No video track, or no movie at all: nothing to say of its codec.
        #expect(try facts(Self.movie([("soun", "mp4a")]))?.videoCodec == nil)
        let text = Data("not a movie".utf8)
        #expect(try facts(text) == LampPresentationVideoFacts(byteCount: Int64(text.count), videoCodec: nil))
        // A box claiming more than the file holds stops the walk, not the app.
        var broken = [UInt8](Self.movie([("vide", "avc1")]))
        broken.replaceSubrange(0..<4, with: [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(try facts(Data(broken))?.videoCodec == nil)
        // Nor does a 64-bit size that would overflow an offset.
        var huge = [UInt8](Self.movie([("vide", "avc1")], largeHeader: true))
        let moov = try #require(Self.index(of: "moov", in: huge))
        huge.replaceSubrange((moov + 4)..<(moov + 12), with: [UInt8](repeating: 0xFF, count: 8))
        #expect(try facts(Data(huge))?.videoCodec == nil)
        // A track switched off is not what plays.
        #expect(try facts(Self.movie([("vide", "avc1"), ("vide", "apcn")], disabled: [0]))?.videoCodec == "apcn")
        #expect(try facts(Self.movie([("vide", "apcn"), ("vide", "avc1")], disabled: [0]))?.videoCodec == "avc1")
        // A sample description with no entries says no codec, rather than
        // reading the next box as one.
        var empty = [UInt8](Self.movie([("vide", "avc1")]))
        let stsd = try #require(Self.index(of: "stsd", in: empty))
        empty.replaceSubrange((stsd + 8)..<(stsd + 12), with: [0, 0, 0, 0])
        #expect(try facts(Data(empty))?.videoCodec == nil)
        #expect(LampPresentationVideo.codecName("vp08") == "VP8")
        // Of a track's entries, the one not every device plays, wherever it is.
        #expect(try facts(Self.movie([("vide", "")], entries: [Self.entry("avc1"), Self.entry("av01")]))?.videoCodec == "av01")
        #expect(try facts(Self.movie([("vide", "")], entries: [Self.entry("hvc1"), Self.entry("avc1")]))?.videoCodec == "hvc1")
        // H.264 by its profile: High plays everywhere, High 10 does not.
        #expect(try facts(Self.movie([("vide", "")], entries: [Self.entry("avc1", profile: 100)]))?.videoCodec == "avc1")
        #expect(try facts(Self.movie([("vide", "")], entries: [Self.entry("avc1", profile: 110)]))?.videoCodec == "avc1:110")
        #expect(LampPresentationVideo.codecName("avc1:110") == "H.264 High 10")
        // An entry claiming more than its box holds is no codec.
        var long = Self.entry("av01")
        long.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(400).bigEndian, Array.init))
        #expect(try facts(Self.movie([("vide", "")], entries: [long]))?.videoCodec == nil)
        #expect(LampPresentationVideo.codecName("vp09") == "VP9")
    }

    private func deck(video: String?, clip: String?) throws -> LampPresentationDeck {
        let json = """
        {"schemaVersion":1,"id":"60910124-99b3-48ca-9310-11c63ed118c0","title":"D","aspectRatio":"widescreen",
         "theme":{"id":"lamp-dark","accentColor":"#F59E0B","backgroundColor":"#111827","foregroundColor":"#F9FAFB","typeface":"system-serif"},
         "slides":[{"id":"3b184129-31c5-48c8-962e-fe79e2862cc8","layout":"image","isHidden":false,"speakerNotes":"",
           "blocks":[{"id":"3921b8a7-335a-4424-945b-bcb9d949bd64","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A"
             \(video.map { #","video":"\#($0)""# } ?? "")\(clip.map { #","clip":{"source":"\#($0)","starts":"click"}"# } ?? "")}]}]}
        """
        return try LampPresentationDeckStore.decodeUnvalidated(Data(json.utf8))
    }

    @Test func aVideoOverItsLimitOrInACodecNotEveryDevicePlaysIsWarnedOf() throws {
        let both = try deck(video: "Assets/loop.mp4", clip: "Assets/clip.mov")
        let facts: [String: LampPresentationVideoFacts] = [
            "Assets/loop.mp4": .init(byteCount: 120_000_000, videoCodec: "avc1"),
            "Assets/clip.mov": .init(byteCount: 200_000_000, videoCodec: "apcn"),
        ]
        let issues = LampPresentationDeckValidator.validate(both, assetExists: { _ in true }, videoFacts: { facts[$0] })
        let advice = issues.filter { $0.message.contains("prepare_video") }
        let video = advice.filter { $0.path == "slides[0].blocks[0].video" }.map(\.message)
        let clip = advice.filter { $0.path == "slides[0].blocks[0].clip" }.map(\.message)
        #expect(video == ["'Assets/loop.mp4' is 120 MB, over the 100 MB a deck carries for a moving background. Bring it in with prepare_video, which makes it smaller; if it is still over, shorten it."])
        // 200 MB is within a clip's 250; ProRes is not for every device.
        #expect(clip == ["'Assets/clip.mov' is ProRes video, which an iPhone or iPad may not play. Bring it in with prepare_video, which saves it as HEVC."])
        #expect(issues.filter { $0.message.contains("prepare_video") }.allSatisfy { $0.severity == .warning })

        // Within limits and HEVC, nothing; unknown, nothing; missing, only
        // that it is missing.
        let fine = LampPresentationDeckValidator.validate(
            both, assetExists: { _ in true },
            videoFacts: { _ in .init(byteCount: 1_000, videoCodec: "hvc1") }
        )
        #expect(!fine.contains { $0.message.contains("prepare_video") })
        #expect(!LampPresentationDeckValidator.validate(both, assetExists: { _ in true }, videoFacts: { _ in nil })
            .contains { $0.message.contains("prepare_video") })
        let missing = LampPresentationDeckValidator.validate(
            both, assetExists: { $0 == "Assets/a.jpg" }, videoFacts: { facts[$0] }
        )
        #expect(!missing.contains { $0.message.contains("prepare_video") })
        // A clip over its own, larger limit.
        let bigClip = LampPresentationDeckValidator.validate(
            try deck(video: nil, clip: "Assets/clip.mp4"), assetExists: { _ in true },
            videoFacts: { _ in .init(byteCount: 250_000_001, videoCodec: "hvc1") }
        )
        #expect(bigClip.map(\.message).contains { $0.hasPrefix("'Assets/clip.mp4' is 251 MB, over the 250 MB a deck carries for a clip.") })
    }
}
