#if os(iOS)
import Foundation
import MapLibre
import OSLog
import UIKit

/// Seamless low-poly patterns, toned for cartography rather than lit PBR materials.
/// All surfaces use provider polygons; no geometry or material survey is inferred.
@MainActor
enum MapTerrainTextureStyle {
    typealias Material = MapTerrainPattern.Material

    static let prefix = MapEnvironmentStyle.prefix + "terrain-"
    private static var images: [String: UIImage] = [:]
    private static let logger = Logger(subsystem: "NaviAstra", category: "TerrainTextures")

    static func imageName(_ material: Material, dark: Bool) -> String {
        prefix + material.rawValue + (dark ? "-night" : "-day")
    }

    /// Prepare each 256 px tile only once, including across style reloads.
    /// Geometry and bounded flat tones stay identical across style reloads.
    static func image(_ material: Material, dark: Bool) -> UIImage? {
        let name = imageName(material, dark: dark)
        if let cached = images[name] { return cached }
        guard let source = MapTerrainPattern.image(material, dark: dark) else {
            logger.error("Nie udało się przygotować wzoru terenu: \(material.rawValue, privacy: .public). Pozostaje podstawowy wygląd mapy.")
            return nil
        }
        let result = UIImage(cgImage: source, scale: 1, orientation: .up)
        images[name] = result
        return result
    }

    static func configure(in style: MLNStyle) {
        // Water and grass use the existing layers and their graceful fallbacks.
        for material in [Material.forestGround, .sand, .rock, .asphalt] {
            for dark in [false, true] {
                if let image = image(material, dark: dark) {
                    style.setImage(image, forName: imageName(material, dark: dark))
                }
            }
        }
        let landscape = style.layers.first {
            guard $0 is MLNFillStyleLayer || $0 is MLNLineStyleLayer,
                  let vector = $0 as? MLNVectorStyleLayer else { return false }
            return vector.sourceLayerIdentifier == "water" || vector.sourceLayerIdentifier == "waterway"
        }
        if let source = style.source(withIdentifier: "openmaptiles"), let landscape {
            for (material, predicate): (Material, NSPredicate) in [
                (.sand, NSPredicate(format: "class == %@ OR subclass IN %@", "sand", ["sand", "beach", "dune"])),
                (.rock, NSPredicate(format: "class == %@ OR subclass IN %@", "rock", ["bare_rock", "scree"]))
            ] {
                install(material, in: style, source: source, sourceLayer: "landcover", predicate: predicate,
                        minimumZoom: 14, below: landscape)
            }
        }
        let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID)
        let base = style.source(withIdentifier: "openmaptiles")
        if let source = planet ?? base, let landscape {
            let canopyID = planet == nil ? "naviastra-forest-tree-pattern"
                : MapEnvironmentStyle.prefix + "planet-wood-pattern"
            let canopy = style.layer(withIdentifier: canopyID) ?? landscape
            install(.forestGround, in: style, source: source, sourceLayer: planet == nil ? "landcover" : "wood",
                    predicate: planet == nil
                        ? NSPredicate(format: "class == %@ OR subclass IN %@", "wood", ["wood", "forest"]) : nil,
                    minimumZoom: 15, below: canopy)
        }
        // Preserve the exact parking filter, including underground exclusions.
        // Planet has no surface-material field: this is only a neutral pattern.
        let parkingID = MapEnvironmentStyle.prefix + (planet == nil ? "parking" : "planet-parking")
        if let parking = style.layer(withIdentifier: parkingID) as? MLNFillStyleLayer,
           let source = planet ?? base {
            install(.asphalt, in: style, source: source, sourceLayer: parking.sourceLayerIdentifier ?? "landuse",
                    predicate: parking.predicate, minimumZoom: 17, above: parking)
        }
    }

    private static func install(_ material: Material, in style: MLNStyle, source: MLNSource,
                                sourceLayer: String, predicate: NSPredicate?, minimumZoom: Float,
                                below: MLNStyleLayer? = nil, above: MLNStyleLayer? = nil) {
        let id = prefix + material.rawValue
        guard style.layer(withIdentifier: id) == nil,
              style.image(forName: imageName(material, dark: false)) != nil,
              style.image(forName: imageName(material, dark: true)) != nil else { return }
        let layer = MLNFillStyleLayer(identifier: id, source: source)
        layer.sourceLayerIdentifier = sourceLayer
        layer.predicate = predicate
        layer.minimumZoomLevel = minimumZoom
        layer.fillPattern = NSExpression(forConstantValue: imageName(material, dark: false))
        layer.fillOpacity = NSExpression(forConstantValue: 0)
        layer.fillAntialiased = NSExpression(forConstantValue: true)
        if let above { style.insertLayer(layer, above: above) }
        else if let below { style.insertLayer(layer, below: below) }
    }

    static func apply(to style: MLNStyle, settings: MapSettings, dark: Bool) {
        for material in [Material.forestGround, .sand, .rock, .asphalt] {
            guard let layer = style.layer(withIdentifier: prefix + material.rawValue) as? MLNFillStyleLayer else { continue }
            let start = Double(layer.minimumZoomLevel)
            let strength = settings.context.isNavigating ? 0.55 : 1.0
            let maximum = material == .asphalt ? 0.26 : 0.60
            layer.fillPattern = NSExpression(forConstantValue: imageName(material, dark: dark))
            layer.fillOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                start, 0, start + 1, maximum * 0.65 * strength, start + 2, maximum * strength])
        }
    }

    static func grassOpacity(navigating: Bool) -> NSExpression {
        let strength = navigating ? 0.55 : 1.0
        return NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
            15, 0, 17, 0.48 * strength, 19, 0.64 * strength])
    }

    static func waterOpacity(navigating: Bool) -> NSExpression {
        let strength = navigating ? 0.55 : 1.0
        return NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
            12, 0, 14, 0.24 * strength, 17, 0.56 * strength, 19, 0.68 * strength])
    }
}
#endif
