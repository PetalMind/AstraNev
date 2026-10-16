#if os(iOS)
import Foundation
import MapLibre
import UIKit

/// Painted map-aligned stripes at the provider's crossing geometry.
/// Their dimensions are cartographic, as in the Planet v4 Streets style.
@MainActor
enum MapCrosswalkAppearance {
    static func image(dark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 36, height: 16), format: format).image { renderer in
            let context = renderer.cgContext
            // Match the road paint, with transparent gaps exposing the actual asphalt.
            context.setFillColor(UIColor(naviHex: dark ? 0xB8C6CB : 0xFFFFFF).cgColor)
            for column in 0..<8 {
                context.fill(CGRect(x: 3 + CGFloat(column) * 4, y: 2, width: 2, height: 12))
            }
        }
    }

    static func configure(_ layer: MLNSymbolStyleLayer) {
        layer.minimumZoomLevel = 17
        layer.iconAnchor = NSExpression(forConstantValue: "center")
        // Only normalized points with an established orientation reach this layer.
        layer.iconRotation = NSExpression(forKeyPath: "_crosswalkRotation")
        layer.iconRotationAlignment = NSExpression(forConstantValue: "map")
        layer.iconPitchAlignment = NSExpression(forConstantValue: "map")
        // Road paint must neither disappear in label collisions nor displace labels.
        layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
        layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
    }

    static func apply(to layer: MLNSymbolStyleLayer) {
        // Fade in from street-level zoom, then grow with the road surface.
        layer.iconScale = NSExpression(mglJSONObject: [
            "interpolate", ["exponential", 2], ["zoom"],
            17, 0.22, 18, 0.55, 20, 1.5, 22, 3.5
        ])
        layer.iconOpacity = NSExpression(mglJSONObject: [
            "interpolate", ["linear"], ["zoom"], 17, 0, 17.5, 0.65, 18, 0.92
        ])
        layer.isVisible = true
    }
}

/// Resolves the stripe axis in geographic coordinates, independent of the camera.
/// Planet's `direction` describes a label angle, not a compass bearing. Where a
/// road is unambiguous, reconcile its axis with our vertical-stripe artwork.
@MainActor
final class MapCrosswalkRenderer {
    static let sourceID = MapEnvironmentStyle.prefix + "planet-crosswalk-source"
    private weak var outputSource: MLNShapeSource?
    private var signature: Int?
    private var refreshedAt = Date.distantPast
    private var refreshTask: Task<Void, Never>?

    private struct Segment {
        let start: SIMD2<Double>
        let end: SIMD2<Double>
        let rotation: Double
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
        init(_ point: SIMD2<Double>) {
            x = Int(floor(point.x / 24))
            y = Int(floor(point.y / 24))
        }
    }

