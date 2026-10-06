#if os(iOS)
import Foundation
import MapLibre
import QuartzCore
import UIKit

struct TransitStopLayerRenderContext {
    let selectedStopID: String?
    let activeStopID: String?
    let alightingStopID: String?
    let selectedRouteID: String?
    let selectedTripStopIDs: Set<String>
    let showsOnlyRouteEndpoints: Bool
    let displayContext: MapDisplayContext
    let transportMode: TransportMode
    let isPlanningCarRoute: Bool
    let isNavigating: Bool
    let isTransitRoutePreview: Bool
    let routeStopIDs: Set<String>
    let userCoordinate: Coordinate?
    let routeEndpointCoordinates: [Coordinate]
}

@MainActor
final class TransitStopLayerRenderer {
    private var pins: [String: MLNPointAnnotation] = [:]
    private var stopsByID: [String: TransitStop] = [:]
    private var markerPresentations: [String: TransitStopMapPresentation] = [:]
    private var lastRenderKey: TransitStopRenderKey?
    private var lastStops: [TransitStop] = []
    private var lastDark = false
    private var lastVoiceOver = false
    private var spriteNames: Set<String> = []
    private let sourceID = "naviastra-transit-stops-source"
    private let layerIDs: Set<String> = ["naviastra-transit-stops", "naviastra-transit-clusters", "naviastra-transit-cluster-count"]

    var annotations: [MLNPointAnnotation] { Array(pins.values) }

