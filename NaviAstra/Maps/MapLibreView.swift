#if os(iOS)
import Foundation
import MapLibre
import QuartzCore
import SwiftUI
import UIKit

private nonisolated enum RouteLineKind: Equatable {
    case activeCasing, active, activeHighlight, future, alternative, traveled, traffic, departed, accuracy
    case incidentCasing, incident(color: UInt32)
    case journeyCasing(walking: Bool, cycling: Bool)
    case journeyLeg(color: UInt32, walking: Bool, cycling: Bool)
}

private struct IncidentLineRenderItem: Equatable {
    let id: String
    let coordinates: [Coordinate]
    let colorHex: UInt32
}

private struct TrafficMapEvent {
    let id: String
    let coordinate: Coordinate
    let title: String
    let subtitle: String
    let categoryLabel: String
    let presentation: TrafficMapPresentation

    init(_ incident: TrafficIncident) {
        id = "incident:\(incident.id)"
        coordinate = incident.coordinate
        title = incident.mapTitle
        subtitle = incident.mapSubtitle
        categoryLabel = incident.category.mapLabel
        presentation = TrafficMapPresentation(incident)
    }

    init(_ alert: RoadSafetyAlert, routeDistance: Double) {
        id = "alert:\(alert.id)"
        coordinate = alert.coordinate
        title = alert.title
        subtitle = "\(alert.distanceText(from: routeDistance)) · © OpenStreetMap contributors"
        categoryLabel = alert.type.title
        presentation = TrafficMapPresentation(alert)
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
    let isNavigating: Bool
    let isTransitRoutePreview: Bool
    let routeStopIDs: Set<String>
    let userCoordinate: Coordinate?
    let routeEndpointCoordinates: [Coordinate]
    let visibleRadius: Double
}

struct MapLibreView: UIViewRepresentable {
    let state: NavigationState
    let transitVehicles: [TransitVehicle]
    let transitStops: [TransitStop]
    let selectedTransitStopID: String?
    let selectedTransitRouteID: String?
    let selectedTransitTripID: String?
    let selectedTransitTripStopIDs: Set<String>
    let activeTransitStopID: String?
    let alightingTransitStopID: String?
    let transitLineCoordinates: [Coordinate]
    let transitLineColor: UInt32?
    let settings: MapSettings
    let isSearchPresented: Bool
    let routePreviewExpanded: Bool
    let viewportPadding: CameraPadding
    let onSearchSelect: (Destination) -> Void
    let onPlaceSelect: ([SearchResult]) -> Void
    let onTransitStopSelect: (TransitStop) -> Void
    let onTransitVehicleSelect: (TransitVehicle) -> Void
    let onMapReady: () -> Void
    let onMapPan: () -> Void
    let onLongPress: (Coordinate) -> Void
    @Environment(\.colorScheme) private var colorScheme

