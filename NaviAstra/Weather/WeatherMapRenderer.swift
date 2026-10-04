#if os(iOS)
import MapLibre
import UIKit

@MainActor final class WeatherMapRenderer {
    private var lastSamples: [RouteWeatherSample] = []

    func update(map: MLNMapView, configuration: WeatherVisualConfiguration, samples: [RouteWeatherSample]) {
        guard let style = map.style else { return }
        let tintID = "naviastra-weather-atmosphere"
        let tint: MLNBackgroundStyleLayer
        if let existing = style.layer(withIdentifier: tintID) as? MLNBackgroundStyleLayer { tint = existing }
        else {
            tint = MLNBackgroundStyleLayer(identifier: tintID)
            insert(tint, into: style)
        }
        tint.backgroundColor = NSExpression(forConstantValue: color(configuration.tintHex))
        tint.backgroundOpacity = NSExpression(forConstantValue: configuration.tintOpacity)
        let sourceID = "naviastra-weather-route-source"
        guard samples != lastSamples || (style.source(withIdentifier: sourceID) == nil && !samples.isEmpty) else { return }
        lastSamples = samples
        for layer in style.layers where layer.identifier.hasPrefix("naviastra-weather-segment-") { style.removeLayer(layer) }
        if let source = style.source(withIdentifier: sourceID) { style.removeSource(source) }
        guard !samples.isEmpty else { return }
        let features: [MLNPolylineFeature] = samples.map { sample in
            var coordinates = sample.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            feature.attributes = ["sample": sample.index]
            return feature
        }
        let source = MLNShapeSource(identifier: sourceID, features: features, options: nil)
        style.addSource(source)
        for sample in samples {
            let layer = MLNLineStyleLayer(identifier: "naviastra-weather-segment-\(sample.index)", source: source)
            layer.predicate = NSPredicate(format: "sample == %d", sample.index)
            layer.lineColor = NSExpression(forConstantValue: color(sample.weather.condition.colorHex))
            layer.lineOpacity = NSExpression(forConstantValue: 0.20)
            layer.lineWidth = NSExpression(forConstantValue: 26)
            layer.lineBlur = NSExpression(forConstantValue: 5)
            layer.lineCap = NSExpression(forConstantValue: "round")
            insert(layer, into: style)
        }
    }
    private func insert(_ layer: MLNStyleLayer, into style: MLNStyle) {
        if let anchor = style.layers.first(where: {
            $0 is MLNSymbolStyleLayer || $0.identifier.hasPrefix("naviastra-active-route")
        }) { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
    }
    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#elseif os(macOS)
import AppKit
import MapKit

private final class WeatherTintOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
}
private final class WeatherTintRenderer: MKOverlayRenderer {
    var tint = NSColor.clear
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setFillColor(tint.cgColor)
        context.fill(rect(for: mapRect))
    }
}
@MainActor final class WeatherMapRenderer {
    private let tint = WeatherTintOverlay()
    private var tintRenderer: WeatherTintRenderer?
    private var configuration = WeatherVisualConfiguration()
    private var lastSamples: [RouteWeatherSample] = []
    private var lines: [(MKPolyline, UInt32)] = []

    func update(map: MKMapView, configuration: WeatherVisualConfiguration, samples: [RouteWeatherSample]) {
        if !map.overlays.contains(where: { $0 === tint }) { map.insertOverlay(tint, at: 0, level: .aboveRoads) }
        if self.configuration != configuration {
            self.configuration = configuration
            tintRenderer?.tint = color(configuration.tintHex, alpha: configuration.tintOpacity)
            tintRenderer?.setNeedsDisplay()
        }
        guard samples != lastSamples else { return }
        lastSamples = samples
        map.removeOverlays(lines.map { $0.0 }); lines = []
        for sample in samples {
            let coordinates = sample.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            lines.append((line, sample.weather.condition.colorHex))
            map.insertOverlay(line, at: 1, level: .aboveRoads)
        }
    }
    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        if overlay === tint {
            let renderer = WeatherTintRenderer(overlay: overlay)
            renderer.tint = color(configuration.tintHex, alpha: configuration.tintOpacity)
            tintRenderer = renderer
            return renderer
        }
        guard let item = lines.first(where: { $0.0 === overlay }) else { return nil }
        let renderer = MKPolylineRenderer(polyline: item.0)
        renderer.strokeColor = color(item.1, alpha: 0.20)
        renderer.lineWidth = 26; renderer.lineCap = .round; renderer.lineJoin = .round
        return renderer
    }
    private func color(_ hex: UInt32, alpha: Double) -> NSColor {
        NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}
#endif
