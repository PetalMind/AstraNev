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
        layer.iconRotation = NSExpression(mglJSONObject: ["coalesce", ["get", "direction"], 0])
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
#endif