    // One layer graph keeps the camera and annotations intact during day/night transitions.
    private var styleURL: URL { URL(string: "https://tiles.openfreemap.org/styles/liberty")! }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.automaticallyAdjustsContentInset = false
        map.delegate = context.coordinator
        map.setCenter(CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122), zoomLevel: 10, animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tappedPOI(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        tap.require(toFail: press)
        map.addGestureRecognizer(press)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        pinch.delegate = context.coordinator
        rotation.delegate = context.coordinator
        map.addGestureRecognizer(pinch)
        map.addGestureRecognizer(rotation)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        guard !isSearchPresented else { return }
        context.coordinator.update(map)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapLibreView
        weak var map: MLNMapView?
        private var routeLines: [StyledLine] = []
        private var incidentLinesByID: [String: [StyledLine]] = [:]
        private var incidentLineRenderItems: [IncidentLineRenderItem] = []
        private var activeRouteSource: MLNShapeSource?
        private var revealGeometry: RouteRevealGeometry?
        private var revealRouteID: UUID?
        private var activeRouteStyleKey = ""
        private var traveledLine: StyledLine?
        private var trafficLine: StyledLine?
        private var accuracyHaloLine: StyledLine?
        private var accuracyHaloCenter: Coordinate?
        private var accuracyHaloRadius: Double?
        private var destinationPin: MLNPointAnnotation?
        private var vehiclePin: MLNPointAnnotation?
        private weak var vehicleAnnotationView: MLNAnnotationView?
        private weak var vehicleArrow: UIImageView?
        private var destinationMarkerIsArrived: Bool?
        private var transitVehiclePins: [String: MLNPointAnnotation] = [:]
        private var transitStopPins: [String: MLNPointAnnotation] = [:]
        private var transitStopMapStops: [String: TransitStop] = [:]
        private var transitStopMarkerStates: [String: TransitStopMapPresentation] = [:]
        private var lastTransitStopRenderKey: TransitStopRenderKey?
        private var transitLine: MLNPolyline?
        private var shownTransitRouteID: String?
        private var shownTransitLineCoordinates: [Coordinate] = []
        private var closurePin: MLNPointAnnotation?
        private var searchPins: [MLNPointAnnotation] = []
        private var searchIDs: [UUID] = []
        private var trafficEventPins: [MLNPointAnnotation] = []
        private var shownTrafficEventGroupIDs: [String] = []
        private var shownTrafficEventGroups: [[TrafficMapEvent]] = []
        private var shownIncidents: [TrafficIncident] = []
        private var shownRoadAlerts: [RoadSafetyAlert] = []
        private var shownRouteIDs: [UUID]?
        private var shownActiveTargetID: UUID?
        private var shownRevealStep = 1_000
        private var traveledRouteID: UUID?
        private var traveledEnd: Coordinate?
        private var projectionRouteID: UUID?
        private var projectionLocation: Coordinate?
        private var cachedRouteProjection: RouteProjection?
        private var trafficCoordinates: [Coordinate]?
        private var trafficColorHex: UInt32?
        private var trafficRasterTemplate: String?
        private var trafficRasterVisible: Bool?
        private var lastStatus: NavigationStatus?
        private var lastColorScheme: ColorScheme?
        private var lastPOIMarkerDark: Bool?
        private var lastStyleURL: URL?
        private var lastViewportPadding: CameraPadding?
        private var lastMapSize: CGSize = .zero
        private var lastIntent: CameraIntent?
        private var lastCameraState: NavigationCameraState?
        private var lastCameraMode: MapDimension?
        private var lastCameraCommandID: Int?
        private var lastOverviewRouteID: UUID?
        private var lastRoutePreviewExpanded: Bool?
        private let navigationStyle = NaviAstraMapStyle()
        private weak var vehicleMarker: UIView?
        private var programmaticCamera = false
        private var routeTransitionTimer: Timer?
        private var transitAnnotationUpdateWorkItem: DispatchWorkItem?
        private var searchMapCenterWorkItem: DispatchWorkItem?

        init(_ parent: MapLibreView) {
            self.parent = parent
            lastStyleURL = parent.styleURL
        }

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            parent.onLongPress(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        @objc func tappedPOI(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map, let style = map.style else { return }
            let layerIDs = Set(style.layers.compactMap { layer -> String? in
                guard let symbolLayer = layer as? MLNSymbolStyleLayer,
                      symbolLayer.sourceLayerIdentifier == "poi" else { return nil }
                return symbolLayer.identifier
            })
            guard !layerIDs.isEmpty else { return }
            let point = recognizer.location(in: map)
            let touchRect = CGRect(origin: point, size: .zero).insetBy(dx: -22, dy: -22)
            let tappedCoordinate = map.convert(point, toCoordinateFrom: map)
            let tappedLocation = CLLocation(latitude: tappedCoordinate.latitude, longitude: tappedCoordinate.longitude)
            let appAnnotations = searchPins + trafficEventPins + Array(transitVehiclePins.values)
                + Array(transitStopPins.values) + [destinationPin, vehiclePin, closurePin].compactMap { $0 }
            guard !appAnnotations.contains(where: { annotation in
                let location = CLLocation(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude)
                return location.distance(from: tappedLocation) < 25
            }) else { return }
            var candidates: [String: (result: SearchResult, distance: CLLocationDistance)] = [:]
            for feature in map.visibleFeatures(in: touchRect, styleLayerIdentifiers: layerIDs).compactMap({ $0 as? MLNPointFeature }) {
                let attributes = feature.attributes
                let category = (attributes["subclass"] as? String) ?? (attributes["class"] as? String)
                guard let category, !category.isEmpty else { continue }
                let name = (attributes["name"] as? String) ?? feature.title ?? (attributes["brand"] as? String)
                guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let coordinate = Coordinate(latitude: feature.coordinate.latitude, longitude: feature.coordinate.longitude)
                let tileOSMID: String?
                if let value = attributes["osm_id"] as? NSNumber, value.int64Value != 0 {
                    tileOSMID = String(value.int64Value)
                } else if let value = attributes["osm_id"] as? String, Int64(value).map({ $0 != 0 }) == true {
                    tileOSMID = value
                } else {
                    tileOSMID = nil
                }
                let result = SearchResult(destination: Destination(name: name, coordinate: coordinate),
                                          street: nil, houseNumber: nil, city: nil, countryCode: nil,
                                          isPOI: true,
                                          osmID: tileOSMID,
                                          placeProvider: .openFreeMap,
                                          category: category,
                                          brand: attributes["brand"] as? String)
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let distance = location.distance(from: tappedLocation)
                let key = result.placeIdentity.cacheKey
                if candidates[key] == nil || distance < candidates[key]!.distance {
                    candidates[key] = (result, distance)
                }
            }
            let places = candidates.values.sorted { $0.distance < $1.distance }
                .prefix(5)
                .map { $0.result }
            if !places.isEmpty { parent.onPlaceSelect(places) }
        }

        @objc func userGesture(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began {
                programmaticCamera = false
                if gesture is UIPanGestureRecognizer { parent.onMapPan() }
                parent.state.cameraState = .freeLook
                parent.state.cameraIntent = nil
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            updatePOIDensity(on: mapView)
            applyCameraIntent(to: mapView)
            parent.onMapReady()
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            navigationStyle.reset()
            updatePOIDensity(on: mapView)
            activeRouteSource = nil
            activeRouteStyleKey = ""
            trafficRasterTemplate = nil
            trafficRasterVisible = nil
            updateTrafficRasterLayer(on: mapView)
            if let route = parent.state.route { updateActiveRouteShape(route, on: mapView) }
        }

        func update(_ map: MLNMapView) {
            let results = showsOnlyRouteEndpoints ? [] : Array(parent.state.searchResults.prefix(8))
            if searchIDs != results.map(\.id) {
                map.removeAnnotations(searchPins)
                searchIDs = results.map(\.id)
                searchPins = results.enumerated().map { index, result in
                    let pin = MLNPointAnnotation()
                    pin.coordinate = result.destination.coordinate.cl
                    pin.title = "\(index + 1). \(result.destination.name)"
                    pin.subtitle = result.destination.address
                    return pin
                }
                map.addAnnotations(searchPins)
            }

            let requestedStyleURL = parent.styleURL
            if lastStyleURL != requestedStyleURL {
                map.styleURL = requestedStyleURL
                lastStyleURL = requestedStyleURL
                navigationStyle.reset()
            }
            updatePOIDensity(on: map)
            updatePOIMarkerAppearance(on: map)
            let routes = parent.state.alternatives + (parent.state.route.map { [$0] } ?? [])
            let routeIDs = routes.map(\.id)
            let revealStep = Int((parent.state.routeRevealProgress * 1_000).rounded())
            let activeTargetID = parent.state.route.flatMap { activeRouteLegs(for: $0).targetID }
            let routesChanged = shownRouteIDs != routeIDs || shownActiveTargetID != activeTargetID
            let revealChanged = shownRevealStep != revealStep
            if routesChanged {
                let oldActiveID = shownRouteIDs?.last
                let animateSelection = lastStatus == .routePreview && parent.state.status == .routePreview &&
                    oldActiveID != parent.state.route?.id
                let animateReroute = lastStatus == .rerouting && parent.state.status == .navigating &&
                    oldActiveID != parent.state.route?.id
                let previousLines = routeLines
                let previousActive = previousLines.first(where: { $0.routeID == oldActiveID && $0.kind == .active })
                map.removeAnnotations(routeLines.map(\.polyline))
                routeLines.removeAll()
                activeRouteSource?.shape = nil
                revealGeometry = nil
                revealRouteID = nil
                for route in parent.state.alternatives {
                    let previousKind: RouteLineKind = route.id == oldActiveID ? .active : .alternative
                    let from = animateSelection ? previousStyle(for: route.id, kind: previousKind, in: previousLines) : nil
                    let dashPeriod = max(300, route.distance / 40)
                    let dashes = RouteMapGeometry.dashedSegments(route.coordinates,
                                                                 dashLength: max(180, dashPeriod * 0.6),
                                                                 gapLength: max(120, dashPeriod * 0.4))
                    for path in dashes {
                        addLine(path, kind: .alternative, routeID: route.id, transitionFrom: from, to: map)
                    }
                }
                if animateReroute, let previousActive {
                    let dark = parent.colorScheme == .dark
                    let fadedBlue = LineStyle(hex: dark ? RouteColorPalette.activeDark : RouteColorPalette.activeLight,
                                              opacity: 0.3, width: 11)
                    addLine(previousActive.coordinates, kind: .departed, transitionFrom: fadedBlue, to: map)
                }
                if let route = parent.state.route {
                    let previous = animateSelection
                        ? previousStyle(for: route.id, kind: .alternative, in: previousLines)
                        : nil
                    addActiveRoute(route, previousStyle: previous,
                                   animateSelection: animateSelection, animateReroute: animateReroute, to: map)
                }
                shownRouteIDs = routeIDs
                shownActiveTargetID = activeTargetID
                if animateSelection || animateReroute { animateRouteSelection(on: map, removeDeparted: animateReroute) }
            }
            if revealChanged {
                if !routesChanged {
                    if let route = parent.state.route { updateActiveRouteShape(route, on: map) }
                }
                shownRevealStep = revealStep
            }

            updateTraveledLine(on: map)
            updateTrafficLine(on: map)
            updateTrafficRasterLayer(on: map)
            if showsOnlyRouteEndpoints {
                removeClosurePin(from: map)
            } else {
                updateClosurePin(on: map)
            }
            updateAccuracyHalo(on: map)

            if let destination = parent.state.destination, parent.state.status != .idle {
                if destinationPin == nil {
                    let pin = MLNPointAnnotation(); pin.title = destination.name
                    destinationPin = pin; map.addAnnotation(pin)
                }
                destinationPin?.coordinate = destination.coordinate.cl
            } else if let pin = destinationPin { map.removeAnnotation(pin); destinationPin = nil }

            updateIncidentPins(on: map)
            updateIncidentLines(on: map)
            let routeDistance = parent.state.progress?.traveledDistance ?? 0
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let roadAlerts = ((!showsOnlyRouteEndpoints || isNavigating) ? parent.state.roadSafetyAlerts : [])
                .filter { alert in
                    guard let distance = alert.distanceAlongRoute else { return false }
                    return distance >= routeDistance - 60 && distance <= routeDistance + 20_000
                        && (!isNavigating || alert.type.isImportantDuringNavigation)
                }
                .sorted { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
                .prefix(40)
            shownRoadAlerts = Array(roadAlerts)
            updateTrafficEventPins(on: map, routeDistance: routeDistance)
            scheduleTransitAnnotationUpdate(on: map)
            updateSelectedTransitLine(on: map)

            if let location = (parent.state.weakGPS ? parent.state.cameraLocation : parent.state.location) {
                let isFollowingRoute = parent.state.status == .navigating || parent.state.status == .rerouting
                let coordinate: Coordinate
                if isFollowingRoute, let route = parent.state.route {
                    coordinate = projection(for: location.coordinate, on: route)?.coordinate ?? location.coordinate
                } else {
                    coordinate = location.coordinate
                }
                if vehiclePin == nil {
                    let pin = MLNPointAnnotation(); pin.title = "Twoja pozycja"
                    vehiclePin = pin; map.addAnnotation(pin)
                }
                vehiclePin?.coordinate = coordinate.cl
            }
            if let marker = vehicleMarker {
                marker.layer.borderColor = parent.state.weakGPS ? UIColor.systemOrange.cgColor : UIColor.white.cgColor
                marker.layer.shadowColor = parent.state.weakGPS ? UIColor.systemOrange.cgColor : UIColor.black.cgColor
                marker.layer.shadowOpacity = parent.state.weakGPS ? 0.42 : 0.22
                marker.layer.shadowRadius = parent.state.weakGPS ? 7 : 4
            }
            let isFollowingRoute = parent.state.status == .navigating || parent.state.status == .rerouting
            vehicleAnnotationView?.centerOffset = isFollowingRoute ? CGVector(dx: 0, dy: 18) : .zero
            if let puckLocation = (parent.state.weakGPS ? parent.state.cameraLocation : parent.state.location),
               isFollowingRoute, puckLocation.course.isFinite, puckLocation.course >= 0 {
                let relativeBearing = puckLocation.course - map.camera.heading
                vehicleArrow?.isHidden = false
                vehicleArrow?.transform = CGAffineTransform(rotationAngle: CGFloat(relativeBearing * .pi / 180))
            } else {
                vehicleArrow?.isHidden = true
                vehicleArrow?.transform = .identity
            }
            updateDestinationMarker(on: map)

            applyCameraIntent(to: map)

            if lastStatus != parent.state.status || lastColorScheme != parent.colorScheme {
                if parent.state.route != nil { updateActiveRouteStyle(on: map) }
                map.setNeedsDisplay()
            }
            if lastStatus == .routePreview && parent.state.status == .navigating {
                animateNavigationStart(on: map)
            }
            lastStatus = parent.state.status
            lastColorScheme = parent.colorScheme
            lastCameraState = parent.state.cameraState
        }

        private func updateTransitVehiclePins(on map: MLNMapView) {
            let isZoomedIn = map.zoomLevel >= 14.7
            let vehicles = Dictionary((showsOnlyRouteEndpoints ? [] : parent.transitVehicles)
                .filter { vehicle in
                    if let tripID = parent.selectedTransitTripID { return vehicle.tripID == tripID }
                    return parent.selectedTransitRouteID.map { routeID in routeID == vehicle.routeID } ?? isZoomedIn
                }
                .map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
            let removedIDs = transitVehiclePins.keys.filter { vehicles[$0] == nil }
            let removedPins = removedIDs.compactMap { transitVehiclePins.removeValue(forKey: $0) }
            if !removedPins.isEmpty { map.removeAnnotations(removedPins) }
            for vehicle in vehicles.values {
                let title = "Linia \(vehicle.line)"
                let subtitle = transitVehicleSubtitle(vehicle)
                if let pin = transitVehiclePins[vehicle.id] {
                    if pin.coordinate.latitude != vehicle.coordinate.latitude || pin.coordinate.longitude != vehicle.coordinate.longitude {
                        pin.coordinate = vehicle.coordinate.cl
                    }
                    if pin.title != title { pin.title = title }
                    if pin.subtitle != subtitle { pin.subtitle = subtitle }
                } else {
                    let pin = MLNPointAnnotation()
                    pin.coordinate = vehicle.coordinate.cl
                    pin.title = title
                    pin.subtitle = subtitle
                    transitVehiclePins[vehicle.id] = pin
                    map.addAnnotation(pin)
                }
            }
        }

        private func roadAlertSubtitle(_ alert: RoadSafetyAlert, routeDistance: Double) -> String {
            guard let distance = alert.distanceAlongRoute else { return "© OpenStreetMap contributors" }
            let remaining = max(0, distance - routeDistance)
            let distanceText = remaining >= 1_000
                ? String(format: "%.1f km", remaining / 1_000)
                : "\(Int(remaining.rounded())) m"
            return "\(distanceText) · © OpenStreetMap contributors"
        }

        private var transitRouteStopIDs: Set<String> {
            let journeyStopIDs = parent.state.route?.journey?.legs.reduce(into: Set<String>()) { result, leg in
                result.formUnion(leg.transitStops.map(\.stopID))
            } ?? []
            return journeyStopIDs.union(parent.selectedTransitTripStopIDs)
        }

        private var transitRouteEndpointCoordinates: [Coordinate] {
            if let coordinates = parent.state.route?.coordinates, !coordinates.isEmpty {
                return [coordinates[0], coordinates[coordinates.count - 1]]
            }
            return [parent.state.location?.coordinate, parent.state.destination?.coordinate].compactMap { $0 }
        }

        private func transitVisibleRadius(on map: MLNMapView, center: Coordinate) -> Double {
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

        private func updateTransitStopPins(on map: MLNMapView) {
            let zoom = map.zoomLevel
            let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
            let routeStopIDs = transitRouteStopIDs
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let isTransitRoutePreview = parent.state.transportMode == .transit
                && (parent.state.status == .destinationPreview || parent.state.status == .routeCalculating
                    || parent.state.status == .routePreview)
            let visibleRadius = transitVisibleRadius(on: map, center: center)
            let visibleStopCount = parent.transitStops.reduce(into: 0) { count, stop in
                if center.distance(to: stop.coordinate) <= visibleRadius { count += 1 }
            }
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
                                                  isNavigating: isNavigating,
                                                  isTransitRoutePreview: isTransitRoutePreview,
                                                  routeStopIDs: routeStopIDs,
                                                  userCoordinate: parent.state.location?.coordinate,
                                                  routeEndpointCoordinates: transitRouteEndpointCoordinates,
                                                  visibleRadius: visibleRadius)
            guard lastTransitStopRenderKey != renderKey else { return }
            lastTransitStopRenderKey = renderKey

            let routeEndpoints = transitRouteEndpointCoordinates
            let visibility = TransitStopMapVisibilityPolicy(zoom: zoom,
                                                            transportMode: parent.state.transportMode,
                                                            isNavigating: isNavigating,
                                                            isTransitRoutePreview: isTransitRoutePreview,
                                                            visibleStopCount: visibleStopCount,
                                                            visibleRadius: visibleRadius,
                                                            mapCenter: center,
                                                            userCoordinate: parent.state.location?.coordinate,
                                                            routeEndpointCoordinates: routeEndpoints,
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
                let isOnRoute = groupDecisions.contains(where: \.isOnRoute)
                let opacity = groupDecisions.map(\.opacity).max() ?? 1
                return (groupedStop, center.distance(to: groupedStop.coordinate), isOnRoute, opacity)
            }.sorted { $0.1 < $1.1 }.prefix(500)
            let groupDecisionsByID = Dictionary(groupedStops.map {
                ($0.0.id, TransitStopMapVisibilityDecision(isOnRoute: $0.2, opacity: $0.3))
            }, uniquingKeysWith: { first, _ in first })
            let stops = groupedStops.map(\.0)
            let byID = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let removedIDs = transitStopPins.keys.filter { byID[$0] == nil }
            let removedPins = removedIDs.compactMap { transitStopPins.removeValue(forKey: $0) }
            removedIDs.forEach { transitStopMapStops.removeValue(forKey: $0) }
            removedIDs.forEach { transitStopMarkerStates.removeValue(forKey: $0) }
            if !removedPins.isEmpty { map.removeAnnotations(removedPins) }
            for stop in byID.values {
                transitStopMapStops[stop.id] = stop
                let memberIDs = Set(stop.detailStopIDs)
                let decision = groupDecisionsByID[stop.id]
                let presentation = stop.mapPresentation(zoom: zoom,
                                                        selected: parent.selectedTransitStopID.map(memberIDs.contains) ?? false,
                                                        active: parent.activeTransitStopID.map(memberIDs.contains) ?? false,
                                                        alighting: parent.alightingTransitStopID.map(memberIDs.contains) ?? false,
                                                        onRoute: decision?.isOnRoute ?? false,
                                                        opacity: decision?.opacity ?? 1)
                if let pin = transitStopPins[stop.id] {
                    if pin.coordinate.latitude != stop.coordinate.latitude || pin.coordinate.longitude != stop.coordinate.longitude {
                        pin.coordinate = stop.coordinate.cl
                    }
                    if pin.title != stop.name { pin.title = stop.name }
                    let subtitle = stop.lines.prefix(5).joined(separator: " · ")
                    if pin.subtitle != subtitle { pin.subtitle = subtitle }
                    if let marker = map.view(for: pin), transitStopMarkerStates[stop.id] != presentation {
                        styleTransitStopMarker(marker, presentation: presentation)
                    }
                } else {
                    let pin = MLNPointAnnotation()
                    pin.coordinate = stop.coordinate.cl
                    pin.title = stop.name
                    pin.subtitle = stop.lines.prefix(5).joined(separator: " · ")
                    transitStopPins[stop.id] = pin
                    transitStopMarkerStates[stop.id] = presentation
                    map.addAnnotation(pin)
                }
                transitStopMarkerStates[stop.id] = presentation
            }
        }

        private func scheduleTransitAnnotationUpdate(on map: MLNMapView) {
            transitAnnotationUpdateWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map else { return }
                self.updateTransitVehiclePins(on: map)
                self.updateTransitStopPins(on: map)
            }
            transitAnnotationUpdateWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func scheduleSearchMapCenterUpdate(_ center: Coordinate) {
            searchMapCenterWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let current = self.parent.state.searchMapCenter,
                   current.distance(to: center) < 35 { return }
                self.parent.state.searchMapCenter = center
            }
            searchMapCenterWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }

        private func updateSelectedTransitLine(on map: MLNMapView) {
            guard shownTransitRouteID != parent.selectedTransitRouteID
                    || shownTransitLineCoordinates != parent.transitLineCoordinates else { return }
            if let transitLine { map.removeAnnotation(transitLine) }
            transitLine = nil
            shownTransitRouteID = parent.selectedTransitRouteID
            shownTransitLineCoordinates = parent.transitLineCoordinates
            guard parent.selectedTransitRouteID != nil, parent.transitLineCoordinates.count > 1 else { return }
            var points = parent.transitLineCoordinates.map(\.cl)
            let line = MLNPolyline(coordinates: &points, count: UInt(points.count))
            transitLine = line
            map.addAnnotation(line)
        }

        private func transitVehicleSubtitle(_ vehicle: TransitVehicle) -> String {
            let mode = vehicle.mode == "TRAM" ? "Tramwaj" : "Autobus"
            let delay = vehicle.delaySeconds.map { seconds in
                if seconds > 30 { return " · opóźnienie +\(max(1, seconds / 60)) min" }
                if seconds < -30 { return " · przed czasem \(max(1, abs(seconds) / 60)) min" }
                return " · punktualnie"
            } ?? ""
            return "\(mode) · aktualizacja \(vehicle.updatedAt.formatted(date: .omitted, time: .shortened))\(delay)"
        }

        private func styleTransitStopMarker(_ marker: MLNAnnotationView, presentation: TransitStopMapPresentation) {
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
            let accent = presentation.isAlighting ? UIColor.systemPurple
                : presentation.isActive ? UIColor.systemOrange
                : presentation.isSelected ? UIColor.systemBlue
                : presentation.isOnRoute ? UIColor.systemTeal
                : transitMarkerColor(for: presentation.modes.first)
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
                image.tintColor = transitMarkerColor(for: mode)
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
                badge.backgroundColor = .systemPurple
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

        private func transitMarkerColor(for mode: TransitStopMode?) -> UIColor {
            guard let mode else { return .systemBlue }
            return UIColor(red: CGFloat((mode.accentHex >> 16) & 0xff) / 255,
                           green: CGFloat((mode.accentHex >> 8) & 0xff) / 255,
                           blue: CGFloat(mode.accentHex & 0xff) / 255, alpha: 1)
        }

        private func updatePOIDensity(on map: MLNMapView) {
            guard let style = map.style else { return }
            navigationStyle.apply(to: style, settings: parent.settings, dark: usesDarkMapAppearance, zoom: map.zoomLevel)
        }

        private var usesDarkMapAppearance: Bool {
            parent.settings.appearance == .night ||
                (parent.settings.appearance == .auto && parent.colorScheme == .dark)
        }

        private func updatePOIMarkerAppearance(on map: MLNMapView) {
            let dark = usesDarkMapAppearance
            guard lastPOIMarkerDark != dark else { return }
            lastPOIMarkerDark = dark
            for (index, pin) in searchPins.enumerated()
                where parent.state.searchResults.indices.contains(index) {
                guard parent.state.searchResults[index].isPOI,
                      let kind = PlacePOIMapMarkerKind(category: parent.state.searchResults[index].category),
                      let marker = map.view(for: pin) else { continue }
                stylePlacePOIMarker(marker, annotation: pin, kind: kind, dark: dark)
            }
        }

        private func applyCameraIntent(to map: MLNMapView) {
            guard map.style != nil, map.bounds.width > 0, map.bounds.height > 0,
                  let intent = parent.state.cameraIntent,
                  parent.state.cameraState != .freeLook else { return }
            let cameraState = parent.state.cameraState
            let cameraMode = parent.settings.cameraMode
            let routeID = parent.state.route?.id
            let cameraCommandChanged = lastCameraCommandID != parent.state.cameraCommandID
            let cameraModeChanged = lastCameraMode != cameraMode
            let cameraStateChanged = lastCameraState != cameraState
            let enteringOverview = cameraState == .routeOverview && lastCameraState != .routeOverview
            let newOverview = cameraState == .routeOverview && lastOverviewRouteID != routeID &&
                lastStatus != .routePreview
            let routePreviewPaddingChanged = lastViewportPadding != parent.viewportPadding || lastMapSize != map.bounds.size
            var effectiveIntent = intent
            effectiveIntent.padding = parent.viewportPadding
            // Keep a usable map viewport even when the drawer is fully expanded.
            effectiveIntent.padding.bottom = min(effectiveIntent.padding.bottom,
                max(0, Double(map.bounds.height) - effectiveIntent.padding.top - 100))
            if cameraState == .routeOverview, !enteringOverview, !newOverview, !cameraCommandChanged,
               !routePreviewPaddingChanged, !cameraModeChanged,
               let route = parent.state.route {
                if isMostlyVisible(route.coordinates, on: map) { return }
            }
            if intent == lastIntent && !enteringOverview && !newOverview && !cameraCommandChanged &&
                !routePreviewPaddingChanged && !cameraModeChanged && !cameraStateChanged { return }
            if cameraMode == .flat && !cameraState.usesNavigationPerspective {
                effectiveIntent.pitch = 0
            } else if cameraState == .browse || cameraState == .destinationPreview || cameraState == .routeOverview {
                effectiveIntent.pitch = 40
            }
            if cameraState == .routeOverview, lastOverviewRouteID != nil,
               let route = parent.state.route, lastStatus == .routePreview {
                effectiveIntent.bounds = route.coordinates
            }
            programmaticCamera = true
            CameraAnimator.apply(effectiveIntent, state: cameraState, to: map)
            lastViewportPadding = parent.viewportPadding
            lastMapSize = map.bounds.size
            lastIntent = intent
            lastCameraMode = cameraMode
            lastCameraCommandID = parent.state.cameraCommandID
            lastRoutePreviewExpanded = parent.routePreviewExpanded
            if cameraState == .routeOverview { lastOverviewRouteID = routeID }
        }

        private func isMostlyVisible(_ points: [Coordinate], on map: MLNMapView) -> Bool {
            guard !points.isEmpty else { return true }
            let padding = parent.viewportPadding
            let safe = CGRect(x: padding.left, y: padding.top,
                              width: max(1, Double(map.bounds.width) - padding.left - padding.right),
                              height: max(1, Double(map.bounds.height) - padding.top - padding.bottom))
            let sampled = stride(from: 0, to: points.count, by: max(1, points.count / 30)).map { points[$0] }
            let inside = sampled.filter { safe.contains(map.convert($0.cl, toPointTo: map)) }.count
            return Double(inside) / Double(sampled.count) >= 0.9
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            if let (stopID, _) = transitStopPins.first(where: { $0.value === annotation }),
               let stop = transitStopMapStops[stopID] {
                parent.onTransitStopSelect(stop)
                return
            }
            if let vehicle = parent.transitVehicles.first(where: { transitVehiclePins[$0.id] === annotation }) {
                parent.onTransitVehicleSelect(vehicle)
                return
            }
            guard let index = searchPins.firstIndex(where: { $0 === annotation }),
                  parent.state.searchResults.indices.contains(index) else { return }
            parent.onPlaceSelect([parent.state.searchResults[index]])
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let index = trafficEventPins.firstIndex(where: { $0 === annotation }),
               shownTrafficEventGroups.indices.contains(index),
               let event = shownTrafficEventGroups[index].max(by: {
                   $0.presentation.clusterPriority < $1.presentation.clusterPriority
               }) {
                return trafficMarkerView(for: annotation,
                                         reuseIdentifier: "traffic-event-\(event.id)",
                                         presentation: event.presentation,
                                         clusterCount: shownTrafficEventGroups[index].count > 1
                                            ? shownTrafficEventGroups[index].count : nil)
            }

            if let closurePin, annotation === closurePin {
                return trafficMarkerView(for: annotation,
                                         reuseIdentifier: "traffic-road-closure",
                                         symbolName: "xmark.octagon.fill",
                                         color: .systemRed)
            }

            if let index = searchPins.firstIndex(where: { $0 === annotation }) {
                if parent.state.searchResults.indices.contains(index),
                   parent.state.searchResults[index].isPOI,
                   let kind = PlacePOIMapMarkerKind(category: parent.state.searchResults[index].category) {
                    return placePOIMarkerView(for: annotation, kind: kind, dark: usesDarkMapAppearance)
                }
                let marker = MLNAnnotationView(reuseIdentifier: nil)
                marker.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
                marker.backgroundColor = .systemBlue
                marker.layer.cornerRadius = 16
                let label = UILabel(frame: marker.bounds)
                label.text = String(index + 1)
                label.textAlignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 15)
                marker.addSubview(label)
                return marker
            }

            if let (stopID, _) = transitStopPins.first(where: { $0.value === annotation }) {
                let marker = MLNAnnotationView(reuseIdentifier: "transit-stop-\(stopID)")
                guard let stop = transitStopMapStops[stopID] else { return marker }
                let presentation = transitStopMarkerStates[stopID] ?? stop.mapPresentation(
                    zoom: mapView.zoomLevel, selected: false, active: false, alighting: false)
                styleTransitStopMarker(marker, presentation: presentation)
                transitStopMarkerStates[stopID] = presentation
                return marker
            }

            if let (vehicleID, _) = transitVehiclePins.first(where: { $0.value === annotation }),
               let vehicle = parent.transitVehicles.first(where: { $0.id == vehicleID }) {
                let marker = MLNAnnotationView(reuseIdentifier: nil)
                marker.frame = CGRect(x: 0, y: 0, width: 38, height: 25)
                marker.backgroundColor = UIColor(red: CGFloat((vehicle.colorHex >> 16) & 0xff) / 255,
                                                  green: CGFloat((vehicle.colorHex >> 8) & 0xff) / 255,
                                                  blue: CGFloat(vehicle.colorHex & 0xff) / 255, alpha: 1)
                marker.layer.cornerRadius = 8
                marker.layer.borderWidth = 1.5
                marker.layer.borderColor = UIColor.white.cgColor
                marker.layer.shadowColor = UIColor.black.cgColor
                marker.layer.shadowOpacity = 0.25
                marker.layer.shadowRadius = 3
                let label = UILabel(frame: marker.bounds)
                label.text = vehicle.line
                label.textAlignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 12)
                marker.addSubview(label)
                return marker
            }

            if let pin = vehiclePin, annotation === pin {
                let identifier = "user-position"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MLNAnnotationView(reuseIdentifier: identifier)
                if view.subviews.isEmpty {
                    let marker = UIView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
                    marker.backgroundColor = .systemBlue
                    marker.layer.cornerRadius = 14
                    marker.layer.borderWidth = 2.5
                    marker.layer.borderColor = UIColor.white.cgColor
                    marker.layer.shadowColor = UIColor.black.cgColor
                    marker.layer.shadowOpacity = 0.22
                    marker.layer.shadowRadius = 4
                    let arrow = UIImageView(image: UIImage(systemName: "location.north.fill"))
                    arrow.tintColor = .white
                    arrow.contentMode = .scaleAspectFit
                    arrow.frame = CGRect(x: 7, y: 6, width: 14, height: 16)
                    marker.addSubview(arrow)
                    view.addSubview(marker)
                    view.frame = marker.frame
                    vehicleMarker = marker
                    vehicleArrow = arrow
                }
                vehicleAnnotationView = view
                return view
            }
            guard let pin = destinationPin, annotation === pin else { return nil }
            let identifier = "destination"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MLNAnnotationView(reuseIdentifier: identifier)
            if view.subviews.isEmpty {
                let marker = UIImageView()
                marker.contentMode = .scaleAspectFit
                marker.frame = CGRect(x: 0, y: 0, width: 30, height: 36)
                view.addSubview(marker)
                view.frame = marker.frame
                view.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
                view.alpha = 0
            }
            destinationMarkerIsArrived = nil
            updateDestinationMarker(on: mapView, for: view)
            if view.alpha == 0 {
                UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseOut) {
                    view.transform = .identity
                    view.alpha = 1
                }
            }
            return view
        }

        private func updateDestinationMarker(on map: MLNMapView, for annotationView: MLNAnnotationView? = nil) {
            guard let pin = destinationPin,
                  let view = annotationView ?? map.view(for: pin),
                  let marker = view.subviews.compactMap({ $0 as? UIImageView }).first else { return }
            let arrived = parent.state.status == .arrived
            guard destinationMarkerIsArrived != arrived else { return }
            marker.image = UIImage(systemName: arrived ? "checkmark.circle.fill" : "mappin.circle.fill")
            marker.tintColor = arrived ? .systemGreen : .systemRed
            destinationMarkerIsArrived = arrived
            if arrived {
                marker.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
                UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.72,
                               initialSpringVelocity: 0.4, options: [.beginFromCurrentState]) {
                    marker.transform = .identity
                }
            }
        }

        private func trafficMarkerView(for annotation: MLNAnnotation,
                                       reuseIdentifier: String,
                                       symbolName: String,
                                       color: UIColor) -> MLNAnnotationView {
            let marker = MLNAnnotationView(reuseIdentifier: reuseIdentifier)
            marker.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            marker.backgroundColor = color
            marker.layer.cornerRadius = 16
            marker.layer.borderWidth = 1.5
            marker.layer.borderColor = UIColor.white.cgColor
            marker.layer.shadowColor = UIColor.black.cgColor
            marker.layer.shadowOpacity = 0.24
            marker.layer.shadowRadius = 3
            marker.isAccessibilityElement = true
            marker.accessibilityLabel = annotation.title ?? "Informacja o ruchu"
            marker.accessibilityHint = annotation.subtitle.flatMap { $0 }
            let image = UIImageView(image: UIImage(systemName: symbolName))
            image.tintColor = .white
            image.contentMode = .scaleAspectFit
            image.frame = CGRect(x: 7, y: 7, width: 18, height: 18)
            marker.addSubview(image)
            return marker
        }

        private func trafficMarkerView(for annotation: MLNAnnotation,
                                       reuseIdentifier: String,
                                       presentation: TrafficMapPresentation,
                                       clusterCount: Int? = nil) -> MLNAnnotationView {
            let marker = MLNAnnotationView(reuseIdentifier: reuseIdentifier)
            let size = CGFloat(clusterCount == nil ? presentation.markerSize : 38)
            marker.frame = CGRect(x: 0, y: 0, width: size, height: size)
            marker.backgroundColor = UIColor(
                red: CGFloat((presentation.colorHex >> 16) & 0xff) / 255,
                green: CGFloat((presentation.colorHex >> 8) & 0xff) / 255,
                blue: CGFloat(presentation.colorHex & 0xff) / 255, alpha: 1)
            marker.layer.cornerRadius = size / 2
            marker.layer.borderWidth = presentation.isCritical ? 2.5 : 1.5
            marker.layer.borderColor = (presentation.isCritical ? UIColor.systemRed : UIColor.white).cgColor
            marker.layer.shadowColor = (presentation.isCritical ? UIColor.systemRed : marker.backgroundColor)?.cgColor
            marker.layer.shadowOpacity = presentation.isCritical ? 0.48 : 0.24
            marker.layer.shadowRadius = presentation.isCritical ? 5 : 3
            marker.isAccessibilityElement = true
            marker.accessibilityLabel = annotation.title ?? "Informacja o ruchu"
            marker.accessibilityHint = annotation.subtitle.flatMap { $0 }
            if let clusterCount {
                let label = UILabel(frame: marker.bounds)
                label.text = String(clusterCount)
                label.textAlignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 15)
                marker.addSubview(label)
            } else {
                let glyphSize = size * 0.54
                let image = UIImageView(image: UIImage(systemName: presentation.symbolName))
                image.tintColor = .white
                image.contentMode = .scaleAspectFit
                image.frame = CGRect(x: (size - glyphSize) / 2, y: (size - glyphSize) / 2,
                                     width: glyphSize, height: glyphSize)
                marker.addSubview(image)
            }
            return marker
        }

