#if os(macOS)
import AppKit
import Foundation
import MapKit

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

/// Owns MapKit annotations and marker presentation for transit stops.
final class MacTransitStopRenderer {
    private var pins: [String: MKPointAnnotation] = [:]
    private var stopsByID: [String: TransitStop] = [:]
    private var markerStates: [String: TransitStopMapPresentation] = [:]
    private var lastRenderKey: TransitStopRenderKey?

    var annotations: [MKPointAnnotation] { Array(pins.values) }

    func update(on map: MKMapView, parent: MapLibreView, showsOnlyRouteEndpoints: Bool) {
        let zoom = log2(360 / max(0.00001, map.region.span.longitudeDelta))
        let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
        let routeStopIDs = transitRouteStopIDs(parent: parent)
        let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
        let isTransitRoutePreview = parent.state.transportMode == .transit
            && (parent.state.status == .destinationPreview || parent.state.status == .routeCalculating
                || parent.state.status == .routePreview)
        let isPlanningCarRoute = parent.state.transportMode == .car
            && (parent.state.status == .destinationPreview || parent.state.status == .routeCalculating
                || parent.state.status == .routePreview)
        let visibleRadius = transitVisibleRadius(on: map, center: center)
        let visibleStopCount = parent.transitStops.reduce(into: 0) { count, stop in
            if center.distance(to: stop.coordinate) <= visibleRadius { count += 1 }
        }
        let routeEndpointCoordinates = transitRouteEndpointCoordinates(parent: parent)
        let renderKey = TransitStopRenderKey(center: center, zoom: zoom,
                                              selectedStopID: parent.selectedTransitStopID,
                                              activeStopID: parent.activeTransitStopID,
                                              alightingStopID: parent.alightingTransitStopID,
                                              selectedRouteID: parent.selectedTransitRouteID,
                                              selectedTripStopIDs: parent.selectedTransitTripStopIDs,
                                              transitStopCount: parent.transitStops.count,
                                              showsOnlyRouteEndpoints: showsOnlyRouteEndpoints,
                                              displayContext: parent.settings.context,
                                              transportMode: parent.state.transportMode,
                                              isPlanningCarRoute: isPlanningCarRoute,
                                              isNavigating: isNavigating,
                                              isTransitRoutePreview: isTransitRoutePreview,
                                              routeStopIDs: routeStopIDs,
                                              userCoordinate: parent.state.location?.coordinate,
                                              routeEndpointCoordinates: routeEndpointCoordinates,
                                              visibleRadius: visibleRadius)
        guard lastRenderKey != renderKey else { return }
        lastRenderKey = renderKey

        let visibility = TransitStopMapVisibilityPolicy(zoom: zoom,
                                                        transportMode: parent.state.transportMode,
                                                        isPlanningCarRoute: isPlanningCarRoute,
                                                        isNavigating: isNavigating,
                                                        isTransitRoutePreview: isTransitRoutePreview,
                                                        visibleStopCount: visibleStopCount,
                                                        visibleRadius: visibleRadius,
                                                        mapCenter: center,
                                                        userCoordinate: parent.state.location?.coordinate,
                                                        routeEndpointCoordinates: routeEndpointCoordinates,
                                                        routeStopIDs: routeStopIDs)
        let candidates = parent.transitStops.compactMap { stop -> (TransitStop, Double, TransitStopMapVisibilityDecision)? in
            let distance = center.distance(to: stop.coordinate)
            guard let decision = visibility.decision(for: stop,
                                                     selectedStopID: parent.selectedTransitStopID,
                                                     activeStopID: parent.activeTransitStopID,
                                                     alightingStopID: parent.alightingTransitStopID) else { return nil }
            return (stop, distance, decision)
        }
        let decisionsByID = Dictionary(candidates.map { ($0.0.id, $0.2) }, uniquingKeysWith: { first, _ in first })
        let groupedCandidates = TransitStop.mapGroups(from: candidates.map(\.0))
        let groupedStops = groupedCandidates.compactMap { group -> (TransitStop, Double, Bool, Double)? in
            guard let nearest = group.min(by: { center.distance(to: $0.coordinate) < center.distance(to: $1.coordinate) }) else {
                return nil
            }
            let highlighted = group.first { $0.id == parent.alightingTransitStopID }
                ?? group.first { $0.id == parent.activeTransitStopID }
                ?? group.first { $0.id == parent.selectedTransitStopID }
            let representative = highlighted ?? nearest
            let groupedStop = representative.mapGroup(members: group)
            let groupDecisions = group.compactMap { decisionsByID[$0.id] }
            return (groupedStop, center.distance(to: groupedStop.coordinate),
                    groupDecisions.contains(where: \.isOnRoute), groupDecisions.map(\.opacity).max() ?? 1)
        }.sorted { $0.1 < $1.1 }.prefix(500)
        let groupDecisionsByID = Dictionary(groupedStops.map {
            ($0.0.id, TransitStopMapVisibilityDecision(isOnRoute: $0.2, opacity: $0.3))
        }, uniquingKeysWith: { first, _ in first })
        let stops = groupedStops.map(\.0)
        let byID = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let removedIDs = pins.keys.filter { byID[$0] == nil }
        let removedPins = removedIDs.compactMap { pins.removeValue(forKey: $0) }
        removedIDs.forEach { stopsByID.removeValue(forKey: $0) }
        removedIDs.forEach { markerStates.removeValue(forKey: $0) }
        if !removedPins.isEmpty { map.removeAnnotations(removedPins) }
        for stop in byID.values {
            stopsByID[stop.id] = stop
            let memberIDs = Set(stop.detailStopIDs)
            let decision = groupDecisionsByID[stop.id]
            let presentation = stop.mapPresentation(zoom: zoom,
                                                    selected: parent.selectedTransitStopID.map(memberIDs.contains) ?? false,
                                                    active: parent.activeTransitStopID.map(memberIDs.contains) ?? false,
                                                    alighting: parent.alightingTransitStopID.map(memberIDs.contains) ?? false,
                                                    onRoute: decision?.isOnRoute ?? false,
                                                    opacity: decision?.opacity ?? 1)
            let subtitle = stop.lines.prefix(5).joined(separator: " · ")
            if let pin = pins[stop.id] {
                if pin.coordinate.latitude != stop.coordinate.latitude || pin.coordinate.longitude != stop.coordinate.longitude {
                    pin.coordinate = stop.coordinate.cl
                }
                if pin.title != stop.name { pin.title = stop.name }
                if pin.subtitle != subtitle { pin.subtitle = subtitle }
                if let marker = map.view(for: pin) as? TransitStopMapAnnotationView,
                   markerStates[stop.id] != presentation {
                    marker.render(presentation)
                }
            } else {
                let pin = MKPointAnnotation()
                pin.coordinate = stop.coordinate.cl
                pin.title = stop.name
                pin.subtitle = subtitle
                pins[stop.id] = pin
                map.addAnnotation(pin)
            }
            markerStates[stop.id] = presentation
        }
    }

