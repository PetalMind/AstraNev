#if os(iOS)
import MapLibre
import UIKit

@MainActor
final class POIOverviewClusterRenderer {
    private let sourceID = "naviastra-poi-overview"
    private let circleID = "naviastra-poi-overview-clusters"
    private let countID = "naviastra-poi-overview-count"
    private let pointsID = "naviastra-poi-overview-points"
    private var lastRefresh = Date.distantPast

    func update(on map: MLNMapView, settings: MapSettings, dark: Bool) {
        guard let style = map.style else { return }
        let enabled = settings.context == .browse && settings.overlays.poi
            && map.zoomLevel >= 10 && map.zoomLevel < 13
        for id in [circleID, countID, pointsID] { style.layer(withIdentifier: id)?.isVisible = enabled }
        guard enabled else { return }
        let categories = settings.visiblePOICategories.filter {
            map.zoomLevel >= Double(MapDisplayPriorityEngine.minimumZoom(for: $0))
        }
        let values = categories.flatMap { category in
            map.zoomLevel < 12 && category == .transit ? ["airport"] : category.tileValues
        }
        let predicate = NSPredicate(format: "(class IN %@ OR subclass IN %@) AND rank <= %d",
                                    values, values, map.zoomLevel < 12 ? 1 : 3)
        let sources = Set(style.layers.compactMap { layer -> String? in
            guard let layer = layer as? MLNSymbolStyleLayer, layer.sourceLayerIdentifier == "poi" else { return nil }
            layer.isVisible = false
            return layer.sourceIdentifier
        })
        guard Date().timeIntervalSince(lastRefresh) >= 0.8 || style.source(withIdentifier: sourceID) == nil else { return }
        lastRefresh = .now
        var points: [String: MLNPointFeature] = [:]
        let bounds = map.bounds.insetBy(dx: -64, dy: -64)
        for id in sources {
            guard let source = style.source(withIdentifier: id) as? MLNVectorTileSource else { continue }
            for feature in source.features(sourceLayerIdentifiers: ["poi"], predicate: predicate) {
                guard let feature = feature as? MLNPointFeature else { continue }
                let point = map.convert(feature.coordinate, toPointTo: map)
                guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { continue }
                let kind = PlacePOIMapMarkerKind(category: feature.attributes["subclass"] as? String)
                    ?? PlacePOIMapMarkerKind(category: feature.attributes["class"] as? String) ?? .generic
                let sprite = "naviastra-poi-overview-\(kind.rawValue)-\(dark)"
                if style.image(forName: sprite) == nil { style.setImage(kind.makeMapStyleImage(dark: dark), forName: sprite) }
                let copy = MLNPointFeature()
                copy.coordinate = feature.coordinate
                copy.attributes = feature.attributes
                copy.attributes["sprite"] = sprite
                let name = feature.attributes["name:pl"] as? String ?? feature.attributes["name"] as? String ?? ""
                let key = "\(feature.coordinate.latitude):\(feature.coordinate.longitude):\(name)"
                points[key] = copy
            }
        }
        let source: MLNShapeSource
        if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource { source = existing }
        else {
            source = MLNShapeSource(identifier: sourceID, shape: nil,
                options: [.clustered: true, .clusterRadius: 44, .maximumZoomLevelForClustering: 12])
            style.addSource(source)
            let circles = MLNCircleStyleLayer(identifier: circleID, source: source)
            circles.predicate = NSPredicate(format: "cluster == YES")
            circles.circleRadius = NSExpression(forConstantValue: 18)
            circles.circleColor = NSExpression(forConstantValue: UIColor(naviHex: NaviAstraColorPalette.transitFallback))
            circles.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            circles.circleStrokeWidth = NSExpression(forConstantValue: 2)
            style.addLayer(circles)
            let counts = MLNSymbolStyleLayer(identifier: countID, source: source)
            counts.predicate = NSPredicate(format: "cluster == YES")
            counts.text = NSExpression(mglJSONObject: ["to-string", ["get", "point_count"]])
            counts.textFontSize = NSExpression(forConstantValue: 12)
            counts.textColor = NSExpression(forConstantValue: UIColor.white)
            style.addLayer(counts)
            let symbols = MLNSymbolStyleLayer(identifier: pointsID, source: source)
            symbols.predicate = NSPredicate(format: "cluster != YES")
            symbols.iconImageName = NSExpression(forKeyPath: "sprite")
            symbols.iconScale = NSExpression(forConstantValue: 0.64)
            symbols.iconAllowsOverlap = NSExpression(forConstantValue: false)
            style.addLayer(symbols)
        }
        source.shape = MLNShapeCollectionFeature(shapes: points.values.sorted {
            $0.coordinate.latitude == $1.coordinate.latitude
                ? $0.coordinate.longitude < $1.coordinate.longitude : $0.coordinate.latitude < $1.coordinate.latitude
        })
    }

    func handleTap(at point: CGPoint, on map: MLNMapView) -> Bool {
        let rect = CGRect(origin: point, size: .zero).insetBy(dx: -22, dy: -22)
        guard let feature = map.visibleFeatures(in: rect, styleLayerIdentifiers: [circleID]).first else { return false }
        map.setCenter(feature.coordinate, zoomLevel: min(13, map.zoomLevel + 2), animated: true)
        return true
    }
}
#endif
