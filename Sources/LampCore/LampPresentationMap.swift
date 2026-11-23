import CoreGraphics
import Foundation

/// How a map figure is drawn, beyond the places it names.
///
/// `route` joins the places in the order written, for a journey: Paul's,
/// the Exodus, the exile. Absent, they stand on their own.
public struct LampPresentationMapOptions: Codable, Equatable, Sendable {
    public var route: Bool?

    public init(route: Bool? = nil) {
        self.route = route
    }

    private enum CodingKeys: String, CodingKey {
        case route
    }

    /// Never fails: options written by a newer app, or written wrongly, are
    /// left out rather than stopping the deck opening.
    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        route = try? container?.decodeIfPresent(Bool.self, forKey: .route)
    }
}

/// One line of a map figure: the place it names and what the map calls it.
public struct LampMapStop: Equatable, Sendable {
    /// The name as written, before any dash.
    public var name: String
    /// What the map prints: the words after a dash, else the place's own
    /// name without OpenBible's number ("Antioch" for "Antioch 2").
    public var label: String
    public var match: LampMapPlaces.Match

    public var place: LampMapPlace? { match.place }
}

extension LampPresentationBlock {
    /// This map's lines, each matched to the place it names.
    public var mapStops: [LampMapStop] {
        listItemRuns.map { runs in
            let line = runs.map(\.text).joined()
            let characters = Array(line)
            var name = line
            var written: String?
            if let split = LampPresentationFigure.timelineSplit(line) {
                name = String(characters[..<split.dateEnd])
                written = String(characters[split.eventStart...])
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let match = LampMapPlaces.match(name)
            let label = written?.trimmingCharacters(in: .whitespacesAndNewlines)
            let place = match.place
            return LampMapStop(
                name: name,
                label: label.flatMap { $0.isEmpty ? nil : $0 } ?? place?.label ?? name,
                match: match
            )
        }
    }

    /// Whether this map joins its places in order.
    public var drawsRoute: Bool { drawnFigure == .map && map?.route == true }
}

/// The part of the earth a map shows, in degrees, and how it is drawn flat.
///
/// Longitude is drawn narrower than latitude by the cosine of the middle
/// latitude, as a map of a region is, so Italy keeps its shape; across the
/// small areas a slide shows, nothing more is needed.
public struct LampMapFrame: Equatable, Sendable {
    public var west: Double
    public var east: Double
    public var south: Double
    public var north: Double

    public init(west: Double, east: Double, south: Double, north: Double) {
        self.west = west
        self.east = east
        self.south = south
        self.north = north
    }

    /// Everything Lamp has the land for: Europe and Russia to the Pacific,
    /// North Africa, the Near East, Persia and Arabia.
    public static let whole = LampMapFrame(west: -25, east: 180, south: 10, north: 75)

    /// The fewest degrees of latitude a map shows: about Galilee. Closer
    /// than this the coastlines Lamp has are too coarse to draw.
    public static let closest = 1.0

    /// Whether two places are nearer than a map at its closest can draw
    /// apart: within about a sixtieth of `closest`, some two kilometres.
    public static func tooCloseToTellApart(_ a: LampMapPlace, _ b: LampMapPlace) -> Bool {
        let squeeze = cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let across = (a.longitude - b.longitude) * squeeze
        let upDown = a.latitude - b.latitude
        return (across * across + upDown * upDown).squareRoot() < closest / 60
    }

    /// Wider than this, the coarser land is detailed enough and much
    /// lighter to draw.
    public static let detailedUpTo = 35.0

    private var squeeze: Double { cos((south + north) / 2 * .pi / 180) }

    /// Width over height, as drawn.
    public var ratio: Double { (east - west) * squeeze / max(north - south, 0.000_1) }

    public var usesDetail: Bool { east - west <= Self.detailedUpTo }

    /// Where a longitude and latitude fall in a map drawn `size` large.
    public func point(longitude: Double, latitude: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (longitude - west) / (east - west) * size.width,
            y: (north - latitude) / (north - south) * size.height
        )
    }

    /// A frame showing every one of `places`, with room around them for
    /// their names, at `ratio` (width over height), held inside `whole`.
    public static func fitting(_ places: [LampMapPlace], ratio: Double) -> LampMapFrame {
        guard let first = places.first else { return .whole.fitted(to: ratio) }
        var frame = LampMapFrame(west: first.longitude, east: first.longitude, south: first.latitude, north: first.latitude)
        for place in places.dropFirst() {
            frame.west = min(frame.west, place.longitude)
            frame.east = max(frame.east, place.longitude)
            frame.south = min(frame.south, place.latitude)
            frame.north = max(frame.north, place.latitude)
        }
        // Room for names around the places, more across than up and down
        // since names run across.
        let height = max(frame.north - frame.south, closest * 0.6)
        let width = max((frame.east - frame.west) * frame.squeeze, closest * 0.6)
        let across = (width * 0.22 + 0.15) / frame.squeeze
        let upDown = height * 0.18 + 0.1
        frame.west -= across
        frame.east += across
        frame.south -= upDown
        frame.north += upDown
        if frame.north - frame.south < closest {
            let middle = (frame.north + frame.south) / 2
            frame.south = middle - closest / 2
            frame.north = middle + closest / 2
        }
        return frame.fitted(to: ratio)
    }

    /// This frame widened or heightened about its middle to `ratio`, then
    /// moved, and if need be shrunk, to lie inside `whole`.
    func fitted(to ratio: Double) -> LampMapFrame {
        guard ratio > 0, ratio.isFinite else { return self }
        var frame = self
        if frame.ratio < ratio {
            let width = (frame.north - frame.south) * ratio / frame.squeeze
            let middle = (frame.west + frame.east) / 2
            frame.west = middle - width / 2
            frame.east = middle + width / 2
        } else {
            let height = (frame.east - frame.west) * frame.squeeze / ratio
            let middle = (frame.south + frame.north) / 2
            frame.south = middle - height / 2
            frame.north = middle + height / 2
        }
        return frame.held(in: .whole, ratio: ratio)
    }

    /// This frame moved to lie inside `bounds` along each side it fits.
    /// Along a side it is longer than, it stays where it is: every place
    /// asked for stays on the map, with sea or empty ground beyond Lamp's
    /// land, rather than the frame being cut down and a place falling off.
    private func held(in bounds: LampMapFrame, ratio: Double) -> LampMapFrame {
        var frame = self
        if frame.east - frame.west <= bounds.east - bounds.west {
            if frame.west < bounds.west { frame.east += bounds.west - frame.west; frame.west = bounds.west }
            if frame.east > bounds.east { frame.west -= frame.east - bounds.east; frame.east = bounds.east }
        }
        if frame.north - frame.south <= bounds.north - bounds.south {
            if frame.south < bounds.south { frame.north += bounds.south - frame.south; frame.south = bounds.south }
            if frame.north > bounds.north { frame.south -= frame.north - bounds.north; frame.north = bounds.north }
        }
        return frame
    }
}
