import Foundation
import ImageIO
import LampCore
import SwiftUI

/// The land, lakes, rivers and shaded relief a map draws, from Natural Earth
/// (public domain), read once (`Scripts/build-map-data.py`).
enum LampMapShapes {
    /// Lines or outlines, each as runs of points in degrees, with the box
    /// around each so a map draws only the ones it shows.
    struct Layer: Sendable {
        var starts: [Int] = []
        var longitudes: [Float] = []
        var latitudes: [Float] = []
        var boxes: [(west: Float, east: Float, south: Float, north: Float)] = []

        var count: Int { boxes.count }

        func range(_ part: Int) -> Range<Int> {
            starts[part]..<(part + 1 < starts.count ? starts[part + 1] : longitudes.count)
        }
    }

    struct Set: Sendable {
        var land: Layer
        var lakes: Layer
        var rivers: Layer
    }

    static let detailed = Set(land: read("land-10m"), lakes: read("lakes-10m"), rivers: read("rivers-10m"))
    static let coarse = Set(land: read("land-50m"), lakes: read("lakes-50m"), rivers: read("rivers-50m"))

    /// Shaded relief over `LampMapFrame.whole`, light where the land is flat
    /// and darker on slopes facing away from the light.
    static let relief: CGImage? = {
        guard let url = LampResourceBundle.named("LampPresentationUI")?
                .url(forResource: "relief", withExtension: "jpg", subdirectory: "Maps"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    /// Reads the build script's encoding: a count of parts, then for each a
    /// count of points and each point as the change from the last, in
    /// thousandths of a degree, as zigzag varints.
    static func read(_ name: String) -> Layer {
        guard let url = LampResourceBundle.named("LampPresentationUI")?
                .url(forResource: name, withExtension: "bin", subdirectory: "Maps"),
              let data = try? Data(contentsOf: url)
        else { return Layer() }
        var layer = Layer()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            func varint() -> Int? {
                var value = 0
                var shift = 0
                while index < bytes.count {
                    let byte = Int(bytes[index])
                    index += 1
                    value |= (byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                    if shift > 56 { return nil }
                }
                return nil
            }
            func signed() -> Int? { varint().map { ($0 >> 1) ^ -($0 & 1) } }
            guard let parts = varint() else { return }
            layer.starts.reserveCapacity(parts)
            layer.boxes.reserveCapacity(parts)
            for _ in 0..<parts {
                guard let count = varint() else { return }
                layer.starts.append(layer.longitudes.count)
                var longitude = 0
                var latitude = 0
                var box = (west: Float.infinity, east: -Float.infinity, south: Float.infinity, north: -Float.infinity)
                for _ in 0..<count {
                    guard let dx = signed(), let dy = signed() else { return }
                    longitude += dx
                    latitude += dy
                    let lon = Float(longitude) / 1000
                    let lat = Float(latitude) / 1000
                    layer.longitudes.append(lon)
                    layer.latitudes.append(lat)
                    box = (min(box.west, lon), max(box.east, lon), min(box.south, lat), max(box.north, lat))
                }
                layer.boxes.append(box)
            }
        }
        return layer
    }

    /// `layer`'s parts that reach into `frame`, drawn `size` large, closed
    /// into outlines when `closed`.
    static func path(_ layer: Layer, in frame: LampMapFrame, size: CGSize, closed: Bool) -> Path {
        var path = Path()
        let west = Float(frame.west), east = Float(frame.east)
        let south = Float(frame.south), north = Float(frame.north)
        let scaleX = size.width / CGFloat(frame.east - frame.west)
        let scaleY = size.height / CGFloat(frame.north - frame.south)
        for part in 0..<layer.count {
            let box = layer.boxes[part]
            guard box.east >= west, box.west <= east, box.north >= south, box.south <= north else { continue }
            let range = layer.range(part)
            var first = true
            for index in range {
                let point = CGPoint(
                    x: CGFloat(layer.longitudes[index] - west) * scaleX,
                    y: CGFloat(north - layer.latitudes[index]) * scaleY
                )
                if first {
                    path.move(to: point)
                    first = false
                } else {
                    path.addLine(to: point)
                }
            }
            if closed { path.closeSubpath() }
        }
        return path
    }
}

/// A map figure: the land around the places a body block names, each place
/// marked and named where OpenBible.info places it, and, for a route, a line
/// joining them in order.
///
/// Drawn quietly, in the theme's colours: the land a step off the ground,
/// its relief shaded, lakes and rivers in the ground's colour, the places in
/// the accent. A site OpenBible.info is unsure of is an open ring, not a
/// dot. Places arrive one at a time where the slide reveals in parts, and a
/// route reaches each as it arrives.
struct LampSlideMap: View {
    var stops: [LampMapStop]
    var isShown: (Int) -> Bool
    var route: Bool
    /// The size the map's names are set at.
    var size: CGFloat
    var ground: Color
    var groundIsDark: Bool
    var ink: Color
    var accent: Color
    var height: CGFloat
    var font: (CGFloat, Font.Weight) -> Font
    /// The deck's typeface, to measure names by.
    var family: String?

    var body: some View {
        GeometryReader { geometry in
            drawn(geometry.size)
        }
        .frame(height: height)
    }

    private struct Mark: Identifiable {
        var id: Int
        var place: LampMapPlace
        var label: String
        var point: CGPoint
        var labelCentre: CGPoint
        /// Set further off than beside its mark, where the places crowd,
        /// and joined to it by a thin line.
        var leader = false
        var labelSize: CGSize = .zero
    }

    private func drawn(_ bounds: CGSize) -> some View {
        let located = stops.enumerated().compactMap { index, stop in stop.place.map { (index, stop, $0) } }
        let frame = LampMapFrame.fitting(located.map(\.2), ratio: Double(bounds.width / max(bounds.height, 1)))
        let marks = placed(located.map { index, stop, place in
            Mark(
                id: index, place: place, label: stop.label,
                point: frame.point(longitude: place.longitude, latitude: place.latitude, in: bounds),
                labelCentre: .zero
            )
        }, in: bounds)
        let radius = cornerRadius
        return ZStack(alignment: .topLeading) {
            land(frame: frame, size: bounds)
            if route, marks.count > 1 {
                ForEach(Array(marks.dropFirst().enumerated()), id: \.element.id) { offset, mark in
                    Path { path in
                        path.move(to: marks[offset].point)
                        path.addLine(to: mark.point)
                    }
                    .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: max(2, size * 0.09), lineCap: .round))
                    // A leg arrives with the place it reaches.
                    .opacity(isShown(mark.id) ? 1 : 0)
                }
            }
            ForEach(marks.filter(\.leader)) { mark in
                Path { path in
                    path.move(to: mark.point)
                    path.addLine(to: Self.nearest(in: CGRect(
                        x: mark.labelCentre.x - mark.labelSize.width / 2,
                        y: mark.labelCentre.y - mark.labelSize.height / 2,
                        width: mark.labelSize.width, height: mark.labelSize.height
                    ), to: mark.point))
                }
                .stroke(ink.opacity(0.45), lineWidth: max(1, size * 0.035))
                .opacity(isShown(mark.id) ? 1 : 0)
            }
            ForEach(marks) { mark in
                marker(mark.place)
                    .position(mark.point)
                    .opacity(isShown(mark.id) ? 1 : 0)
                name(mark)
                    .position(mark.labelCentre)
                    .opacity(isShown(mark.id) ? 1 : 0)
            }
            // CC BY asks for the source, the licence, and that the data was
            // changed, with the work wherever it goes: a slide exported as a
            // picture or a PDF leaves Lamp's notices behind.
            Text("Places: OpenBible.info, CC BY 4.0, adapted \u{00B7} Map: Natural Earth")
                .font(font(max(size * 0.34, 9), .regular))
                .foregroundStyle(ink.opacity(0.55))
                .padding(.horizontal, size * 0.3)
                .padding(.vertical, size * 0.15)
                .frame(width: bounds.width, height: bounds.height, alignment: .bottomTrailing)
        }
        .frame(width: bounds.width, height: bounds.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(ink.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        // The places drawn and arrived, and no line left off the map.
        .accessibilityLabel("Map: " + marks.filter { isShown($0.id) }.map(\.label).joined(separator: ", "))
    }

    private var cornerRadius: CGFloat { size * 0.35 }

    private func land(frame: LampMapFrame, size bounds: CGSize) -> some View {
        let shapes = frame.usesDetail ? LampMapShapes.detailed : LampMapShapes.coarse
        let land = LampMapShapes.path(shapes.land, in: frame, size: bounds, closed: true)
        let lakes = LampMapShapes.path(shapes.lakes, in: frame, size: bounds, closed: true)
        let rivers = LampMapShapes.path(shapes.rivers, in: frame, size: bounds, closed: false)
        let whole = LampMapFrame.whole
        let topLeft = frame.point(longitude: whole.west, latitude: whole.north, in: bounds)
        let bottomRight = frame.point(longitude: whole.east, latitude: whole.south, in: bounds)
        let reliefRect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        let dark = groundIsDark
        // The relief has 30 pixels a degree; drawn much larger than that it
        // turns to blocks, so it fades out as a map comes in close.
        let enlarged = bounds.height / CGFloat(frame.north - frame.south) / 30
        let reliefStrength = min(max((6 - Double(enlarged)) / 3, 0), 1)
        let ink = self.ink
        let ground = self.ground
        let line = max(1, size * 0.045)
        return Canvas { context, _ in
            context.fill(Path(CGRect(origin: .zero, size: bounds)), with: .color(ground))
            context.fill(land, with: .color(ink.opacity(dark ? 0.1 : 0.07)))
            if let relief = LampMapShapes.relief, reliefStrength > 0 {
                // Slopes shaded on the land alone: darkened on a light
                // ground, lightened on a dark one, where darkening a dark
                // land shows nothing.
                var shaded = context
                shaded.clip(to: land)
                if dark {
                    shaded.addFilter(.colorInvert())
                    shaded.blendMode = .screen
                    shaded.opacity = 0.5 * reliefStrength
                } else {
                    shaded.blendMode = .multiply
                    shaded.opacity = 0.55 * reliefStrength
                }
                shaded.draw(Image(decorative: relief, scale: 1).interpolation(.high), in: reliefRect)
            }
            context.fill(lakes, with: .color(ground))
            context.stroke(rivers, with: .color(ground), lineWidth: line)
        }
    }

    @ViewBuilder
    private func marker(_ place: LampMapPlace) -> some View {
        let dot = size * 0.36
        switch place.kind {
        case .point:
            if place.isUncertain {
                Circle().stroke(accent, lineWidth: max(1.5, size * 0.07)).frame(width: dot, height: dot)
            } else {
                Circle().fill(accent).frame(width: dot, height: dot)
            }
        case .mountain:
            Image(systemName: place.isUncertain ? "triangle" : "triangle.fill")
                .font(.system(size: dot * 0.9))
                .foregroundStyle(accent)
        case .region, .water:
            // An area has no mark of its own, but one placed uncertainly
            // is marked so, as an uncertain town is.
            if place.isUncertain {
                Circle().stroke(accent, lineWidth: max(1.5, size * 0.07)).frame(width: dot * 0.8, height: dot * 0.8)
            }
        }
    }

    /// Whether a place is drawn with a mark beside its name rather than its
    /// name over it.
    private func isMarked(_ place: LampMapPlace) -> Bool {
        place.kind == .point || place.kind == .mountain || place.isUncertain
    }

    private func name(_ mark: Mark) -> some View {
        // A soft edge in the ground's colour, so a name reads over relief,
        // a river or a route.
        styledName(mark)
            .shadow(color: ground.opacity(0.9), radius: size * 0.08)
            .shadow(color: ground.opacity(0.6), radius: size * 0.2)
    }

    @ViewBuilder
    private func styledName(_ mark: Mark) -> some View {
        switch mark.place.kind {
        case .region:
            Text(mark.label.uppercased())
                .font(font(size * 0.62, .semibold))
                .tracking(size * 0.12)
                .foregroundStyle(ink.opacity(0.72))
                .fixedSize()
        case .water:
            Text(mark.label)
                .font(font(size * 0.66, .regular).italic())
                .foregroundStyle(ink.opacity(0.72))
                .fixedSize()
        case .point, .mountain:
            Text(mark.label)
                .font(font(size * 0.74, .semibold))
                .foregroundStyle(ink)
                .fixedSize()
        }
    }

    /// The point of `rect` nearest `point`, where a leader line meets a name.
    private static func nearest(in rect: CGRect, to point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    /// Where each name goes: beside its mark to the right, else the left,
    /// above, below or a corner, whichever first keeps clear of the names
    /// and marks already placed and of the map's edge, or failing that
    /// overlaps them least. An area's unmarked name sits over its point.
    private func placed(_ marks: [Mark], in bounds: CGSize) -> [Mark] {
        let gap = size * 0.3
        let inset = CGRect(origin: .zero, size: bounds).insetBy(dx: size * 0.2, dy: size * 0.2)
        let markRects = marks.map { mark -> CGRect in
            let side = isMarked(mark.place) ? size * 0.4 : 0
            return CGRect(x: mark.point.x - side / 2, y: mark.point.y - side / 2, width: side, height: side)
        }
        var taken: [CGRect] = []
        return marks.enumerated().map { index, mark in
            var mark = mark
            let isArea = mark.place.kind == .region && !mark.place.isUncertain
            // Measured as drawn: an area's name in capitals, spaced out.
            let isRegion = mark.place.kind == .region
            let label = isRegion ? mark.label.uppercased() : mark.label
            let measured = LampPresentationTextMeasure.size(
                label, family: family, size: size * (isRegion ? 0.62 : 0.74), bold: true
            )
            let width = measured.width + (isRegion ? CGFloat(label.count) * size * 0.12 : 0) + size * 0.1
            let height = max(measured.height, size * 0.74 * 1.3)
            let p = mark.point
            let side = gap + width / 2
            let up = gap + height / 2
            var candidates: [CGPoint] = isArea || (mark.place.kind == .water && !mark.place.isUncertain)
                ? [p, CGPoint(x: p.x, y: p.y - height), CGPoint(x: p.x, y: p.y + height)]
                : []
            candidates += [
                CGPoint(x: p.x + side, y: p.y),
                CGPoint(x: p.x - side, y: p.y),
                CGPoint(x: p.x, y: p.y - up),
                CGPoint(x: p.x, y: p.y + up),
                CGPoint(x: p.x + side * 0.8, y: p.y - up * 0.8),
                CGPoint(x: p.x + side * 0.8, y: p.y + up * 0.8),
                CGPoint(x: p.x - side * 0.8, y: p.y - up * 0.8),
                CGPoint(x: p.x - side * 0.8, y: p.y + up * 0.8),
            ]
            func rect(_ centre: CGPoint) -> CGRect {
                CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
            }
            let others = markRects.enumerated().filter { $0.offset != index }.map(\.element)
            func overlap(_ centre: CGPoint) -> CGFloat {
                let box = rect(centre)
                let blocked = (taken + others).reduce(CGFloat(0)) { total, other in
                    let shared = box.intersection(other)
                    return total + (shared.isNull ? 0 : shared.width * shared.height)
                }
                let outside = box.width * box.height - {
                    let inside = box.intersection(inset)
                    return inside.isNull ? 0 : inside.width * inside.height
                }()
                return blocked + outside * 4
            }
            // Where none beside the mark is clear, further off, with a line
            // back to it.
            let far: [CGPoint] = [
                CGPoint(x: p.x + side * 2.2, y: p.y - up * 1.6),
                CGPoint(x: p.x - side * 2.2, y: p.y - up * 1.6),
                CGPoint(x: p.x + side * 2.2, y: p.y + up * 1.6),
                CGPoint(x: p.x - side * 2.2, y: p.y + up * 1.6),
                CGPoint(x: p.x, y: p.y - up * 2.6),
                CGPoint(x: p.x, y: p.y + up * 2.6),
                CGPoint(x: p.x + side * 3.2, y: p.y),
                CGPoint(x: p.x - side * 3.2, y: p.y),
            ]
            let chosen: CGPoint
            // Clear, to within rounding: an area worked out as a difference
            // of two others is rarely exactly zero.
            func clear(_ centre: CGPoint) -> Bool { overlap(centre) < 0.5 }
            if let near = candidates.first(where: clear) {
                chosen = near
            } else if let away = far.first(where: clear) {
                chosen = away
                mark.leader = true
            } else {
                // Crowded everywhere: whichever overlaps least, near or far,
                // with its line back to the mark if far.
                let best = (candidates + far).min { overlap($0) < overlap($1) } ?? p
                chosen = best
                mark.leader = far.contains(best) && !candidates.contains(best)
            }
            taken.append(rect(chosen))
            mark.labelCentre = chosen
            mark.labelSize = CGSize(width: width, height: height)
            return mark
        }
    }
}
