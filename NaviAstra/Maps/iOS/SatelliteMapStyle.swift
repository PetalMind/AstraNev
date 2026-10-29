#if os(iOS)
import Foundation
import MapLibre
import Network
import OSLog
import UIKit

/// Public imagery services, with no account or API key. Only the 2016 EOX
/// mosaic is CC BY 4.0; newer mosaics require a commercial licence.
@MainActor
final class SatelliteMapStyle {
    private static let prefix = SatelliteTileRecovery.sourcePrefix
    private var standardVisibility: [String: Bool] = [:]
    private var standardLabels: [String: (NSExpression?, NSExpression?, NSExpression?)] = [:]
    private var applied: Bool?
    private var recovery = SatelliteTileRecovery()
    private weak var recoveryMap: MLNMapView?
    private var recoveryEnabled = false
    private var recoveryIsActive = false
    private var recoveryTask: Task<Void, Never>?
    private var scheduledRetry: Date?
    private var networkMonitor: NWPathMonitor?
    private var monitorID = UUID()
    private var networkAvailable = true
    private let logger = Logger(subsystem: "NaviAstra", category: "SatelliteRecovery")

    static let description = "W Polsce zdjęcia lotnicze GUGiK, a na świecie zdjęcia Sentinel‑2 z 2016 roku. Poza pokryciem GUGiK szczegóły są ograniczone do około 10 m. Zdjęcia wymagają internetu i nie są częścią pobieranych map offline."
    static let eoxCredit = "EOxCloudless · EOX IT Services GmbH · zmodyfikowane dane Copernicus Sentinel 2016"
    static let eoxURL = URL(string: "https://cloudless.eox.at")!
    static let eoxMapsURL = URL(string: "https://maps.eox.at")!
    static let eoxLicenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    static let gugikURL = URL(string: "https://www.geoportal.gov.pl/pl/dane/ortofotomapa-orto/")!

