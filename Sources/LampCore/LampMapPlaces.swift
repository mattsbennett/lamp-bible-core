import Foundation

/// A place the Bible names, where OpenBible.info's Bible Geocoding Data
/// places it (CC BY 4.0), as Lamp ships it (`Scripts/build-map-data.py`).
///
/// Its location is OpenBible's likeliest identification, with how sure that
/// is. Many sites are disputed, so a map shows an uncertain one as uncertain
/// rather than as settled.
public struct LampMapPlace: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        /// A town, a spring, a well, an island: a point with its name.
        case point
        /// A land, a people's country, a valley: a name over an area.
        case region
        /// A river, a wadi, a sea.
        case water
        /// A mountain, a range, a hill.
        case mountain
    }

    public var id: String
    /// OpenBible's name for it, numbered where two places share a name
    /// ("Antioch 1", "Antioch 2").
    public var name: String
    /// Other names English Bibles use for it ("Laish" for Dan).
    public var otherNames: [String]
    public var longitude: Double
    public var latitude: Double
    /// OpenBible's confidence in the site, 0 to 1000: the identification's
    /// share of scholarly support times how surely it resolves to this spot.
    public var confidence: Int
    public var kind: Kind
    /// The first verse that names it, to tell two places of one name apart.
    public var firstVerse: String

    /// Below this, the site is drawn as uncertain and the deck validator
    /// says so.
    public static let settledConfidence = 500

    public var isUncertain: Bool { confidence < Self.settledConfidence }

    /// Its name as a map prints it: without the number that tells two places
    /// of one name apart.
    public var label: String {
        guard let space = name.lastIndex(of: " "),
              name[name.index(after: space)...].allSatisfy(\.isNumber),
              name.index(after: space) < name.endIndex
        else { return name }
        return String(name[..<space])
    }
}

/// The places a map can name, read once from the data Lamp ships.
public enum LampMapPlaces {
    /// Where the places are, for a tool that checks a copy of them.
    public static var resourceURL: URL? {
        LampResourceBundle.named("LampCore")?.url(forResource: "places", withExtension: "json", subdirectory: "Maps")
    }

    public static let all: [LampMapPlace] = {
        guard let url = resourceURL,
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return document.places.compactMap(\.place)
    }()

    private static let byName: [String: [LampMapPlace]] = {
        var names: [String: [LampMapPlace]] = [:]
        for place in all {
            names[key(place.name), default: []].append(place)
        }
        return names
    }()

    private static let byOtherName: [String: [LampMapPlace]] = {
        var names: [String: [LampMapPlace]] = [:]
        for place in all {
            for other in place.otherNames {
                names[key(other), default: []].append(place)
            }
        }
        return names
    }()

    /// What a name on a map line finds.
    public enum Match: Equatable, Sendable {
        case place(LampMapPlace)
        /// More than one place goes by it; OpenBible numbers them, and the
        /// line should name one ("Antioch 1").
        case ambiguous([LampMapPlace])
        case unknown

        /// The place found, if one was.
        public var place: LampMapPlace? {
            if case .place(let place) = self { return place }
            return nil
        }
    }

    /// The place `name` names: OpenBible's own name for it, ignoring case;
    /// else the one place that goes by it, counting both OpenBible's numbered
    /// places of that name ("Antioch" for "Antioch 1" and "Antioch 2") and
    /// the names English Bibles use ("Kadesh" for Kadesh-barnea too). A name
    /// more than one place goes by finds none of them, since a map that
    /// guessed would put a place in the wrong country.
    public static func match(_ name: String) -> Match {
        let name = key(name)
        if let places = byName[name], places.count == 1 { return .place(places[0]) }
        var candidates: [String: LampMapPlace] = [:]
        for place in all where key(place.label) == name && place.label != place.name {
            candidates[place.id] = place
        }
        for place in byOtherName[name] ?? [] {
            candidates[place.id] = place
        }
        let found = candidates.values.sorted { $0.name < $1.name }
        switch found.count {
        case 0: return .unknown
        case 1: return .place(found[0])
        default: return .ambiguous(found)
        }
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private struct Document: Decodable {
        var places: [Row]
    }

    /// One place as the data stores it: an array, to keep the file small.
    private struct Row: Decodable {
        var place: LampMapPlace?

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            let id = try row.decode(String.self)
            let name = try row.decode(String.self)
            let others = try row.decode([String].self)
            let longitude = try row.decode(Double.self)
            let latitude = try row.decode(Double.self)
            let confidence = try row.decode(Int.self)
            let kind = try row.decode(String.self)
            let verse = try row.decode(String.self)
            place = LampMapPlace.Kind(rawValue: kind).map {
                LampMapPlace(
                    id: id, name: name, otherNames: others,
                    longitude: longitude, latitude: latitude,
                    confidence: confidence, kind: $0, firstVerse: verse
                )
            }
        }
    }
}