        func mapView(_ mapView: MLNMapView, didSelect view: MLNAnnotationView) {
            guard let annotation = view.annotation,
                  trafficEventPins.contains(where: { $0 === annotation }) else { return }
            let scale = 42 / max(1, view.bounds.width)
            UIView.animate(withDuration: 0.16) { view.transform = CGAffineTransform(scaleX: scale, y: scale) }
        }

        func mapView(_ mapView: MLNMapView, didDeselect view: MLNAnnotationView) {
            UIView.animate(withDuration: 0.14) { view.transform = .identity }
        }

        private func placePOIMarkerView(for annotation: MLNAnnotation,
                                        kind: PlacePOIMapMarkerKind, dark: Bool) -> MLNAnnotationView {
            let marker = MLNAnnotationView(reuseIdentifier: "poi-\(kind.rawValue)")
            stylePlacePOIMarker(marker, annotation: annotation, kind: kind, dark: dark)
            return marker
        }

        private func stylePlacePOIMarker(_ marker: MLNAnnotationView, annotation: MLNAnnotation,
                                         kind: PlacePOIMapMarkerKind, dark: Bool) {
            marker.subviews.forEach { $0.removeFromSuperview() }
            marker.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
            let background = PlacePOIMapPalette.backgroundHex(dark: dark)
            marker.backgroundColor = UIColor(red: CGFloat((background >> 16) & 0xff) / 255,
                                              green: CGFloat((background >> 8) & 0xff) / 255,
                                              blue: CGFloat(background & 0xff) / 255, alpha: 1)
            marker.layer.cornerRadius = 11
            marker.layer.borderWidth = 1.8
            let color = PlacePOIMapPalette.accentColor(dark: dark)
            marker.layer.borderColor = color.cgColor
            marker.layer.shadowColor = UIColor.black.cgColor
            marker.layer.shadowOpacity = 0.18
            marker.layer.shadowRadius = 3
            marker.layer.shadowOffset = CGSize(width: 0, height: 1)
            let glyph = UIImageView(image: UIImage(systemName: kind.symbolName,
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18,
                                                                                                   weight: .semibold)))
            glyph.tintColor = color
            glyph.contentMode = .scaleAspectFit
            glyph.frame = marker.bounds.insetBy(dx: 8, dy: 8)
            marker.addSubview(glyph)
            marker.isAccessibilityElement = true
            marker.accessibilityLabel = "\(kind.accessibilityName): \(annotation.title.flatMap { $0 } ?? "")"
            marker.accessibilityHint = annotation.subtitle.flatMap { $0 }
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            transitVehiclePins.values.contains { $0 === annotation }
                || transitStopPins.values.contains { $0 === annotation }
                || trafficEventPins.contains { $0 === annotation }
                || (closurePin.map { $0 === annotation } ?? false)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            scheduleSearchMapCenterUpdate(center)

