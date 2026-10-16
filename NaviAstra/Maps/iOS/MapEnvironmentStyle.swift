#if os(iOS)
import Foundation
import MapLibre
import UIKit

/// Static vector presentation: MapLibre owns viewport scheduling, caching and geometry.
/// Fine details are opt-in via a real TileJSON endpoint, never generated from missing OSM tags.
@MainActor
enum MapEnvironmentStyle {
    static let prefix = "naviastra-environment-"

    static func configure(in style: MLNStyle) {
        guard let source = style.source(withIdentifier: "openmaptiles") else { return }
        for dark in [false, true] {
            style.setImage(pavingPattern(dark: dark), forName: pavingName(dark))
        }
        // Liberty omits farmland and some small leisure areas, although the tiles contain them.
        if let anchor = style.layers.first(where: { ($0 as? MLNVectorStyleLayer)?.sourceLayerIdentifier == "waterway" }) {
            let fields = MLNFillStyleLayer(identifier: prefix + "farmland", source: source)
            fields.sourceLayerIdentifier = "landcover"
            fields.predicate = NSPredicate(format: "class == %@", "farmland")
            fields.minimumZoomLevel = 12
            style.insertLayer(fields, below: anchor)
            let leisure = MLNFillStyleLayer(identifier: prefix + "leisure", source: source)
            leisure.sourceLayerIdentifier = "landuse"
            leisure.predicate = NSPredicate(format: "class IN %@", ["playground", "stadium", "theme_park", "zoo"])
            leisure.minimumZoomLevel = 16
            style.insertLayer(leisure, below: anchor)
            // Render only polygons supplied as parking by a provider, never POI buffers.
            let parking = MLNFillStyleLayer(identifier: prefix + "parking", source: source)
            parking.sourceLayerIdentifier = "landuse"
            parking.predicate = NSPredicate(format: "class == %@", "parking")
            parking.minimumZoomLevel = 15
            style.insertLayer(parking, below: anchor)
        }
        // Preserve the provider's ground / bridge / tunnel filters and relative layer order.
        let paths = style.layers.compactMap { $0 as? MLNLineStyleLayer }.filter {
            $0.sourceLayerIdentifier == "transportation" && $0.identifier.contains("path_pedestrian")
                && !$0.identifier.contains("casing")
        }
        for path in paths {
            let casing = MLNLineStyleLayer(identifier: prefix + path.identifier + "-edge", source: source)
            casing.sourceLayerIdentifier = path.sourceLayerIdentifier
            casing.predicate = path.predicate
            casing.minimumZoomLevel = 16
            casing.lineJoin = NSExpression(forConstantValue: "round")
            casing.lineCap = NSExpression(forConstantValue: "round")
            style.insertLayer(casing, below: path)
            let steps = MLNLineStyleLayer(identifier: prefix + path.identifier + "-steps", source: source)
            steps.sourceLayerIdentifier = path.sourceLayerIdentifier
            steps.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                path.predicate, NSPredicate(format: "subclass == %@", "steps")
            ].compactMap { $0 })
            steps.minimumZoomLevel = 18
            steps.lineDashPattern = NSExpression(forConstantValue: [0.35, 1.3])
            style.insertLayer(steps, above: path)
        }
        // Real rail centerlines; offset rails and sleepers are a cartographic symbol, not a survey.
        let rails = style.layers.compactMap { $0 as? MLNLineStyleLayer }.filter {
            $0.sourceLayerIdentifier == "transportation" && $0.identifier.contains("rail")
                && !$0.identifier.contains("hatching")
        }
        for rail in rails {
            for side in [-1, 1] {
                let track = MLNLineStyleLayer(identifier: prefix + rail.identifier + "-rail-\(side)", source: source)
                track.sourceLayerIdentifier = rail.sourceLayerIdentifier
                track.predicate = rail.predicate
                track.minimumZoomLevel = 17
                track.lineOffset = NSExpression(mglJSONObject: [
                    "interpolate", ["exponential", 1.4], ["zoom"], 17, Double(side), 20, Double(side) * 3.5
                ])
                track.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 17, 0.6, 20, 1.1])
                style.insertLayer(track, above: rail)
            }
        }
        if let area = style.layers.first(where: { $0.identifier == "road_area_pattern" }) {
            let texture = MLNFillStyleLayer(identifier: prefix + "paving", source: source)
            texture.sourceLayerIdentifier = "transportation"
            texture.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                (area as? MLNVectorStyleLayer)?.predicate,
                NSPredicate(format: "class == %@ OR subclass IN %@", "pedestrian", ["pedestrian", "square"])
            ].compactMap { $0 })
            texture.minimumZoomLevel = 17
            style.insertLayer(texture, above: area)
        }
        // Ground approaches terminate visually at the road edge even before
        // detailed asphalt is available. Elevated and underground paths keep their order.
        if let road = groundRoadAnchor(in: style) {
            let approaches = style.layers.filter { layer in
                guard let line = layer as? MLNLineStyleLayer,
                      line.sourceLayerIdentifier == "transportation" else { return false }
                let id = line.identifier.lowercased()
                return id.contains("path_pedestrian") && !id.contains("bridge") && !id.contains("tunnel")
            }
            for layer in approaches {
                style.removeLayer(layer)
                style.insertLayer(layer, below: road)
            }
        }
        MapTilerEnvironmentStyle.configure(in: style)
    }

    /// The first actual ground carriageway, excluding paths, rails and other levels.
    static func groundRoadAnchor(in style: MLNStyle) -> MLNStyleLayer? {
        style.layers.first { layer in
            guard let line = layer as? MLNLineStyleLayer,
                  line.sourceLayerIdentifier == "transportation" else { return false }
            let id = line.identifier.lowercased()
            return id.hasPrefix("road_")
                && !["path", "pedestrian", "rail", "hatching", "bridge", "tunnel"].contains(where: id.contains)
        }
    }

    static func apply(to style: MLNStyle, settings: MapSettings, dark: Bool) {
        let navigating = settings.context.isNavigating
        let cycling = settings.context == .cycling
        let path = constantColor(dark ? 0x313238 : 0xF4F1EC)
        let edge = constantColor(dark ? 0x42434A : 0xD5D3CF)
        let cycle = constantColor(cycling ? (dark ? 0x699594 : 0xB5D2C8) : (dark ? 0x333B3B : 0xE1E9DE))
        let shared = constantColor(cycling ? (dark ? 0x748F88 : 0xC4D7C9) : (dark ? 0x383A37 : 0xEBEBDD))
        // MapLibre 6.29's multi-branch case serializer cannot encode a compound
        // predicate in MLN_IF. Nested binary conditionals preserve the same priority.
        let cycleColor = NSExpression(forMLNConditional: NSPredicate(format: "subclass == %@", "cycleway"),
                                      trueExpression: cycle, falseExpression: path)
        let pathColor = NSExpression(forMLNConditional: sharedCondition,
                                     trueExpression: shared, falseExpression: cycleColor)
        let opacity = navigating && settings.context == .driving ? 0.72 : 1.0
        let railOpacity = settings.overlays.transit || settings.context == .transit ? 0.8 : 0.48
        for layer in style.layers {
            if let fill = layer as? MLNFillStyleLayer {
                if fill.identifier == prefix + "farmland" {
                    fill.fillColor = constantColor(dark ? 0x3A4130 : 0xE6E7C9)
                } else if fill.identifier == prefix + "leisure" || fill.identifier == prefix + "parking" {
                    fill.fillColor = landuseColor(dark: dark)
                    fill.fillOpacity = fade(15, 16, maximum: 0.85)
                } else if fill.identifier == "road_area_pattern" {
                    // Replace Liberty's prominent checkerboard with a quiet solid surface.
                    fill.fillPattern = nil
                    fill.minimumZoomLevel = 16
                    fill.fillColor = pathColor
                    fill.fillOutlineColor = constantColor(dark ? 0x42434A : 0xD5D3CF)
                    fill.fillOpacity = fade(16, 17, maximum: opacity)
                } else if fill.identifier == prefix + "paving" {
                    fill.fillPattern = NSExpression(forConstantValue: pavingName(dark))
                    fill.fillOpacity = fade(17, 18, maximum: navigating ? 0.04 : 0.08)
                }
            }
            if let line = layer as? MLNLineStyleLayer, line.sourceLayerIdentifier == "transportation" {
                let id = line.identifier
                if id.contains("path_pedestrian") {
                    line.minimumZoomLevel = id.hasSuffix("-steps") ? 18 : 16
                    let casing = id.hasSuffix("-edge") || id.contains("casing")
                    line.lineColor = casing ? edge : pathColor
                    line.lineCap = NSExpression(forConstantValue: "round")
                    line.lineJoin = NSExpression(forConstantValue: "round")
                    line.lineWidth = pathWidth(casing: casing)
                    line.lineOpacity = fade(16, 17, maximum: opacity)
                    if id.hasSuffix("-steps") {
                        line.lineColor = constantColor(dark ? 0x66676A : 0xBCB9B2)
                        line.lineWidth = pathWidth(casing: false)
                        line.lineOpacity = fade(18, 18.5, maximum: 0.65)
                    } else {
                        // Solid ribbons represent mapped paths; the old dashed stroke looked like a road marking.
                        line.lineDashPattern = nil
                    }
                } else if id.contains("rail") {
                    let strength = id.contains("transit") ? railOpacity * 0.75 : railOpacity
                    line.lineColor = constantColor(dark ? 0x687279 : 0xA5AAA9)
                    line.lineOpacity = NSExpression(forConstantValue: strength)
                    if id.contains("hatching") {
                        line.minimumZoomLevel = 17
                        line.lineWidth = NSExpression(mglJSONObject: [
                            "interpolate", ["exponential", 1.4], ["zoom"], 17, 3, 20, 8
                        ])
                        line.lineDashPattern = NSExpression(forConstantValue: [0.25, 2.5])
                        line.lineOpacity = fade(17, 17.7, maximum: strength)
                    } else if !id.hasPrefix(prefix) {
                        line.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 12, 0.3, 15, 0.65, 17, 0.8])
                        line.lineOpacity = NSExpression(mglJSONObject: [
                            "interpolate", ["linear"], ["zoom"], 16.9, strength, 17.7, 0
                        ])
                    } else {
                        line.lineOpacity = fade(17, 17.7, maximum: strength)
                    }
                }
            }
            if let line = layer as? MLNLineStyleLayer, line.sourceLayerIdentifier == "waterway",
               !line.identifier.hasPrefix(prefix) {
                // Streams and drains enter later than rivers and canals; never animate water.
                line.lineOpacity = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    13, ["match", ["get", "class"], ["river", "canal"], 1, 0],
                    15, ["case", ["==", ["get", "intermittent"], 1], 0.55, 1]
                ])
            }
            if let symbol = layer as? MLNSymbolStyleLayer,
               ["poi", "place", "park", "transportation_name", "aerodrome_label"].contains(symbol.sourceLayerIdentifier ?? ""),
               !symbol.identifier.contains("shield") {
                symbol.text = NSExpression(mglJSONObject: [
                    "coalesce", ["get", "name:pl"], ["get", "name"], ["get", "name:latin"], ""
                ])
            }
        }
        MapTilerEnvironmentStyle.apply(to: style, settings: settings, dark: dark)
    }

    private static let sharedCondition = NSPredicate(
        format: "foot IN %@ AND bicycle IN %@ AND subclass IN %@",
        ["yes", "designated"], ["yes", "designated"], ["footway", "path", "cycleway"]
    )

    private static func pathWidth(casing: Bool) -> NSExpression {
        let addition = casing ? 1.0 : 0.0
        return NSExpression(mglJSONObject: ["interpolate", ["exponential", 1.6], ["zoom"],
            16, 1.5 + addition, 17, 3.5 + addition, 18, 6 + addition, 20, 16 + addition])
    }

    static func landuseColor(dark: Bool) -> NSExpression {
        NSExpression(mglJSONObject: ["match", ["get", "class"],
            "parking", rgb(dark ? 0x303238 : 0xE3E2DE),
            ["pitch", "playground", "stadium", "track"], rgb(dark ? 0x33443C : 0xD8E2D1),
            "cemetery", rgb(dark ? 0x2F3C32 : 0xD5DFCD),
            ["school", "hospital", "university", "college", "kindergarten"], rgb(dark ? 0x33343A : 0xE9E5DF),
            ["commercial", "retail", "industrial", "garages", "railway"], rgb(dark ? 0x2C3035 : 0xE3E2DF),
            rgb(dark ? 0x292E33 : 0xECEBE7)])
    }

    private static func fade(_ start: Double, _ end: Double, maximum: Double) -> NSExpression {
        NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], start, 0, end, maximum])
    }
    // JSON colors must have an explicit color type; a bare string stays NSString in NSExpression.
    private static func rgb(_ value: UInt32) -> [Any] {
        ["rgb", (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }
    private static func constantColor(_ value: UInt32) -> NSExpression { NSExpression(forConstantValue: UIColor(naviHex: value)) }
    private static func pavingName(_ dark: Bool) -> String { prefix + "paving-" + (dark ? "night" : "day") }
    private static func pavingPattern(dark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { renderer in
            let context = renderer.cgContext
            context.setStrokeColor(UIColor(white: dark ? 0.8 : 0.25, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            for row in 0..<4 {
                let y = CGFloat(row * 8) + 0.5
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: 32, y: y))
                for column in 0..<2 {
                    let x = CGFloat(column * 16 + (row.isMultiple(of: 2) ? 0 : 8)) + 0.5
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x, y: y + 8))
                }
            }
            context.strokePath()
        }
    }
}
#endif
