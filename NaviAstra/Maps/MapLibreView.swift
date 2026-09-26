#if os(iOS)
import Foundation
import MapLibre
import QuartzCore
import SwiftUI
import UIKit

@MainActor
private final class PuckDisplayLinkTarget: NSObject {
    weak var coordinator: MapLibreView.Coordinator?

    @objc func render(_ link: CADisplayLink) {
        coordinator?.renderPuckFrame(link)
    }
}

private nonisolated enum RouteLineKind: Equatable {
    case activeCasing, active, activeHighlight, future, alternative, traveledCasing, traveled, traffic, departed, accuracy
    case routeTraffic(color: UInt32)
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
    let isPlanningCarRoute: Bool
    let isNavigating: Bool
    let isTransitRoutePreview: Bool
    let routeStopIDs: Set<String>
    let userCoordinate: Coordinate?
    let routeEndpointCoordinates: [Coordinate]
    let visibleRadius: Double
}

struct MapLibreView: UIViewRepresentable {
    let scene: MapScene

    var state: NavigationState { scene.navigationState }
    var transitVehicles: [TransitVehicle] { scene.transit.vehicles }
    var transitStops: [TransitStop] { scene.transit.stops }
    var selectedTransitStopID: String? { scene.transit.selectedStopID }
    var selectedTransitRouteID: String? { scene.transit.selectedRouteID }
    var selectedTransitTripID: String? { scene.transit.selectedTripID }
    var selectedTransitTripStopIDs: Set<String> { scene.transit.selectedTripStopIDs }
    var activeTransitStopID: String? { scene.transit.activeStopID }
    var alightingTransitStopID: String? { scene.transit.alightingStopID }
    var transitLineCoordinates: [Coordinate] { scene.transit.lineCoordinates }
    var transitLineColor: UInt32? { scene.transit.lineColor }
    var settings: MapSettings { scene.settings }
    var isSearchPresented: Bool { scene.isSearchPresented }
    var routePreviewExpanded: Bool { scene.routePreviewExpanded }
    var viewportPadding: CameraPadding { scene.viewportPadding }
    var onSearchSelect: (Destination) -> Void { scene.commands.onSearchSelect }
    var onPlaceSelect: ([SearchResult]) -> Void { scene.commands.onPlaceSelect }
    var onTransitStopSelect: (TransitStop) -> Void { scene.commands.onTransitStopSelect }
    var onTransitVehicleSelect: (TransitVehicle) -> Void { scene.commands.onTransitVehicleSelect }
    var onMapReady: () -> Void { scene.commands.onMapReady }
    var onMapPan: () -> Void { scene.commands.onMapPan }
    var onLongPress: (Coordinate) -> Void { scene.commands.onLongPress }
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
        context.coordinator.startPuckDisplayLink()
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        guard !isSearchPresented else { return }
        context.coordinator.update(map)
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        coordinator.stopPuckDisplayLink()
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapLibreView
        weak var map: MLNMapView?
        private var routeLines: [StyledLine] = []
        private var incidentLinesByID: [String: [StyledLine]] = [:]
        private var incidentLineRenderItems: [IncidentLineRenderItem] = []
        private var activeRouteSource: MLNShapeSource?
        private var completedRouteSource: MLNShapeSource?
        private var revealGeometry: RouteRevealGeometry?
        private var revealRouteID: UUID?
        private var activeRouteStyleKey = ""
        private var trafficLine: StyledLine?
        private var accuracyHaloLine: StyledLine?
        private var accuracyHaloCenter: Coordinate?
        private var accuracyHaloRadius: Double?
        private var destinationPin: MLNPointAnnotation?
        private var routeOriginPin: MLNPointAnnotation?
        private var vehiclePin: MLNPointAnnotation?
        private let puckEngine = NavigationPuckEngine()
        private var puckDisplayLink: CADisplayLink?
        private var puckDisplayLinkTarget: PuckDisplayLinkTarget?
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
        private var activeGeometryProgressRouteID: UUID?
        private var activeGeometryProgressStep: Int?
        private var trafficCoordinates: [Coordinate]?
        private var trafficColorHex: UInt32?
        private var shownRouteTrafficSegments: [RouteTrafficSegment] = []
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

