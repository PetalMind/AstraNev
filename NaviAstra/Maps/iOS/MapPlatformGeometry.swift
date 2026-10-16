#if os(iOS)
import MapLibre

@MainActor
enum MapPlatformGeometry {
    static func build(from source: MLNVectorTileSource?, on map: MLNMapView, settings: MapSettings) -> MapLinearObjectGeometry.Output {
        guard settings.overlays.poi, settings.visiblePOICategories.contains(.transit), map.zoomLevel >= 18,
              let source else { return .init() }
        let filter = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "class == %@", "platform"), MapObjectModelInput.groundPredicate])
        var polygons: [MLNPolygon] = []
        for feature in source.features(sourceLayerIdentifiers: ["pedestrian"], predicate: filter) {
            polygons += (feature as? MLNPolygon).map { [$0] } ?? (feature as? MLNMultiPolygon)?.polygons ?? []
        }
        let center = CLLocation(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
        polygons.sort {
            CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: center)
                < CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude).distance(from: center)
        }
        var output = MapLinearObjectGeometry.Output(), seen: Set<String> = []
        var remaining = MapDetailPolicy.constrained ? 400 : 1_200
        for polygon in polygons.prefix(32) {
            let rings = [polygon] + (polygon.interiorPolygons ?? [])
            let cost = rings.reduce(0) { $0 + Int($1.pointCount) }
            guard cost <= remaining, polygon.pointCount >= 4,
                  MapDetailPolicy.contains(polygon.coordinate, on: map, margin: 64) else { continue }
            let key = rings.map { ring in
                (0..<Int(ring.pointCount)).map { "\(ring.coordinates[$0].latitude):\(ring.coordinates[$0].longitude)" }.joined(separator: ";")
            }.joined(separator: "/")
            guard seen.insert(key).inserted else { continue }
            // Preserve the actual outline and holes. Only the low profile is schematic.
            let shape = MLNPolygonFeature(coordinates: polygon.coordinates, count: polygon.pointCount, interiorPolygons: polygon.interiorPolygons)
            shape.identifier = "platform:\(key)" as NSString
            shape.attributes = ["_base": 0, "_top": 0.18, "_material": "stone", "_kind": "platform", "_service": true]
            remaining -= cost; output.shapes.append(shape); output.key += key + "|"
        }
        return output
    }
}
#endif
