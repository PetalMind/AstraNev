#if os(iOS)
import MapLibre
import UIKit

/// Visibility is separate from the native filter. Bare Boolean predicates are not filters.
enum MapPOIRouteFilter {
    case unrestricted, hidden, corridor(NSPredicate)

    var predicate: NSPredicate? {
        if case .corridor(let predicate) = self { return predicate }
        return nil
    }

    var allowsDisplay: Bool {
        if case .hidden = self { return false }
        return true
    }
}

/// Cartographic importance, derived from provider rank or the documented category.
/// Planet's POI layers do not supply rank; no popularity is inferred from a brand/name.
enum POIVisualImportance: Int {
    case landmark, major, normal, minor

    var minimumZoom: Double {
        switch self {
        case .landmark: 13.5
        case .major: 15
        case .normal: 16.5
        case .minor: 18
        }
    }

    static func resolve(category: String, rank: Int?) -> Self {
        if ["castle", "palace", "monument", "archaeological_site", "cathedral"].contains(category) {
            return .landmark
        }
        if ["attraction", "museum", "viewpoint"].contains(category), let rank, rank <= 3 { return .landmark }
        if ["mall", "hospital", "university", "stadium", "station", "bus_station", "airport", "aerodrome"].contains(category) {
            return .major
        }
        if ["supermarket", "hotel", "museum", "attraction", "restaurant", "theatre", "theater", "zoo", "theme_park", "aquarium"].contains(category) {
            return .normal
        }
        return .minor
    }
}

/// One collision-aware presentation of actual tile POIs. Planet points take precedence
/// over nearby duplicates from OpenMapTiles, which also provides the offline fallback.
@MainActor
final class MapPOIVisualRenderer {
    static let sourceID = "naviastra-poi-visual-source"
    static let pointsID = "naviastra-poi-visual-points"
    private static let selectionSourceID = "naviastra-poi-selection-source"
    private static let haloID = "naviastra-poi-selection-halo"
    private static let ringID = "naviastra-poi-selection-ring"
    private static let planetLayers = ["poi_shopping", "poi_food", "poi_tourism", "poi_culture",
        "poi_healthcare", "poi_accommodation", "poi_education", "poi_sport", "poi_public", "poi_station"]
    private var refreshedAt = Date.distantPast
    private var refreshKey = ""
    private var contentKey = ""
    private var selectionKey = ""
    private var refreshTask: Task<Void, Never>?

    static func isPOILayer(_ layer: MLNSymbolStyleLayer) -> Bool {
        layer.sourceLayerIdentifier == "poi" || layer.identifier == pointsID
    }