        func startPuckDisplayLink() {
            guard puckDisplayLink == nil else { return }
            let target = PuckDisplayLinkTarget()
            target.coordinator = self
            let displayLink = CADisplayLink(target: target, selector: #selector(PuckDisplayLinkTarget.render(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
            displayLink.isPaused = true
            displayLink.add(to: .main, forMode: .common)
            puckDisplayLinkTarget = target
            puckDisplayLink = displayLink
        }

        func stopPuckDisplayLink() {
            puckDisplayLink?.invalidate()
            puckDisplayLink = nil
            puckDisplayLinkTarget?.coordinator = nil
            puckDisplayLinkTarget = nil
        }

        func renderPuckFrame(_ link: CADisplayLink) {
            renderPuckFrame()
        }

        private func renderPuckFrame() {
            guard let map, let frame = puckEngine.frame() else { return }
            if vehiclePin == nil {
                let pin = MLNPointAnnotation()
                pin.title = "Twoja pozycja"
                vehiclePin = pin
                map.addAnnotation(pin)
            }
            vehiclePin?.coordinate = frame.coordinate.cl
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            vehicleAnnotationView?.centerOffset = isNavigating ? CGVector(dx: 0, dy: 18) : .zero
            if isNavigating, let bearing = frame.bearing {
                let relativeBearing = bearing - map.camera.heading
                vehicleArrow?.isHidden = false
                vehicleArrow?.transform = CGAffineTransform(rotationAngle: CGFloat(relativeBearing * .pi / 180))
            } else {
                vehicleArrow?.isHidden = true
                vehicleArrow?.transform = .identity
            }
        }

        private func updatePuck(on map: MLNMapView) {
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let activeRoute = isNavigating ? parent.state.route : nil
            let matchedRoute: NavigationRouteMatch? = parent.state.routeMatch.flatMap { match -> NavigationRouteMatch? in
                guard let activeRoute,
                      match.routeID == activeRoute.id,
                      match.locationTimestamp == parent.state.location?.timestamp else { return nil }
                return match
            }
            puckEngine.update(location: parent.state.location, route: activeRoute,
                              isNavigating: isNavigating, matchedRoute: matchedRoute)
            puckDisplayLink?.isPaused = !isNavigating || parent.state.location == nil
            renderPuckFrame()
            if let marker = vehicleMarker {
                marker.layer.borderColor = parent.state.weakGPS ? UIColor.systemOrange.cgColor : UIColor.white.cgColor
                marker.layer.shadowColor = parent.state.weakGPS ? UIColor.systemOrange.cgColor : UIColor.black.cgColor
                marker.layer.shadowOpacity = parent.state.weakGPS ? 0.42 : 0.22
                marker.layer.shadowRadius = parent.state.weakGPS ? 7 : 4
            }
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

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            updatePOIZoomDensity(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            navigationStyle.reset()
            updatePOIDensity(on: mapView)
            activeRouteSource = nil
            completedRouteSource = nil
            activeRouteStyleKey = ""
            activeGeometryProgressRouteID = nil
            activeGeometryProgressStep = nil
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
                activeGeometryProgressRouteID = nil
                activeGeometryProgressStep = nil
                shownRouteTrafficSegments = []
                activeRouteSource?.shape = nil
                completedRouteSource?.shape = nil
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

            updateActiveRouteGeometryProgress(on: map)
            updateTrafficLine(on: map)
            updateRouteTrafficLines(on: map)
            updateTrafficRasterLayer(on: map)
            if showsOnlyRouteEndpoints {
                removeClosurePin(from: map)
            } else {
                updateClosurePin(on: map)
            }
            updateAccuracyHalo(on: map)

            if let destination = parent.state.destination, parent.state.status != .idle,
               !parent.state.routeOriginMapSelectionActive {
                if destinationPin == nil {
                    let pin = MLNPointAnnotation(); pin.title = destination.name
                    destinationPin = pin; map.addAnnotation(pin)
                }
                destinationPin?.coordinate = destination.coordinate.cl
            } else if let pin = destinationPin { map.removeAnnotation(pin); destinationPin = nil }

            if let origin = parent.state.routeOrigin, !origin.isCurrentLocation,
               !parent.state.routeOriginMapSelectionActive,
               parent.state.status != .idle {
                if routeOriginPin == nil {
                    let pin = MLNPointAnnotation()
                    routeOriginPin = pin
                    map.addAnnotation(pin)
                }
                routeOriginPin?.title = "A · \(origin.name)"
                routeOriginPin?.subtitle = origin.address
                routeOriginPin?.coordinate = (parent.state.route?.coordinates.first ?? origin.coordinate).cl
            } else if let pin = routeOriginPin {
                map.removeAnnotation(pin)
                routeOriginPin = nil
            }

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

            updatePuck(on: map)
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
            let isPlanningCarRoute = parent.state.transportMode == .car
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
                                                  isPlanningCarRoute: isPlanningCarRoute,
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
                                                            isPlanningCarRoute: isPlanningCarRoute,
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

        private func updatePOIZoomDensity(on map: MLNMapView) {
            guard let style = map.style else { return }
            navigationStyle.updatePOIDensity(to: style, zoom: map.zoomLevel)
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
            if parent.state.transportMode == .walking && cameraState.usesNavigationPerspective {
                // Lower the camera focal point so the puck sits below center while
                // the camera target stays on the route ahead.
                effectiveIntent.padding.top += min(260, max(140, Double(map.bounds.height) * 0.3))
            }
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
            MapLibreCameraAnimator.apply(effectiveIntent, state: cameraState, to: map)
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
            if let routeOriginPin, annotation === routeOriginPin {
                let identifier = "route-origin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MLNAnnotationView(reuseIdentifier: identifier)
                if view.subviews.isEmpty {
                    let marker = UIImageView(image: UIImage(systemName: "a.circle.fill"))
                    marker.tintColor = .systemBlue
                    marker.contentMode = .scaleAspectFit
                    marker.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
                    view.addSubview(marker)
                    view.frame = marker.frame
                }
                view.annotation = annotation
                view.isAccessibilityElement = true
                view.accessibilityLabel = annotation.title.flatMap { $0 } ?? "Punkt startowy"
                view.accessibilityHint = annotation.subtitle.flatMap { $0 }
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
            marker.image = UIImage(systemName: arrived ? "checkmark.circle.fill" : "b.circle.fill")
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
            if parent.state.transportMode == .transit, route.journey != nil {
                (style.source(withIdentifier: "naviastra-active-route-source") as? MLNShapeSource)?.shape = nil
                (style.source(withIdentifier: "naviastra-completed-route-source") as? MLNShapeSource)?.shape = nil
                activeGeometryProgressRouteID = route.id
                activeGeometryProgressStep = nil
                return
            }
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
            let completedSourceID = "naviastra-completed-route-source"
            let completedSource: MLNShapeSource
            if let existing = style.source(withIdentifier: completedSourceID) as? MLNShapeSource {
                completedSource = existing
            } else {
                completedSource = MLNShapeSource(identifier: completedSourceID, shape: nil, options: nil)
                style.addSource(completedSource)
            }
            completedRouteSource = completedSource
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
            let completedCasingID = "naviastra-completed-route-casing"
            let completedLineID = "naviastra-completed-route-line"
            let completedCasing: MLNLineStyleLayer
            if let existing = style.layer(withIdentifier: completedCasingID) as? MLNLineStyleLayer {
                completedCasing = existing
            } else {
                completedCasing = MLNLineStyleLayer(identifier: completedCasingID, source: completedSource)
                completedCasing.lineCap = NSExpression(forConstantValue: "round")
                completedCasing.lineJoin = NSExpression(forConstantValue: "round")
                completedCasing.lineColorTransition = MLNTransitionMake(0.3, 0)
                completedCasing.lineWidthTransition = MLNTransitionMake(0.3, 0)
                style.addLayer(completedCasing)
            }
            let completedLine: MLNLineStyleLayer
            if let existing = style.layer(withIdentifier: completedLineID) as? MLNLineStyleLayer {
                completedLine = existing
            } else {
                completedLine = MLNLineStyleLayer(identifier: completedLineID, source: completedSource)
                completedLine.lineCap = NSExpression(forConstantValue: "round")
                completedLine.lineJoin = NSExpression(forConstantValue: "round")
                completedLine.lineColorTransition = MLNTransitionMake(0.3, 0)
                completedLine.lineWidthTransition = MLNTransitionMake(0.3, 0)
                style.addLayer(completedLine)
            }
            updateActiveRouteStyle(on: map)

            let progress = parent.state.status == .routePreview ? parent.state.routeRevealProgress : 1
            let visible = revealGeometry?.visibleCoordinates(progress: progress) ?? activeRouteLegs(for: route).active
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            if isNavigating {
                let progressDistance = RouteGeometrySplitter.length(of: route.coordinates)
                    * parent.state.routeGeometryProgress
                let split = RouteGeometrySplitter.split(activeRouteLegs(for: route).active,
                                                        atDistance: progressDistance)
                source.shape = shape(for: split.remaining)
                completedSource.shape = shape(for: split.completed)
            } else {
                source.shape = shape(for: visible)
                completedSource.shape = nil
            }
            activeGeometryProgressRouteID = isNavigating ? route.id : nil
            if isNavigating {
                let stepDistance = route.distance > 0
                    ? route.distance * parent.state.routeGeometryProgress
                    : RouteGeometrySplitter.length(of: route.coordinates) * parent.state.routeGeometryProgress
                activeGeometryProgressStep = Int((stepDistance / 2).rounded(.down))
            } else {
                activeGeometryProgressStep = nil
            }
        }

        private func shape(for coordinates: [Coordinate]) -> MLNPolyline? {
            guard coordinates.count > 1 else { return nil }
            var points = coordinates.map(\.cl)
            return MLNPolyline(coordinates: &points, count: UInt(points.count))
        }

        private func updateActiveRouteStyle(on map: MLNMapView) {
            guard let style = map.style,
                  let casing = style.layer(withIdentifier: "naviastra-active-route-casing") as? MLNLineStyleLayer,
                  let line = style.layer(withIdentifier: "naviastra-active-route-line") as? MLNLineStyleLayer,
                  let highlight = style.layer(withIdentifier: "naviastra-active-route-highlight") as? MLNLineStyleLayer,
                  let completedCasing = style.layer(withIdentifier: "naviastra-completed-route-casing") as? MLNLineStyleLayer,
                  let completedLine = style.layer(withIdentifier: "naviastra-completed-route-line") as? MLNLineStyleLayer else { return }
            let casingStyle = lineStyle(for: .activeCasing)
            let activeStyle = lineStyle(for: .active)
            let highlightStyle = lineStyle(for: .activeHighlight)
            let completedCasingStyle = lineStyle(for: .traveledCasing)
            let completedStyle = lineStyle(for: .traveled)
            let key = "\(casingStyle.hex)-\(casingStyle.opacity)-\(casingStyle.width)-\(activeStyle.hex)-\(activeStyle.opacity)-\(activeStyle.width)-\(highlightStyle.hex)-\(highlightStyle.opacity)-\(highlightStyle.width)-\(completedCasingStyle.opacity)-\(completedCasingStyle.width)-\(completedStyle.opacity)-\(completedStyle.width)"
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
            completedCasing.lineColor = NSExpression(forConstantValue: color(hex: completedCasingStyle.hex, opacity: 1))
            completedCasing.lineOpacity = NSExpression(forConstantValue: completedCasingStyle.opacity)
            completedCasing.lineWidth = NSExpression(forConstantValue: completedCasingStyle.width)
            completedLine.lineColor = NSExpression(forConstantValue: color(hex: completedStyle.hex, opacity: 1))
            completedLine.lineOpacity = NSExpression(forConstantValue: completedStyle.opacity)
            completedLine.lineWidth = NSExpression(forConstantValue: completedStyle.width)
        }

        private func addJourneyLegs(_ legs: [JourneyLeg], routeID: UUID, transitionStyle: LineStyle?,
                                    to map: MLNMapView) -> Bool {
            var didDrawLeg = false
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let journeyLength = legs.reduce(0.0) {
                $0 + RouteGeometrySplitter.length(of: $1.coordinates)
            }
            let progressDistance = isNavigating
                ? journeyLength * parent.state.routeGeometryProgress
                : 0
            var legStartDistance = 0.0
            for leg in legs where leg.coordinates.count > 1 {
                let legLength = RouteGeometrySplitter.length(of: leg.coordinates)
                let completedDistance = max(0, min(legLength, progressDistance - legStartDistance))
                let split = RouteGeometrySplitter.split(leg.coordinates, atDistance: completedDistance)
                if split.completed.count > 1 {
                    addLine(split.completed, kind: .traveledCasing, routeID: routeID, to: map)
                    addLine(split.completed, kind: .traveled, routeID: routeID, to: map)
                    didDrawLeg = true
                }

                let mode = leg.mode.lowercased()
                let walking = isWalkingLeg(mode)
                let cycling = mode.contains("bicycle") || mode.contains("bike")
                let color = walking ? RouteColorPalette.walking : cycling ? RouteColorPalette.cycling : RouteColorPalette.activeLight
                let paths = walking ? RouteMapGeometry.dashedSegments(split.remaining) : [split.remaining]
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
                legStartDistance += legLength
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

        private func updateActiveRouteGeometryProgress(on map: MLNMapView) {
            guard let route = parent.state.route else {
                activeGeometryProgressRouteID = nil
                activeGeometryProgressStep = nil
                return
            }
            guard parent.state.status == .navigating || parent.state.status == .rerouting else {
                if activeGeometryProgressRouteID != nil { updateActiveRouteShape(route, on: map) }
                activeGeometryProgressRouteID = nil
                activeGeometryProgressStep = nil
                return
            }

            if parent.state.transportMode == .transit, let journey = route.journey {
                let routeDistance = route.distance > 0 ? route.distance :
                    journey.legs.reduce(0.0) { $0 + RouteGeometrySplitter.length(of: $1.coordinates) }
                let step = Int((routeDistance * parent.state.routeGeometryProgress / 2).rounded(.down))
                guard activeGeometryProgressRouteID != route.id || activeGeometryProgressStep != step else { return }
                activeGeometryProgressRouteID = route.id
                activeGeometryProgressStep = step
                guard step > 0 else { return }
                let previousJourneyLines = routeLines.filter {
                    guard $0.routeID == route.id else { return false }
                    switch $0.kind {
                    case .journeyCasing, .journeyLeg, .traveledCasing, .traveled: return true
                    default: return false
                    }
                }
                map.removeAnnotations(previousJourneyLines.map(\.polyline))
                routeLines.removeAll { line in
                    guard line.routeID == route.id else { return false }
                    switch line.kind {
                    case .journeyCasing, .journeyLeg, .traveledCasing, .traveled: return true
                    default: return false
                    }
                }
                _ = addJourneyLegs(journey.legs, routeID: route.id, transitionStyle: nil, to: map)
                return
            }

            let routeDistance = route.distance > 0 ? route.distance : RouteGeometrySplitter.length(of: route.coordinates)
            let step = Int((routeDistance * parent.state.routeGeometryProgress / 2).rounded(.down))
            guard activeGeometryProgressRouteID != route.id || activeGeometryProgressStep != step else { return }
            activeGeometryProgressRouteID = route.id
            activeGeometryProgressStep = step
            guard step > 0 else { return }
            updateActiveRouteShape(route, on: map)
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

        private func updateRouteTrafficLines(on map: MLNMapView) {
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let routeID = parent.state.route?.id
            let segments = parent.settings.overlays.traffic && parent.state.transportMode == .car && isNavigating
                ? (parent.state.traffic?.routeFlowSegments ?? []).filter { $0.routeID == routeID }
                : []
            guard segments != shownRouteTrafficSegments else { return }
            let previousLines = routeLines.filter { line in
                if case .routeTraffic = line.kind { return true }
                return false
            }
            map.removeAnnotations(previousLines.map(\.polyline))
            routeLines.removeAll { line in
                if case .routeTraffic = line.kind { return true }
                return false
            }
            shownRouteTrafficSegments = segments
            guard let routeID else { return }
            for segment in segments {
                addLine(segment.coordinates, kind: .routeTraffic(color: segment.colorHex),
                        routeID: routeID, to: map)
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
            case .traveledCasing:
                return LineStyle(hex: RouteColorPalette.traveled,
                                 opacity: parent.state.status == .rerouting ? 0.06 : 0.16,
                                 width: activeRouteWidth(navigating: navigating) * 0.75 + 1)
            case .traveled:
                return LineStyle(hex: RouteColorPalette.traveled,
                                 opacity: parent.state.status == .rerouting ? 0.16 : 0.4,
                                 width: max(1, activeRouteWidth(navigating: navigating) * 0.75))
            case .traffic:
                return LineStyle(hex: parent.state.traffic?.flow?.overlayColorHex ?? RouteColorPalette.trafficFree,
                                 opacity: 1, width: 4.5)
            case .routeTraffic(let color):
                return LineStyle(hex: color, opacity: 0.98, width: activeRouteWidth(navigating: navigating))
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
#endif