            let wasProgrammaticCamera = programmaticCamera
            if wasProgrammaticCamera { programmaticCamera = false }
            if !wasProgrammaticCamera, parent.state.status == .routePreview {
                parent.state.cameraState = .freeLook
                parent.state.cameraIntent = nil
                parent.onMapPan()
            }
            updatePOIDensity(on: mapView)
            updateIncidentPins(on: mapView)
            updateTrafficEventPins(on: mapView,
                                   routeDistance: parent.state.progress?.traveledDistance ?? 0)
            scheduleTransitAnnotationUpdate(on: mapView)
        }

        private func updateIncidentPins(on map: MLNMapView) {
            let routeDistance = parent.state.progress?.traveledDistance ?? 0
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let incidents = parent.settings.overlays.traffic
                ? (parent.state.traffic?.incidents ?? []).filter { incident in
                    guard isNavigating else { return true }
                    guard incident.isImportantDuringNavigation,
                          let distance = incident.distanceAlongRoute else { return false }
                    return distance > routeDistance && distance <= routeDistance + 12_000
                }
                : []
            shownIncidents = incidents
        }

        private func updateTrafficEventPins(on map: MLNMapView, routeDistance: Double) {
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let events = MainActor.assumeIsolated { () -> [TrafficMapEvent] in
                var events: [TrafficMapEvent] = []
                for incident in shownIncidents {
                    events.append(TrafficMapEvent(incident))
                }
                for alert in shownRoadAlerts {
                    events.append(TrafficMapEvent(alert, routeDistance: routeDistance))
                }
                return events
            }
            let groups = clusteredTrafficEvents(events, on: map, isNavigating: isNavigating)
            let groupIDs = groups.map {
                $0.map { "\($0.id):\($0.presentation.colorHex):\($0.presentation.priority)" }
                    .sorted().joined(separator: ",")
            }
            if groupIDs != shownTrafficEventGroupIDs {
                map.removeAnnotations(trafficEventPins)
                trafficEventPins = groups.map { group in
                    let pin = MLNPointAnnotation()
                    pin.coordinate = trafficEventCenter(group).cl
                    if group.count == 1, let event = group.first {
                        pin.title = event.title
                        pin.subtitle = event.subtitle
                    } else {
                        pin.title = "\(group.count) zdarzenia drogowe"
                        pin.subtitle = trafficEventClusterSubtitle(group)
                    }
                    return pin
                }
                map.addAnnotations(trafficEventPins)
                shownTrafficEventGroupIDs = groupIDs
            }
            shownTrafficEventGroups = groups
            for (group, pin) in zip(groups, trafficEventPins) {
                pin.coordinate = trafficEventCenter(group).cl
                if group.count == 1, let event = group.first {
                    pin.title = event.title
                    pin.subtitle = event.subtitle
                } else {
                    pin.title = "\(group.count) zdarzenia drogowe"
                    pin.subtitle = trafficEventClusterSubtitle(group)
                }
            }
        }

        private func clusteredTrafficEvents(_ events: [TrafficMapEvent], on map: MLNMapView,
                                            isNavigating: Bool) -> [[TrafficMapEvent]] {
            guard map.zoomLevel < 13.2, !isNavigating, events.count > 1 else {
                return events.map { [$0] }
            }
            let points = events.map { map.convert($0.coordinate.cl, toPointTo: map) }
            var remaining = Set(events.indices)
            var groups: [[TrafficMapEvent]] = []
            while let first = remaining.min() {
                remaining.remove(first)
                var component = [first]
                var frontier = [first]
                while let current = frontier.popLast() {
                    let matches = remaining.filter { candidate in
                        hypot(points[current].x - points[candidate].x,
                              points[current].y - points[candidate].y) < 44
                    }
                    for match in matches {
                        remaining.remove(match)
                        frontier.append(match)
                        component.append(match)
                    }
                }
                groups.append(component.map { events[$0] })
            }
            return groups
        }