    /// Restore before the standard style updates its visibility and label colors.
    /// Navigation, traffic, weather and transit layers are never included here.
    func restoreStandard(in style: MLNStyle) {
        applied = nil
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
        guard enabled != applied else { return }
        if enabled { install(in: style) }
        for layer in style.layers where layer.identifier.hasPrefix(Self.prefix) {
            layer.isVisible = enabled
        }
        applied = enabled
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

    func updateRecovery(on map: MLNMapView, enabled: Bool, renderingEnabled: Bool) {
        recoveryMap = map
        recoveryEnabled = enabled
        if !enabled { recovery.resetFailures() }
        let active = enabled && renderingEnabled
        guard recoveryIsActive != active else { return }
        recoveryIsActive = active
        if active {
            recovery.retryPendingNow(.now)
            startNetworkMonitor()
            scheduleRecovery()
        } else { stopRecovery() }
    }

    func tileOperation(_ operation: MLNTileOperation, sourceID: String, tile: SatelliteTileAddress) {
        guard recoveryEnabled else { return }
        if operation == .error { recovery.failed(sourceID: sourceID, tile: tile, now: .now) }
        else if operation == .endParse { recovery.succeeded(sourceID: sourceID, tile: tile) }
        else { return }
        scheduleRecovery()
    }

    func stopRecovery() {
        recoveryIsActive = false
        recoveryTask?.cancel()
        recoveryTask = nil
        scheduledRetry = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        monitorID = UUID()
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        let id = UUID()
        monitorID = id
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.monitorID == id, self.recoveryIsActive else { return }
                let restored = available && !self.networkAvailable
                self.networkAvailable = available
                if restored { self.recovery.retryPendingNow(.now) }
                self.scheduleRecovery()
            }
        }
        monitor.start(queue: DispatchQueue(label: "NaviAstra.SatelliteRecovery"))
    }

    private func scheduleRecovery() {
        guard recoveryIsActive, networkAvailable, let deadline = recovery.nextRetry else {
            recoveryTask?.cancel()
            recoveryTask = nil
            scheduledRetry = nil
            return
        }
        guard scheduledRetry != deadline else { return }
        recoveryTask?.cancel()
        scheduledRetry = deadline
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, let self, self.recoveryIsActive,
                  let style = self.recoveryMap?.style else { return }
            self.recoveryTask = nil
            self.scheduledRetry = nil
            for attempt in self.recovery.takeDueAttempts(now: .now) {
                let layers = style.layers
                let layerIndex = layers.firstIndex { $0.identifier == attempt.previousIdentifier + "-image" }
                let nextLayer = layerIndex.flatMap { index in
                    layers.indices.contains(index + 1) ? layers[index + 1] : nil
                }
                if let layer = style.layer(withIdentifier: attempt.previousIdentifier + "-image") {
                    style.removeLayer(layer)
                }
                if let source = style.source(withIdentifier: attempt.previousIdentifier) {
                    style.removeSource(source)
                }
                self.install(attempt.source, in: style, preservingAnchor: nextLayer)
                // Do not log tile coordinates, imagery URLs or the user's location.
                self.logger.info("Retrying failed satellite source: \(attempt.source.rawValue, privacy: .public)")
            }
            self.scheduleRecovery()
        }
    }

    private func install(in style: MLNStyle) {
        for source in SatelliteRasterSource.allCases { install(source, in: style) }
    }

    private func install(_ kind: SatelliteRasterSource, in style: MLNStyle,
                         preservingAnchor: MLNStyleLayer? = nil) {
        let identifier = recovery.identifier(for: kind)
        guard style.source(withIdentifier: identifier) == nil else { return }
        // Rebuilt world imagery must stay below the Polish overlay, including
        // when its old source and layer have just been removed.
        let defaultAnchor = kind == .world
            ? style.layer(withIdentifier: recovery.identifier(for: .poland) + "-image")
                ?? style.layers.first { $0 is MLNSymbolStyleLayer }
            : style.layers.first { $0 is MLNSymbolStyleLayer }
        // Traffic and weather may have been inserted above this imagery after
        // the style loaded. Keep their existing order when replacing the source.
        let anchor = preservingAnchor ?? defaultAnchor
        if kind == .world {
            let template = "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg"
            let world = MLNRasterTileSource(identifier: identifier, tileURLTemplates: [template],
                options: [.tileSize: 256, .minimumZoomLevel: 0, .maximumZoomLevel: 14,
                    .attributionHTMLString: "<a href='https://cloudless.eox.at'>EOxCloudless</a> by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016) · <a href='https://creativecommons.org/licenses/by/4.0/'>CC BY 4.0</a>"])
            insert(world, into: style, below: anchor)
            return
        }
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: 48.8, longitude: 13.8),
                                         ne: CLLocationCoordinate2D(latitude: 55, longitude: 24.4))
        // WMS PNG keeps areas without Polish imagery transparent. JPEG WMTS
        // tiles would obscure the global mosaic along the border and coverage gaps.
        // A 1024 px image for a 512 pt tile supplies Retina detail with four times
        // fewer requests than 256 pt tiles. WMS renders from the original imagery.
        // One lossless tile: fetch standard imagery only where the high-resolution
        // response has transparent gaps. Avoid downloading a fully hidden image.
        let source = MLNRasterTileSource(identifier: identifier,
                tileURLTemplates: [SatelliteTileKey.template], options: [
                    .tileSize: 512, .minimumZoomLevel: 12, .maximumZoomLevel: 20,
                    .coordinateBounds: NSValue(mlnCoordinateBounds: bounds),
                    .attributionHTMLString: "<a href='https://www.geoportal.gov.pl/pl/dane/ortofotomapa-orto/'>Ortofotomapa · GUGiK</a>"
                ])
        insert(source, into: style, below: anchor, minimumZoom: 12)
    }

    private func insert(_ source: MLNRasterTileSource, into style: MLNStyle,
                        below anchor: MLNStyleLayer?, minimumZoom: Float = 0) {
        style.addSource(source)
        let layer = MLNRasterStyleLayer(identifier: source.identifier + "-image", source: source)
        layer.minimumZoomLevel = minimumZoom
        // Show the detailed tile as soon as it arrives, without blending it with
        // a stretched parent tile while the navigation camera keeps moving.
        layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
        if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
    }
}
#endif