    func refresh(on map: MLNMapView, enabled: Bool) {
        guard enabled, map.zoomLevel >= 17,
              let style = map.style,
              let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource,
              let output = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        if outputSource !== output {
            outputSource = output
            signature = nil
            refreshedAt = .distantPast
        }
        // Coalesce tile/frame updates and retain a trailing refresh after rendering stops.
        let elapsed = Date().timeIntervalSince(refreshedAt)
        if elapsed < 0.75 {
            if refreshTask == nil {
                refreshTask = Task { [weak self, weak map] in
                    do { try await Task.sleep(for: .seconds(0.75 - elapsed)) } catch { return }
                    guard let self, let map else { return }
                    self.refreshTask = nil
                    self.refresh(on: map, enabled: enabled)
                }
            }
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshedAt = .now

        let origin = map.centerCoordinate
        let longitudeScale = 111_320 * cos(origin.latitude * .pi / 180)
        func local(_ coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
            var longitude = coordinate.longitude - origin.longitude
            longitude -= (longitude / 360).rounded() * 360
            return SIMD2(longitude * longitudeScale, (coordinate.latitude - origin.latitude) * 111_320)
        }
        let viewport = map.bounds.insetBy(dx: -48, dy: -48)
        let crossings = planet.features(sourceLayerIdentifiers: ["street_furniture"],
            predicate: NSPredicate(format: "class == %@ AND subclass == %@", "street", "crossing"))
            .compactMap { $0 as? MLNPointFeature }.filter {
                guard CLLocationCoordinate2DIsValid($0.coordinate) else { return false }
                let screen = map.convert($0.coordinate, toPointTo: map)
                return screen.x.isFinite && screen.y.isFinite && viewport.contains(screen)
            }
        var points: [MLNPointFeature] = []
        var seen = Set<String>()
        var grid: [Cell: [Segment]] = [:]
        if !crossings.isEmpty {
            // Use the same native z15 tiles as the crossing points. Exclude other
            // levels and paths: a bridge, tunnel or sidewalk must not rotate road paint.
            let roads = planet.features(sourceLayerIdentifiers: ["road"], predicate: NSPredicate(
                format: "construction != true AND (brunnel == nil OR brunnel == %@) AND (layer == nil OR layer == 0)", "ford"))
            let occupied = Set(crossings.map { Cell(local($0.coordinate)) })
            var nearby = Set<Cell>()
            for cell in occupied {
                for x in -1...1 {
                    for y in -1...1 {
                        nearby.insert(Cell(SIMD2(Double(cell.x + x) * 24 + 12, Double(cell.y + y) * 24 + 12)))
                    }
                }
            }
            for feature in roads {
                let lines: [MLNPolyline]
                if let line = feature as? MLNPolyline { lines = [line] }
                else if let multi = feature as? MLNMultiPolyline { lines = multi.polylines }
                else { continue }
                for line in lines where line.pointCount >= 2 {
                    for index in 1..<Int(line.pointCount) {
                        let first = line.coordinates[index - 1]
                        let second = line.coordinates[index]
                        guard CLLocationCoordinate2DIsValid(first), CLLocationCoordinate2DIsValid(second) else { continue }
                        let start = local(first), end = local(second), delta = end - start
                        guard delta.x * delta.x + delta.y * delta.y >= 0.25 else { continue }
                        let segment = Segment(start: start, end: end,
                            rotation: Self.axis(atan2(delta.x, delta.y) * 180 / .pi))
                        let lower = Cell(SIMD2(min(start.x, end.x) - 4, min(start.y, end.y) - 4))
                        let upper = Cell(SIMD2(max(start.x, end.x) + 4, max(start.y, end.y) + 4))
                        for cell in nearby where cell.x >= lower.x && cell.x <= upper.x
                            && cell.y >= lower.y && cell.y <= upper.y {
                            grid[cell, default: []].append(segment)
                        }
                    }
                }
            }
        }
        for crossing in crossings {
            let coordinate = crossing.coordinate
            // The tileset has no unique crossing IDs; adjacent tiles can repeat a point.
            let identity = "\(Int((coordinate.latitude * 1_000_000).rounded())):\(Int((coordinate.longitude * 1_000_000).rounded()))"
            guard seen.insert(identity).inserted else { continue }
            let point = local(coordinate)
            let roadRotation = Self.roadRotation(at: point, segments: grid[Cell(point)] ?? [])
            let direction = (crossing.attributes["direction"] as? NSNumber)?.doubleValue
                ?? (crossing.attributes["direction"] as? String).flatMap(Double.init)
            let supplied = direction.flatMap { $0.isFinite && (-90...90).contains($0) ? Self.axis($0) : nil }
            let rotation: Double
            if let supplied {
                // Retain oblique crossings. Correct only the perpendicular axis
                // convention between the provider's label and our stripe image.
                let perpendicular = Self.axis(supplied + 90)
                if let roadRotation,
                   Self.difference(perpendicular, roadRotation) + 5 < Self.difference(supplied, roadRotation) {
                    rotation = perpendicular
                } else { rotation = supplied }
            } else if let roadRotation {
                rotation = roadRotation
            } else {
                // A missing angle at a junction cannot be replaced with a fixed north-up zebra.
                continue
            }
            let resolved = MLNPointFeature()
            resolved.coordinate = coordinate
            resolved.attributes = ["_crosswalkRotation": rotation]
            points.append(resolved)
        }
        points.sort {
            if $0.coordinate.latitude != $1.coordinate.latitude { return $0.coordinate.latitude < $1.coordinate.latitude }
            return $0.coordinate.longitude < $1.coordinate.longitude
        }
        var hasher = Hasher()
        for point in points {
            hasher.combine(point.coordinate.latitude)
            hasher.combine(point.coordinate.longitude)
            hasher.combine((point.attributes["_crosswalkRotation"] as? NSNumber)?.doubleValue)
        }
        let updated = hasher.finalize()
        guard signature != updated else { return }
        signature = updated
        output.shape = MLNShapeCollectionFeature(shapes: points)
    }

    private static func axis(_ degrees: Double) -> Double {
        (degrees.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180)
    }

    private static func difference(_ first: Double, _ second: Double) -> Double {
        let delta = abs(first - second)
        return min(delta, 180 - delta)
    }

    private static func roadRotation(at point: SIMD2<Double>, segments: [Segment]) -> Double? {
        var candidates: [(distance: Double, rotation: Double)] = []
        for segment in segments {
            let delta = segment.end - segment.start
            let offset = point - segment.start
            let lengthSquared = delta.x * delta.x + delta.y * delta.y
            let fraction = min(1, max(0, (offset.x * delta.x + offset.y * delta.y) / lengthSquared))
            let distance = point - (segment.start + delta * fraction)
            let meters = hypot(distance.x, distance.y)
            if meters <= 4 { candidates.append((meters, segment.rotation)) }
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }),
              !candidates.contains(where: {
                  $0.distance <= best.distance + 1 && difference($0.rotation, best.rotation) > 20
              }) else { return nil }
        return best.rotation
    }
}
#endif
