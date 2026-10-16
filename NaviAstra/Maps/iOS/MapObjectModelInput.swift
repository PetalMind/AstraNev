#if os(iOS)
import MapLibre

/// Only explicit physical categories produce bodies. A parcel pickup counter or a
/// station centroid never implies a locker, shelter or platform footprint.
struct MapObjectModelPoint {
    let coordinate: CLLocationCoordinate2D
    let kind: MapStreetFurnitureGeometry.Kind
    var category: MapPOICategory? = nil
    var safetyCategory: MapSafetyPOICategory? = nil
    var identity = ""
    var label = ""
    var bearing: Double? = nil
    var width: Double? = nil
    var depth: Double? = nil
    var height: Double? = nil
    var leafType: String? = nil
    var groundModelAllowed = true
    var sign: RoadSignSymbol? = nil
    var extraSigns: [RoadSignSymbol] = []
    var priority = 0
    var signs: [RoadSignSymbol] { (sign.map { [$0] } ?? []) + extraSigns }
    var observationKey: String {
        "\(kind.rawValue):\(Int((coordinate.latitude * 1e7).rounded())):\(Int((coordinate.longitude * 1e7).rounded())):\(canonicalID)"
    }
    var canonicalID: String {
        let components = identity.lowercased().split(whereSeparator: { ":-/".contains($0) }).map(String.init)
        if let i = components.firstIndex(where: { ["node", "way", "relation"].contains($0) }), i + 1 < components.count,
           let id = UInt64(components[i + 1]), id > 0 { return "osm:\(components[i]):\(id)" }
        return identity
    }

    static func metadata(_ feature: MLNFeature, kind: MapStreetFurnitureGeometry.Kind,
                         category: MapPOICategory? = nil) -> Self {
        let a = feature.attributes
        func number(_ key: String) -> Double? {
            let value = (a[key] as? NSNumber)?.doubleValue ?? (a[key] as? String).flatMap(Double.init)
            return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        let direction = (a["direction"] as? NSNumber)?.doubleValue ?? (a["direction"] as? String).flatMap(Double.init)
        return Self(coordinate: feature.coordinate, kind: kind, category: category,
            identity: (a["osm_type"] as? String).flatMap { type in
                guard ["node", "way", "relation"].contains(type.lowercased()), let id = a["osm_id"] else { return nil }
                return "osm:\(type):\(id)"
            } ?? ((a["osm_id"] as? String).flatMap { $0.contains(":") || $0.contains("-") ? $0 : nil } ?? ""),
            label: a["name"] as? String ?? a["ref"] as? String ?? "",
            bearing: direction.flatMap { $0.isFinite && (0...360).contains($0) ? $0 : nil },
            width: number(kind == .tree ? "diameter_crown" : "width"), depth: number("length"),
            height: number("height"), leafType: a["leaf_type"] as? String,
            groundModelAllowed: MapObjectModelInput.groundPredicate.evaluate(with: a), priority: 2)
    }

    func isAllowed(settings: MapSettings, zoom: Double) -> Bool {
        guard settings.overlays.poi else { return false }
        if let category, !settings.visiblePOICategories.contains(category) { return false }
        if let safetyCategory {
            return settings.roadPOICategories.contains(safetyCategory)
                && MapDisplayPriorityEngine.showsRoadDetail(safetyCategory, zoom: zoom,
                    navigating: settings.context.isNavigating)
        }
        return true
    }
}

@MainActor
enum MapObjectModelInput {
    static let tileLayers = ["poi_public", "poi_transport", "poi_station"]
    // These models are anchored to ground; a floor/layer is not a height in meters.
    static let groundPredicate = NSPredicate(format:
        "(indoor == nil OR indoor != true) AND (construction == nil OR construction != true) AND (underground == nil OR underground != true) AND (bridge == nil OR bridge != true) AND (tunnel == nil OR tunnel != true) AND (brunnel == nil OR NOT (brunnel IN %@)) AND (level == nil OR level == 0) AND (layer == nil OR layer == 0)", ["bridge", "tunnel"])

    static func tiles(in style: MLNStyle) -> [MapObjectModelPoint] {
        var result: [MapObjectModelPoint] = []
        let filter = groundPredicate
        if let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource {
            for layer in tileLayers {
                for feature in planet.features(sourceLayerIdentifiers: [layer], predicate: filter) {
                    guard let point = feature as? MLNPointFeature else { continue }
                    let subclass = point.attributes["subclass"] as? String ?? ""
                    let tileClass = point.attributes["class"] as? String ?? ""
                    let kind: MapStreetFurnitureGeometry.Kind
                    let category: MapPOICategory
                    switch (layer, tileClass, subclass) {
                    case ("poi_public", _, "parcel_locker"): kind = .parcelLocker; category = .shopping
                    case ("poi_transport", "fuel", "charging_station"): kind = .charger; category = .charging
                    case ("poi_station", "bus", "bus_stop"), ("poi_station", "railway", "tram_stop"):
                        kind = .stop; category = .transit
                    case ("poi_station", "bus", "bus_station"), ("poi_station", "railway", "station"),
                         ("poi_station", "railway", "halt"), ("poi_station", "railway", "subway"):
                        kind = .station; category = .transit
                    default: continue
                    }
                    result.append(.metadata(point, kind: kind, category: category))
                }
            }
        }
        if let base = style.source(withIdentifier: "openmaptiles") as? MLNVectorTileSource {
            for feature in base.features(sourceLayerIdentifiers: ["poi"], predicate: filter) {
                guard let point = feature as? MLNPointFeature else { continue }
                let value = point.attributes["subclass"] as? String ?? point.attributes["class"] as? String ?? ""
                if let kind = serviceKind(category: value) {
                    result.append(.metadata(point, kind: kind, category: kind == .charger ? .charging : .shopping))
                }
            }
        }
        if let buildings = style.source(withIdentifier: MapTilerEnvironmentStyle.buildingsSourceID) as? MLNVectorTileSource {
            for feature in buildings.features(sourceLayerIdentifiers: ["building_entrance"], predicate: filter) {
                guard let point = feature as? MLNPointFeature else { continue }
                result.append(.metadata(point, kind: .entrance))
            }
        }
        return result
    }

    static func serviceKind(category: String?) -> MapStreetFurnitureGeometry.Kind? {
        switch category {
        case "charging_station": .charger
        case "parcel_locker": .parcelLocker
        default: nil
        }
    }

    static func roadKind(category: MapSafetyPOICategory) -> MapStreetFurnitureGeometry.Kind? {
        switch category {
        case .speedCameras: .speedCamera
        case .surveillanceCameras: .camera
        case .trafficSignals: .trafficSignals
        case .trafficSigns, .heightLimits, .weightLimits, .truckRestrictions: .sign
        default: nil
        }
    }

    static func roadCategory(alert: RoadSafetyAlert) -> MapSafetyPOICategory? {
        if let category = alert.mapSafetyPOICategory { return category }
        switch alert.type {
        case .trafficSign, .stopSign, .giveWaySign, .noEntrySign, .noOvertakingSign,
             .speedLimitSign, .trafficZoneSign: return .trafficSigns
        default: return nil
        }
    }
}
#endif