    func stop(for annotation: MKAnnotation) -> TransitStop? {
        guard let (stopID, _) = pins.first(where: { $0.value === annotation }) else { return nil }
        return stopsByID[stopID]
    }

    func annotationView(for annotation: MKAnnotation, map: MKMapView) -> MKAnnotationView? {
        guard let (stopID, _) = pins.first(where: { $0.value === annotation }),
              let stop = stopsByID[stopID] else { return nil }
        let marker = TransitStopMapAnnotationView(annotation: annotation,
                                                  reuseIdentifier: "transit-stop-\(stopID)")
        marker.render(markerStates[stopID] ?? stop.mapPresentation(
            zoom: log2(360 / max(0.00001, map.region.span.longitudeDelta)),
            selected: false, active: false, alighting: false))
        marker.canShowCallout = true
        marker.displayPriority = .defaultHigh
        return marker
    }

    private func transitRouteStopIDs(parent: MapLibreView) -> Set<String> {
        let journeyStopIDs = parent.state.route?.journey?.legs.reduce(into: Set<String>()) { result, leg in
            result.formUnion(leg.transitStops.map(\.stopID))
        } ?? []
        return journeyStopIDs.union(parent.selectedTransitTripStopIDs)
    }

    private func transitRouteEndpointCoordinates(parent: MapLibreView) -> [Coordinate] {
        if let coordinates = parent.state.route?.coordinates, !coordinates.isEmpty {
            return [coordinates[0], coordinates[coordinates.count - 1]]
        }
        return [parent.state.location?.coordinate, parent.state.destination?.coordinate].compactMap { $0 }
    }

    private func transitVisibleRadius(on map: MKMapView, center: Coordinate) -> Double {
        let bounds = map.bounds
        let corners = [
            NSPoint(x: bounds.minX, y: bounds.minY),
            NSPoint(x: bounds.maxX, y: bounds.minY),
            NSPoint(x: bounds.minX, y: bounds.maxY),
            NSPoint(x: bounds.maxX, y: bounds.maxY)
        ]
        let radius = corners.map { point -> Double in
            let coordinate = map.convert(point, toCoordinateFrom: map)
            return center.distance(to: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }.max() ?? 0
        return max(100, radius)
    }
}
#endif
