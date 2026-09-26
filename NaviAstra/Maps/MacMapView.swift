#if os(macOS)
import AppKit
import CoreLocation
import Foundation
import MapKit
import QuartzCore
import SwiftUI

private extension MapPOICategory {
    var mapKitCategories: [MKPointOfInterestCategory] {
        switch self {
        case .fuel: [.gasStation]
        case .parking: [.parking]
        case .charging: [.evCharger]
        case .food: [.restaurant, .cafe, .bakery]
        case .shopping: [.store]
        case .health: [.hospital, .pharmacy]
        case .attractions: [.museum, .theater, .park, .nationalPark]
        case .transit: [.airport, .publicTransport]
        case .lodging: [.hotel, .campground]
        }
    }
}

private nonisolated enum MacRouteLineKind: Hashable {
    case activeCasing, active, activeHighlight, future, alternative, traveled, traffic, departed, accuracy
    case routeTraffic(color: UInt32)
    case incidentCasing, incident(color: UInt32)
    case journeyCasing(walking: Bool, cycling: Bool)
    case journeyLeg(color: UInt32, walking: Bool, cycling: Bool)
}

private struct MacIncidentLineRenderItem: Equatable {
    let id: String
    let coordinates: [Coordinate]
    let colorHex: UInt32
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

/// The iOS MapLibre binary has no macOS slice. This adapter renders the shared navigation state.
struct MapLibreView: NSViewRepresentable {
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122),
                                         span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)), animated: false)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClicked(_:)))
        click.numberOfClicksRequired = 2
        map.addGestureRecognizer(click)
        let placeClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.placeClicked(_:)))
        placeClick.numberOfClicksRequired = 1
        placeClick.delegate = context.coordinator
        map.addGestureRecognizer(placeClick)
        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        map.addGestureRecognizer(pan)
        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        let rotation = NSRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userGesture(_:)))
        map.addGestureRecognizer(magnify)
        map.addGestureRecognizer(rotation)
        context.coordinator.map = map
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        guard !isSearchPresented else { return }
        context.coordinator.update(map)
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopPuckRenderTimer()
    }

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: MapLibreView
        weak var map: MKMapView?
        private var routeOverlays: [StyledOverlay] = []
        private var incidentOverlays: [String: [StyledOverlay]] = [:]
        private var incidentOverlayRenderItems: [MacIncidentLineRenderItem] = []
        private var shownRouteTrafficSegments: [RouteTrafficSegment] = []
        private var traveledOverlay: StyledOverlay?
        private var trafficOverlay: StyledOverlay?
        private var accuracyHaloOverlay: StyledOverlay?
        private var accuracyHaloCenter: Coordinate?
        private var accuracyHaloRadius: Double?
        private var destinationPin: MKPointAnnotation?
        private var routeOriginPin: MKPointAnnotation?
        private var positionPin: MKPointAnnotation?
        private let puckEngine = NavigationPuckEngine()
        private var puckRenderTimer: Timer?
        private var lastPositionMarkerAngle: Int?
        private var lastPositionMarkerIsNavigating: Bool?
        private var lastDestinationMarkerIsArrived: Bool?
        private var transitVehiclePins: [String: MKPointAnnotation] = [:]
        private var transitStopPins: [String: MKPointAnnotation] = [:]
        private var transitStopMapStops: [String: TransitStop] = [:]
        private var transitStopMarkerStates: [String: TransitStopMapPresentation] = [:]
        private var lastTransitStopRenderKey: TransitStopRenderKey?
        private var transitLineOverlay: MKPolyline?
        private var trafficRasterOverlays: [String: MKTileOverlay] = [:]
        private var trafficRasterTemplates: [String: String] = [:]
        private var shownTransitRouteID: String?
        private var shownTransitLineCoordinates: [Coordinate] = []
        private var closurePin: MKPointAnnotation?
        private var searchPins: [MKPointAnnotation] = []
        private var searchIDs: [UUID] = []
        private var incidentPins: [MKPointAnnotation] = []
        private var shownIncidentIDs: [String] = []
        private var shownIncidents: [TrafficIncident] = []
        private var roadAlertPins: [MKPointAnnotation] = []
        private var shownRoadAlertIDs: [String] = []
        private var shownRoadAlerts: [RoadSafetyAlert] = []
        private var shownRouteIDs: [UUID]?
        private var shownActiveTargetID: UUID?
        private var shownRevealStep = 1_000
        private var activeGeometryProgressRouteID: UUID?
        private var activeGeometryProgressStep: Int?
        private var traveledRouteID: UUID?
        private var traveledProgressStep: Int?
        private var trafficCoordinates: [Coordinate]?
        private var trafficColorHex: UInt32?
        private var lastStatus: NavigationStatus?
        private var lastColorScheme: ColorScheme?
        private var lastViewportPadding: CameraPadding?
        private var lastMapSize: CGSize = .zero
        private var lastIntent: CameraIntent?
        private var lastCameraState: NavigationCameraState?
        private var lastCameraCommandID: Int?
        private var lastOverviewRouteID: UUID?
        private var lastRoutePreviewExpanded: Bool?
        private var programmaticCamera = false
        private var lastBaseMap: BaseMap?
        private var lastDimension: MapDimension?
        private var lastCameraMode: MapDimension?
        private var lastPOICategories: Set<MapPOICategory>?
        private var lastPOIMarkerDark: Bool?
        private var lastBuildingVisibility: Bool?
        private var routeTransitionTimer: Timer?
        private var placeSearch: MKLocalSearch?
        private var placeRequestID = UUID()
        private var transitAnnotationUpdateWorkItem: DispatchWorkItem?
        private var searchMapCenterWorkItem: DispatchWorkItem?

        init(_ parent: MapLibreView) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let click = gestureRecognizer as? NSClickGestureRecognizer,
                  let other = otherGestureRecognizer as? NSClickGestureRecognizer else { return false }
            return click.numberOfClicksRequired == 1 && other.numberOfClicksRequired == 2
        }

        @objc func placeClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let map, recognizer.state == .ended else { return }
            let point = recognizer.location(in: map)
            // Search pins already have an exact identity and need no network lookup.
            if let index = searchPins.firstIndex(where: {
                let screen = map.convert($0.coordinate, toPointTo: map)
                return hypot(screen.x - point.x, screen.y - point.y) < 24
            }), parent.state.searchResults.indices.contains(index) {
                placeSearch?.cancel()
                placeRequestID = UUID()
                parent.onPlaceSelect([parent.state.searchResults[index]])
                return
            }
            let transitPins = Array(transitStopPins.values) + Array(transitVehiclePins.values)
            if transitPins.contains(where: {
                let screen = map.convert($0.coordinate, toPointTo: map)
                return hypot(screen.x - point.x, screen.y - point.y) < 24
            }) { return }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            let edge = map.convert(NSPoint(x: point.x + 24, y: point.y), toCoordinateFrom: map)
            let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let radius = center.distance(from: CLLocation(latitude: edge.latitude, longitude: edge.longitude))
            // Native feature annotations are iOS-only. Resolve actual nearby POIs on macOS.
            guard radius < 500 else { return }
            placeSearch?.cancel()
            let requestID = UUID()
            placeRequestID = requestID
            let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: max(20, radius))
            let visibleCategories = parent.settings.visiblePOICategories.flatMap(\.mapKitCategories)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: visibleCategories)
            let search = MKLocalSearch(request: request)
            placeSearch = search
            search.start { [weak self, weak map] response, _ in
                guard let self, let map, self.placeRequestID == requestID, let response else { return }
                let results = response.mapItems.compactMap { item -> SearchResult? in
                    let location = item.location.coordinate
                    let screen = map.convert(location, toPointTo: map)
                    guard hypot(screen.x - point.x, screen.y - point.y) <= 24, let name = item.name else { return nil }
                    return SearchResult(destination: Destination(name: name,
                                                                  coordinate: Coordinate(latitude: location.latitude, longitude: location.longitude),
                                                                  address: item.address?.fullAddress),
                                        street: nil, houseNumber: nil, city: item.addressRepresentations?.cityName,
                                        countryCode: item.addressRepresentations?.region?.identifier.lowercased(),
                                        isPOI: true, providerID: item.identifier?.rawValue, placeProvider: .mapKit,
                                        category: item.pointOfInterestCategory?.rawValue,
                                        phone: item.phoneNumber, website: item.url?.absoluteString,
                                        timeZoneIdentifier: item.timeZone?.identifier)
                }
                if !results.isEmpty { self.parent.onPlaceSelect(Array(results.prefix(6))) }
            }
        }

        @objc func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let map, recognizer.state == .ended else { return }
            placeSearch?.cancel()
            placeRequestID = UUID()
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            parent.onLongPress(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        @objc func userGesture(_ gesture: NSGestureRecognizer) {
            guard gesture.state == .began else { return }
            placeSearch?.cancel()
            placeRequestID = UUID()
            programmaticCamera = false
            if gesture is NSPanGestureRecognizer { parent.onMapPan() }
            parent.state.cameraState = .freeLook
            parent.state.cameraIntent = nil
        }

        func update(_ map: MKMapView) {
            let results = showsOnlyRouteEndpoints ? [] : Array(parent.state.searchResults.prefix(8))
            if searchIDs != results.map(\.id) {
                map.removeAnnotations(searchPins)
                searchIDs = results.map(\.id)
                searchPins = results.enumerated().map { index, result in
                    let pin = MKPointAnnotation()
                    pin.coordinate = result.destination.coordinate.cl
                    pin.title = "\(index + 1). \(result.destination.name)"
                    pin.subtitle = result.destination.address
                    return pin
                }
                map.addAnnotations(searchPins)
            }
            updatePOIMarkerAppearance(on: map)

            if lastBaseMap != parent.settings.baseMap || lastDimension != parent.settings.cameraMode {
                switch parent.settings.baseMap {
                case .standard, .terrain:
                    let configuration = MKStandardMapConfiguration()
                    configuration.elevationStyle = parent.settings.baseMap == .terrain ? .realistic : .flat
                    map.preferredConfiguration = configuration
                case .satellite:
                    let configuration = MKImageryMapConfiguration()
                    configuration.elevationStyle = parent.settings.cameraMode == .threeD ? .realistic : .flat
                    map.preferredConfiguration = configuration
                }
                lastBaseMap = parent.settings.baseMap
                lastDimension = parent.settings.cameraMode
            }
            let trafficTemplate = parent.colorScheme == .dark
                ? parent.state.trafficDarkTileURLTemplate
                : parent.state.trafficLightTileURLTemplate
            let incidentTemplate = parent.colorScheme == .dark
                ? parent.state.trafficDarkIncidentTileURLTemplate
                : parent.state.trafficLightIncidentTileURLTemplate
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let showsNativeTraffic = parent.settings.overlays.traffic && !isNavigating &&
                trafficTemplate == nil && incidentTemplate == nil
            if map.showsTraffic != showsNativeTraffic { map.showsTraffic = showsNativeTraffic }
            updateTrafficRasterOverlays(on: map, flowTemplate: trafficTemplate,
                                        incidentTemplate: isNavigating ? nil : incidentTemplate,
                                        visible: parent.settings.overlays.traffic)
            if lastPOICategories != parent.settings.visiblePOICategories {
                let categories = parent.settings.visiblePOICategories.flatMap(\.mapKitCategories)
                map.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
                lastPOICategories = parent.settings.visiblePOICategories
            }
            if lastBuildingVisibility != parent.settings.overlays.buildings3D {
                map.showsBuildings = parent.settings.overlays.buildings3D
                lastBuildingVisibility = parent.settings.overlays.buildings3D
            }
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
                let previousOverlays = routeOverlays
                let previousActive = previousOverlays.first(where: { $0.routeID == oldActiveID && $0.kind == .active })
                map.removeOverlays(routeOverlays.map(\.polyline))
                routeOverlays.removeAll()
                activeGeometryProgressRouteID = nil
                activeGeometryProgressStep = nil
                shownRouteTrafficSegments = []
                for route in parent.state.alternatives {
                    let previousKind: MacRouteLineKind = route.id == oldActiveID ? .active : .alternative
                    let from = animateSelection ? previousStyle(for: route.id, kind: previousKind, in: previousOverlays) : nil
                    let dashPeriod = max(300, route.distance / 40)
                    let dashes = RouteMapGeometry.dashedSegments(route.coordinates,
                                                                 dashLength: max(180, dashPeriod * 0.6),
                                                                 gapLength: max(120, dashPeriod * 0.4))
                    for path in dashes {
                        addOverlay(path, kind: .alternative, routeID: route.id, transitionFrom: from, to: map)
                    }
                }
                if animateReroute, let previousActive {
                    let dark = parent.colorScheme == .dark
                    let fadedBlue = LineStyle(hex: dark ? RouteColorPalette.activeDark : RouteColorPalette.activeLight,
                                              opacity: 0.3, width: 11)
                    addOverlay(previousActive.coordinates, kind: .departed, transitionFrom: fadedBlue, to: map)
                }
                if let route = parent.state.route {
                    let previous = animateSelection
                        ? previousStyle(for: route.id, kind: .alternative, in: previousOverlays)
                        : nil
                    addActiveRoute(route, previousStyle: previous,
                                   animateSelection: animateSelection, animateReroute: animateReroute, to: map)
                }
                shownRouteIDs = routeIDs
                shownActiveTargetID = activeTargetID
                if animateSelection || animateReroute { animateRouteSelection(removeDeparted: animateReroute) }
            }
            if revealChanged {
                if !routesChanged {
                    updateRouteReveal(on: map)
                }
                shownRevealStep = revealStep
            }

            updateActiveRouteProgress(on: map)
            updateTraveledOverlay(on: map)
            updateTrafficOverlay(on: map)
            updateRouteTrafficOverlays(on: map)
            if showsOnlyRouteEndpoints {
                removeClosurePin(from: map)
            } else {
                updateClosurePin(on: map)
            }
            updateAccuracyHalo(on: map)

            if let destination = parent.state.destination, parent.state.status != .idle,
               !parent.state.routeOriginMapSelectionActive {
                if destinationPin == nil {
                    let pin = MKPointAnnotation(); pin.title = destination.name
                    destinationPin = pin; map.addAnnotation(pin)
                }
                destinationPin?.coordinate = destination.coordinate.cl
            } else if let pin = destinationPin { map.removeAnnotation(pin); destinationPin = nil }

            if let origin = parent.state.routeOrigin, !origin.isCurrentLocation,
               !parent.state.routeOriginMapSelectionActive,
               parent.state.status != .idle {
                if routeOriginPin == nil {
                    let pin = MKPointAnnotation()
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

            let routeDistance = parent.state.progress?.traveledDistance ?? 0
            let incidents = parent.settings.overlays.traffic
                ? (parent.state.traffic?.incidents ?? []).filter { incident in
                    guard isNavigating else { return true }
                    guard incident.isImportantDuringNavigation else { return false }
                    guard let distance = incident.distanceAlongRoute else { return false }
                    return distance > routeDistance && distance <= routeDistance + 12_000
                }
                : []
            let incidentIDs = incidents.map { "\($0.id):\($0.category.rawValue):\($0.severity.rawValue)" }
            if incidentIDs != shownIncidentIDs {
                map.removeAnnotations(incidentPins)
                incidentPins = incidents.map { incident in
                    let pin = MKPointAnnotation()
                    pin.coordinate = incident.coordinate.cl
                    pin.title = incident.mapTitle
                    pin.subtitle = incident.mapSubtitle
                    return pin
                }
                map.addAnnotations(incidentPins)
                shownIncidentIDs = incidentIDs
            }
            shownIncidents = Array(incidents)
            for (incident, pin) in zip(incidents, incidentPins) {
                pin.coordinate = incident.coordinate.cl
                pin.title = incident.mapTitle
                pin.subtitle = incident.mapSubtitle
            }
            updateIncidentOverlays(on: map, incidents: incidents)
            let roadAlerts = ((!showsOnlyRouteEndpoints || isNavigating) ? parent.state.roadSafetyAlerts : [])
                .filter { alert in
                    guard let distance = alert.distanceAlongRoute else { return false }
                    return distance >= routeDistance - 60 && distance <= routeDistance + 20_000
                        && (!isNavigating || alert.type.isImportantDuringNavigation)
                }
                .sorted { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
                .prefix(40)
            let alertIDs = roadAlerts.map { "\($0.id):\($0.type.rawValue)" }
            if alertIDs != shownRoadAlertIDs {
                map.removeAnnotations(roadAlertPins)
                roadAlertPins = roadAlerts.map { alert in
                    let pin = MKPointAnnotation()
                    pin.coordinate = alert.coordinate.cl
                    return pin
                }
                map.addAnnotations(roadAlertPins)
                shownRoadAlertIDs = alertIDs
            }
            shownRoadAlerts = Array(roadAlerts)
            for (alert, pin) in zip(roadAlerts, roadAlertPins) {
                pin.coordinate = alert.coordinate.cl
                pin.title = alert.title
                pin.subtitle = roadAlertSubtitle(alert, routeDistance: routeDistance)
            }
            scheduleTransitAnnotationUpdate(on: map)
            updateSelectedTransitLine(on: map)

            updatePositionPuck(on: map)

            applyCameraIntent(to: map)
            if lastDestinationMarkerIsArrived != (parent.state.status == .arrived),
               let destinationPin, let view = map.view(for: destinationPin) {
                view.image = destinationMarkerImage(arrived: parent.state.status == .arrived)
                lastDestinationMarkerIsArrived = parent.state.status == .arrived
            }

            if lastStatus != parent.state.status || lastColorScheme != parent.colorScheme {
                for overlay in allStyledOverlays {
                    updateRenderer(for: overlay, on: map)
                }
            }
            if lastStatus == .routePreview && parent.state.status == .navigating {
                animateNavigationStart()
            }
            lastStatus = parent.state.status
            lastColorScheme = parent.colorScheme
            lastCameraState = parent.state.cameraState
        }

        private func roadAlertSubtitle(_ alert: RoadSafetyAlert, routeDistance: Double) -> String {
            guard let distance = alert.distanceAlongRoute else { return "© OpenStreetMap contributors" }
            let remaining = max(0, distance - routeDistance)
            let distanceText = remaining >= 1_000
                ? String(format: "%.1f km", remaining / 1_000)
                : "\(Int(remaining.rounded())) m"
            return "\(distanceText) · © OpenStreetMap contributors"
        }

        private func updateTransitVehiclePins(on map: MKMapView) {
            let zoom = log2(360 / max(0.00001, map.region.span.longitudeDelta))
            let isZoomedIn = zoom >= 14.7
            let vehicles = Dictionary((showsOnlyRouteEndpoints ? [] : parent.transitVehicles).filter { vehicle in
                if let tripID = parent.selectedTransitTripID { return vehicle.tripID == tripID }
                return parent.selectedTransitRouteID.map { $0 == vehicle.routeID } ?? isZoomedIn
            }.map { ($0.id, $0) },
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
                    let pin = MKPointAnnotation()
                    pin.coordinate = vehicle.coordinate.cl
                    pin.title = title
                    pin.subtitle = subtitle
                    transitVehiclePins[vehicle.id] = pin
                    map.addAnnotation(pin)
                }
            }
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

        private func updateTransitStopPins(on map: MKMapView) {
            let zoom = log2(360 / max(0.00001, map.region.span.longitudeDelta))
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

            let visibility = TransitStopMapVisibilityPolicy(zoom: zoom,
                                                            transportMode: parent.state.transportMode,
                                                            isPlanningCarRoute: isPlanningCarRoute,
                                                            isNavigating: isNavigating,
                                                            isTransitRoutePreview: isTransitRoutePreview,
                                                            visibleStopCount: visibleStopCount,
                                                            visibleRadius: visibleRadius,
                                                            mapCenter: center,
                                                            userCoordinate: parent.state.location?.coordinate,
                                                            routeEndpointCoordinates: transitRouteEndpointCoordinates,
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
                let subtitle = stop.lines.prefix(5).joined(separator: " · ")
                if let pin = transitStopPins[stop.id] {
                    if pin.coordinate.latitude != stop.coordinate.latitude || pin.coordinate.longitude != stop.coordinate.longitude {
                        pin.coordinate = stop.coordinate.cl
                    }
                    if pin.title != stop.name { pin.title = stop.name }
                    if pin.subtitle != subtitle { pin.subtitle = subtitle }
                    if let marker = map.view(for: pin) as? TransitStopMapAnnotationView,
                       transitStopMarkerStates[stop.id] != presentation {
                        marker.render(presentation)
                    }
                } else {
                    let pin = MKPointAnnotation()
                    pin.coordinate = stop.coordinate.cl
                    pin.title = stop.name
                    pin.subtitle = subtitle
                    transitStopPins[stop.id] = pin
                    map.addAnnotation(pin)
                }
                transitStopMarkerStates[stop.id] = presentation
            }
        }

        private func scheduleTransitAnnotationUpdate(on map: MKMapView) {
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

        private func updateSelectedTransitLine(on map: MKMapView) {
            guard shownTransitRouteID != parent.selectedTransitRouteID
                    || shownTransitLineCoordinates != parent.transitLineCoordinates else { return }
            if let transitLineOverlay { map.removeOverlay(transitLineOverlay) }
            transitLineOverlay = nil
            shownTransitRouteID = parent.selectedTransitRouteID
            shownTransitLineCoordinates = parent.transitLineCoordinates
            guard parent.selectedTransitRouteID != nil, parent.transitLineCoordinates.count > 1 else { return }
            var points = parent.transitLineCoordinates.map(\.cl)
            let line = MKPolyline(coordinates: &points, count: points.count)
            transitLineOverlay = line
            map.addOverlay(line, level: .aboveRoads)
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

        private func applyCameraIntent(to map: MKMapView) {
            guard map.bounds.width > 0, map.bounds.height > 0,
                  let intent = parent.state.cameraIntent,
                  parent.state.cameraState != .freeLook else { return }
            let cameraState = parent.state.cameraState
            let cameraMode = parent.settings.cameraMode
            let routeID = parent.state.route?.id
            let cameraCommandChanged = lastCameraCommandID != parent.state.cameraCommandID
            let cameraStateChanged = lastCameraState != cameraState
            let cameraModeChanged = lastCameraMode != cameraMode
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
               let route = parent.state.route, isMostlyVisible(route.coordinates, on: map) { return }
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
            MacMapCameraAnimator.apply(effectiveIntent, state: cameraState, to: map)
            lastViewportPadding = parent.viewportPadding
            lastMapSize = map.bounds.size
            lastIntent = intent
            lastCameraMode = cameraMode
            lastCameraCommandID = parent.state.cameraCommandID
            lastRoutePreviewExpanded = parent.routePreviewExpanded
            if cameraState == .routeOverview { lastOverviewRouteID = routeID }
        }

        private func isMostlyVisible(_ points: [Coordinate], on map: MKMapView) -> Bool {
            guard !points.isEmpty else { return true }
            let padding = parent.viewportPadding
            let safe = CGRect(x: padding.left, y: padding.top,
                              width: max(1, Double(map.bounds.width) - padding.left - padding.right),
                              height: max(1, Double(map.bounds.height) - padding.top - padding.bottom))
            let sampled = stride(from: 0, to: points.count, by: max(1, points.count / 30)).map { points[$0] }
            return Double(sampled.filter { safe.contains(map.convert($0.cl, toPointTo: map)) }.count) / Double(sampled.count) >= 0.9
        }

        private var usesDarkMapAppearance: Bool {
            parent.settings.appearance == .night ||
                (parent.settings.appearance == .auto && parent.colorScheme == .dark)
        }

        private func updatePOIMarkerAppearance(on map: MKMapView) {
            let dark = usesDarkMapAppearance
            guard lastPOIMarkerDark != dark else { return }
            lastPOIMarkerDark = dark
            for (index, pin) in searchPins.enumerated()
                where parent.state.searchResults.indices.contains(index) {
                guard parent.state.searchResults[index].isPOI,
                      let kind = PlacePOIMapMarkerKind(category: parent.state.searchResults[index].category),
                      let marker = map.view(for: pin) else { continue }
                stylePOIMarker(marker, annotation: pin, kind: kind, dark: dark)
            }
        }

        private func stylePOIMarker(_ marker: MKAnnotationView, annotation: MKAnnotation,
                                    kind: PlacePOIMapMarkerKind, dark: Bool) {
            marker.subviews.forEach { $0.removeFromSuperview() }
            let size: CGFloat = 36
            marker.frame = NSRect(x: 0, y: 0, width: size, height: size)
            marker.wantsLayer = true
            let background = PlacePOIMapPalette.backgroundHex(dark: dark)
            marker.layer?.backgroundColor = NSColor(
                calibratedRed: CGFloat((background >> 16) & 0xff) / 255,
                green: CGFloat((background >> 8) & 0xff) / 255,
                blue: CGFloat(background & 0xff) / 255, alpha: 1).cgColor
            marker.layer?.cornerRadius = 11
            marker.layer?.borderWidth = 1.8
            let color = PlacePOIMapPalette.accentColor(dark: dark)
            marker.layer?.borderColor = color.cgColor
            marker.layer?.shadowColor = NSColor.black.cgColor
            marker.layer?.shadowOpacity = 0.18
            marker.layer?.shadowRadius = 3
            marker.layer?.shadowOffset = CGSize(width: 0, height: -1)
            let image = NSImageView(frame: NSRect(x: 8, y: 8, width: 20, height: 20))
            image.image = NSImage(systemSymbolName: kind.symbolName,
                                  accessibilityDescription: kind.accessibilityName)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            image.contentTintColor = color
            image.imageScaling = .scaleProportionallyUpOrDown
            marker.addSubview(image)
            marker.canShowCallout = true
            marker.displayPriority = .defaultHigh
            marker.setAccessibilityLabel("\(kind.accessibilityName): \(annotation.title ?? "")")
            marker.setAccessibilityRole(.button)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if annotation is MKClusterAnnotation || incidentPins.contains(where: { $0 === annotation })
                || roadAlertPins.contains(where: { $0 === annotation }) {
                view.wantsLayer = true
                let scale = 42 / max(1, view.frame.width)
                view.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                return
            }
            if let (stopID, _) = transitStopPins.first(where: { $0.value === annotation }),
               let stop = transitStopMapStops[stopID] {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onTransitStopSelect(stop)
                return
            }
            if let vehicle = parent.transitVehicles.first(where: { transitVehiclePins[$0.id] === annotation }) {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onTransitVehicleSelect(vehicle)
                return
            }
            if let index = searchPins.firstIndex(where: { $0 === annotation }),
               parent.state.searchResults.indices.contains(index) {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onPlaceSelect([parent.state.searchResults[index]])
                return
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let annotation = view.annotation,
                  annotation is MKClusterAnnotation || incidentPins.contains(where: { $0 === annotation })
                    || roadAlertPins.contains(where: { $0 === annotation }) else { return }
            view.layer?.setAffineTransform(.identity)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let presentation = cluster.memberAnnotations.compactMap { trafficPresentation(for: $0) }
                    .max { $0.clusterPriority < $1.clusterPriority } ?? TrafficMapPresentation(
                        TrafficIncident(id: "cluster", description: "Zdarzenia drogowe",
                                        coordinate: Coordinate(latitude: cluster.coordinate.latitude,
                                                              longitude: cluster.coordinate.longitude),
                                        delaySeconds: nil, category: .unknown, severity: .unknown))
                let marker = TrafficMapAnnotationView(annotation: annotation, reuseIdentifier: "traffic-cluster")
                marker.render(presentation: presentation, clusterCount: cluster.memberAnnotations.count)
                return marker
            }
            if let index = incidentPins.firstIndex(where: { $0 === annotation }),
               shownIncidents.indices.contains(index) {
                let incident = shownIncidents[index]
                let marker = TrafficMapAnnotationView(annotation: annotation,
                                                      reuseIdentifier: "traffic-incident-\(incident.category.rawValue)")
                marker.render(presentation: TrafficMapPresentation(incident))
                return marker
            }

            if let pin = closurePin, pin === annotation {
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "traffic-road-closure")
                marker.glyphImage = NSImage(systemSymbolName: "xmark.octagon.fill",
                                            accessibilityDescription: "Droga zamknięta")
                marker.markerTintColor = .systemRed
                marker.canShowCallout = true
                marker.displayPriority = .defaultHigh
                return marker
            }

            if let index = searchPins.firstIndex(where: { $0 === annotation }) {
                if parent.state.searchResults.indices.contains(index),
                   parent.state.searchResults[index].isPOI,
                   let kind = PlacePOIMapMarkerKind(category: parent.state.searchResults[index].category) {
                    let marker = MKAnnotationView(annotation: annotation,
                                                  reuseIdentifier: "poi-\(kind.rawValue)")
                    stylePOIMarker(marker, annotation: annotation, kind: kind, dark: usesDarkMapAppearance)
                    return marker
                }
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
                marker.glyphText = String(index + 1)
                marker.markerTintColor = .systemBlue
                return marker
            }

            if let (stopID, _) = transitStopPins.first(where: { $0.value === annotation }),
               let stop = transitStopMapStops[stopID] {
                let marker = TransitStopMapAnnotationView(annotation: annotation,
                                                          reuseIdentifier: "transit-stop-\(stopID)")
                marker.render(transitStopMarkerStates[stopID] ?? stop.mapPresentation(
                    zoom: log2(360 / max(0.00001, mapView.region.span.longitudeDelta)),
                    selected: false, active: false, alighting: false))
                marker.canShowCallout = true
                marker.displayPriority = .defaultHigh
                return marker
            }

            if let (vehicleID, _) = transitVehiclePins.first(where: { $0.value === annotation }),
               let vehicle = parent.transitVehicles.first(where: { $0.id == vehicleID }) {
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "transit-\(vehicleID)")
                marker.glyphText = vehicle.line
                marker.markerTintColor = NSColor(calibratedRed: CGFloat((vehicle.colorHex >> 16) & 0xff) / 255,
                                                 green: CGFloat((vehicle.colorHex >> 8) & 0xff) / 255,
                                                 blue: CGFloat(vehicle.colorHex & 0xff) / 255, alpha: 1)
                marker.canShowCallout = true
                marker.clusteringIdentifier = "transit-vehicles"
                marker.displayPriority = .defaultHigh
                return marker
            }

            if let alertIndex = roadAlertPins.firstIndex(where: { $0 === annotation }),
               shownRoadAlerts.indices.contains(alertIndex) {
                let alert = shownRoadAlerts[alertIndex]
                let marker = TrafficMapAnnotationView(annotation: annotation,
                                                      reuseIdentifier: "road-alert-\(alert.type.rawValue)")
                marker.render(presentation: TrafficMapPresentation(alert))
                return marker
            }

            if let pin = positionPin, annotation === pin {
                let identifier = "user-position"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
                let location = parent.state.weakGPS ? parent.state.cameraLocation : parent.state.location
                let relativeBearing = location.flatMap { location -> CLLocationDirection? in
                    guard isNavigating, location.course.isFinite, location.course >= 0 else { return nil }
                    return location.course - mapView.camera.heading
                }
                view.image = positionMarkerImage(navigating: isNavigating, relativeBearing: relativeBearing)
                view.centerOffset = isNavigating ? CGPoint(x: 0, y: 16) : .zero
                lastPositionMarkerAngle = relativeBearing.map { Int($0.rounded()) }
                lastPositionMarkerIsNavigating = isNavigating
                view.displayPriority = .required
                return view
            }
            if let routeOriginPin, annotation === routeOriginPin {
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "route-origin")
                marker.glyphText = "A"
                marker.markerTintColor = .systemBlue
                marker.canShowCallout = true
                marker.displayPriority = .required
                return marker
            }
            guard let pin = destinationPin, annotation === pin else { return nil }
            let identifier = "destination"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.image = destinationMarkerImage(arrived: parent.state.status == .arrived)
            lastDestinationMarkerIsArrived = parent.state.status == .arrived
            view.displayPriority = .required
            return view
        }

        private func trafficPresentation(for annotation: MKAnnotation) -> TrafficMapPresentation? {
            if let index = incidentPins.firstIndex(where: { $0 === annotation }), shownIncidents.indices.contains(index) {
                return TrafficMapPresentation(shownIncidents[index])
            }
            if let index = roadAlertPins.firstIndex(where: { $0 === annotation }), shownRoadAlerts.indices.contains(index) {
                return TrafficMapPresentation(shownRoadAlerts[index])
            }
            return nil
        }

        private func updatePositionPuck(on map: MKMapView) {
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let activeRoute = isNavigating ? parent.state.route : nil
            let matchedRoute = parent.state.routeMatch.flatMap { match in
                guard let activeRoute,
                      match.routeID == activeRoute.id,
                      match.locationTimestamp == parent.state.location?.timestamp else { return nil }
                return match
            }
            puckEngine.update(location: parent.state.location, route: activeRoute,
                              isNavigating: isNavigating, matchedRoute: matchedRoute)
            if isNavigating, parent.state.location != nil {
                if puckRenderTimer == nil {
                    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                        self?.renderPositionPuckFrame()
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    puckRenderTimer = timer
                }
            } else {
                stopPuckRenderTimer()
            }
            renderPositionPuckFrame()
        }

        func stopPuckRenderTimer() {
            puckRenderTimer?.invalidate()
            puckRenderTimer = nil
        }

        private func renderPositionPuckFrame() {
            guard let map, let frame = puckEngine.frame() else { return }
            if positionPin == nil {
                let pin = MKPointAnnotation()
                pin.title = "Twoja pozycja"
                positionPin = pin
                map.addAnnotation(pin)
            }
            positionPin?.coordinate = frame.coordinate.cl
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            updatePositionPuckStyle(on: map, isNavigating: isNavigating, bearing: frame.bearing)
        }

        private func updatePositionPuckStyle(on map: MKMapView, isNavigating: Bool,
                                             bearing: CLLocationDirection?) {
            guard let positionPin, let view = map.view(for: positionPin) else { return }
            view.centerOffset = isNavigating ? CGPoint(x: 0, y: 16) : .zero
            let relativeBearing = bearing.flatMap { isNavigating ? $0 - map.camera.heading : nil }
            let angle = relativeBearing.map { Int($0.rounded()) }
            if lastPositionMarkerAngle != angle || lastPositionMarkerIsNavigating != isNavigating {
                view.image = positionMarkerImage(navigating: isNavigating, relativeBearing: relativeBearing)
                lastPositionMarkerAngle = angle
                lastPositionMarkerIsNavigating = isNavigating
            }
        }

        private func positionMarkerImage(navigating: Bool, relativeBearing: CLLocationDirection?) -> NSImage {
            NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                let circle = rect.insetBy(dx: 1.25, dy: 1.25)
                context.setFillColor(NSColor.systemBlue.cgColor)
                context.fillEllipse(in: circle)
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(2.5)
                context.strokeEllipse(in: circle)
                guard navigating, let relativeBearing else { return true }

                context.saveGState()
                context.translateBy(x: rect.midX, y: rect.midY)
                context.rotate(by: CGFloat(relativeBearing * .pi / 180))
                context.translateBy(x: -rect.midX, y: -rect.midY)
                let arrow = CGMutablePath()
                arrow.move(to: CGPoint(x: 14, y: 22))
                arrow.addLine(to: CGPoint(x: 20, y: 8))
                arrow.addLine(to: CGPoint(x: 14, y: 11))
                arrow.addLine(to: CGPoint(x: 8, y: 8))
                arrow.closeSubpath()
                context.addPath(arrow)
                context.setFillColor(NSColor.white.cgColor)
                context.fillPath()
                context.restoreGState()
                return true
            }
        }

        private func destinationMarkerImage(arrived: Bool) -> NSImage? {
            let symbol = NSImage(systemSymbolName: arrived ? "checkmark.circle.fill" : "b.circle.fill",
                                 accessibilityDescription: arrived ? "Dotarłeś do celu" : "Cel")
            return symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(
                paletteColors: [arrived ? .systemGreen : .systemRed]))
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            scheduleSearchMapCenterUpdate(center)

            let wasProgrammaticCamera = programmaticCamera
            if wasProgrammaticCamera { programmaticCamera = false }
            if !wasProgrammaticCamera, parent.state.status == .routePreview {
                parent.state.cameraState = .freeLook
                parent.state.cameraIntent = nil
                parent.onMapPan()
            }
            scheduleTransitAnnotationUpdate(on: mapView)
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard fullyRendered else { return }
            applyCameraIntent(to: mapView)
            parent.onMapReady()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let transitLineOverlay, overlay === transitLineOverlay {
                let renderer = MKPolylineRenderer(polyline: transitLineOverlay)
                let color = parent.transitLineColor ?? 0x248BFF
                renderer.strokeColor = NSColor(calibratedRed: CGFloat((color >> 16) & 0xff) / 255,
                                               green: CGFloat((color >> 8) & 0xff) / 255,
                                               blue: CGFloat(color & 0xff) / 255, alpha: 0.9)
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            if let styled = styledOverlay(for: line) {
                apply(presentedStyle(for: styled), to: renderer)
                if styled.kind == .active || styled.kind == .activeCasing || styled.kind == .activeHighlight {
                    renderer.strokeEnd = parent.state.status == .routePreview
                        ? CGFloat(parent.state.routeRevealProgress) : 1
                }
            }
            return renderer
        }

        private func updateTrafficRasterOverlays(on map: MKMapView, flowTemplate: String?,
                                                 incidentTemplate: String?, visible: Bool) {
            let requested: [(identifier: String, template: String?)] = visible
                ? [("flow", flowTemplate), ("incidents", incidentTemplate)]
                : []
            let requestedIDs = Set(requested.compactMap { $0.template == nil ? nil : $0.identifier })
            for identifier in Array(trafficRasterOverlays.keys) where !requestedIDs.contains(identifier) {
                if let overlay = trafficRasterOverlays.removeValue(forKey: identifier) {
                    map.removeOverlay(overlay)
                }
                trafficRasterTemplates[identifier] = nil
            }
            for item in requested {
                guard let template = item.template,
                      trafficRasterTemplates[item.identifier] != template else { continue }
                if let oldOverlay = trafficRasterOverlays.removeValue(forKey: item.identifier) {
                    map.removeOverlay(oldOverlay)
                }
                let overlay = MKTileOverlay(urlTemplate: template)
                overlay.canReplaceMapContent = false
                overlay.tileSize = CGSize(width: 256, height: 256)
                trafficRasterOverlays[item.identifier] = overlay
                trafficRasterTemplates[item.identifier] = template
                map.addOverlay(overlay, level: .aboveRoads)
            }
        }

        private func addOverlay(_ coordinates: [Coordinate], kind: MacRouteLineKind, routeID: UUID? = nil,
                                transitionFrom: LineStyle? = nil, to map: MKMapView) {
            guard coordinates.count > 1 else { return }
            var points = coordinates.map(\.cl)
            let polyline = MKPolyline(coordinates: &points, count: points.count)
            let styled = StyledOverlay(polyline: polyline, coordinates: coordinates, kind: kind, routeID: routeID,
                                       transitionFrom: transitionFrom, transitionStartedAt: transitionFrom == nil ? nil : Date())
            routeOverlays.append(styled)
            map.addOverlay(polyline)
        }

        private func addActiveRoute(_ route: NavigationRoute, previousStyle: LineStyle?,
                                    animateSelection: Bool, animateReroute: Bool, to map: MKMapView) {
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
                addOverlay(path, kind: .future, routeID: route.id, to: map)
            }

            let casing = lineStyle(for: .activeCasing)
            let invisibleCasing = LineStyle(hex: casing.hex, opacity: 0, width: casing.width)
            addOverlay(legs.active, kind: .activeCasing, routeID: route.id,
                       transitionFrom: animateSelection || animateReroute ? invisibleCasing : nil, to: map)
            addOverlay(legs.active, kind: .active, routeID: route.id,
                       transitionFrom: transitionStyle, to: map)
            addOverlay(legs.active, kind: .activeHighlight, routeID: route.id, to: map)
        }

        private func activeRouteLegs(for route: NavigationRoute) -> RouteLegGeometry {
            return RouteMapGeometry.activeLeg(in: route.coordinates,
                                              from: parent.state.location?.coordinate,
                                              through: parent.state.waypoints + parent.state.evChargingStops)
        }

        private func updateRouteReveal(on map: MKMapView) {
            let progress = parent.state.status == .routePreview
                ? CGFloat(parent.state.routeRevealProgress) : 1
            for overlay in routeOverlays where overlay.kind == .active || overlay.kind == .activeCasing || overlay.kind == .activeHighlight {
                guard let renderer = map.renderer(for: overlay.polyline) as? MKPolylineRenderer else { continue }
                renderer.strokeEnd = progress
                renderer.setNeedsDisplay()
            }
        }

        private func addJourneyLegs(_ legs: [JourneyLeg], routeID: UUID, transitionStyle: LineStyle?,
                                    to map: MKMapView) -> Bool {
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
                    addOverlay(split.completed, kind: .traveled, routeID: routeID, to: map)
                    didDrawLeg = true
                }

                let mode = leg.mode.lowercased()
                let walking = isWalkingLeg(mode)
                let cycling = mode.contains("bicycle") || mode.contains("bike")
                let color = walking ? RouteColorPalette.walking : cycling ? RouteColorPalette.cycling : RouteColorPalette.activeLight
                let paths = walking ? RouteMapGeometry.dashedSegments(split.remaining) : [split.remaining]
                for path in paths where path.count > 1 {
                    let kind = MacRouteLineKind.journeyLeg(color: color, walking: walking, cycling: cycling)
                    let casingKind = MacRouteLineKind.journeyCasing(walking: walking, cycling: cycling)
                    let casing = lineStyle(for: casingKind)
                    let invisibleCasing = LineStyle(hex: casing.hex, opacity: 0, width: casing.width)
                    addOverlay(path, kind: casingKind, routeID: routeID,
                               transitionFrom: transitionStyle == nil ? nil : invisibleCasing, to: map)
                    addOverlay(path, kind: kind, routeID: routeID, transitionFrom: transitionStyle, to: map)
                    didDrawLeg = true
                }
                legStartDistance += legLength
            }
            return didDrawLeg
        }

        private func isWalkingLeg(_ mode: String) -> Bool {
            mode == "walk" || mode == "walking" || mode == "foot" || mode == "pedestrian" || mode.contains("walk")
        }

        private func previousStyle(for routeID: UUID, kind: MacRouteLineKind, in overlays: [StyledOverlay]) -> LineStyle? {
            guard let overlay = overlays.first(where: { $0.routeID == routeID && $0.kind == kind }) else { return nil }
            return presentedStyle(for: overlay)
        }

        private func animateRouteSelection(removeDeparted: Bool = false) {
            routeTransitionTimer?.invalidate()
            let start = Date()
            routeTransitionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if let map = self.map {
                    for overlay in self.allStyledOverlays {
                        self.updateRenderer(for: overlay, on: map)
                    }
                }
                if Date().timeIntervalSince(start) >= 0.3 {
                    if removeDeparted {
                        let departed = self.routeOverlays.filter { $0.kind == .departed }.map(\.polyline)
                        self.map?.removeOverlays(departed)
                        self.routeOverlays.removeAll { $0.kind == .departed }
                    }
                    timer.invalidate()
                    self.routeTransitionTimer = nil
                }
            }
        }

        private func animateNavigationStart() {
            let startedAt = Date()
            for index in routeOverlays.indices {
                let kind = routeOverlays[index].kind
                let startingStyle = lineStyle(for: kind, navigating: false)
                routeOverlays[index].transitionFrom = startingStyle
                routeOverlays[index].transitionStartedAt = startedAt
            }
            animateRouteSelection()
        }

        private func updateAccuracyHalo(on map: MKMapView) {
            guard let location = parent.state.location,
                  Date().timeIntervalSince(location.timestamp) >= 0,
                  Date().timeIntervalSince(location.timestamp) < 20,
                  location.accuracy >= 15, location.accuracy <= 150 else {
                if let accuracyHaloOverlay { map.removeOverlay(accuracyHaloOverlay.polyline) }
                accuracyHaloOverlay = nil
                accuracyHaloCenter = nil
                accuracyHaloRadius = nil
                return
            }

            if let accuracyHaloCenter, let accuracyHaloRadius,
               accuracyHaloCenter.distance(to: location.coordinate) < 8,
               abs(accuracyHaloRadius - location.accuracy) < 5 { return }

            if let accuracyHaloOverlay { map.removeOverlay(accuracyHaloOverlay.polyline) }
            let coordinates = LocationAccuracyGeometry.circle(center: location.coordinate,
                                                              radiusMeters: location.accuracy)
            var points = coordinates.map(\.cl)
            let polyline = MKPolyline(coordinates: &points, count: points.count)
            accuracyHaloOverlay = StyledOverlay(polyline: polyline, coordinates: coordinates, kind: .accuracy,
                                                routeID: nil, transitionFrom: nil, transitionStartedAt: nil)
            accuracyHaloCenter = location.coordinate
            accuracyHaloRadius = location.accuracy
            map.addOverlay(polyline)
        }

        private func updateActiveRouteProgress(on map: MKMapView) {
            guard let route = parent.state.route,
                  parent.state.status == .navigating || parent.state.status == .rerouting else {
                activeGeometryProgressRouteID = nil
                activeGeometryProgressStep = nil
                return
            }

            if parent.state.transportMode == .transit, let journey = route.journey {
                let stepLength = route.distance > 0 ? route.distance : journey.legs.reduce(0.0) {
                    $0 + RouteGeometrySplitter.length(of: $1.coordinates)
                }
                let step = Int((stepLength * parent.state.routeGeometryProgress / 2).rounded(.down))
                guard activeGeometryProgressRouteID != route.id || activeGeometryProgressStep != step else { return }
                activeGeometryProgressRouteID = route.id
                activeGeometryProgressStep = step
                guard step > 0 else { return }
                let journeyOverlays = routeOverlays.filter { overlay in
                    guard overlay.routeID == route.id else { return false }
                    switch overlay.kind {
                    case .journeyCasing, .journeyLeg, .traveled: true
                    default: false
                    }
                }
                map.removeOverlays(journeyOverlays.map(\.polyline))
                routeOverlays.removeAll { overlay in
                    guard overlay.routeID == route.id else { return false }
                    switch overlay.kind {
                    case .journeyCasing, .journeyLeg, .traveled: true
                    default: false
                    }
                }
                _ = addJourneyLegs(journey.legs, routeID: route.id, transitionStyle: nil, to: map)
                return
            }

            let stepLength = route.distance > 0 ? route.distance : RouteGeometrySplitter.length(of: route.coordinates)
            let step = Int((stepLength * parent.state.routeGeometryProgress / 2).rounded(.down))
            guard activeGeometryProgressRouteID != route.id || activeGeometryProgressStep != step else { return }
            activeGeometryProgressRouteID = route.id
            activeGeometryProgressStep = step
            guard step > 0 else { return }

            let activeKinds: Set<MacRouteLineKind> = [.active, .activeCasing, .activeHighlight]
            let previousActive = routeOverlays.filter { $0.routeID == route.id && activeKinds.contains($0.kind) }
            map.removeOverlays(previousActive.map(\.polyline))
            routeOverlays.removeAll { $0.routeID == route.id && activeKinds.contains($0.kind) }

            let activeLeg = activeRouteLegs(for: route).active
            let routeLength = RouteGeometrySplitter.length(of: route.coordinates)
            let progressDistance = routeLength * parent.state.routeGeometryProgress
            let split = RouteGeometrySplitter.split(activeLeg, atDistance: progressDistance)
            guard split.remaining.count > 1 else { return }
            addOverlay(split.remaining, kind: .activeCasing, routeID: route.id, to: map)
            addOverlay(split.remaining, kind: .active, routeID: route.id, to: map)
            addOverlay(split.remaining, kind: .activeHighlight, routeID: route.id, to: map)
        }

        private func updateTraveledOverlay(on map: MKMapView) {
            guard let route = parent.state.route,
                  parent.state.status == .navigating || parent.state.status == .rerouting,
                  !(parent.state.transportMode == .transit && route.journey != nil) else {
                removeTraveledOverlay(from: map)
                return
            }

            let fraction = parent.state.routeGeometryProgress
            let stepLength = route.distance > 0 ? route.distance : RouteGeometrySplitter.length(of: route.coordinates)
            let step = Int((stepLength * fraction / 2).rounded(.down))
            if traveledRouteID == route.id, traveledProgressStep == step { return }
            let progressDistance = RouteGeometrySplitter.length(of: route.coordinates) * fraction
            let coordinates = RouteGeometrySplitter.split(route.coordinates, atDistance: progressDistance).completed
            guard coordinates.count > 1 else {
                removeTraveledOverlay(from: map)
                return
            }
            removeTraveledOverlay(from: map)
            var points = coordinates.map(\.cl)
            let polyline = MKPolyline(coordinates: &points, count: points.count)
            traveledOverlay = StyledOverlay(polyline: polyline, coordinates: coordinates, kind: .traveled,
                                            routeID: route.id, transitionFrom: nil, transitionStartedAt: nil)
            traveledRouteID = route.id
            traveledProgressStep = step
            map.addOverlay(polyline)
        }

        private func removeTraveledOverlay(from map: MKMapView) {
            if let traveledOverlay { map.removeOverlay(traveledOverlay.polyline) }
            traveledOverlay = nil
            traveledRouteID = nil
            traveledProgressStep = nil
        }

        private func updateTrafficOverlay(on map: MKMapView) {
            guard parent.settings.overlays.traffic, let flow = parent.state.traffic?.flow, flow.coordinates.count > 1 else {
                if let trafficOverlay { map.removeOverlay(trafficOverlay.polyline) }
                trafficOverlay = nil
                trafficCoordinates = nil
                trafficColorHex = nil
                return
            }
            if trafficCoordinates != flow.coordinates {
                if let trafficOverlay { map.removeOverlay(trafficOverlay.polyline) }
                var points = flow.coordinates.map(\.cl)
                let polyline = MKPolyline(coordinates: &points, count: points.count)
                trafficOverlay = StyledOverlay(polyline: polyline, coordinates: flow.coordinates, kind: .traffic, routeID: nil,
                                               transitionFrom: nil, transitionStartedAt: nil)
                trafficCoordinates = flow.coordinates
                map.addOverlay(polyline)
            }
            if trafficColorHex != flow.overlayColorHex {
                trafficColorHex = flow.overlayColorHex
                if let trafficOverlay { updateRenderer(for: trafficOverlay, on: map) }
            }
        }

        private func updateRouteTrafficOverlays(on map: MKMapView) {
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let routeID = parent.state.route?.id
            let segments = parent.settings.overlays.traffic && parent.state.transportMode == .car && isNavigating
                ? (parent.state.traffic?.routeFlowSegments ?? []).filter { $0.routeID == routeID }
                : []
            guard segments != shownRouteTrafficSegments else { return }
            let previousOverlays = routeOverlays.filter { overlay in
                if case .routeTraffic = overlay.kind { return true }
                return false
            }
            map.removeOverlays(previousOverlays.map(\.polyline))
            routeOverlays.removeAll { overlay in
                if case .routeTraffic = overlay.kind { return true }
                return false
            }
            shownRouteTrafficSegments = segments
            guard let routeID else { return }
            for segment in segments {
                addOverlay(segment.coordinates, kind: .routeTraffic(color: segment.colorHex),
                           routeID: routeID, to: map)
            }
        }

        private func updateIncidentOverlays(on map: MKMapView, incidents: [TrafficIncident]) {
            let renderItems = incidents.filter { $0.geometry.count > 1 }.map {
                MacIncidentLineRenderItem(id: $0.id, coordinates: $0.geometry,
                                          colorHex: TrafficMapPresentation($0).colorHex)
            }.sorted { $0.id < $1.id }
            guard renderItems != incidentOverlayRenderItems else { return }
            map.removeOverlays(incidentOverlays.values.flatMap { $0.map(\.polyline) })
            incidentOverlays.removeAll()
            incidentOverlayRenderItems = renderItems
            for item in renderItems {
                func makeOverlay(kind: MacRouteLineKind) -> StyledOverlay {
                    var points = item.coordinates.map(\.cl)
                    let polyline = MKPolyline(coordinates: &points, count: points.count)
                    let overlay = StyledOverlay(polyline: polyline, coordinates: item.coordinates,
                                                kind: kind, routeID: nil,
                                                transitionFrom: nil, transitionStartedAt: nil)
                    map.addOverlay(polyline, level: .aboveRoads)
                    return overlay
                }
                incidentOverlays[item.id] = [
                    makeOverlay(kind: .incidentCasing),
                    makeOverlay(kind: .incident(color: item.colorHex))
                ]
            }
        }

        private func updateClosurePin(on map: MKMapView) {
            guard parent.settings.overlays.traffic, let flow = parent.state.traffic?.flow, flow.roadClosure, !flow.coordinates.isEmpty else {
                removeClosurePin(from: map)
                return
            }
            if closurePin == nil {
                let pin = MKPointAnnotation()
                pin.title = "Droga zamknięta"
                pin.subtitle = "TomTom zgłasza zamknięty odcinek drogi."
                closurePin = pin
                map.addAnnotation(pin)
            }
            closurePin?.coordinate = flow.coordinates[flow.coordinates.count / 2].cl
        }

        private func removeClosurePin(from map: MKMapView) {
            if let closurePin { map.removeAnnotation(closurePin); self.closurePin = nil }
        }

        private var showsOnlyRouteEndpoints: Bool {
            parent.state.destination != nil && parent.state.status != .idle
        }

        private var allStyledOverlays: [StyledOverlay] {
            routeOverlays + incidentOverlays.values.flatMap { $0 }
                + [traveledOverlay, trafficOverlay, accuracyHaloOverlay].compactMap { $0 }
        }

        private func styledOverlay(for polyline: MKPolyline) -> StyledOverlay? {
            allStyledOverlays.first { $0.polyline === polyline }
        }

        private func updateRenderer(for overlay: StyledOverlay, on map: MKMapView) {
            guard let renderer = map.renderer(for: overlay.polyline) as? MKPolylineRenderer else { return }
            apply(presentedStyle(for: overlay), to: renderer)
            renderer.setNeedsDisplay()
        }

        private func apply(_ style: LineStyle, to renderer: MKPolylineRenderer) {
            renderer.strokeColor = color(hex: style.hex, opacity: style.opacity)
            renderer.lineWidth = style.width
        }

        private func lineStyle(for kind: MacRouteLineKind, navigating navigationOverride: Bool? = nil) -> LineStyle {
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

        private func presentedStyle(for overlay: StyledOverlay) -> LineStyle {
            let target = lineStyle(for: overlay.kind)
            guard let start = overlay.transitionFrom, let transitionStartedAt = overlay.transitionStartedAt else { return target }
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

        private func color(hex: UInt32, opacity: CGFloat) -> NSColor {
            NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: opacity)
        }

        private struct StyledOverlay {
            let polyline: MKPolyline
            let coordinates: [Coordinate]
            let kind: MacRouteLineKind
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