    func update(on map: MLNMapView, stops: [TransitStop], context: TransitStopLayerRenderContext) {
        let zoom = map.zoomLevel
        let center = Coordinate(latitude: map.centerCoordinate.latitude,
                                longitude: map.centerCoordinate.longitude)
        let visibleRadius = visibleRadius(on: map, center: center)
        let visibleStopCount = stops.reduce(into: 0) { count, stop in
            if center.distance(to: stop.coordinate) <= visibleRadius { count += 1 }
        }
        let renderKey = TransitStopRenderKey(center: center, zoom: zoom,
                                             selectedStopID: context.selectedStopID,
                                             activeStopID: context.activeStopID,
                                             alightingStopID: context.alightingStopID,
                                             selectedRouteID: context.selectedRouteID,
                                             selectedTripStopIDs: context.selectedTripStopIDs,
                                             transitStopCount: stops.count,
                                             showsOnlyRouteEndpoints: context.showsOnlyRouteEndpoints,
                                             displayContext: context.displayContext,
                                             transportMode: context.transportMode,
                                             isPlanningCarRoute: context.isPlanningCarRoute,
                                             isNavigating: context.isNavigating,
                                             isTransitRoutePreview: context.isTransitRoutePreview,
                                             routeStopIDs: context.routeStopIDs,
                                             userCoordinate: context.userCoordinate,
                                             routeEndpointCoordinates: context.routeEndpointCoordinates,
                                             visibleRadius: visibleRadius)
        let dark = map.traitCollection.userInterfaceStyle == .dark
        let voiceOver = UIAccessibility.isVoiceOverRunning
        guard lastRenderKey != renderKey || lastStops != stops || lastDark != dark || lastVoiceOver != voiceOver
                || map.style?.source(withIdentifier: sourceID) == nil else { return }
        lastRenderKey = renderKey
        lastStops = stops
        lastDark = dark
        lastVoiceOver = voiceOver

        let visibility = TransitStopMapVisibilityPolicy(zoom: zoom,
                                                        transportMode: context.transportMode,
                                                        isPlanningCarRoute: context.isPlanningCarRoute,
                                                        isNavigating: context.isNavigating,
                                                        isTransitRoutePreview: context.isTransitRoutePreview,
                                                        visibleStopCount: visibleStopCount,
                                                        visibleRadius: visibleRadius,
                                                        mapCenter: center,
                                                        userCoordinate: context.userCoordinate,
                                                        routeEndpointCoordinates: context.routeEndpointCoordinates,
                                                        routeStopIDs: context.routeStopIDs)
        let candidates = stops.compactMap { stop -> (TransitStop, Double, TransitStopMapVisibilityDecision)? in
            let distance = center.distance(to: stop.coordinate)
            guard let decision = visibility.decision(for: stop,
                                                     selectedStopID: context.selectedStopID,
                                                     activeStopID: context.activeStopID,
                                                     alightingStopID: context.alightingStopID) else { return nil }
            return (stop, distance, decision)
        }
        let decisionsByID = Dictionary(candidates.map { ($0.0.id, $0.2) },
                                       uniquingKeysWith: { first, _ in first })
        let groupedCandidates = TransitStop.mapGroups(from: candidates.map(\.0))
        let groupedStops = groupedCandidates.compactMap { group -> (TransitStop, Double, Bool, Double)? in
            guard let nearest = group.min(by: { center.distance(to: $0.coordinate) < center.distance(to: $1.coordinate) }) else {
                return nil
            }
            let highlighted = group.first { $0.id == context.alightingStopID }
                ?? group.first { $0.id == context.activeStopID }
                ?? group.first { $0.id == context.selectedStopID }
            let representative = highlighted ?? nearest
            let groupedStop = representative.mapGroup(members: group)
            let groupDecisions = group.compactMap { decisionsByID[$0.id] }
            let isOnRoute = groupDecisions.contains(where: \.isOnRoute)
            let opacity = groupDecisions.map(\.opacity).max() ?? 1
            return (groupedStop, center.distance(to: groupedStop.coordinate), isOnRoute, opacity)
        }.sorted { $0.1 < $1.1 }.prefix(500)
        let groupDecisionsByID = Dictionary(groupedStops.map {
            ($0.0.id, TransitStopMapVisibilityDecision(isOnRoute: $0.2, opacity: $0.3))
        }, uniquingKeysWith: { first, _ in first })
        let visibleStops = groupedStops.map(\.0)
        let stopsByID = Dictionary(visibleStops.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var layeredFeatures: [MLNPointFeature] = []
        var annotationIDs: Set<String> = []
        // Keep important route stops and VoiceOver elements as accessible native views.
        for stop in stopsByID.values {
            let members = Set(stop.detailStopIDs)
            if voiceOver || (context.selectedStopID.map(members.contains) ?? false)
                || (context.activeStopID.map(members.contains) ?? false)
                || (context.alightingStopID.map(members.contains) ?? false)
                || groupDecisionsByID[stop.id]?.isOnRoute == true {
                annotationIDs.insert(stop.id)
            }
        }
        let removedIDs = pins.keys.filter { !annotationIDs.contains($0) }
        let removedPins = removedIDs.compactMap { pins.removeValue(forKey: $0) }
        removedIDs.forEach { self.stopsByID.removeValue(forKey: $0) }
        removedIDs.forEach { markerPresentations.removeValue(forKey: $0) }
        if !removedPins.isEmpty { map.removeAnnotations(removedPins) }

        for stop in stopsByID.values {
            self.stopsByID[stop.id] = stop
            let memberIDs = Set(stop.detailStopIDs)
            let decision = groupDecisionsByID[stop.id]
            let presentation = stop.mapPresentation(zoom: zoom,
                                                    selected: context.selectedStopID.map(memberIDs.contains) ?? false,
                                                    active: context.activeStopID.map(memberIDs.contains) ?? false,
                                                    alighting: context.alightingStopID.map(memberIDs.contains) ?? false,
                                                    onRoute: decision?.isOnRoute ?? false,
                                                    opacity: decision?.opacity ?? 1)
            if !annotationIDs.contains(stop.id) {
                markerPresentations[stop.id] = presentation
                let feature = MLNPointFeature()
                feature.coordinate = stop.coordinate.cl
                feature.attributes = ["stopID": stop.id, "name": presentation.name ?? "",
                    "sprite": spriteName(for: presentation, on: map), "opacity": presentation.opacity]
                layeredFeatures.append(feature)
                continue
            }
            if let pin = pins[stop.id] {
                if pin.coordinate.latitude != stop.coordinate.latitude || pin.coordinate.longitude != stop.coordinate.longitude {
                    pin.coordinate = stop.coordinate.cl
                }
                if pin.title != stop.name { pin.title = stop.name }
                let subtitle = stop.lines.prefix(5).joined(separator: " · ")
                if pin.subtitle != subtitle { pin.subtitle = subtitle }
                if let marker = map.view(for: pin), markerPresentations[stop.id] != presentation {
                    style(marker, presentation: presentation)
                }
            } else {
                let pin = MLNPointAnnotation()
                pin.coordinate = stop.coordinate.cl
                pin.title = stop.name
                pin.subtitle = stop.lines.prefix(5).joined(separator: " · ")
                pins[stop.id] = pin
                markerPresentations[stop.id] = presentation
                map.addAnnotation(pin)
            }
            markerPresentations[stop.id] = presentation
        }
        self.stopsByID = stopsByID
        updateLayers(features: layeredFeatures, on: map)
    }

    /// Returns true when a layer handled the tap, including expansion of a cluster.
    func handleTap(at point: CGPoint, on map: MLNMapView,
                   onExpandCluster: () -> Void, onSelect: (TransitStop) -> Void) -> Bool {
        let rect = CGRect(origin: point, size: .zero).insetBy(dx: -18, dy: -18)
        let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: layerIDs)
        // Prefer an actual stop over a cluster whose icon merely overlaps the touch area.
        if let stop = features.compactMap({ feature -> TransitStop? in
            guard let id = feature.attributes["stopID"] as? String else { return nil }
            return stopsByID[id]
        }).min(by: { lhs, rhs in
            let a = map.convert(lhs.coordinate.cl, toPointTo: map)
            let b = map.convert(rhs.coordinate.cl, toPointTo: map)
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }) {
            onSelect(stop)
            return true
        }
        if let cluster = features.compactMap({ $0 as? MLNPointFeatureCluster }).first,
           let source = map.style?.source(withIdentifier: sourceID) as? MLNShapeSource {
            onExpandCluster()
            map.setCenter(cluster.coordinate, zoomLevel: min(18, source.zoomLevel(forExpanding: cluster) + 0.1), animated: true)
            return true
        }
        return false
    }

