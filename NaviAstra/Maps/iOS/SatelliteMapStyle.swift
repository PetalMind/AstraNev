#if os(iOS)
import Foundation
import MapLibre
import UIKit

/// Public imagery services, with no account or API key. Only the 2016 EOX
/// mosaic is CC BY 4.0; newer mosaics require a commercial licence.
@MainActor
final class SatelliteMapStyle {
    private static let prefix = "naviastra-satellite-"
    private var standardVisibility: [String: Bool] = [:]
    private var standardLabels: [String: (NSExpression?, NSExpression?, NSExpression?)] = [:]

    static let description = "W Polsce zdjęcia lotnicze GUGiK, a na świecie zdjęcia Sentinel‑2 z 2016 roku. Poza pokryciem GUGiK szczegóły są ograniczone do około 10 m. Zdjęcia wymagają internetu i nie są częścią pobieranych map offline."
    static let eoxCredit = "EOxCloudless · EOX IT Services GmbH · zmodyfikowane dane Copernicus Sentinel 2016"
    static let eoxURL = URL(string: "https://cloudless.eox.at")!
    static let eoxMapsURL = URL(string: "https://maps.eox.at")!
    static let eoxLicenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    static let gugikURL = URL(string: "https://www.geoportal.gov.pl/pl/dane/ortofotomapa-orto/")!

    /// Restore before the standard style updates its visibility and label colors.
    /// Navigation, traffic, weather and transit layers are never included here.
    func restoreStandard(in style: MLNStyle) {
        for (id, visible) in standardVisibility { style.layer(withIdentifier: id)?.isVisible = visible }
        for (id, values) in standardLabels {
            guard let label = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
            label.textColor = values.0
            label.textHaloColor = values.1
            label.textHaloWidth = values.2
        }
        standardVisibility.removeAll()
        standardLabels.removeAll()
    }

    func apply(to style: MLNStyle, enabled: Bool) {
        if enabled { install(in: style) }
        for layer in style.layers where layer.identifier.hasPrefix(Self.prefix) {
            layer.isVisible = enabled
        }
        guard enabled else { return }
        for layer in style.layers {
            let vector = layer as? MLNVectorStyleLayer
            let isBaseLayer = vector?.sourceIdentifier == "openmaptiles"
                || layer.identifier.hasPrefix(MapEnvironmentStyle.prefix)
                || layer.identifier.hasPrefix("naviastra-building-")
                || layer.identifier.hasPrefix("naviastra-detailed-roads")
                || layer.identifier == "natural_earth"
            guard isBaseLayer else { continue }
            if let label = layer as? MLNSymbolStyleLayer,
               !layer.identifier.hasPrefix("naviastra-detailed-roads"),
               !layer.identifier.hasPrefix(MapEnvironmentStyle.prefix) {
                if standardLabels[layer.identifier] == nil {
                    standardLabels[layer.identifier] = (label.textColor, label.textHaloColor, label.textHaloWidth)
                }
                label.textColor = NSExpression(forConstantValue: UIColor.white)
                label.textHaloColor = NSExpression(forConstantValue: UIColor(white: 0.08, alpha: 0.9))
                label.textHaloWidth = NSExpression(forConstantValue: 1.5)
            } else {
                if standardVisibility[layer.identifier] == nil { standardVisibility[layer.identifier] = layer.isVisible }
                layer.isVisible = false
            }
        }
    }

    private func install(in style: MLNStyle) {
        guard style.source(withIdentifier: Self.prefix + "world") == nil else { return }
        // Above geographic fills, below labels and all navigation overlays.
        let anchor = style.layers.first { $0 is MLNSymbolStyleLayer }
        let world = MLNRasterTileSource(identifier: Self.prefix + "world", tileURLTemplates: [
            "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg"
        ], options: [.tileSize: 256, .minimumZoomLevel: 0, .maximumZoomLevel: 14,
                     .attributionHTMLString: "<a href='https://cloudless.eox.at'>EOxCloudless</a> by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016) · <a href='https://creativecommons.org/licenses/by/4.0/'>CC BY 4.0</a>"])
        insert(world, into: style, below: anchor)

        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: 48.8, longitude: 13.8),
                                         ne: CLLocationCoordinate2D(latitude: 55, longitude: 24.4))
        // WMS PNG keeps areas without Polish imagery transparent. JPEG WMTS
        // tiles would obscure the global mosaic along the border and coverage gaps.
        for resolution in ["StandardResolution", "HighResolution"] {
            let template = "https://mapy.geoportal.gov.pl/wss/service/PZGIK/ORTO/WMS/\(resolution)"
                + "?SERVICE=WMS&REQUEST=GetMap&VERSION=1.3.0&LAYERS=Raster&STYLES="
                + "&FORMAT=image/png&TRANSPARENT=TRUE&CRS=EPSG:3857"
                + "&WIDTH=256&HEIGHT=256&BBOX={bbox-epsg-3857}"
            let source = MLNRasterTileSource(identifier: Self.prefix + resolution,
                tileURLTemplates: [template], options: [
                    .tileSize: 256, .minimumZoomLevel: 12, .maximumZoomLevel: 19,
                    .coordinateBounds: NSValue(mlnCoordinateBounds: bounds),
                    .attributionHTMLString: "<a href='https://www.geoportal.gov.pl/pl/dane/ortofotomapa-orto/'>Ortofotomapa · GUGiK</a>"
                ])
            insert(source, into: style, below: anchor, minimumZoom: 12)
        }
    }

    private func insert(_ source: MLNRasterTileSource, into style: MLNStyle,
                        below anchor: MLNStyleLayer?, minimumZoom: Float = 0) {
        style.addSource(source)
        let layer = MLNRasterStyleLayer(identifier: source.identifier + "-image", source: source)
        layer.minimumZoomLevel = minimumZoom
        layer.rasterFadeDuration = NSExpression(forConstantValue: 200)
        if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
    }
}
#endif
