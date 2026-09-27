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
    var isBottomSheetDragging: Bool { scene.isBottomSheetDragging }
    var viewportPadding: CameraPadding { scene.viewportPadding }
    var onSearchSelect: (Destination) -> Void { scene.commands.onSearchSelect }
    var onPlaceSelect: ([SearchResult]) -> Void { scene.commands.onPlaceSelect }
    var onTransitStopSelect: (TransitStop) -> Void { scene.commands.onTransitStopSelect }
    var onTransitVehicleSelect: (TransitVehicle) -> Void { scene.commands.onTransitVehicleSelect }
    var onParkedCarSelect: () -> Void { scene.commands.onParkedCarSelect }
    var onCyclingPathsStatus: (OSMCyclingPathsStatus) -> Void { scene.commands.onCyclingPathsStatus }
    var onMapReady: () -> Void { scene.commands.onMapReady }
    var onMapPan: () -> Void { scene.commands.onMapPan }
    var onLongPress: (Coordinate) -> Void { scene.commands.onLongPress }
    @Environment(\.colorScheme) var colorScheme

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
        coordinator.stopCyclingPathUpdates()
    }

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: MapLibreView
        weak var map: MKMapView?
        private let routeRenderer: MacRouteRenderer
        private var destinationPin: MKPointAnnotation?
        private var routeOriginPin: MKPointAnnotation?
        private var positionPin: MKPointAnnotation?
        private let puckEngine = NavigationPuckEngine()
        private var puckRenderTimer: Timer?
        private var lastPositionMarkerAngle: Int?
        private var lastPositionMarkerIsNavigating: Bool?
        private var lastDestinationMarkerIsArrived: Bool?
        private var transitVehiclePins: [String: MKPointAnnotation] = [:]
        private let transitStopRenderer = MacTransitStopRenderer()
        private var transitLineOverlay: MKPolyline?
        private var cyclingPathOverlays: [MKPolyline] = []
        private var cyclingPathQueryID: String?
        private var cyclingPathTask: Task<Void, Never>?
        private var cyclingPathStatus: OSMCyclingPathsStatus = .disabled
        private var trafficRasterOverlays: [String: MKTileOverlay] = [:]
        private var trafficRasterTemplates: [String: String] = [:]
        private var shownTransitRouteID: String?
        private var shownTransitLineCoordinates: [Coordinate] = []
        private var closurePin: MKPointAnnotation?
        private var parkedCarPin: MKPointAnnotation?
        private var shownParkedCarID: UUID?
        private var searchPins: [MKPointAnnotation] = []
        private var searchIDs: [UUID] = []
        private var incidentPins: [MKPointAnnotation] = []
        private var shownIncidentIDs: [String] = []
        private var shownIncidents: [TrafficIncident] = []
        private var roadAlertPins: [MKPointAnnotation] = []
        private var shownRoadAlertIDs: [String] = []
        private var shownRoadAlerts: [RoadSafetyAlert] = []
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
        private var placeSearch: MKLocalSearch?
        private var placeRequestID = UUID()
        private var transitAnnotationUpdateWorkItem: DispatchWorkItem?
        private var searchMapCenterWorkItem: DispatchWorkItem?

        init(_ parent: MapLibreView) {
            self.parent = parent
            self.routeRenderer = MacRouteRenderer(parent: parent)
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let click = gestureRecognizer as? NSClickGestureRecognizer,
                  let other = otherGestureRecognizer as? NSClickGestureRecognizer else { return false }
            return click.numberOfClicksRequired == 1 && other.numberOfClicksRequired == 2
        }

        @objc func placeClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let map, recognizer.state == .ended else { return }
            let point = recognizer.location(in: map)
            if let pin = parkedCarPin {
                let screen = map.convert(pin.coordinate, toPointTo: map)
                if hypot(screen.x - point.x, screen.y - point.y) < 30 { return }
            }
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
            let transitPins = transitStopRenderer.annotations + Array(transitVehiclePins.values)
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
            routeRenderer.updateContext(parent)
            updateCyclingPaths(on: map)
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
            if let car = parent.scene.parkedCar {
                if parkedCarPin == nil || shownParkedCarID != car.id {
                    if let parkedCarPin { map.removeAnnotation(parkedCarPin) }
                    let pin = MKPointAnnotation()
                    pin.coordinate = car.coordinate.cl
                    pin.title = "Zaparkowany samochód"
                    pin.subtitle = car.parkedAt.formatted(date: .omitted, time: .shortened)
                    parkedCarPin = pin
                    shownParkedCarID = car.id
                    map.addAnnotation(pin)
                }
                parkedCarPin?.coordinate = car.coordinate.cl
            } else if let pin = parkedCarPin {
                map.removeAnnotation(pin)
                parkedCarPin = nil
                shownParkedCarID = nil
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
            routeRenderer.updateRoutes(on: map, previousStatus: lastStatus)
            routeRenderer.updateTrafficOverlay(on: map)
            routeRenderer.updateRouteTrafficOverlays(on: map)
            if showsOnlyRouteEndpoints {
                removeClosurePin(from: map)
            } else {
                updateClosurePin(on: map)
            }
            routeRenderer.updateAccuracyHalo(on: map)

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
            routeRenderer.updateIncidentOverlays(on: map, incidents: incidents)
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
                routeRenderer.refreshAll(on: map)
            }
            if lastStatus == .routePreview && parent.state.status == .navigating {
                routeRenderer.animateNavigationStart()
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

        private func scheduleTransitAnnotationUpdate(on map: MKMapView) {
            transitAnnotationUpdateWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map else { return }
                self.updateTransitVehiclePins(on: map)
                self.transitStopRenderer.update(on: map, parent: self.parent,
                                                showsOnlyRouteEndpoints: self.showsOnlyRouteEndpoints)
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
            if parent.isBottomSheetDragging && routePreviewPaddingChanged {
                effectiveIntent.animationDuration = 0
            }
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
            if let pin = parkedCarPin, annotation === pin {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onParkedCarSelect()
                return
            }
            if annotation is MKClusterAnnotation || incidentPins.contains(where: { $0 === annotation })
                || roadAlertPins.contains(where: { $0 === annotation }) {
                view.wantsLayer = true
                let scale = 42 / max(1, view.frame.width)
                view.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                return
            }
            if let stop = transitStopRenderer.stop(for: annotation) {
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
            if let pin = parkedCarPin, annotation === pin {
                let marker = MKAnnotationView(annotation: annotation, reuseIdentifier: "parked-car")
                marker.frame = NSRect(x: 0, y: 0, width: 64, height: 54)
                marker.wantsLayer = true
                marker.layer?.backgroundColor = NSColor.systemOrange.cgColor
                marker.layer?.cornerRadius = 16
                marker.layer?.borderWidth = 2
                marker.layer?.borderColor = NSColor.white.cgColor
                marker.layer?.shadowColor = NSColor.black.cgColor
                marker.layer?.shadowOpacity = 0.25
                marker.layer?.shadowRadius = 4

                let icon = NSImageView(frame: NSRect(x: 22, y: 31, width: 20, height: 19))
                icon.image = NSImage(systemSymbolName: "car.side.fill", accessibilityDescription: "Samochód")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
                icon.contentTintColor = .white
                icon.imageScaling = .scaleProportionallyUpOrDown
                marker.addSubview(icon)
                let label = NSTextField(labelWithString: "Auto")
                label.frame = NSRect(x: 3, y: 17, width: 58, height: 13)
                label.alignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 10)
                marker.addSubview(label)
                let time = NSTextField(labelWithString: pin.subtitle ?? "")
                time.frame = NSRect(x: 3, y: 4, width: 58, height: 12)
                time.alignment = .center
                time.textColor = NSColor.white.withAlphaComponent(0.9)
                time.font = .systemFont(ofSize: 8, weight: .medium)
                marker.addSubview(time)
                marker.setAccessibilityLabel("Zaparkowany samochód, \(pin.subtitle ?? "")")
                marker.setAccessibilityRole(.button)
                marker.displayPriority = .required
                return marker
            }
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

            if let marker = transitStopRenderer.annotationView(for: annotation, map: mapView) {
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
            let matchedRoute: NavigationRouteMatch? = parent.state.routeMatch.flatMap { match -> NavigationRouteMatch? in
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
            updateCyclingPaths(on: mapView)
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
            if let line = cyclingPathOverlays.first(where: { $0 === overlay }) {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = parent.colorScheme == .dark
                    ? NSColor(calibratedRed: 0.39, green: 0.91, blue: 0.66, alpha: 0.95)
                    : NSColor(calibratedRed: 0.03, green: 0.56, blue: 0.37, alpha: 0.94)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
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
            routeRenderer.configure(renderer, for: line)
            return renderer
        }

        func stopCyclingPathUpdates() {
            cyclingPathTask?.cancel()
            cyclingPathTask = nil
        }

        private func updateCyclingPaths(on map: MKMapView) {
            guard parent.settings.overlays.cycling else {
                stopCyclingPathUpdates()
                cyclingPathQueryID = nil
                if !cyclingPathOverlays.isEmpty {
                    map.removeOverlays(cyclingPathOverlays)
                    cyclingPathOverlays = []
                }
                setCyclingPathStatus(.disabled)
                return
            }

            let region = map.region
            let center = Coordinate(latitude: region.center.latitude, longitude: region.center.longitude)
            guard let query = OSMCyclingQuery.visible(
                center: center,
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta
            ) else {
                stopCyclingPathUpdates()
                cyclingPathQueryID = "zoomed-out"
                if !cyclingPathOverlays.isEmpty {
                    map.removeOverlays(cyclingPathOverlays)
                    cyclingPathOverlays = []
                }
                setCyclingPathStatus(.zoomIn)
                return
            }
            guard cyclingPathQueryID != query.id else { return }

            cyclingPathQueryID = query.id
            cyclingPathTask?.cancel()
            map.removeOverlays(cyclingPathOverlays)
            cyclingPathOverlays = []
            setCyclingPathStatus(.loading)
            cyclingPathTask = Task { [weak self, weak map] in
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    let result = try await OSMCyclingPathProvider.shared.paths(in: query)
                    guard !Task.isCancelled, let self, let map,
                          self.cyclingPathQueryID == query.id,
                          self.parent.settings.overlays.cycling else { return }
                    map.removeOverlays(self.cyclingPathOverlays)
                    self.cyclingPathOverlays = result.paths.map { path in
                        var coordinates = path.coordinates.map(\.cl)
                        let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                        line.title = "Ścieżka OSM · © OpenStreetMap contributors"
                        return line
                    }
                    map.addOverlays(self.cyclingPathOverlays, level: .aboveRoads)
                    self.setCyclingPathStatus(.loaded(count: result.paths.count,
                                                      truncated: result.truncated))
                } catch {
                    guard !Task.isCancelled, let self, let map,
                          self.cyclingPathQueryID == query.id else { return }
                    map.removeOverlays(self.cyclingPathOverlays)
                    self.cyclingPathOverlays = []
                    self.setCyclingPathStatus(.unavailable)
                }
            }
        }

        private func setCyclingPathStatus(_ status: OSMCyclingPathsStatus) {
            guard cyclingPathStatus != status else { return }
            cyclingPathStatus = status
            parent.onCyclingPathsStatus(status)
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

    }
}

#endif