    func configure(in style: MLNStyle) {
        guard style.source(withIdentifier: Self.sourceID) == nil else { return }
        refreshTask?.cancel()
        refreshTask = nil
        refreshedAt = .distantPast
        refreshKey = ""
        contentKey = ""
        selectionKey = ""
        if let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) {
            for name in Self.planetLayers {
                // Keep source tiles loaded for normalization, without visible probe markers.
                let probe = MLNCircleStyleLayer(identifier: "naviastra-poi-load-" + name, source: planet)
                probe.sourceLayerIdentifier = name
                probe.minimumZoomLevel = 13
                probe.circleRadius = NSExpression(forConstantValue: 1)
                // Constant false predicates are not valid standalone MapLibre filters.
                probe.circleOpacity = NSExpression(forConstantValue: 0)
                probe.circleStrokeOpacity = NSExpression(forConstantValue: 0)
                style.addLayer(probe)
            }
        }
        for dark in [false, true] {
            for sport in MapSportKind.allCases {
                style.setImage(sport.image(dark: dark), forName: sport.imageName(dark: dark))
            }
            for (layer, symbol) in [("poi_education", "graduationcap.fill"), ("poi_sport", "sportscourt.fill"), ("landmark", "star.fill")] {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36)).image { renderer in
                    let rect = CGRect(x: 2, y: 2, width: 32, height: 32)
                    let color = UIColor(naviHex: layer == "landmark" ? PlacePOIMapMarkerKind.culture.colorHex(dark: dark)
                        : (dark ? 0xA5BFAD : 0x53795E))
                    renderer.cgContext.setFillColor(color.cgColor)
                    renderer.cgContext.fillEllipse(in: rect)
                    let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
                        .withTintColor(.white, renderingMode: .alwaysOriginal)
                    glyph?.draw(in: CGRect(x: 9, y: 9, width: 18, height: 18))
                }
                style.setImage(image, forName: "naviastra-poi-special-\(layer)-\(dark)")
            }
        }
        let source = MLNShapeSource(identifier: Self.sourceID, shape: nil, options: nil)
        style.addSource(source)
        let symbols = MLNSymbolStyleLayer(identifier: Self.pointsID, source: source)
        symbols.minimumZoomLevel = 12
        symbols.text = NSExpression(forKeyPath: "_label")
        symbols.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
        symbols.textFontSize = NSExpression(mglJSONObject: ["match", ["get", "_importance"], 0, 14, 1, 13, 12])
        symbols.textAnchor = NSExpression(forConstantValue: "top")
        symbols.textOffset = NSExpression(forConstantValue: [0, 1.25])
        symbols.textOptional = NSExpression(forConstantValue: true)
        symbols.textAllowsOverlap = NSExpression(forConstantValue: false)
        symbols.iconAllowsOverlap = NSExpression(forConstantValue: false)
        symbols.iconIgnoresPlacement = NSExpression(forConstantValue: false)
        symbols.symbolSortKey = NSExpression(forKeyPath: "_sort")
        style.addLayer(symbols)
        let selection = MLNShapeSource(identifier: Self.selectionSourceID, shape: nil, options: nil)
        style.addSource(selection)
        for id in [Self.haloID, Self.ringID] {
            let circle = MLNCircleStyleLayer(identifier: id, source: selection)
            let halo = id == Self.haloID
            circle.circleRadius = NSExpression(forConstantValue: halo ? 24 : 18)
            circle.circleOpacity = NSExpression(forConstantValue: halo ? 0.16 : 0)
            circle.circleStrokeWidth = NSExpression(forConstantValue: halo ? 0 : 2.5)
            circle.circleBlur = NSExpression(forConstantValue: halo ? 0.6 : 0)
            style.insertLayer(circle, below: symbols)
        }
    }

    func apply(to style: MLNStyle, settings: MapSettings, zoom: Double, dark: Bool, routeFilter: MapPOIRouteFilter) {
        guard let points = style.layer(withIdentifier: Self.pointsID) as? MLNSymbolStyleLayer else { return }
        points.isVisible = settings.overlays.poi && routeFilter.allowsDisplay
        let categories = settings.visiblePOICategories.map(\.rawValue)
        points.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "_minimumZoom <= %f AND _category IN %@", zoom, categories), routeFilter.predicate
        ].compactMap { $0 })
        points.textHaloColor = NSExpression(forConstantValue: UIColor(naviHex: dark ? 0x222B35 : 0xFFFFFF))
        points.textHaloWidth = NSExpression(forConstantValue: 1.5)
        // Category color and images are assigned by the existing common POI style.
    }

    func refresh(on map: MLNMapView, settings: MapSettings, dark: Bool, selected: SearchResult?, updatesSelection: Bool = true) {
        guard let style = map.style else { return }
        if updatesSelection { updateSelection(in: style, selected: selected, dark: dark) }
        guard settings.overlays.poi, map.zoomLevel >= 12 else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        let center = map.centerCoordinate
        let key = "\(Int(center.latitude * 10_000)):\(Int(center.longitude * 10_000)):\(Int(map.zoomLevel * 2)):\(dark):\(settings.context):\(settings.visiblePOICategories.map(\.rawValue).sorted())"
        let elapsed = Date().timeIntervalSince(refreshedAt)
        if refreshKey == key, elapsed < 0.8 {
            if refreshTask == nil {
                refreshTask = Task { [weak self, weak map] in
                    do { try await Task.sleep(for: .seconds(0.8 - elapsed)) } catch { return }
                    guard let self, let map else { return }
                    self.refreshTask = nil
                    self.refresh(on: map, settings: settings, dark: dark, selected: nil, updatesSelection: false)
                }
            }
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshKey = key
        refreshedAt = .now
        guard let output = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource else { return }
        struct Candidate {
            let point: MLNPointFeature
            let name: String
            let kind: PlacePOIMapMarkerKind
            let category: MapPOICategory
            let importance: POIVisualImportance
            let planet: Bool
        }
        var candidates: [Candidate] = []
        let viewport = map.bounds.insetBy(dx: -48, dy: -48)
        func append(source: MLNVectorTileSource, layer: String, planet: Bool) {
            let predicate = NSPredicate(format: "access == nil OR access != %@", "no")
            for feature in source.features(sourceLayerIdentifiers: [layer], predicate: predicate) {
                guard let point = feature as? MLNPointFeature else { continue }
                let screen = map.convert(point.coordinate, toPointTo: map)
                guard screen.x.isFinite, screen.y.isFinite, viewport.contains(screen) else { continue }
                let attributes = point.attributes
                guard let resolved = Self.resolve(layer: layer, attributes: attributes) else { continue }
                let sport = MapSportKind.resolve(layer: layer, attributes: attributes)
                let rawName = attributes["name:pl"] as? String ?? attributes["name"] as? String
                    ?? attributes["brand"] as? String ?? attributes["operator"] as? String ?? ""
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let category = attributes["subclass"] as? String ?? attributes["class"] as? String ?? ""
                let tileClass = attributes["class"] as? String ?? ""
                let rank = (attributes["rank"] as? NSNumber)?.intValue
                let specific = POIVisualImportance.resolve(category: category, rank: rank)
                let broad = POIVisualImportance.resolve(category: tileClass, rank: rank)
                let importance = POIVisualImportance(rawValue: min(specific.rawValue, broad.rawValue)) ?? .minor
                let minimumZoom = [.fuel, .parking, .charging].contains(resolved.category)
                    ? Double(MapDisplayPriorityEngine.minimumZoom(for: resolved.category))
                    : (sport == nil ? importance.minimumZoom : min(17, importance.minimumZoom))
                guard minimumZoom <= map.zoomLevel,
                      settings.visiblePOICategories.contains(resolved.category) else { continue }
                let copy = MLNPointFeature()
                copy.coordinate = point.coordinate
                copy.identifier = point.identifier
                copy.attributes = attributes
                copy.attributes["_label"] = sport.map { name.isEmpty ? $0.title : "\(name) · \($0.title)" } ?? name
                copy.attributes["_kind"] = resolved.kind.rawValue
                copy.attributes["_fallbackName"] = sport?.title ?? (layer == "poi_education" ? "Placówka edukacyjna"
                    : (layer == "poi_sport" ? "Obiekt sportowy" : resolved.kind.accessibilityName)
                )
                if let sport {
                    copy.attributes["_sport"] = sport.rawValue
                    copy.attributes["_sprite"] = sport.imageName(dark: dark)
                } else if importance == .landmark {
                    copy.attributes["_sprite"] = "naviastra-poi-special-landmark-\(dark)"
                } else if layer == "poi_education" || layer == "poi_sport" {
                    copy.attributes["_sprite"] = "naviastra-poi-special-\(layer)-\(dark)"
                }
                copy.attributes["_category"] = resolved.category.rawValue
                copy.attributes["_planet"] = planet
                copy.attributes["_importance"] = importance.rawValue
                // Road service POIs retain their existing route presentation thresholds.
                copy.attributes["_minimumZoom"] = minimumZoom
                copy.attributes["_sort"] = importance.rawValue * 1_000 + min(999, rank ?? 999)
                copy.attributes["_color"] = String(format: "#%06X", sport?.colorHex(dark: dark) ?? resolved.kind.colorHex(dark: dark))
                // Without a name, keep a useful icon and Polish category in the place sheet.
                let specificCategory = ["unknown", "yes", ""].contains(category) ? tileClass : category
                copy.attributes["_selectionCategory"] = resolved.category == .shopping && layer != "poi_public"
                    ? "shop=\(specificCategory)" : specificCategory
                candidates.append(Candidate(point: copy, name: name, kind: resolved.kind, category: resolved.category, importance: importance, planet: planet))
            }
        }
        if let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource {
            for layer in Self.planetLayers { append(source: planet, layer: layer, planet: true) }
        }
        if let base = style.source(withIdentifier: "openmaptiles") as? MLNVectorTileSource {
            append(source: base, layer: "poi", planet: false)
        }
        candidates.sort {
            if $0.planet != $1.planet { return $0.planet }
            if $0.importance != $1.importance { return $0.importance.rawValue < $1.importance.rawValue }
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.point.coordinate.latitude != $1.point.coordinate.latitude {
                return $0.point.coordinate.latitude < $1.point.coordinate.latitude
            }
            return $0.point.coordinate.longitude < $1.point.coordinate.longitude
        }
        var points: [MLNPointFeature] = []
        var byName: [String: [CLLocation]] = [:]
        for candidate in candidates {
            let location = CLLocation(latitude: candidate.point.coordinate.latitude, longitude: candidate.point.coordinate.longitude)
            let normalized = candidate.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            let family = (candidate.point.attributes["_sport"] as? String).map { "sport:\($0)" }
                ?? (candidate.name.isEmpty ? candidate.kind.rawValue : String(candidate.category.rawValue))
            let identity = "\(family):\(normalized)"
            let distance = candidate.name.isEmpty ? 2.0 : 25.0
            guard !(byName[identity] ?? []).contains(where: { $0.distance(from: location) < distance }) else { continue }
            byName[identity, default: []].append(location)
            points.append(candidate.point)
        }
        points.sort {
            let left = $0.attributes["_sort"] as? Int ?? 0
            let right = $1.attributes["_sort"] as? Int ?? 0
            if left != right { return left < right }
            if $0.coordinate.latitude != $1.coordinate.latitude { return $0.coordinate.latitude < $1.coordinate.latitude }
            return $0.coordinate.longitude < $1.coordinate.longitude
        }
        points = Array(points.prefix(1_200))
        // Stable content avoids a render -> source update -> render feedback loop.
        let nextKey = points.map { point in
            let data = (try? JSONSerialization.data(withJSONObject: point.attributes, options: [.sortedKeys])) ?? Data()
            return "\(point.identifier.map { String(describing: $0) } ?? ""):\(point.coordinate.latitude):\(point.coordinate.longitude):\(data.base64EncodedString())"
        }.joined(separator: "|")
        guard nextKey != contentKey else { return }
        contentKey = nextKey
        output.shape = MLNShapeCollectionFeature(shapes: points)
    }

    private func updateSelection(in style: MLNStyle, selected: SearchResult?, dark: Bool) {
        let nextKey = "\(selected?.placeIdentity.cacheKey ?? ""):\(dark)"
        guard nextKey != selectionKey else { return }
        selectionKey = nextKey
        let source = style.source(withIdentifier: Self.selectionSourceID) as? MLNShapeSource
        guard let selected, selected.isPOI else { source?.shape = nil; return }
        let point = MLNPointFeature()
        point.coordinate = selected.destination.coordinate.cl
        source?.shape = point
        let kind = PlacePOIMapMarkerKind(category: selected.category) ?? .generic
        let sport = MapSportKind.resolve(layer: "poi", attributes: ["subclass": selected.category ?? ""])
        let color = NSExpression(forConstantValue: UIColor(naviHex: sport?.colorHex(dark: dark) ?? kind.colorHex(dark: dark)))
        for id in [Self.haloID, Self.ringID] {
            let circle = style.layer(withIdentifier: id) as? MLNCircleStyleLayer
            circle?.circleColor = color
            circle?.circleStrokeColor = color
        }
    }

    private static func resolve(layer: String, attributes: [String: Any]) -> (category: MapPOICategory, kind: PlacePOIMapMarkerKind)? {
        switch layer {
        case "poi_shopping": return (.shopping, .shopping)
        case "poi_food": return (.food, attributes["class"] as? String == "cafe" ? .cafe : .food)
        case "poi_tourism": return (.attractions, .attraction)
        case "poi_culture": return (.attractions, .culture)
        case "poi_healthcare": return (.health, .health)
        case "poi_accommodation": return (.lodging, .lodging)
        case "poi_education", "poi_sport": return (.attractions, .generic)
        case "poi_public":
            guard attributes["class"] as? String == "service" else { return nil }
            return (.shopping, .generic)
        case "poi_station":
            // TransitStopRenderer owns stops and stations, including their selection.
            guard attributes["class"] as? String == "aerodrome" else { return nil }
            return (.transit, .airport)
        default:
            if MapSportKind.resolve(layer: layer, attributes: attributes) != nil { return (.attractions, .generic) }
            let specific = attributes["subclass"] as? String
            let broad = attributes["class"] as? String
            guard let category = MapPOICategory.allCases.first(where: { $0.tileValues.contains(specific ?? "") })
                ?? MapPOICategory.allCases.first(where: { $0.tileValues.contains(broad ?? "") }) else { return nil }
            if category == .transit, specific != "airport", broad != "airport" { return nil }
            let kind = PlacePOIMapMarkerKind(category: specific) ?? PlacePOIMapMarkerKind(category: broad) ?? .generic
            return (category, kind)
        }
    }

}
#endif
