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
        guard lastRenderKey != renderKey else { return }
        lastRenderKey = renderKey

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
        let removedIDs = pins.keys.filter { stopsByID[$0] == nil }
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