    private func spriteName(for presentation: TransitStopMapPresentation, on map: MLNMapView) -> String {
        let modes = presentation.modes.map(\.rawValue).joined(separator: "-")
        let name = "naviastra-transit-icon-\(modes)-\(Int(presentation.markerSize))-\(lastDark)"
        guard let style = map.style else { return name }
        // A newly loaded style has no source or sprites, even if the SDK wrapper is reused.
        if style.image(forName: name) == nil {
            let plain = TransitStopMapPresentation(modes: presentation.modes, name: nil,
                markerSize: presentation.markerSize, isSelected: false, isActive: false,
                isAlighting: false, isOnRoute: false, opacity: 1, showsAlightingBadge: false)
            let marker = MLNAnnotationView(reuseIdentifier: nil)
            marker.overrideUserInterfaceStyle = lastDark ? .dark : .light
            self.style(marker, presentation: plain)
            let size = CGSize(width: marker.bounds.width + 8, height: marker.bounds.height + 8)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.translateBy(x: 4, y: 4)
                marker.layer.render(in: context.cgContext)
            }
            style.setImage(image, forName: name)
            spriteNames.insert(name)
        }
        return name
    }

    private func updateLayers(features: [MLNPointFeature], on map: MLNMapView) {
        guard let style = map.style else { return }
        let source: MLNShapeSource
        if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource { source = existing }
        else {
            source = MLNShapeSource(identifier: sourceID, shape: nil,
                options: [.clustered: true, .clusterRadius: 44, .maximumZoomLevelForClustering: 14])
            style.addSource(source)
        }
        source.shape = MLNShapeCollectionFeature(shapes: features)
        if style.layer(withIdentifier: "naviastra-transit-stops") == nil {
            let symbols = MLNSymbolStyleLayer(identifier: "naviastra-transit-stops", source: source)
            symbols.predicate = NSPredicate(format: "cluster != YES")
            symbols.iconImageName = NSExpression(forKeyPath: "sprite")
            symbols.iconOpacity = NSExpression(forKeyPath: "opacity")
            symbols.iconAllowsOverlap = NSExpression(forConstantValue: true)
            symbols.text = NSExpression(forKeyPath: "name")
            symbols.textOpacity = NSExpression(forKeyPath: "opacity")
            symbols.textFontSize = NSExpression(forConstantValue: 10)
            symbols.textOffset = NSExpression(forConstantValue: [0, 1.8])
            symbols.textAnchor = NSExpression(forConstantValue: "top")
            style.addLayer(symbols)
            let clusters = MLNCircleStyleLayer(identifier: "naviastra-transit-clusters", source: source)
            clusters.predicate = NSPredicate(format: "cluster == YES")
            clusters.circleRadius = NSExpression(forConstantValue: 18)
            clusters.circleColor = NSExpression(forConstantValue: UIColor(naviHex: NaviAstraColorPalette.transitFallback))
            clusters.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            clusters.circleStrokeWidth = NSExpression(forConstantValue: 2)
            style.addLayer(clusters)
            let count = MLNSymbolStyleLayer(identifier: "naviastra-transit-cluster-count", source: source)
            count.predicate = NSPredicate(format: "cluster == YES")
            count.text = NSExpression(mglJSONObject: ["to-string", ["get", "point_count"]])
            count.textFontSize = NSExpression(forConstantValue: 12)
            count.textColor = NSExpression(forConstantValue: UIColor.white)
            count.textAllowsOverlap = NSExpression(forConstantValue: true)
            style.addLayer(count)
        }
        if let symbols = style.layer(withIdentifier: "naviastra-transit-stops") as? MLNSymbolStyleLayer {
            symbols.textColor = NSExpression(forConstantValue: lastDark ? UIColor.white : UIColor.black)
            symbols.textHaloColor = NSExpression(forConstantValue: lastDark ? UIColor.black : UIColor.white)
            symbols.textHaloWidth = NSExpression(forConstantValue: 1.5)
        }
        // Bound sprite lifetime to variants still present in the source.
        let used = Set(features.compactMap { $0.attributes["sprite"] as? String })
        for name in spriteNames.subtracting(used) { style.removeImage(forName: name) }
        spriteNames = used
    }

    func stop(for annotation: MLNAnnotation) -> TransitStop? {
        guard let (stopID, _) = pins.first(where: { $0.value === annotation }) else { return nil }
        return stopsByID[stopID]
    }

    func annotationView(for annotation: MLNAnnotation, on map: MLNMapView) -> MLNAnnotationView? {
        guard let (stopID, _) = pins.first(where: { $0.value === annotation }) else { return nil }
        let marker = MLNAnnotationView(reuseIdentifier: "transit-stop-\(stopID)")
        guard let stop = stopsByID[stopID] else { return marker }
        let presentation = markerPresentations[stopID] ?? stop.mapPresentation(
            zoom: map.zoomLevel, selected: false, active: false, alighting: false)
        style(marker, presentation: presentation)
        markerPresentations[stopID] = presentation
        return marker
    }

    func contains(_ annotation: MLNAnnotation) -> Bool {
        pins.values.contains { $0 === annotation }
    }

    private func visibleRadius(on map: MLNMapView, center: Coordinate) -> Double {
        let bounds = map.bounds
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        ]
        let radius = corners.map { point -> Double in
            let coordinate = map.convert(point, toCoordinateFrom: map)
            return center.distance(to: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }.max() ?? 0
        return max(100, radius)
    }

    private func style(_ marker: MLNAnnotationView, presentation: TransitStopMapPresentation) {
        marker.subviews.forEach { $0.removeFromSuperview() }
        let iconWidth: CGFloat = presentation.modes.count > 1
            ? CGFloat(presentation.modes.count) * 15 + 12 : CGFloat(presentation.markerSize)
        let iconHeight = CGFloat(presentation.markerSize)
        let titleHeight: CGFloat = presentation.name == nil ? 0 : 16
        let badgeHeight: CGFloat = presentation.showsAlightingBadge ? 17 : 0
        let nameWidth = presentation.name.map { CGFloat(min(170, max(60, $0.count * 7))) } ?? 0
        let contentWidth = max(iconWidth, nameWidth)
        marker.frame = CGRect(x: 0, y: 0, width: contentWidth,
                              height: iconHeight + titleHeight + badgeHeight
                                + (titleHeight > 0 || badgeHeight > 0 ? 3 : 0))
        marker.centerOffset = CGVector(dx: 0, dy: (titleHeight + badgeHeight) / 2)
        marker.backgroundColor = .clear
        marker.layer.cornerRadius = 0
        marker.layer.borderWidth = 0
        marker.layer.shadowOpacity = 0

        let capsule = UIView(frame: CGRect(x: (contentWidth - iconWidth) / 2, y: 0,
                                           width: iconWidth, height: iconHeight))
        capsule.backgroundColor = .secondarySystemBackground
        capsule.layer.cornerRadius = presentation.isMultimodal || presentation.modes.contains(.rail)
            ? iconHeight / 2 : 8
        capsule.layer.borderWidth = presentation.isActive || presentation.isAlighting ? 3
            : presentation.isSelected || presentation.isOnRoute ? 2.5 : 1.5
        let brand = UIColor(named: "AccentColor")
            ?? UIColor(naviHex: NaviAstraColorPalette.brandPrimaryDay)
        let route = UIColor(naviHex: NaviAstraColorPalette.navigationActiveDay)
        let accent = presentation.isAlighting ? brand
            : presentation.isActive ? route
            : presentation.isSelected ? brand
            : presentation.isOnRoute ? route
            : markerColor(for: presentation.modes.first)
        capsule.layer.borderColor = accent.cgColor
        capsule.layer.shadowColor = UIColor.black.cgColor
        capsule.layer.shadowOpacity = 0.24
        capsule.layer.shadowRadius = 3
        marker.alpha = CGFloat(presentation.opacity)
        if presentation.isActive && !presentation.isAlighting {
            let pulse = CABasicAnimation(keyPath: "shadowRadius")
            pulse.fromValue = 2.5
            pulse.toValue = 5
            pulse.duration = 1.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            capsule.layer.add(pulse, forKey: "transit-active-stop-pulse")
        }
        marker.addSubview(capsule)

        let imageSize: CGFloat = presentation.modes.count > 1 ? 13 : min(19, iconHeight * 0.58)
        let spacing: CGFloat = 1
        let symbolsWidth = CGFloat(presentation.modes.count) * imageSize
            + CGFloat(max(0, presentation.modes.count - 1)) * spacing
        var x = (iconWidth - symbolsWidth) / 2
        for mode in presentation.modes {
            let image = UIImageView(image: UIImage(systemName: mode.symbolName))
            image.tintColor = markerColor(for: mode)
            image.contentMode = .scaleAspectFit
            image.frame = CGRect(x: x, y: (iconHeight - imageSize) / 2,
                                 width: imageSize, height: imageSize)
            capsule.addSubview(image)
            x += imageSize + spacing
        }

        var nextY = iconHeight + 2
        if presentation.showsAlightingBadge {
            let badge = UILabel(frame: CGRect(x: (contentWidth - 64) / 2, y: nextY, width: 64, height: 14))
            badge.text = "WYSIĄDŹ"
            badge.font = .systemFont(ofSize: 8, weight: .bold)
            badge.textAlignment = .center
            badge.textColor = .white
            badge.backgroundColor = UIColor(named: "AccentColor")
                ?? UIColor(naviHex: NaviAstraColorPalette.brandPrimaryDay)
            badge.layer.cornerRadius = 6
            badge.clipsToBounds = true
            marker.addSubview(badge)
            nextY += badgeHeight
        }
        if let name = presentation.name {
            let label = UILabel(frame: CGRect(x: 0, y: nextY, width: contentWidth, height: titleHeight))
            label.text = name
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .label
            label.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.94)
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.layer.cornerRadius = 5
            label.clipsToBounds = true
            marker.addSubview(label)
        }
        marker.isAccessibilityElement = true
        marker.accessibilityLabel = presentation.accessibilityLabel
    }

    private func markerColor(for mode: TransitStopMode?) -> UIColor {
        guard let mode else { return UIColor(naviHex: NaviAstraColorPalette.transitFallback) }
        return UIColor(red: CGFloat((mode.accentHex >> 16) & 0xff) / 255,
                       green: CGFloat((mode.accentHex >> 8) & 0xff) / 255,
                       blue: CGFloat(mode.accentHex & 0xff) / 255, alpha: 1)
    }
}

private struct TransitStopRenderKey: Equatable {
    let center: Coordinate
    let zoom: Double
    let selectedStopID: String?
    let activeStopID: String?
    let alightingStopID: String?
    let selectedRouteID: String?
    let selectedTripStopIDs: Set<String>
    let transitStopCount: Int
    let showsOnlyRouteEndpoints: Bool
    let displayContext: MapDisplayContext
    let transportMode: TransportMode
    let isPlanningCarRoute: Bool
    let isNavigating: Bool
    let isTransitRoutePreview: Bool
    let routeStopIDs: Set<String>
    let userCoordinate: Coordinate?
    let routeEndpointCoordinates: [Coordinate]
    let visibleRadius: Double
}
#endif