        private func trafficEventCenter(_ group: [TrafficMapEvent]) -> Coordinate {
            guard group.count > 1 else { return group.first?.coordinate ?? Coordinate(latitude: 0, longitude: 0) }
            return Coordinate(latitude: group.map(\.coordinate.latitude).reduce(0, +) / Double(group.count),
                              longitude: group.map(\.coordinate.longitude).reduce(0, +) / Double(group.count))
        }

        private func trafficEventClusterSubtitle(_ group: [TrafficMapEvent]) -> String {
            Array(Set(group.map(\.categoryLabel))).sorted().prefix(3).joined(separator: " · ")
        }

        private func updateIncidentLines(on map: MLNMapView) {
            let renderItems = shownIncidents.filter { $0.geometry.count > 1 }.map {
                IncidentLineRenderItem(id: $0.id, coordinates: $0.geometry,
                                       colorHex: TrafficMapPresentation($0).colorHex)
            }.sorted { $0.id < $1.id }
            guard renderItems != incidentLineRenderItems else { return }
            map.removeAnnotations(incidentLinesByID.values.flatMap { $0.map(\.polyline) })
            incidentLinesByID.removeAll()
            incidentLineRenderItems = renderItems
            for item in renderItems {
                let casing = makeIncidentLine(item.coordinates, kind: .incidentCasing, on: map)
                let line = makeIncidentLine(item.coordinates, kind: .incident(color: item.colorHex), on: map)
                incidentLinesByID[item.id] = [casing, line]
            }
        }

        private func makeIncidentLine(_ coordinates: [Coordinate], kind: RouteLineKind,
                                      on map: MLNMapView) -> StyledLine {
            var points = coordinates.map(\.cl)
            let polyline = MLNPolyline(coordinates: &points, count: UInt(points.count))
            let line = StyledLine(polyline: polyline, coordinates: coordinates, kind: kind,
                                  routeID: nil, transitionFrom: nil, transitionStartedAt: nil)
            map.addAnnotation(polyline)
            return line
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if let transitLine, transitLine === annotation, let color = parent.transitLineColor {
                return self.color(hex: color, opacity: 0.9)
            }
            guard let line = annotation as? MLNPolyline, let styled = styledLine(for: line) else { return .systemBlue }
            let style = presentedStyle(for: styled)
            return color(hex: style.hex, opacity: style.opacity)
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            if let transitLine, transitLine === annotation { return 5 }
            guard let styled = styledLine(for: annotation) else { return 2 }
            return presentedStyle(for: styled).width
        }

        private func addLine(_ coordinates: [Coordinate], kind: RouteLineKind, routeID: UUID? = nil,
                             transitionFrom: LineStyle? = nil, to map: MLNMapView) {
            guard coordinates.count > 1 else { return }
            var points = coordinates.map(\.cl)
            let polyline = MLNPolyline(coordinates: &points, count: UInt(points.count))
            let styled = StyledLine(polyline: polyline, coordinates: coordinates, kind: kind, routeID: routeID,
                                    transitionFrom: transitionFrom, transitionStartedAt: transitionFrom == nil ? nil : Date())
            routeLines.append(styled)
            map.addAnnotation(polyline)
        }

        private func addActiveRoute(_ route: NavigationRoute, previousStyle: LineStyle?,
                                    animateSelection: Bool, animateReroute: Bool, to map: MLNMapView) {
            let transitionStyle: LineStyle? = {
                guard animateSelection || animateReroute else { return nil }
                if animateReroute {
                    let style = lineStyle(for: .active)
                    return LineStyle(hex: style.hex, opacity: 0, width: style.width)
                }
                return previousStyle
            }()

            if parent.state.transportMode == .transit,
               let journey = route.journey,
               addJourneyLegs(journey.legs, routeID: route.id, transitionStyle: transitionStyle, to: map) {
                return
            }
            let legs = activeRouteLegs(for: route)
            for path in RouteMapGeometry.dashedSegments(legs.continuation, dashLength: 75, gapLength: 36) {
                addLine(path, kind: .future, routeID: route.id, to: map)
            }
            updateActiveRouteShape(route, on: map)
        }

        private func activeRouteLegs(for route: NavigationRoute) -> RouteLegGeometry {
            return RouteMapGeometry.activeLeg(in: route.coordinates,
                                              from: parent.state.location?.coordinate,
                                              through: parent.state.waypoints + parent.state.evChargingStops)
        }

        private func updateActiveRouteShape(_ route: NavigationRoute, on map: MLNMapView) {
            guard let style = map.style else { return }
            let sourceID = "naviastra-active-route-source"
            let casingID = "naviastra-active-route-casing"
            let lineID = "naviastra-active-route-line"
            let highlightID = "naviastra-active-route-highlight"
            let source: MLNShapeSource
            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                source = existing
            } else {
                source = MLNShapeSource(identifier: sourceID, shape: nil, options: nil)
                style.addSource(source)
            }
            activeRouteSource = source
            if revealRouteID != route.id {
                revealRouteID = route.id
                revealGeometry = RouteRevealGeometry(coordinates: activeRouteLegs(for: route).active)
            }

            let casing: MLNLineStyleLayer
            if let existing = style.layer(withIdentifier: casingID) as? MLNLineStyleLayer {
                casing = existing
            } else {
                casing = MLNLineStyleLayer(identifier: casingID, source: source)
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                casing.lineColorTransition = MLNTransitionMake(0.3, 0)
                casing.lineWidthTransition = MLNTransitionMake(0.3, 0)
                style.addLayer(casing)
            }
            let line: MLNLineStyleLayer
            if let existing = style.layer(withIdentifier: lineID) as? MLNLineStyleLayer {
                line = existing
            } else {
                line = MLNLineStyleLayer(identifier: lineID, source: source)
                line.lineCap = NSExpression(forConstantValue: "round")
                line.lineJoin = NSExpression(forConstantValue: "round")
                line.lineColorTransition = MLNTransitionMake(0.3, 0)
                line.lineWidthTransition = MLNTransitionMake(0.3, 0)
                style.addLayer(line)
            }
            let highlight: MLNLineStyleLayer
            if let existing = style.layer(withIdentifier: highlightID) as? MLNLineStyleLayer {
                highlight = existing
            } else {
                highlight = MLNLineStyleLayer(identifier: highlightID, source: source)
                highlight.lineCap = NSExpression(forConstantValue: "round")
                highlight.lineJoin = NSExpression(forConstantValue: "round")
                highlight.lineColorTransition = MLNTransitionMake(0.3, 0)
                highlight.lineWidthTransition = MLNTransitionMake(0.3, 0)
                style.addLayer(highlight)
            }
            updateActiveRouteStyle(on: map)

