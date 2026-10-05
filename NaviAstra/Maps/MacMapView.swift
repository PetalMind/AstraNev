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
    var onRouteSelect: (UUID) -> Void { scene.commands.onRouteSelect }
    var onCyclingPathsStatus: (OSMCyclingPathsStatus) -> Void { scene.commands.onCyclingPathsStatus }
    var onRoadPOIStatus: (MapRoadPOIStatus) -> Void { scene.commands.onRoadPOIStatus }
    var onTransitViewportChange: (TransitMapViewport) -> Void { scene.commands.onTransitViewportChange }
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
        coordinator.stopMapRoadPOIUpdates()
        coordinator.stopShopLogoUpdates()
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
        private var lastDestinationMarkerIsArrived: Bool?
        private var transitVehiclePins: [String: MKPointAnnotation] = [:]
        private let transitStopRenderer = MacTransitStopRenderer()
        private var transitLineOverlay: MKPolyline?
        private var cyclingPathOverlays: [MKPolyline] = []
        private var cyclingPathQueryID: String?
        private var cyclingPathTask: Task<Void, Never>?
        private var cyclingPathStatus: OSMCyclingPathsStatus = .disabled
        private var mapRoadPOIs: [MapRoadPOI] = []
        private var mapRoadPOIRetryAfter: Date?
        private var mapRoadPOIQueryID: String?
        private var mapRoadPOITask: Task<Void, Never>?
        private var mapRoadPOIStatus: MapRoadPOIStatus = .disabled
        private var mapRoadPOIPins: [MKPointAnnotation] = []
        private var shownMapRoadPOIIDs: [String] = []
        private var shownMapRoadPOIs: [MapRoadPOI] = []
        private var trafficRasterOverlays: [String: MKTileOverlay] = [:]
        private var trafficRasterTemplates: [String: String] = [:]
        private var shownTransitRouteID: String?
        private var shownTransitLineCoordinates: [Coordinate] = []
        private var closurePin: MKPointAnnotation?
        private var parkedCarPin: MKPointAnnotation?
        private var shownParkedCarID: UUID?
        private var searchPins: [MKPointAnnotation] = []
        private var searchIDs: [UUID] = []
        private var shownPlaceResults: [SearchResult] = []
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
        private var lastBaseMap: BaseMap?
        private var lastDimension: MapDimension?
        private var lastCameraMode: MapDimension?
        private var lastPOICategories: Set<MapPOICategory>?
        private let shopLogoLoader = ShopPOILogoLoader()
        private var shopViewportTask: Task<Void, Never>?
        private var shopViewportSearch: MKLocalSearch?
        private var shopViewportKey: String?
        private var shopViewportResults: [SearchResult] = []
        private var shopLogoResults: [String: SearchResult] = [:]
        private var shopLogoPins: [String: MKPointAnnotation] = [:]
        private var lastShopLogosEnabled: Bool?
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
            if click.numberOfClicksRequired == 1, let map,
               routeRenderer.routeID(near: click.location(in: map), on: map) != nil {
                return false
            }
            return click.numberOfClicksRequired == 1 && other.numberOfClicksRequired == 2
        }

        @objc func placeClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let map, recognizer.state == .ended else { return }
            let point = recognizer.location(in: map)
            if routeRenderer.containsETAMarker(at: point, on: map) { return }
            if let pin = parkedCarPin {
                let screen = map.convert(pin.coordinate, toPointTo: map)
                if hypot(screen.x - point.x, screen.y - point.y) < 30 { return }
            }
            if let entry = shopLogoPins.first(where: {
                let screen = map.convert($0.value.coordinate, toPointTo: map)
                return hypot(screen.x - point.x, screen.y - point.y) < 24
            }), let result = shopLogoResults[entry.key] {
                parent.onPlaceSelect([result])
                return
            }
            // Search pins already have an exact identity and need no network lookup.
            if let index = searchPins.firstIndex(where: {
                let screen = map.convert($0.coordinate, toPointTo: map)
                return hypot(screen.x - point.x, screen.y - point.y) < 24
            }), shownPlaceResults.indices.contains(index) {
                placeSearch?.cancel()
                placeRequestID = UUID()
                parent.onPlaceSelect([shownPlaceResults[index]])
                return
            }
            let transitPins = transitStopRenderer.annotations + Array(transitVehiclePins.values)
            if transitPins.contains(where: {
                let screen = map.convert($0.coordinate, toPointTo: map)
                return hypot(screen.x - point.x, screen.y - point.y) < 24
            }) { return }
            if let routeID = routeRenderer.routeID(near: point, on: map) {
                parent.onRouteSelect(routeID)
                return
            }
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
                let results = response.mapItems.compactMap { item -> (result: SearchResult, distance: CLLocationDistance)? in
                    let location = item.location.coordinate
                    let screen = map.convert(location, toPointTo: map)
                    guard hypot(screen.x - point.x, screen.y - point.y) <= 24, let name = item.name else { return nil }
                    let distance = center.distance(from: item.location)
                    var result = SearchResult(destination: Destination(name: name,
                                                                        coordinate: Coordinate(latitude: location.latitude, longitude: location.longitude),
                                                                        address: item.address?.fullAddress),
                                              street: nil, houseNumber: nil, city: item.addressRepresentations?.cityName,
                                              countryCode: item.addressRepresentations?.region?.identifier.lowercased(),
                                              isPOI: true, providerID: item.identifier?.rawValue, placeProvider: .mapKit,
                                              category: item.pointOfInterestCategory?.rawValue,
                                              phone: item.phoneNumber, website: item.url?.absoluteString,
                                              timeZoneIdentifier: item.timeZone?.identifier)
                    result.selectionDistanceFromTap = distance
                    return (result, distance)
                }
                let places = results.sorted { $0.distance < $1.distance }.prefix(5).map { $0.result }
                if !places.isEmpty { self.parent.onPlaceSelect(places) }
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
            if gesture is NSPanGestureRecognizer { parent.onMapPan() }
            parent.state.cameraState = .freeLook
            parent.state.cameraIntent = nil
        }

        private let weatherRenderer = WeatherMapRenderer()

        func update(_ map: MKMapView) {
            routeRenderer.updateContext(parent)
            updateCyclingPaths(on: map)
            updateMapRoadPOIs(on: map)
            let results = parent.scene.placeMarkers
            shownPlaceResults = results
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
                if parkedCarPin == nil || shownParkedCarID != car.id || parkedCarPin?.subtitle != car.mapTimestamp {
                    if let parkedCarPin { map.removeAnnotation(parkedCarPin) }
                    let pin = MKPointAnnotation()
                    pin.coordinate = car.coordinate.cl
                    pin.title = "Zaparkowany samochód"
                    pin.subtitle = car.mapTimestamp
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
            updateShopLogos(on: map)
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
            weatherRenderer.update(map: map, configuration: parent.scene.weather, samples: parent.scene.weatherSamples)
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
            let showsRoadAlerts = !showsOnlyRouteEndpoints || isNavigating
            let roadAlertDistance = parent.state.roadAlertRouteDistance
            let roadAlerts = (showsRoadAlerts ? parent.state.roadSafetyAlerts : [])
                .filter { alert in
                    if let category = alert.mapSafetyPOICategory,
                       !parent.settings.safetyPOICategories.contains(category) { return false }
                    guard let distance = alert.distanceAlongRoute else { return false }
                    guard isNavigating else { return true }
                    return distance >= roadAlertDistance - 60 && distance <= roadAlertDistance + 20_000
                        && alert.type.isImportantDuringNavigation
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
                pin.subtitle = roadAlertSubtitle(alert, routeDistance: roadAlertDistance)
            }
            updateMapRoadPOIAnnotations(on: map)
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
            alert.mapSubtitle(from: routeDistance)
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
            effectiveIntent = effectiveIntent.fittingViewport(
                parent.viewportPadding, width: Double(map.bounds.width), height: Double(map.bounds.height))
            if parent.isBottomSheetDragging && routePreviewPaddingChanged {
                effectiveIntent.animationDuration = 0
            }
            if cameraState == .routeOverview, !enteringOverview, !newOverview, !cameraCommandChanged,
               !routePreviewPaddingChanged, !cameraModeChanged,
               let route = parent.state.route {
                let overviewCoordinates = parent.state.status == .routePreview
                    ? (parent.state.alternatives + [route]).flatMap(\.coordinates)
                    : route.coordinates
                if isMostlyVisible(overviewCoordinates, on: map) { return }
            }
            if intent == lastIntent && !enteringOverview && !newOverview && !cameraCommandChanged &&
                !routePreviewPaddingChanged && !cameraModeChanged && !cameraStateChanged { return }
            if cameraMode == .flat {
                effectiveIntent.pitch = 0
            } else if cameraState == .destinationPreview || cameraState == .routeOverview {
                effectiveIntent.pitch = 12
            } else if cameraState == .browse {
                effectiveIntent.pitch = 40
            }
            if cameraState == .routeOverview, lastOverviewRouteID != nil,
               let route = parent.state.route, lastStatus == .routePreview {
                effectiveIntent.bounds = (parent.state.alternatives + [route]).flatMap(\.coordinates)
            }
            MacMapCameraAnimator.apply(effectiveIntent, state: cameraState, to: map)
            lastViewportPadding = parent.viewportPadding
            lastMapSize = map.bounds.size
            lastIntent = intent
            lastCameraState = cameraState
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

        func stopShopLogoUpdates() {
            shopViewportTask?.cancel()
            shopViewportSearch?.cancel()
            shopLogoLoader.stop()
        }

        private func updateShopLogos(on map: MKMapView) {
            let enabled = parent.settings.shopLogosEnabled
            let showsStores = enabled && parent.settings.visiblePOICategories.contains(.shopping)
                && map.region.span.longitudeDelta < 0.06
            if !showsStores {
                shopViewportTask?.cancel()
                shopViewportSearch?.cancel()
                shopViewportKey = nil
                shopViewportResults = []
                refreshShopLogoMarkers(on: map)
                return
            }
            let region = map.region
            let key = [region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta]
                .map { String(Int(($0 * 1000).rounded())) }.joined(separator: ":")
            if key != shopViewportKey {
                shopViewportKey = key
                shopViewportTask?.cancel()
                shopViewportSearch?.cancel()
                shopViewportResults = []
                shopViewportTask = Task { [weak self, weak map] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self, let map else { return }
                    let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
                    request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.store])
                    let search = MKLocalSearch(request: request)
                    self.shopViewportSearch = search
                    guard let reply = try? await search.start(), !Task.isCancelled,
                          self.shopViewportKey == key else { return }
                    self.shopViewportResults = reply.mapItems.prefix(32).compactMap { item in
                        guard let name = item.name else { return nil }
                        let coordinate = item.location.coordinate
                        return SearchResult(destination: Destination(name: name,
                            coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                            address: item.address?.fullAddress), street: nil, houseNumber: nil,
                            city: item.addressRepresentations?.cityName,
                            countryCode: item.addressRepresentations?.region?.identifier.lowercased(),
                            isPOI: true, providerID: item.identifier?.rawValue, placeProvider: .mapKit,
                            category: item.pointOfInterestCategory?.rawValue)
                    }
                    self.refreshShopLogoMarkers(on: map)
                }
            }
            refreshShopLogoMarkers(on: map)
        }

        private func refreshShopLogoMarkers(on map: MKMapView) {
            let places = shownPlaceResults.filter { $0.isPOI && PlacePOIMapMarkerKind(category: $0.category) == .shopping }
                + shopViewportResults
            shopLogoLoader.update(places.map(\.placeIdentity), enabled: parent.settings.shopLogosEnabled) { [weak self, weak map] in
                guard let self, let map else { return }
                self.syncShopLogoPins(on: map)
                self.lastPOIMarkerDark = nil
                self.updatePOIMarkerAppearance(on: map)
            }
            syncShopLogoPins(on: map)
        }

        private func syncShopLogoPins(on map: MKMapView) {
            let searchKeys = Set(shownPlaceResults.map { $0.placeIdentity.cacheKey })
            let desired = parent.settings.shopLogosEnabled ? shopViewportResults.filter {
                shopLogoLoader.images[$0.placeIdentity.cacheKey] != nil && !searchKeys.contains($0.placeIdentity.cacheKey)
            } : []
            let keys = Set(desired.map { $0.placeIdentity.cacheKey })
            for key in Array(shopLogoPins.keys) where !keys.contains(key) {
                if let pin = shopLogoPins.removeValue(forKey: key) { map.removeAnnotation(pin) }
                shopLogoResults.removeValue(forKey: key)
            }
            for result in desired {
                let key = result.placeIdentity.cacheKey
                shopLogoResults[key] = result
                guard shopLogoPins[key] == nil else { continue }
                let pin = MKPointAnnotation()
                pin.coordinate = result.destination.coordinate.cl
                pin.title = result.destination.name
                shopLogoPins[key] = pin
                map.addAnnotation(pin)
            }
        }

        private func updatePOIMarkerAppearance(on map: MKMapView) {
            let dark = usesDarkMapAppearance
            guard lastPOIMarkerDark != dark || lastShopLogosEnabled != parent.settings.shopLogosEnabled else { return }
            lastPOIMarkerDark = dark
            lastShopLogosEnabled = parent.settings.shopLogosEnabled
            for pin in shopLogoPins.values {
                if let marker = map.view(for: pin) { stylePOIMarker(marker, annotation: pin, kind: .shopping, dark: dark) }
            }
            for (index, pin) in searchPins.enumerated()
                where shownPlaceResults.indices.contains(index) {
                guard shownPlaceResults[index].isPOI,
                      let kind = PlacePOIMapMarkerKind(category: shownPlaceResults[index].category),
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
            let background = kind.colorHex(dark: dark)
            marker.layer?.backgroundColor = NSColor(
                calibratedRed: CGFloat((background >> 16) & 0xff) / 255,
                green: CGFloat((background >> 8) & 0xff) / 255,
                blue: CGFloat(background & 0xff) / 255, alpha: 1).cgColor
            marker.layer?.cornerRadius = 18
            marker.layer?.borderWidth = 1.8
            let color = dark ? NSColor(naviHex: 0x17212B) : NSColor.white
            let rim = NSColor(naviHex: PlacePOIMapPalette.backgroundHex(dark: dark))
            marker.layer?.borderColor = rim.cgColor
            marker.layer?.shadowColor = NSColor.black.cgColor
            marker.layer?.shadowOpacity = 0.18
            marker.layer?.shadowRadius = 3
            marker.layer?.shadowOffset = CGSize(width: 0, height: -1)
            let image = NSImageView(frame: NSRect(x: 8, y: 8, width: 20, height: 20))
            image.image = NSImage(systemSymbolName: kind.symbolName,
                                  accessibilityDescription: kind.accessibilityName)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            let identity = searchPins.firstIndex(where: { $0 === annotation }).flatMap {
                shownPlaceResults.indices.contains($0) ? shownPlaceResults[$0].placeIdentity : nil
            } ?? shopLogoPins.first(where: { $0.value === annotation }).flatMap { shopLogoResults[$0.key]?.placeIdentity }
            if kind == .shopping, parent.settings.shopLogosEnabled, let identity,
               let logo = shopLogoLoader.images[identity.cacheKey] {
                image.image = logo
                marker.layer?.backgroundColor = NSColor.white.cgColor
                image.contentTintColor = nil
            } else {
                image.contentTintColor = color
            }
            image.imageScaling = .scaleProportionallyUpOrDown
            marker.addSubview(image)
            marker.canShowCallout = true
            let isSelectedPlace = searchPins.firstIndex(where: { $0 === annotation }).map {
                shownPlaceResults.indices.contains($0)
                    && shownPlaceResults[$0].id == parent.scene.selectedPlace?.id
            } ?? false
            marker.displayPriority = isSelectedPlace ? .required : .defaultHigh
            marker.setAccessibilityLabel("\(kind.accessibilityName): \(annotation.title.flatMap { $0 } ?? "")")
            marker.setAccessibilityRole(.button)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if let routeID = routeRenderer.routeID(forETAMarker: annotation) {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onRouteSelect(routeID)
                return
            }
            if let pin = parkedCarPin, annotation === pin {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onParkedCarSelect()
                return
            }
            if let signMarker = view as? TrafficMapAnnotationView, signMarker.isShowingRoadSign {
                signMarker.setRoadSignSelected(true)
                return
            }
            if annotation is MKClusterAnnotation || incidentPins.contains(where: { $0 === annotation })
                || roadAlertPins.contains(where: { $0 === annotation })
                || mapRoadPOIPins.contains(where: { $0 === annotation }) {
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
            if let entry = shopLogoPins.first(where: { $0.value === annotation }), let result = shopLogoResults[entry.key] {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onPlaceSelect([result])
                return
            }
            if let index = searchPins.firstIndex(where: { $0 === annotation }),
               shownPlaceResults.indices.contains(index) {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onPlaceSelect([shownPlaceResults[index]])
                return
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let annotation = view.annotation,
                  annotation is MKClusterAnnotation || incidentPins.contains(where: { $0 === annotation })
                    || roadAlertPins.contains(where: { $0 === annotation })
                    || mapRoadPOIPins.contains(where: { $0 === annotation }) else { return }
            (view as? TrafficMapAnnotationView)?.setRoadSignSelected(false)
            view.layer?.setAffineTransform(.identity)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let marker = routeRenderer.annotationView(for: annotation) { return marker }
            if let pin = parkedCarPin, annotation === pin {
                let marker = MKAnnotationView(annotation: annotation, reuseIdentifier: "parked-car")
                marker.frame = NSRect(x: 0, y: 0, width: 80, height: 70)
                marker.centerOffset = CGPoint(x: 0, y: -35)
                marker.wantsLayer = true
                let bubble = CAShapeLayer()
                let path = CGMutablePath()
                path.addRoundedRect(in: CGRect(x: 1, y: 11, width: 78, height: 58), cornerWidth: 18, cornerHeight: 18)
                path.move(to: CGPoint(x: 31, y: 13))
                path.addLine(to: CGPoint(x: 40, y: 1))
                path.addLine(to: CGPoint(x: 49, y: 13))
                path.closeSubpath()
                bubble.path = path
                bubble.fillColor = PlacePOIMapPalette.accentColor(dark: usesDarkMapAppearance).cgColor
                bubble.strokeColor = NSColor.white.cgColor
                bubble.lineWidth = 2
                bubble.shadowColor = NSColor.black.cgColor
                bubble.shadowOpacity = 0.25
                bubble.shadowRadius = 4
                marker.layer?.addSublayer(bubble)

                let icon = NSImageView(frame: NSRect(x: 28, y: 41, width: 24, height: 23))
                icon.image = NSImage(systemSymbolName: "car.side.fill", accessibilityDescription: "Samochód")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
                icon.contentTintColor = .white
                icon.imageScaling = .scaleProportionallyUpOrDown
                marker.addSubview(icon)
                let label = NSTextField(labelWithString: "Auto")
                label.frame = NSRect(x: 4, y: 25, width: 72, height: 16)
                label.alignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 12)
                marker.addSubview(label)
                let time = NSTextField(labelWithString: pin.subtitle ?? "")
                time.frame = NSRect(x: 4, y: 13, width: 72, height: 13)
                time.alignment = .center
                time.textColor = NSColor.white.withAlphaComponent(0.9)
                time.font = .systemFont(ofSize: 10, weight: .medium)
                marker.addSubview(time)
                marker.setAccessibilityLabel("Zaparkowany samochód, \(pin.subtitle ?? "")")
                marker.setAccessibilityRole(.button)
                marker.displayPriority = .required
                return marker
            }
            if let cluster = annotation as? MKClusterAnnotation {
                let memberPresentations = cluster.memberAnnotations.compactMap { trafficPresentation(for: $0) }
                let presentation = memberPresentations.filter { $0.roadSign != nil }
                    .max { $0.clusterPriority < $1.clusterPriority }
                    ?? memberPresentations.max { $0.clusterPriority < $1.clusterPriority }
                    ?? TrafficMapPresentation(
                        TrafficIncident(id: "cluster", description: "Zdarzenia drogowe",
                                        coordinate: Coordinate(latitude: cluster.coordinate.latitude,
                                                              longitude: cluster.coordinate.longitude),
                                        delaySeconds: nil, category: .unknown, severity: .unknown))
                let marker = TrafficMapAnnotationView(annotation: annotation, reuseIdentifier: "traffic-cluster")
                let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
                marker.render(presentation: presentation,
                              clusterCount: cluster.memberAnnotations.count,
                              isNavigating: isNavigating)
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

            if let index = mapRoadPOIPins.firstIndex(where: { $0 === annotation }),
               shownMapRoadPOIs.indices.contains(index) {
                let poi = shownMapRoadPOIs[index]
                let marker = TrafficMapAnnotationView(annotation: annotation,
                                                      reuseIdentifier: "map-road-poi-\(poi.category.rawValue)")
                marker.render(presentation: TrafficMapPresentation(poi), isNavigating: false)
                return marker
            }

            if let pin = closurePin, pin === annotation {
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "traffic-road-closure")
                marker.glyphImage = NSImage(systemSymbolName: "nosign", accessibilityDescription: "Droga zamknięta")
                marker.markerTintColor = NSColor(naviHex: NaviAstraColorPalette.closure)
                marker.canShowCallout = true
                marker.displayPriority = .defaultHigh
                return marker
            }

            if shopLogoPins.values.contains(where: { $0 === annotation }) {
                let marker = MKAnnotationView(annotation: annotation, reuseIdentifier: "shop-logo")
                stylePOIMarker(marker, annotation: annotation, kind: .shopping, dark: usesDarkMapAppearance)
                return marker
            }
            if let index = searchPins.firstIndex(where: { $0 === annotation }) {
                if shownPlaceResults.indices.contains(index),
                   shownPlaceResults[index].isPOI,
                   let kind = PlacePOIMapMarkerKind(category: shownPlaceResults[index].category) {
                    let marker = MKAnnotationView(annotation: annotation,
                                                  reuseIdentifier: "poi-\(kind.rawValue)")
                    stylePOIMarker(marker, annotation: annotation, kind: kind, dark: usesDarkMapAppearance)
                    return marker
                }
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
                marker.glyphText = String(index + 1)
                marker.markerTintColor = PlacePOIMapPalette.accentColor(dark: usesDarkMapAppearance)
                if shownPlaceResults.indices.contains(index),
                   shownPlaceResults[index].id == parent.scene.selectedPlace?.id {
                    marker.displayPriority = .required
                }
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
                let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
                marker.render(presentation: TrafficMapPresentation(alert), isNavigating: isNavigating)
                return marker
            }

            if let pin = positionPin, annotation === pin {
                let identifier = "user-position"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? NavigationMarkerMapKitView
                    ?? NavigationMarkerMapKitView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.update(positionMarkerPresentation(on: mapView, bearing: puckEngine.frame()?.bearing))
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            }
            if let routeOriginPin, annotation === routeOriginPin {
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "route-origin")
                marker.glyphText = "A"
                marker.markerTintColor = NSColor(naviHex: parent.colorScheme == .dark
                    ? NaviAstraColorPalette.textPrimaryNight : NaviAstraColorPalette.textPrimaryDay)
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
            if let index = mapRoadPOIPins.firstIndex(where: { $0 === annotation }),
               shownMapRoadPOIs.indices.contains(index) {
                return TrafficMapPresentation(shownMapRoadPOIs[index])
            }
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
            if isNavigating, parent.state.location != nil, parent.scene.energyPolicy.mapRenderingEnabled {
                let interval = 1.0 / Double(max(1, parent.scene.energyPolicy.mapFramesPerSecond))
                if let puckRenderTimer, abs(puckRenderTimer.timeInterval - interval) > 0.001 {
                    stopPuckRenderTimer()
                }
                if puckRenderTimer == nil {
                    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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
            guard let positionPin, let view = map.view(for: positionPin) as? NavigationMarkerMapKitView else { return }
            view.update(positionMarkerPresentation(on: map, bearing: bearing))
        }

        private func positionMarkerPresentation(on map: MKMapView, bearing: Double?) -> NavigationMarkerPresentation {
            let zoom = log2(360 / max(0.00001, map.region.span.longitudeDelta))
            return NavigationMarkerPresentation.resolve(
                state: parent.state, settings: parent.settings, bearing: bearing,
                cameraHeading: map.camera.heading, pitch: Double(map.camera.pitch), zoom: zoom,
                night: parent.colorScheme == .dark,
                increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        }

        private func destinationMarkerImage(arrived: Bool) -> NSImage? {
            let symbol = NSImage(systemSymbolName: arrived ? "checkmark.circle.fill" : "flag.fill",
                                 accessibilityDescription: arrived ? "Dotarłeś do celu" : "Cel")
            return symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(
                paletteColors: [NSColor(naviHex: arrived ? NaviAstraColorPalette.success :
                    (parent.colorScheme == .dark ? NaviAstraColorPalette.textPrimaryNight : NaviAstraColorPalette.textPrimaryDay))]))
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updatePositionPuckStyle(on: mapView, isNavigating: false, bearing: puckEngine.frame()?.bearing)
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            scheduleSearchMapCenterUpdate(center)
            let region = mapView.region
            let halfLatitude = min(90, max(0, region.span.latitudeDelta / 2))
            let halfLongitude = min(180, max(0, region.span.longitudeDelta / 2))
            parent.onTransitViewportChange(TransitMapViewport(
                south: max(-90, region.center.latitude - halfLatitude),
                west: max(-180, region.center.longitude - halfLongitude),
                north: min(90, region.center.latitude + halfLatitude),
                east: min(180, region.center.longitude + halfLongitude),
                zoom: log2(360 / max(0.00001, region.span.longitudeDelta))))

            // Region changes also come from automatic route fitting and sheet resizing.
            // Only userGesture should enter free look and collapse the sheet.
            scheduleTransitAnnotationUpdate(on: mapView)
            updateCyclingPaths(on: mapView)
            updateMapRoadPOIs(on: mapView)
            updateMapRoadPOIAnnotations(on: mapView)
            updateShopLogos(on: mapView)
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard fullyRendered else { return }
            applyCameraIntent(to: mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let renderer = weatherRenderer.renderer(for: overlay) { return renderer }
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let line = cyclingPathOverlays.first(where: { $0 === overlay }) {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = NSColor(naviHex: parent.colorScheme == .dark
                    ? NaviAstraColorPalette.cyclingRouteNight
                    : NaviAstraColorPalette.cyclingRouteDay).withAlphaComponent(0.92)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let transitLineOverlay, overlay === transitLineOverlay {
                let renderer = MKPolylineRenderer(polyline: transitLineOverlay)
                let color = parent.transitLineColor ?? NaviAstraColorPalette.transitFallback
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

        func stopMapRoadPOIUpdates() {
            mapRoadPOITask?.cancel()
            mapRoadPOITask = nil
        }

        private func updateMapRoadPOIs(on map: MKMapView) {
            let region = map.region
            let center = Coordinate(latitude: region.center.latitude,
                                    longitude: region.center.longitude)
            guard let query = MapRoadPOIQuery.visible(
                center: center,
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta,
                categories: parent.settings.roadPOICategories
            ) else {
                stopMapRoadPOIUpdates()
                setMapRoadPOIStatus(parent.settings.roadPOICategories.isEmpty ? .disabled : .zoomIn)
                guard mapRoadPOIQueryID != nil || !mapRoadPOIs.isEmpty else { return }
                mapRoadPOIQueryID = nil
                mapRoadPOIs = []
                updateMapRoadPOIAnnotations(on: map)
                return
            }
            guard mapRoadPOIQueryID != query.id ||
                    (mapRoadPOIRetryAfter ?? .distantFuture) <= .now
            else { return }

            let queryChanged = mapRoadPOIQueryID != query.id
            mapRoadPOIQueryID = query.id
            stopMapRoadPOIUpdates()
            if queryChanged {
                // Keep visible, eligible points while the replacement request is loading.
                mapRoadPOIs = mapRoadPOIs.filter { query.contains($0) }
            }
            setMapRoadPOIStatus(.loading)
            updateMapRoadPOIAnnotations(on: map)
            mapRoadPOITask = Task { [weak self, weak map] in
                do {
                    let result: MapRoadPOIResult
                    if let cached = await MapRoadPOIProvider.shared.cachedPoints(in: query) {
                        result = cached
                    } else {
                        try await Task.sleep(nanoseconds: 350_000_000)
                        try Task.checkCancellation()
                        result = try await MapRoadPOIProvider.shared.points(in: query)
                    }
                    guard !Task.isCancelled, let self, let map,
                          self.mapRoadPOIQueryID == query.id,
                          self.parent.settings.roadPOICategories.isSuperset(of: query.categories) else { return }
                    self.mapRoadPOIRetryAfter = nil
                    self.mapRoadPOIs = result.points
                    self.setMapRoadPOIStatus(result.unavailableSources.isEmpty
                        ? .loaded(count: result.points.count)
                        : .partial(count: result.points.count,
                                   message: "Niedostępne źródło: " + result.unavailableSources.joined(separator: ", ")))
                    self.updateMapRoadPOIAnnotations(on: map)
                    let refreshDelay: TimeInterval = result.unavailableSources.isEmpty ? 300 : 60
                    self.mapRoadPOIRetryAfter = Date().addingTimeInterval(refreshDelay)
                    do { try await Task.sleep(for: .seconds(refreshDelay)) }
                    catch { return }
                    guard !Task.isCancelled, self.mapRoadPOIQueryID == query.id else { return }
                    self.mapRoadPOITask = nil
                    self.updateMapRoadPOIs(on: map)
                } catch {
                    guard !Task.isCancelled, let self, let map,
                          self.mapRoadPOIQueryID == query.id else { return }
                    // A failed refresh must not remove previously downloaded points.
                    self.mapRoadPOIRetryAfter = Date().addingTimeInterval(30)
                    self.setMapRoadPOIStatus(.unavailable)
                    self.updateMapRoadPOIAnnotations(on: map)
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { return }
                    guard !Task.isCancelled, self.mapRoadPOIQueryID == query.id else { return }
                    self.mapRoadPOITask = nil
                    self.updateMapRoadPOIs(on: map)
                }
            }
        }

        private func setMapRoadPOIStatus(_ status: MapRoadPOIStatus) {
            guard mapRoadPOIStatus != status else { return }
            mapRoadPOIStatus = status
            parent.onRoadPOIStatus(status)
        }

        private func updateMapRoadPOIAnnotations(on map: MKMapView) {
            let routeAlertIDs = Set(shownRoadAlerts.map { $0.mapPOIID ?? $0.id })
            let area = map.visibleMapRect
            let visibleArea = area.insetBy(dx: -area.size.width * 0.15, dy: -area.size.height * 0.15)
            let points = mapRoadPOIs.filter {
                !routeAlertIDs.contains($0.id) && visibleArea.contains(MKMapPoint($0.coordinate.cl))
            }
            var retainedPins = Dictionary(uniqueKeysWithValues: zip(shownMapRoadPOIIDs, mapRoadPOIPins))
            var addedPins: [MKPointAnnotation] = []
            let pins = points.map { point in
                if let pin = retainedPins.removeValue(forKey: point.id) { return pin }
                let pin = MKPointAnnotation()
                addedPins.append(pin)
                return pin
            }
            if !retainedPins.isEmpty { map.removeAnnotations(Array(retainedPins.values)) }
            mapRoadPOIPins = pins
            shownMapRoadPOIIDs = points.map(\.id)
            shownMapRoadPOIs = points
            for (point, pin) in zip(points, pins) {
                if pin.coordinate.latitude != point.coordinate.latitude || pin.coordinate.longitude != point.coordinate.longitude {
                    pin.coordinate = point.coordinate.cl
                }
                if pin.title != point.title { pin.title = point.title }
                if pin.subtitle != point.subtitle { pin.subtitle = point.subtitle }
            }
            if !addedPins.isEmpty { map.addAnnotations(addedPins) }
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
                        line.title = "Ścieżka rowerowa"
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
                pin.subtitle = "Zgłoszone zamknięcie odcinka drogi."
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
