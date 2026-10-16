#if os(iOS)
import MapLibre
import UIKit
import simd

/// Matches a single sport POI to a single rectangular pitch. Ambiguity leaves the
/// original leisure fill intact. No dimensions or discipline are inferred from imagery.
@MainActor
final class MapSportSurfaceRenderer {
    private static let prefix = MapEnvironmentStyle.prefix + "sport-"
    private static let sourceID = prefix + "source"
    private var refreshedAt = Date.distantPast
    private var contentKey = ""
    private var refreshTask: Task<Void, Never>?

    func configure(in style: MLNStyle) {
        refreshTask?.cancel()
        refreshTask = nil
        refreshedAt = .distantPast
        contentKey = ""
        guard style.source(withIdentifier: Self.sourceID) == nil,
              let leisure = style.layers.first(where: {
                  ($0 as? MLNVectorStyleLayer)?.sourceIdentifier == MapTilerEnvironmentStyle.sourceID
                      && ($0 as? MLNVectorStyleLayer)?.sourceLayerIdentifier == "leisure"
              }) else { return }
        let source = MLNShapeSource(identifier: Self.sourceID, shape: nil, options: nil)
        style.addSource(source)
        let surface = MLNFillStyleLayer(identifier: Self.prefix + "surface", source: source)
        surface.minimumZoomLevel = 17.5
        surface.predicate = NSPredicate(format: "_part == %@", "surface")
        surface.fillColor = NSExpression(mglJSONObject: ["to-color", ["get", "_color"]])
        surface.fillAntialiased = NSExpression(forConstantValue: true)
        style.insertLayer(surface, above: leisure)
        let lines = MLNLineStyleLayer(identifier: Self.prefix + "markings", source: source)
        lines.minimumZoomLevel = 18
        lines.predicate = NSPredicate(format: "_part == %@", "markings")
        lines.lineJoin = NSExpression(forConstantValue: "round")
        lines.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 18, 0.7, 20, 1.3, 22, 2])
        style.insertLayer(lines, above: surface)
    }

    func refresh(on map: MLNMapView, settings: MapSettings, dark: Bool, enabled: Bool) {
        guard let style = map.style,
              let output = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource else { return }
        let visible = enabled && settings.baseMap != .satellite && map.zoomLevel >= 17.5
        let surface = style.layer(withIdentifier: Self.prefix + "surface") as? MLNFillStyleLayer
        let lines = style.layer(withIdentifier: Self.prefix + "markings") as? MLNLineStyleLayer
        surface?.isVisible = visible
        lines?.isVisible = visible
        guard visible else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        let quiet = settings.context.isNavigating ? 0.55 : 1.0
        surface?.fillOpacity = NSExpression(forConstantValue: 0.8 * quiet)
        lines?.lineColor = NSExpression(forConstantValue: UIColor(naviHex: dark ? 0xDFE7DD : 0xFCFCED))
        lines?.lineOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 18, 0, 18.5, quiet * 0.9])
        let elapsed = Date().timeIntervalSince(refreshedAt)
        if elapsed < 1 {
            refreshTask?.cancel()
            refreshTask = Task { [weak self, weak map] in
                do { try await Task.sleep(for: .seconds(1 - elapsed)) } catch { return }
                guard let self, let map else { return }
                self.refreshTask = nil
                self.refresh(on: map, settings: settings, dark: dark, enabled: enabled)
            }
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshedAt = .now
        guard let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource else { return }
        // Read the original sport points, including unnamed facilities, not collision-filtered symbols.
        let points = planet.features(sourceLayerIdentifiers: ["poi_sport"], predicate: nil)
            .compactMap { $0 as? MLNPointFeature }
        var pitches: [(polygon: MLNPolygon, frame: PitchFrame, key: String)] = []
        var seen = Set<String>()
        for feature in planet.features(sourceLayerIdentifiers: ["leisure"], predicate: NSPredicate(format: "class == %@", "pitch")) {
            let polygons: [MLNPolygon]
            if let polygon = feature as? MLNPolygon { polygons = [polygon] }
            else if let multi = feature as? MLNMultiPolygon { polygons = multi.polygons }
            else { continue }
            for polygon in polygons {
                guard let frame = PitchFrame(polygon: polygon) else { continue }
                let screen = (0..<Int(polygon.pointCount)).map { map.convert(polygon.coordinates[$0], toPointTo: map) }
                guard screen.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                let bounds = screen.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1))) }
                guard bounds.intersects(map.bounds.insetBy(dx: -80, dy: -80)) else { continue }
                let key = frame.identity
                guard seen.insert(key).inserted else { continue }
                pitches.append((polygon, frame, key))
                if pitches.count >= 250 { break }
            }
            if pitches.count >= 250 { break }
        }
        var shapes: [MLNShape] = []
        var keys: [String] = []
        for pitch in pitches {
            let contained = points.filter { pitch.frame.contains($0.coordinate) }
            // Tile buffers may repeat the same POI. Different points, including different
            // disciplines at the same location, must not classify the whole polygon.
            var unique: [String: MLNPointFeature] = [:]
            for point in contained {
                let sport = point.attributes["class"] as? String ?? ""
                let id = "\(point.identifier.map { String(describing: $0) } ?? ""):\(sport):\(point.coordinate.latitude):\(point.coordinate.longitude)"
                unique[id] = point
            }
            guard unique.count == 1, let point = unique.values.first,
                  pitches.filter({ $0.frame.contains(point.coordinate) }).count == 1,
                  let sport = MapSportKind.resolve(layer: "poi_sport", attributes: point.attributes),
                  !sport.markings.isEmpty,
                  sport.markings.allSatisfy({ marking in
                      zip(marking, marking.dropFirst()).allSatisfy { a, b in
                          (0...16).allSatisfy { step in
                              let t = CGFloat(step) / 16
                              return pitch.frame.contains(pitch.frame.coordinate(
                                  CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
                          }
                      }
                  }) else { continue }
            let color = String(format: "#%06X", sport.colorHex(dark: dark))
            let surface = MLNPolygonFeature(coordinates: pitch.polygon.coordinates, count: pitch.polygon.pointCount)
            surface.attributes = ["_part": "surface", "_color": color]
            shapes.append(surface)
            for marking in sport.markings {
                var coordinates = marking.map { pitch.frame.coordinate($0) }
                let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                line.attributes = ["_part": "markings"]
                shapes.append(line)
            }
            keys.append("\(pitch.key):\(sport.rawValue):\(dark)")
        }
        let key = keys.sorted().joined(separator: "|")
        guard key != contentKey else { return }
        contentKey = key
        output.shape = MLNShapeCollectionFeature(shapes: shapes)
    }

    private struct PitchFrame {
        let origin: CLLocationCoordinate2D
        let scale: Double
        let ring: [SIMD2<Double>]
        let axis: SIMD2<Double>
        let normal: SIMD2<Double>
        let low: SIMD2<Double>
        let high: SIMD2<Double>
        let identity: String

        init?(polygon: MLNPolygon) {
            guard polygon.interiorPolygons?.isEmpty != false,
                  polygon.pointCount >= 4, polygon.pointCount <= 32 else { return nil }
            let coordinates = (0..<Int(polygon.pointCount)).map { polygon.coordinates[$0] }
            guard coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else { return nil }
            let origin = coordinates[0]
            let scale = cos(origin.latitude * .pi / 180)
            guard scale > 0.1 else { return nil }
            let ring = coordinates.map {
                SIMD2(($0.longitude - origin.longitude) * 111_320 * scale, ($0.latitude - origin.latitude) * 111_320)
            }
            // Clipped tile fragments cannot establish the full dimensions of a court.
            for coordinate in coordinates {
                let x = (coordinate.longitude + 180) / 360 * 32_768
                let latitude = coordinate.latitude * .pi / 180
                let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * 32_768
                if abs(x - x.rounded()) < 0.0005 || abs(y - y.rounded()) < 0.0005 { return nil }
            }
            var best: (area: Double, axis: SIMD2<Double>, low: SIMD2<Double>, high: SIMD2<Double>)?
            for index in 1..<ring.count {
                let delta = ring[index] - ring[index - 1]
                guard simd_length(delta) > 1 else { continue }
                let axis = simd_normalize(delta)
                let normal = SIMD2(-axis.y, axis.x)
                let projected = ring.map { SIMD2(simd_dot($0, axis), simd_dot($0, normal)) }
                let low = projected.reduce(SIMD2(repeating: Double.infinity), simd_min)
                let high = projected.reduce(SIMD2(repeating: -Double.infinity), simd_max)
                let size = high - low
                let area = size.x * size.y
                if best == nil || area < best!.area { best = (area, axis, low, high) }
            }
            guard var best else { return nil }
            if best.high.x - best.low.x < best.high.y - best.low.y {
                let old = best
                best.axis = SIMD2(-old.axis.y, old.axis.x)
                best.low = SIMD2(old.low.y, -old.high.x)
                best.high = SIMD2(old.high.y, -old.low.x)
            }
            let size = best.high - best.low
            let area = abs(zip(ring, ring.dropFirst() + [ring[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
            guard size.x >= 10, size.x <= 130, size.y >= 5, size.y <= 90,
                  size.x / size.y <= 3, area / best.area >= 0.94 else { return nil }
            self.origin = origin
            self.scale = scale
            self.ring = ring
            self.axis = best.axis
            self.normal = SIMD2(-best.axis.y, best.axis.x)
            self.low = best.low
            self.high = best.high
            self.identity = coordinates.map { "\($0.latitude):\($0.longitude)" }.sorted().joined(separator: ";")
        }

        func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            let point = SIMD2((coordinate.longitude - origin.longitude) * 111_320 * scale,
                              (coordinate.latitude - origin.latitude) * 111_320)
            var inside = false
            for index in ring.indices {
                let a = ring[index], b = ring[(index + 1) % ring.count]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        }

        func coordinate(_ point: CGPoint) -> CLLocationCoordinate2D {
            let local = low + SIMD2(Double(point.x), Double(point.y)) * (high - low)
            let meters = axis * local.x + normal * local.y
            return CLLocationCoordinate2D(latitude: origin.latitude + meters.y / 111_320,
                                          longitude: origin.longitude + meters.x / (111_320 * scale))
        }
    }
}
#endif