            let progress = parent.state.status == .routePreview ? parent.state.routeRevealProgress : 1
            let visible = revealGeometry?.visibleCoordinates(progress: progress) ?? activeRouteLegs(for: route).active
            guard visible.count > 1 else { source.shape = nil; return }
            var points = visible.map(\.cl)
            source.shape = MLNPolyline(coordinates: &points, count: UInt(points.count))
        }

        private func updateActiveRouteStyle(on map: MLNMapView) {
            guard let style = map.style,
                  let casing = style.layer(withIdentifier: "naviastra-active-route-casing") as? MLNLineStyleLayer,
                  let line = style.layer(withIdentifier: "naviastra-active-route-line") as? MLNLineStyleLayer,
                  let highlight = style.layer(withIdentifier: "naviastra-active-route-highlight") as? MLNLineStyleLayer else { return }
            let casingStyle = lineStyle(for: .activeCasing)
            let activeStyle = lineStyle(for: .active)
            let highlightStyle = lineStyle(for: .activeHighlight)
            let key = "\(casingStyle.hex)-\(casingStyle.opacity)-\(casingStyle.width)-\(activeStyle.hex)-\(activeStyle.opacity)-\(activeStyle.width)-\(highlightStyle.hex)-\(highlightStyle.opacity)-\(highlightStyle.width)"
            guard key != activeRouteStyleKey else { return }
            activeRouteStyleKey = key
            casing.lineColor = NSExpression(forConstantValue: color(hex: casingStyle.hex, opacity: 1))
            casing.lineOpacity = NSExpression(forConstantValue: casingStyle.opacity)
            casing.lineWidth = NSExpression(forConstantValue: casingStyle.width)
            line.lineColor = NSExpression(forConstantValue: color(hex: activeStyle.hex, opacity: 1))
            line.lineOpacity = NSExpression(forConstantValue: activeStyle.opacity)
            line.lineWidth = NSExpression(forConstantValue: activeStyle.width)
            highlight.lineColor = NSExpression(forConstantValue: color(hex: highlightStyle.hex, opacity: 1))
            highlight.lineOpacity = NSExpression(forConstantValue: highlightStyle.opacity)
            highlight.lineWidth = NSExpression(forConstantValue: highlightStyle.width)
        }

        private func addJourneyLegs(_ legs: [JourneyLeg], routeID: UUID, transitionStyle: LineStyle?,
                                    to map: MLNMapView) -> Bool {
            var didDrawLeg = false
            for leg in legs where leg.coordinates.count > 1 {
                let mode = leg.mode.lowercased()
                let walking = isWalkingLeg(mode)
                let cycling = mode.contains("bicycle") || mode.contains("bike")
                let color = walking ? RouteColorPalette.walking : cycling ? RouteColorPalette.cycling : RouteColorPalette.activeLight
                let paths = walking ? RouteMapGeometry.dashedSegments(leg.coordinates) : [leg.coordinates]
                for path in paths where path.count > 1 {
                    let kind = RouteLineKind.journeyLeg(color: color, walking: walking, cycling: cycling)
                    let casingKind = RouteLineKind.journeyCasing(walking: walking, cycling: cycling)
                    let casing = lineStyle(for: casingKind)
                    let invisibleCasing = LineStyle(hex: casing.hex, opacity: 0, width: casing.width)
                    addLine(path, kind: casingKind, routeID: routeID,
                            transitionFrom: transitionStyle == nil ? nil : invisibleCasing, to: map)
                    addLine(path, kind: kind, routeID: routeID, transitionFrom: transitionStyle, to: map)
                    didDrawLeg = true
                }
            }
            return didDrawLeg
        }

        private func isWalkingLeg(_ mode: String) -> Bool {
            mode == "walk" || mode == "walking" || mode == "foot" || mode == "pedestrian" || mode.contains("walk")
        }

        private func previousStyle(for routeID: UUID, kind: RouteLineKind, in lines: [StyledLine]) -> LineStyle? {
            guard let line = lines.first(where: { $0.routeID == routeID && $0.kind == kind }) else { return nil }
            return presentedStyle(for: line)
        }

        private func animateRouteSelection(on map: MLNMapView, removeDeparted: Bool = false) {
            routeTransitionTimer?.invalidate()
            let start = Date()
            routeTransitionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak map] timer in
                guard let self else { timer.invalidate(); return }
                if Date().timeIntervalSince(start) >= 0.3 {
                    if removeDeparted {
                        let departed = self.routeLines.filter { $0.kind == .departed }.map(\.polyline)
                        map?.removeAnnotations(departed)
                        self.routeLines.removeAll { $0.kind == .departed }
                    }
                    map?.setNeedsDisplay()
                    timer.invalidate()
                    self.routeTransitionTimer = nil
                } else {
                    map?.setNeedsDisplay()
                }
            }
        }

        private func animateNavigationStart(on map: MLNMapView) {
            let startedAt = Date()
            for index in routeLines.indices {
                let kind = routeLines[index].kind
                let startingStyle = lineStyle(for: kind, navigating: false)
                routeLines[index].transitionFrom = startingStyle
                routeLines[index].transitionStartedAt = startedAt
            }
            animateRouteSelection(on: map)
        }

        private func updateAccuracyHalo(on map: MLNMapView) {
            guard let location = parent.state.location,
                  Date().timeIntervalSince(location.timestamp) >= 0,
                  Date().timeIntervalSince(location.timestamp) < 20,
                  location.accuracy >= 15, location.accuracy <= 150 else {
                if let accuracyHaloLine { map.removeAnnotation(accuracyHaloLine.polyline) }
                accuracyHaloLine = nil
                accuracyHaloCenter = nil
                accuracyHaloRadius = nil
                return
            }

            if let accuracyHaloCenter, let accuracyHaloRadius,
               accuracyHaloCenter.distance(to: location.coordinate) < 8,
               abs(accuracyHaloRadius - location.accuracy) < 5 { return }

            if let accuracyHaloLine { map.removeAnnotation(accuracyHaloLine.polyline) }
            let coordinates = LocationAccuracyGeometry.circle(center: location.coordinate,
                                                              radiusMeters: location.accuracy)
            var points = coordinates.map(\.cl)
            let polyline = MLNPolyline(coordinates: &points, count: UInt(points.count))
            accuracyHaloLine = StyledLine(polyline: polyline, coordinates: coordinates, kind: .accuracy,
                                          routeID: nil, transitionFrom: nil, transitionStartedAt: nil)
            accuracyHaloCenter = location.coordinate
            accuracyHaloRadius = location.accuracy
            map.addAnnotation(polyline)
        }

        private func updateTraveledLine(on map: MLNMapView) {
            guard let route = parent.state.route,
                  parent.state.status == .navigating || parent.state.status == .rerouting,
                  let location = parent.state.location,
                  let projection = projection(for: location.coordinate, on: route),
                  projection.distanceFromRoute <= max(100, location.accuracy * 2),
                  projection.alongRoute > 15 else {
                removeTraveledLine(from: map)
                return
            }

            if traveledRouteID == route.id, let traveledEnd, traveledEnd.distance(to: projection.coordinate) < 15 { return }
            removeTraveledLine(from: map)
            let coordinates = Array(route.coordinates.prefix(projection.segment + 1)) + [projection.coordinate]
            guard coordinates.count > 1 else { return }
            var points = coordinates.map(\.cl)
            let polyline = MLNPolyline(coordinates: &points, count: UInt(points.count))
            traveledLine = StyledLine(polyline: polyline, coordinates: coordinates, kind: .traveled, routeID: route.id,
                                      transitionFrom: nil, transitionStartedAt: nil)
            traveledRouteID = route.id
            traveledEnd = projection.coordinate
            map.addAnnotation(polyline)
            if let trafficLine { map.removeAnnotation(trafficLine.polyline); map.addAnnotation(trafficLine.polyline) }
        }

        private func removeTraveledLine(from map: MLNMapView) {
            if let traveledLine { map.removeAnnotation(traveledLine.polyline) }
            traveledLine = nil
            traveledRouteID = nil
            traveledEnd = nil
        }

        private func projection(for location: Coordinate, on route: NavigationRoute) -> RouteProjection? {
            if projectionRouteID == route.id, projectionLocation == location {
                return cachedRouteProjection
            }
            let projection = MapMatcher.project(location, onto: route.coordinates)
            projectionRouteID = route.id
            projectionLocation = location
            cachedRouteProjection = projection
            return projection
        }

        private func updateTrafficLine(on map: MLNMapView) {
            guard parent.settings.overlays.traffic, let flow = parent.state.traffic?.flow, flow.coordinates.count > 1 else {
                if let trafficLine { map.removeAnnotation(trafficLine.polyline) }
                trafficLine = nil
                trafficCoordinates = nil
                trafficColorHex = nil
                return
            }
            if trafficCoordinates != flow.coordinates {
                if let trafficLine { map.removeAnnotation(trafficLine.polyline) }
                var points = flow.coordinates.map(\.cl)
                let polyline = MLNPolyline(coordinates: &points, count: UInt(points.count))
                trafficLine = StyledLine(polyline: polyline, coordinates: flow.coordinates, kind: .traffic, routeID: nil,
                                         transitionFrom: nil, transitionStartedAt: nil)
                trafficCoordinates = flow.coordinates
                map.addAnnotation(polyline)
            }
            if trafficColorHex != flow.overlayColorHex {
                trafficColorHex = flow.overlayColorHex
                map.setNeedsDisplay()
            }
        }

        private func updateTrafficRasterLayer(on map: MLNMapView) {
            let flowTemplate = parent.colorScheme == .dark
                ? parent.state.trafficDarkTileURLTemplate
                : parent.state.trafficLightTileURLTemplate
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let isVisible = parent.settings.overlays.traffic
            let requestedIncidentTemplate = parent.colorScheme == .dark
                ? parent.state.trafficDarkIncidentTileURLTemplate
                : parent.state.trafficLightIncidentTileURLTemplate
            let incidentTemplate = isNavigating ? nil : requestedIncidentTemplate
            let templateKey = "\(flowTemplate ?? "")|\(incidentTemplate ?? "")"
            guard templateKey != trafficRasterTemplate || isVisible != trafficRasterVisible else { return }
            guard let style = map.style else { return }

            let tileLayers = ["navi-astra-traffic-flow", "navi-astra-traffic-incidents"]
            for identifier in tileLayers {
                if let layer = style.layer(withIdentifier: identifier) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: identifier) { style.removeSource(source) }
            }
            trafficRasterTemplate = templateKey
            trafficRasterVisible = isVisible
            guard isVisible else { return }

            let tileSources: [(identifier: String, template: String?, opacity: Double)] = [
                ("navi-astra-traffic-flow", flowTemplate, 0.78),
                ("navi-astra-traffic-incidents", incidentTemplate, 0.88)
            ]
            for tile in tileSources {
                guard let template = tile.template else { continue }
                let source = MLNRasterTileSource(identifier: tile.identifier,
                                                 tileURLTemplates: [template],
                                                 options: [.tileSize: 256])
                let layer = MLNRasterStyleLayer(identifier: tile.identifier, source: source)
                layer.rasterOpacity = NSExpression(forConstantValue: tile.opacity)
                style.addSource(source)
                if let firstLabelLayer = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                    style.insertLayer(layer, below: firstLabelLayer)
                } else {
                    style.addLayer(layer)
                }
            }
        }

        private func updateClosurePin(on map: MLNMapView) {
            guard parent.settings.overlays.traffic, let flow = parent.state.traffic?.flow, flow.roadClosure, !flow.coordinates.isEmpty else {
                removeClosurePin(from: map)
                return
            }
            if closurePin == nil {
                let pin = MLNPointAnnotation()
                pin.title = "Droga zamknięta"
                pin.subtitle = "TomTom zgłasza zamknięty odcinek drogi."
                closurePin = pin
                map.addAnnotation(pin)
            }
            closurePin?.coordinate = flow.coordinates[flow.coordinates.count / 2].cl
        }

        private func removeClosurePin(from map: MLNMapView) {
            if let closurePin { map.removeAnnotation(closurePin); self.closurePin = nil }
        }

        private var showsOnlyRouteEndpoints: Bool {
            parent.state.destination != nil && parent.state.status != .idle
        }

        private func styledLine(for polyline: MLNPolyline) -> StyledLine? {
            if let line = routeLines.first(where: { $0.polyline === polyline }) { return line }
            if let line = incidentLinesByID.values.joined().first(where: { $0.polyline === polyline }) { return line }
            if accuracyHaloLine?.polyline === polyline { return accuracyHaloLine }
            if traveledLine?.polyline === polyline { return traveledLine }
            if trafficLine?.polyline === polyline { return trafficLine }
            return nil
        }

        private func lineStyle(for kind: RouteLineKind, navigating navigationOverride: Bool? = nil) -> LineStyle {
            let navigating = navigationOverride ?? (parent.state.status == .navigating || parent.state.status == .rerouting)
            let dark = parent.colorScheme == .dark
            switch kind {
            case .activeCasing:
                return LineStyle(hex: dark ? RouteColorPalette.casingDark : RouteColorPalette.casingLight,
                                 opacity: 0.82, width: activeRouteWidth(navigating: navigating) + 4)
            case .active:
                return LineStyle(hex: activeRouteColor(dark: dark),
                                 opacity: parent.state.status == .rerouting ? 0.3 : 1,
                                 width: activeRouteWidth(navigating: navigating))
            case .activeHighlight:
                let opacity = parent.state.status == .rerouting ? 0.2 : (dark ? 0.76 : 0.66)
                return LineStyle(hex: 0xFFFFFF, opacity: opacity,
                                 width: max(1.5, activeRouteWidth(navigating: navigating) * 0.22))
            case .future:
                return LineStyle(hex: dark ? RouteColorPalette.alternativeDark : RouteColorPalette.alternativeLight,
                                 opacity: 0.82, width: max(4, activeRouteWidth(navigating: navigating) - 4))
            case .journeyCasing(let walking, let cycling):
                let width = journeyLegWidth(walking: walking, cycling: cycling, navigating: navigating)
                return LineStyle(hex: dark ? RouteColorPalette.casingDark : RouteColorPalette.casingLight,
                                 opacity: walking ? 0.76 : 0.82, width: width + (walking ? 3 : 4))
            case .journeyLeg(let color, let walking, let cycling):
                return LineStyle(hex: color, opacity: 1,
                                 width: journeyLegWidth(walking: walking, cycling: cycling, navigating: navigating))
            case .alternative:
                return LineStyle(hex: dark ? RouteColorPalette.alternativeDark : RouteColorPalette.alternativeLight,
                                 opacity: navigating ? 0 : 0.52, width: 5)
            case .accuracy:
                return LineStyle(hex: 0x26A69A, opacity: 0.14, width: 6)
            case .incidentCasing:
                return LineStyle(hex: 0xFFFFFF, opacity: 0.9, width: navigating ? 10 : 8)
            case .incident(let color):
                return LineStyle(hex: color, opacity: 0.96, width: navigating ? 7 : 5)
            case .traveled:
                return LineStyle(hex: RouteColorPalette.traveled, opacity: 0.44,
                                 width: max(1, activeRouteWidth(navigating: navigating) - 1))
            case .traffic:
                return LineStyle(hex: parent.state.traffic?.flow?.overlayColorHex ?? RouteColorPalette.trafficFree,
                                 opacity: 1, width: 4.5)
            case .departed:
                return LineStyle(hex: dark ? RouteColorPalette.alternativeDark : RouteColorPalette.alternativeLight,
                                 opacity: 0, width: 6)
            }
        }

        private func activeRouteColor(dark: Bool) -> UInt32 {
            switch parent.state.transportMode {
            case .car, .transit, .parkRide: dark ? RouteColorPalette.activeDark : RouteColorPalette.activeLight
            case .walking: RouteColorPalette.walking
            case .bicycle: RouteColorPalette.cycling
            }
        }

        private func activeRouteWidth(navigating: Bool) -> CGFloat {
            switch parent.state.transportMode {
            case .car, .transit, .parkRide: navigating ? 11 : 8
            case .walking: navigating ? 8 : 6
            case .bicycle: navigating ? 10 : 8
            }
        }

        private func journeyLegWidth(walking: Bool, cycling: Bool, navigating: Bool) -> CGFloat {
            if walking { return navigating ? 8 : 6 }
            if cycling { return navigating ? 10 : 8 }
            return navigating ? 11 : 8
        }

        private func presentedStyle(for line: StyledLine) -> LineStyle {
            let target = lineStyle(for: line.kind)
            guard let start = line.transitionFrom, let transitionStartedAt = line.transitionStartedAt else { return target }
            let amount = CGFloat(max(0, min(1, Date().timeIntervalSince(transitionStartedAt) / 0.3)))
            return LineStyle(hex: interpolate(start.hex, target.hex, amount: amount),
                             opacity: start.opacity + (target.opacity - start.opacity) * amount,
                             width: start.width + (target.width - start.width) * amount)
        }

        private func interpolate(_ start: UInt32, _ end: UInt32, amount: CGFloat) -> UInt32 {
            func channel(_ shift: UInt32) -> UInt32 {
                let startValue = CGFloat((start >> shift) & 0xFF)
                let endValue = CGFloat((end >> shift) & 0xFF)
                return UInt32((startValue + (endValue - startValue) * amount).rounded())
            }
            return (channel(16) << 16) | (channel(8) << 8) | channel(0)
        }

        private func color(hex: UInt32, opacity: CGFloat) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: opacity)
        }

        private struct StyledLine {
            let polyline: MLNPolyline
            let coordinates: [Coordinate]
            let kind: RouteLineKind
            let routeID: UUID?
            var transitionFrom: LineStyle?
            var transitionStartedAt: Date?
        }
        private struct LineStyle {
            let hex: UInt32
            let opacity: CGFloat
            let width: CGFloat
        }
    }
}

private enum CameraAnimator {
    static func apply(_ intent: CameraIntent, state: NavigationCameraState, to map: MLNMapView) {
        if !intent.bounds.isEmpty, state == .destinationPreview || state == .routeOverview || state == .arrived {
            let camera = map.camera
            camera.pitch = CGFloat(intent.pitch)
            camera.heading = intent.bearing
            map.setCamera(camera, withDuration: 0, animationTimingFunction: nil)
            let lats = intent.bounds.map(\.latitude), lons = intent.bounds.map(\.longitude)
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                             ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
            map.setVisibleCoordinateBounds(bounds,
                edgePadding: UIEdgeInsets(top: CGFloat(intent.padding.top), left: CGFloat(intent.padding.left),
                                          bottom: CGFloat(intent.padding.bottom), right: CGFloat(intent.padding.right)),
                animated: true, completionHandler: nil)
            return
        }
        let camera = map.camera
        camera.centerCoordinate = intent.target.cl
        camera.pitch = CGFloat(intent.pitch)
        camera.heading = intent.bearing
        camera.altitude = max(120, camera.altitude * pow(2, map.zoomLevel - intent.zoom))
        let duration: TimeInterval = switch state {
        case .startingNavigation: 1.1
        case .maneuverNow: 0.45
        case .leavingManeuver: 0.7
        case .approachingManeuver: 0.4
        case .followNavigation, .rerouting, .weakGPS: 0.28
        default: 0.45
        }
        map.setCamera(camera, withDuration: duration, animationTimingFunction: nil,
                      edgePadding: UIEdgeInsets(top: intent.padding.top, left: intent.padding.left,
                                                bottom: intent.padding.bottom, right: intent.padding.right),
                      completionHandler: nil)
    }
}


/// NaviAstra's visual layer on top of the OpenFreeMap / OpenMapTiles schema.
/// No fabricated POI, heights, traffic, or elevation data are introduced here.
private final class NaviAstraMapStyle {
    private var lastKey = ""
    private var originalPredicates: [String: NSPredicate] = [:]
    private var configured = false

    func reset() {
        lastKey = ""
        originalPredicates.removeAll()
        configured = false
    }

    func apply(to style: MLNStyle, settings: MapSettings, dark: Bool, zoom: Double) {
        if !configured {
            configure(style)
            configured = true
        }
        let density = zoom < 15 ? 0 : (zoom < 17 ? 1 : 2)
        let categories = settings.visiblePOICategories.sorted { $0.rawValue < $1.rawValue }
        let key = "\(dark)-\(settings.context)-\(categories.map(\.rawValue))-\(density)-\(settings.overlays.buildings3D)-\(settings.cameraMode)-\(settings.overlays.transit)"
        guard key != lastKey else { return }
        lastKey = key
        style.transition = MLNTransition(duration: 0.4, delay: 0)
        let navigating = settings.context.isNavigating
        let light = style.light
        let lightPosition = MLNSphericalPositionMake(1.15, dark ? 220 : 225, dark ? 55 : 50)
        light.anchor = NSExpression(forConstantValue: "map")
        light.position = NSExpression(forConstantValue: NSValue(mlnSphericalPosition: lightPosition))
        light.intensity = NSExpression(forConstantValue: dark ? 0.34 : 0.56)
        light.color = NSExpression(forConstantValue: color(dark ? 0xC8D8E8 : 0xFFF9EF))
        light.positionTransition = MLNTransition(duration: 0.4, delay: 0)
        light.intensityTransition = MLNTransition(duration: 0.4, delay: 0)
        light.colorTransition = MLNTransition(duration: 0.4, delay: 0)
        style.light = light
        let background = color(dark ? 0x111D29 : 0xF2F4F1)
        let text = color(dark ? 0xD5E3EC : 0x344D5B)
        let muted = color(dark ? 0x8B9FAA : 0x788B93)
        let water = color(dark ? 0x16384A : 0xB9DFEC)
        let majorRoad = color(dark ? 0x799AA8 : 0xFFFFFF)
        let minorRoad = color(dark ? 0x354B59 : 0xFFFFFF)
        let values = categories.flatMap(\.tileValues)
        let categoryPredicate = values.isEmpty ? NSPredicate(value: false) :
            NSPredicate(format: "class IN %@ OR subclass IN %@", values, values)
        let providerTransitValues = MapPOICategory.transit.tileValues.filter { $0 != "airport" }
        let hideProviderTransitPredicate = NSPredicate(
            format: "NOT (class IN %@ OR subclass IN %@)", providerTransitValues, providerTransitValues)

        for layer in style.layers {
            let id = layer.identifier
            if let layer = layer as? MLNBackgroundStyleLayer {
                layer.backgroundColor = NSExpression(forConstantValue: background)
            }
            // The low-zoom raster would otherwise retain its daytime colors at night.
            if id == "natural_earth" { layer.isVisible = !dark }
            if let layer = layer as? MLNFillStyleLayer {
                if id == "naviastra-forest-tree-pattern" {
                    layer.fillPattern = NSExpression(forConstantValue: forestPatternName(dark: dark, dense: false))
                    continue
                }
                if id == "naviastra-forest-tree-pattern-dense" {
                    layer.fillPattern = NSExpression(forConstantValue: forestPatternName(dark: dark, dense: true))
                    continue
                }
                if id == "naviastra-water-wave-pattern" {
                    layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: dark, dense: false))
                    continue
                }
                if id == "naviastra-water-wave-pattern-dense" {
                    layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: dark, dense: true))
                    continue
                }
                let source = layer.sourceLayerIdentifier ?? ""
                let fill: UIColor
                switch source {
                case "water":
                    layer.fillColor = waterColorExpression(dark: dark)
                    layer.fillOpacity = NSExpression(mglJSONObject: [
                        "case", ["==", ["get", "intermittent"], 1], 0.82, 1
                    ])
                    continue
                case "waterway": fill = water
                case "park": fill = color(dark ? 0x203F37 : 0xCCE3C9)
                case "landcover":
                    layer.fillColor = landcoverColorExpression(dark: dark)
                    continue
                case "landuse": fill = color(dark ? 0x23313B : 0xE8ECE5)
                case "building": fill = color(dark ? 0x303E48 : 0xDAD5CD)
                case "aeroway": fill = color(dark ? 0x2B3C48 : 0xDCE4E8)
                default: continue
                }
                layer.fillColor = NSExpression(forConstantValue: fill)
                if source == "building" {
                    let neutralColor = dark ? "#303E48" : "#DAD5CD"
                    layer.fillColor = buildingColorExpression(neutralColor: neutralColor)
                    layer.fillOpacity = NSExpression(forConstantValue: navigating ? 0.42 : 0.75)
                    layer.fillOutlineColor = NSExpression(forConstantValue: color(dark ? 0x4A606B : 0xC2CFD4))
                }
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer {
                layer.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                layer.fillExtrusionColor = buildingColorExpression(neutralColor: dark ? "#43515B" : "#D7D1C8")
                layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    15, navigating ? 0.08 : 0.12,
                    16, navigating ? 0.28 : 0.48,
                    17, navigating ? 0.42 : 0.72
                ])
                layer.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
                layer.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: 0.45)
            }
            if let layer = layer as? MLNLineStyleLayer {
                let source = layer.sourceLayerIdentifier ?? ""
                if source == "transportation" {
                    let casing = id.contains("casing")
                    let rail = id.contains("rail")
                    let main = id.contains("motorway") || id.contains("trunk") || id.contains("primary")
                    let path = id.contains("path") || id.contains("pedestrian")
                    let pathFocus = settings.context == .walking || settings.context == .cycling
                    let roadColor: UIColor = rail ? color(dark ? 0x78949F : 0x91A8B3) :
                        (casing ? color(dark ? 0x1B2A36 : 0xCBD7DB) :
                            (path && pathFocus ? color(dark ? 0x74CBB5 : 0x459983) : (main ? majorRoad : minorRoad)))
                    layer.lineColor = NSExpression(forConstantValue: roadColor)
                    layer.lineOpacity = NSExpression(forConstantValue: navigating && !main && !pathFocus ? 0.48 : 1.0)
                    if rail {
                        layer.lineOpacity = NSExpression(forConstantValue: settings.overlays.transit || settings.context == .transit ? 1.0 : 0.35)
                        layer.lineColor = NSExpression(forConstantValue: settings.overlays.transit ? color(dark ? 0xBBA8ED : 0x8071B0) : roadColor)
                    }
                } else if source == "waterway" {
                    layer.lineColor = NSExpression(forConstantValue: water)
                    layer.lineWidth = NSExpression(mglJSONObject: [
                        "interpolate", ["linear"], ["zoom"],
                        9, ["match", ["get", "class"], "river", 1.0, "canal", 0.8, 0.55],
                        16, ["match", ["get", "class"], "river", 3.0, "canal", 2.2, 1.25]
                    ])
                } else if source == "boundary" {
                    layer.lineColor = NSExpression(forConstantValue: muted)
                    layer.lineOpacity = NSExpression(forConstantValue: navigating ? 0.2 : 0.5)
                } else if source == "aeroway" {
                    layer.lineColor = NSExpression(forConstantValue: color(dark ? 0x5D707A : 0xC0CDD5))
                } else if source == "park" {
                    layer.lineColor = NSExpression(forConstantValue: color(dark ? 0x355647 : 0xADCDB1))
                }
            }
            if let layer = layer as? MLNSymbolStyleLayer {
                let source = layer.sourceLayerIdentifier ?? ""
                layer.textColor = NSExpression(forConstantValue: source == "water_name" ? color(dark ? 0x83B3C9 : 0x4E8399) : text)
                layer.textHaloColor = NSExpression(forConstantValue: background)
                layer.textHaloWidth = NSExpression(forConstantValue: 1.2)
                if source == "poi" {
                    layer.iconImageName = poiIconExpression(dark: dark)
                    let rank = NSPredicate(format: "rank <= %d", density == 0 ? 3 : (density == 1 ? 19 : 1000))
                    let original = originalPredicates[id] ?? NSPredicate(value: true)
                    layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        original, categoryPredicate, hideProviderTransitPredicate, rank
                    ])
                    layer.isVisible = !categories.isEmpty
                    layer.textOpacity = NSExpression(forConstantValue: 1)
                    layer.iconOpacity = NSExpression(forConstantValue: 1)
                } else if id.contains("highway-name-minor") || id.contains("highway-name-path") {
                    layer.textOpacity = NSExpression(forConstantValue: navigating && settings.context == .driving ? 0.4 : 1.0)
                } else if source == "place" {
                    layer.textOpacity = NSExpression(forConstantValue: navigating ? 0.6 : 1.0)
                }
            }
        }
    }

    private func configure(_ style: MLNStyle) {
        for kind in PlacePOIMapMarkerKind.allCases {
            style.setImage(kind.makeMapStyleImage(dark: false), forName: poiImageName(kind, dark: false))
            style.setImage(kind.makeMapStyleImage(dark: true), forName: poiImageName(kind, dark: true))
        }
        for dark in [false, true] {
            style.setImage(forestTreePattern(dark: dark, dense: false),
                           forName: forestPatternName(dark: dark, dense: false))
            style.setImage(forestTreePattern(dark: dark, dense: true),
                           forName: forestPatternName(dark: dark, dense: true))
            style.setImage(waterWavePattern(dark: dark, dense: false),
                           forName: waterPatternName(dark: dark, dense: false))
            style.setImage(waterWavePattern(dark: dark, dense: true),
                           forName: waterPatternName(dark: dark, dense: true))
        }
        for layer in style.layers {
            if let layer = layer as? MLNSymbolStyleLayer, layer.sourceLayerIdentifier == "poi" {
                if let predicate = layer.predicate { originalPredicates[layer.identifier] = predicate }
                switch layer.identifier {
                case "poi_r1": layer.minimumZoomLevel = 12
                case "poi_r7": layer.minimumZoomLevel = 15
                case "poi_r20": layer.minimumZoomLevel = 17
                case "poi_transit": layer.minimumZoomLevel = 14
                default: break
                }
                layer.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
                layer.textFontSize = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 12, 11, 17, 13])
                // Preserve collision detection: more available features must not mean overlapping labels.
                layer.textAllowsOverlap = NSExpression(forConstantValue: false)
                layer.iconAllowsOverlap = NSExpression(forConstantValue: false)
            }
            if let layer = layer as? MLNFillStyleLayer, layer.sourceLayerIdentifier == "building" {
                layer.maximumZoomLevel = 24 // Retain footprints when extrusion is disabled.
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer {
                layer.minimumZoomLevel = 15
                layer.predicate = NSPredicate(format: "hide_3d != true")
                layer.fillExtrusionHeight = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    15, 0, 16, ["*", ["coalesce", ["get", "render_height"], 0], 0.4],
                    17, ["coalesce", ["get", "render_height"], 0]
                ])
                layer.fillExtrusionBase = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    15, 0, 16, ["*", ["coalesce", ["get", "render_min_height"], 0], 0.4],
                    17, ["coalesce", ["get", "render_min_height"], 0]
                ])
            }
            if let layer = layer as? MLNLineStyleLayer, layer.sourceLayerIdentifier == "transportation",
               !layer.identifier.contains("rail"), !layer.identifier.contains("hatching") {
                let id = layer.identifier
                let major = id.contains("motorway") || id.contains("trunk") || id.contains("primary")
                let secondary = id.contains("secondary") || id.contains("tertiary")
                let path = id.contains("path") || id.contains("pedestrian")
                let casing: Double = id.contains("casing") ? 1.5 : 0
                let width: Double = major ? 11 : (secondary ? 8 : (path ? 3 : 5))
                layer.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["exponential", 1.4], ["zoom"],
                    10, (major ? 1.5 : 0.4) + casing * 0.3, 15, width * 0.45 + casing, 18, width + casing])
            }
        }
        installForestTreePatternLayers(in: style)
        installWaterWavePatternLayers(in: style)
        if style.layer(withIdentifier: "naviastra-house-numbers") == nil,
           let source = style.source(withIdentifier: "openmaptiles") {
            let numbers = MLNSymbolStyleLayer(identifier: "naviastra-house-numbers", source: source)
            numbers.sourceLayerIdentifier = "housenumber"
            numbers.minimumZoomLevel = 17
            numbers.text = NSExpression(forKeyPath: "housenumber")
            numbers.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            numbers.textFontSize = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 17, 10, 19, 13])
            numbers.textAllowsOverlap = NSExpression(forConstantValue: false)
            style.addLayer(numbers)
        }
    }

    private func installForestTreePatternLayers(in style: MLNStyle) {
        guard let source = style.source(withIdentifier: "openmaptiles"),
              let lastLandcoverFill = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "landcover" }) else { return }

        let forestFilter = NSPredicate(format: "subclass IN %@", ["forest", "wood"])
        let layers: [(String, Float, Float, Bool)] = [
            ("naviastra-forest-tree-pattern", 13, 15, false),
            ("naviastra-forest-tree-pattern-dense", 15, 24, true)
        ]
        for (identifier, minimumZoom, maximumZoom, dense) in layers
            where style.layer(withIdentifier: identifier) == nil {
            let layer = MLNFillStyleLayer(identifier: identifier, source: source)
            layer.sourceLayerIdentifier = "landcover"
            layer.predicate = forestFilter
            layer.minimumZoomLevel = minimumZoom
            layer.maximumZoomLevel = maximumZoom
            layer.fillPattern = NSExpression(forConstantValue: forestPatternName(dark: false, dense: dense))
            layer.fillOpacity = NSExpression(forConstantValue: 0.78)
            style.insertLayer(layer, above: lastLandcoverFill)
        }
    }

    private func installWaterWavePatternLayers(in style: MLNStyle) {
        guard let source = style.source(withIdentifier: "openmaptiles"),
              let lastWaterFill = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "water" }) else { return }

        let waterFilter = NSPredicate(format: "class IN %@", ["ocean", "lake", "river", "pond", "dock"])
        let layers: [(String, Float, Float, Bool)] = [
            ("naviastra-water-wave-pattern", 12, 15, false),
            ("naviastra-water-wave-pattern-dense", 15, 24, true)
        ]
        for (identifier, minimumZoom, maximumZoom, dense) in layers
            where style.layer(withIdentifier: identifier) == nil {
            let layer = MLNFillStyleLayer(identifier: identifier, source: source)
            layer.sourceLayerIdentifier = "water"
            layer.predicate = waterFilter
            layer.minimumZoomLevel = minimumZoom
            layer.maximumZoomLevel = maximumZoom
            layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: false, dense: dense))
            layer.fillOpacity = NSExpression(forConstantValue: dense ? 0.2 : 0.12)
            style.insertLayer(layer, above: lastWaterFill)
        }
    }

    private func landcoverColorExpression(dark: Bool) -> NSExpression {
        let forest = hexColor(dark ? 0x1D3931 : 0xBAD7BF)
        let scrub = hexColor(dark ? 0x263D34 : 0xCADCC6)
        let grass = hexColor(dark ? 0x294235 : 0xDDEBD3)
        let meadow = hexColor(dark ? 0x2B4035 : 0xE5EED7)
        let cultivated = hexColor(dark ? 0x303E34 : 0xD9E7CD)
        let garden = hexColor(dark ? 0x29483A : 0xD9ECD5)
        let wetland = hexColor(dark ? 0x263F40 : 0xD1E3D8)
        let sand = hexColor(dark ? 0x3D3B30 : 0xEDE4C7)
        let rock = hexColor(dark ? 0x3D4142 : 0xDFDDD3)
        let ice = hexColor(dark ? 0x30434B : 0xE6F0F1)
        let byClass: [Any] = [
            "match", ["get", "class"],
            "wood", forest, "grass", grass, "farmland", cultivated,
            "wetland", wetland, "sand", sand, "rock", rock, "ice", ice, forest
        ]
        let expression: [Any] = [
            "match", ["get", "subclass"],
            ["forest", "wood"], forest,
            ["scrub", "shrubbery", "heath", "fell", "mangrove"], scrub,
            ["grass", "grassland", "golf_course", "wet_meadow"], grass,
            ["meadow"], meadow,
            ["orchard", "vineyard", "farm", "farmland", "plant_nursery"], cultivated,
            ["garden", "flowerbed", "allotments", "recreation_ground", "village_green"], garden,
            ["marsh", "reedbed", "swamp", "bog", "wetland", "saltmarsh", "tidalflat"], wetland,
            ["sand", "beach", "dune"], sand,
            ["bare_rock", "scree"], rock,
            ["glacier"], ice,
            byClass
        ]
        return NSExpression(mglJSONObject: expression)
    }

    private func waterColorExpression(dark: Bool) -> NSExpression {
        let expression: [Any] = [
            "match", ["get", "class"],
            "ocean", hexColor(dark ? 0x16384A : 0xB5DDEB),
            "lake", hexColor(dark ? 0x194052 : 0xB9E0ED),
            "river", hexColor(dark ? 0x1B465A : 0xADD9EA),
            "pond", hexColor(dark ? 0x1E4858 : 0xB1DCEB),
            "dock", hexColor(dark ? 0x1D4354 : 0xA9D7E8),
            "swimming_pool", hexColor(dark ? 0x23566A : 0x83CDE5),
            hexColor(dark ? 0x194052 : 0xB9E0ED)
        ]
        return NSExpression(mglJSONObject: expression)
    }

    private func forestPatternName(dark: Bool, dense: Bool) -> String {
        "naviastra-forest-\(dense ? "dense-" : "")\(dark ? "dark" : "light")"
    }

    private func waterPatternName(dark: Bool, dense: Bool) -> String {
        "naviastra-water-\(dense ? "dense-" : "")\(dark ? "dark" : "light")"
    }

    private func forestTreePattern(dark: Bool, dense: Bool) -> UIImage {
        let tileSize: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tileSize, height: tileSize), format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let positions: [(CGFloat, CGFloat, CGFloat)] = dense
                ? [(7, 8, 8), (23, 6, 9), (42, 9, 8), (56, 17, 9), (13, 26, 8),
                   (34, 25, 9), (52, 36, 8), (4, 47, 8), (24, 48, 9), (43, 53, 8)]
                : [(12, 12, 10), (43, 17, 11), (28, 36, 10), (54, 48, 10), (5, 53, 9)]
            let canopy = color(dark ? 0x5C846D : 0x729A7C).withAlphaComponent(0.78).cgColor
            let highlight = color(dark ? 0x426B56 : 0x91B398).withAlphaComponent(0.74).cgColor
            let trunk = color(dark ? 0xB4A27D : 0x897653).withAlphaComponent(0.62).cgColor

            for (index, tree) in positions.enumerated() {
                let (x, y, size) = tree
                let half = size / 2
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: y - half))
                path.addLine(to: CGPoint(x: x - half * 0.85, y: y + half * 0.62))
                path.addLine(to: CGPoint(x: x + half * 0.85, y: y + half * 0.62))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(index.isMultiple(of: 2) ? canopy : highlight)
                context.fillPath()

                let trunkRect = CGRect(x: x - 0.55, y: y + half * 0.48, width: 1.1, height: 1.7)
                context.setFillColor(trunk)
                context.fill(trunkRect)
            }
        }
    }

    private func waterWavePattern(dark: Bool, dense: Bool) -> UIImage {
        let tileSize: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tileSize, height: tileSize), format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let rows: [CGFloat] = dense ? [8, 24, 40, 56] : [16, 48]
            context.setStrokeColor(color(dark ? 0x74AFC3 : 0x4B98B0).withAlphaComponent(0.72).cgColor)
            context.setLineWidth(dense ? 0.9 : 0.75)
            for (index, y) in rows.enumerated() {
                let offset = index.isMultiple(of: 2) ? CGFloat(0) : CGFloat(5)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: -4, y: y + offset))
                path.addCurve(to: CGPoint(x: 68, y: y + offset),
                              control1: CGPoint(x: 18, y: y - 5 + offset),
                              control2: CGPoint(x: 46, y: y + 5 + offset))
                context.addPath(path)
                context.strokePath()
            }
        }
    }

    private func hexColor(_ hex: UInt32) -> String {
        String(format: "#%06X", hex)
    }

    private func poiImageName(_ kind: PlacePOIMapMarkerKind, dark: Bool) -> String {
        "naviastra-poi-\(kind.rawValue)-\(dark ? "dark" : "light")"
    }

    private func poiIconExpression(dark: Bool) -> NSExpression {
        let kinds = PlacePOIMapMarkerKind.allCases.filter { $0 != .generic }
        func matchExpression(for property: String, fallback: Any) -> [Any] {
            var expression: [Any] = ["match", ["get", property]]
            for kind in kinds where !kind.tileValues.isEmpty {
                expression.append(kind.tileValues)
                expression.append(poiImageName(kind, dark: dark))
            }
            expression.append(fallback)
            return expression
        }
        let subclassMatch = matchExpression(for: "subclass", fallback: poiImageName(.generic, dark: dark))
        return NSExpression(mglJSONObject: matchExpression(for: "class", fallback: subclassMatch))
    }

    private func buildingColorExpression(neutralColor: String) -> NSExpression {
        // OpenMapTiles has an explicit `colour` tag but no building class; keep OSM color as a restrained 22% tint.
        NSExpression(mglJSONObject: [
            "interpolate", ["linear"], 0.22,
            0, neutralColor,
            1, ["to-color", ["get", "colour"], neutralColor]
        ])
    }

    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif
