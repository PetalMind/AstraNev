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

@MainActor
private final class RoadSignMapLibreAnnotationView: MLNAnnotationView {
    private var host: UIHostingController<RoadSignView>?
    private var badge: UILabel?
    private var symbol: RoadSignSymbol?
    private var signSize: CGFloat = 24
    private var isRoadSignSelected = false

    func render(
        symbol: RoadSignSymbol,
        size: CGFloat,
        clusterCount: Int? = nil,
        directionUncertain: Bool = false
    ) {
        self.symbol = symbol
        signSize = size

        let frameSize = max(
            size + 8,
            clusterCount == nil ? 0 : 38
        )

        frame = CGRect(
            x: 0,
            y: 0,
            width: frameSize,
            height: frameSize
        )

        backgroundColor = .clear
        layer.borderWidth = 0
        layer.shadowOpacity = 0

        if let host {
            host.rootView = RoadSignView(
                symbol: symbol,
                size: size,
                isSelected: isRoadSignSelected
            )
        } else {
            let controller = UIHostingController(
                rootView: RoadSignView(
                    symbol: symbol,
                    size: size,
                    isSelected: isRoadSignSelected
                )
            )

            controller.view.backgroundColor = .clear
            controller.view.isUserInteractionEnabled = false
            controller.view.frame = bounds
            controller.view.autoresizingMask = [
                .flexibleWidth,
                .flexibleHeight
            ]

            addSubview(controller.view)
            host = controller
        }

        host?.view.frame = bounds
        host?.view.alpha = directionUncertain ? 0.66 : 1

        badge?.removeFromSuperview()
        badge = nil

        if let clusterCount, clusterCount > 1 {
            let label = UILabel(
                frame: CGRect(
                    x: frameSize - 19,
                    y: 0,
                    width: 19,
                    height: 13
                )
            )

            label.text = "+\(clusterCount - 1)"
            label.textAlignment = .center
            label.textColor = .white
            label.font = .systemFont(ofSize: 8, weight: .bold)
            label.backgroundColor = UIColor(
                white: 0.12,
                alpha: 0.92
            )
            label.layer.cornerRadius = 6.5
            label.clipsToBounds = true

            addSubview(label)
            badge = label
        }
    }

    func setRoadSignSelected(_ selected: Bool) {
        guard isRoadSignSelected != selected,
              let symbol
        else {
            return
        }

        isRoadSignSelected = selected

        host?.rootView = RoadSignView(
            symbol: symbol,
            size: signSize,
            isSelected: selected
        )
    }
}

private struct TrafficMapEvent {
    let id: String
    let coordinate: Coordinate
    let title: String
    let subtitle: String
    let categoryLabel: String
    let presentation: TrafficMapPresentation
    let isMapPOI: Bool

    init(_ incident: TrafficIncident) {
        id = "incident:\(incident.id)"
        coordinate = incident.coordinate
        title = incident.mapTitle
        subtitle = incident.mapSubtitle
        categoryLabel = incident.category.mapLabel
        presentation = TrafficMapPresentation(incident)
        isMapPOI = false
    }

    init(_ alert: RoadSafetyAlert, routeDistance: Double) {
        id = "alert:\(alert.id)"
        coordinate = alert.coordinate
        title = alert.title
        subtitle = alert.mapSubtitle(from: routeDistance)
        categoryLabel = alert.type.title
        presentation = TrafficMapPresentation(alert)
        isMapPOI = false
    }

    init(_ poi: MapRoadPOI) {
        id = poi.id
        coordinate = poi.coordinate
        title = poi.title
        subtitle = poi.subtitle
        categoryLabel = poi.category.title
        presentation = TrafficMapPresentation(poi)
        isMapPOI = true
    }
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
    @Environment(\.colorScheme) private var colorScheme

    // One layer graph keeps the camera and annotations intact during day/night transitions.
    private var styleURL: URL { URL(string: "https://tiles.openfreemap.org/styles/liberty")! }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.attributionButton.isHidden = true
        map.logoView.isHidden = true
        map.automaticallyAdjustsContentInset = false
        map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(rawValue: 1)
        map.prefetchesTiles = false
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
        map.delegate = nil
        map.setCamera(map.camera, withDuration: 0, animationTimingFunction: nil)
        map.prefetchesTiles = false
        coordinator.stopPuckDisplayLink()
        coordinator.stopCyclingPathUpdates()
        coordinator.stopMapRoadPOIUpdates()
        coordinator.stopDeferredAnnotationUpdates()
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapLibreView
        weak var map: MLNMapView?
        private var trafficLines: [StyledLine] = []
        private var accuracyHaloLine: StyledLine?
        private var accuracyHaloCenter: Coordinate?
        private var accuracyHaloRadius: Double?
        private var destinationPin: MLNPointAnnotation?
        private var parkedCarPin: MLNPointAnnotation?
        private var shownParkedCarID: UUID?
        private var routeOriginPin: MLNPointAnnotation?
        private var vehiclePin: MLNPointAnnotation?
        private let puckEngine = NavigationPuckEngine()
        private var puckDisplayLink: CADisplayLink?
        private var puckDisplayLinkTarget: PuckDisplayLinkTarget?
        private weak var vehicleAnnotationView: MLNAnnotationView?
        private var destinationMarkerIsArrived: Bool?
        private var transitVehiclePins: [String: MLNPointAnnotation] = [:]
        private let weatherRenderer = WeatherMapRenderer()
        private let routeLayerRenderer = RouteLayerRenderer()
        private let transitStopRenderer = TransitStopLayerRenderer()
        private var transitLine: MLNPolyline?
        private var cyclingPathLines: [MLNPolyline] = []
        private var cyclingPathQueryID: String?
        private var cyclingPathTask: Task<Void, Never>?
        private var cyclingPathStatus: OSMCyclingPathsStatus = .disabled
        private var mapRoadPOIs: [MapRoadPOI] = []
        private var mapRoadPOIRetryAfter: Date?
        private var mapRoadPOIQueryID: String?
        private var mapRoadPOITask: Task<Void, Never>?
        private var mapRoadPOIStatus: MapRoadPOIStatus = .disabled
        private var shownTransitRouteID: String?
        private var shownTransitLineCoordinates: [Coordinate] = []
        private var closurePin: MLNPointAnnotation?
        private var searchPins: [MLNPointAnnotation] = []
        private var searchIDs: [UUID] = []
        private var shownPlaceResults: [SearchResult] = []
        private var trafficEventPins: [MLNPointAnnotation] = []
        private var shownTrafficEventGroupIDs: [String] = []
        private var shownTrafficEventGroups: [[TrafficMapEvent]] = []
        private var shownIncidents: [TrafficIncident] = []
        private var shownRoadAlerts: [RoadSafetyAlert] = []
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
        private let streetLabels = NavigationStreetLabels()
        private weak var vehicleMarker: NavigationMarkerNativeView?
        private var cameraAnimationInFlight = false
        private var cameraUpdatePending = false
        private var cameraAnimationGeneration = 0
        private var trafficAnnotationUpdateWorkItem: DispatchWorkItem?
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
            updatePositionMarker(bearing: frame.bearing)
        }

        private func updatePositionMarker(bearing: Double?) {
            guard let map, let marker = vehicleMarker else { return }
            let presentation = NavigationMarkerPresentation.resolve(
                state: parent.state, settings: parent.settings, bearing: bearing,
                cameraHeading: map.camera.heading, pitch: map.camera.pitch, zoom: map.zoomLevel,
                night: parent.colorScheme == .dark,
                increasedContrast: UIAccessibility.isDarkerSystemColorsEnabled)
            marker.update(presentation)
            if vehicleAnnotationView?.frame.size != marker.frame.size {
                vehicleAnnotationView?.frame.size = marker.frame.size
            }
            vehicleAnnotationView?.centerOffset = .zero
            vehicleAnnotationView?.isAccessibilityElement = true
            vehicleAnnotationView?.accessibilityLabel = presentation.accessibilityLabel
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
            puckDisplayLink?.isPaused = !parent.scene.energyPolicy.mapRenderingEnabled ||
                !isNavigating || parent.state.location == nil
            renderPuckFrame()
        }

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            parent.onLongPress(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        @objc func tappedPOI(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map else { return }
            let point = recognizer.location(in: map)
            guard !routeLayerRenderer.containsETAMarker(at: point, on: map) else { return }
            let tappedCoordinate = map.convert(point, toCoordinateFrom: map)
            let tappedLocation = CLLocation(latitude: tappedCoordinate.latitude, longitude: tappedCoordinate.longitude)
            let appAnnotations = searchPins + trafficEventPins + Array(transitVehiclePins.values)
                + transitStopRenderer.annotations + [destinationPin, vehiclePin, closurePin, parkedCarPin].compactMap { $0 }
            guard !appAnnotations.contains(where: { annotation in
                let location = CLLocation(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude)
                return location.distance(from: tappedLocation) < 25
            }) else { return }
            if let routeID = routeLayerRenderer.routeID(near: point, on: map) {
                parent.onRouteSelect(routeID)
                return
            }
            guard let style = map.style else { return }
            let layerIDs = Set(style.layers.compactMap { layer -> String? in
                guard let symbolLayer = layer as? MLNSymbolStyleLayer,
                      symbolLayer.sourceLayerIdentifier == "poi" else { return nil }
                return symbolLayer.identifier
            })
            guard !layerIDs.isEmpty else { return }
            let touchRect = CGRect(origin: point, size: .zero).insetBy(dx: -22, dy: -22)
            var candidates: [String: (result: SearchResult, distance: CLLocationDistance)] = [:]
            for feature in map.visibleFeatures(in: touchRect, styleLayerIdentifiers: layerIDs).compactMap({ $0 as? MLNPointFeature }) {
                let attributes = feature.attributes
                let category = (attributes["subclass"] as? String) ?? (attributes["class"] as? String)
                guard let category, !category.isEmpty else { continue }
                let markerKind = PlacePOIMapMarkerKind(category: category)
                let name = (attributes["name"] as? String)
                    ?? feature.title
                    ?? (attributes["brand"] as? String)
                    ?? (attributes["operator"] as? String)
                    ?? markerKind?.accessibilityName
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
                var result = SearchResult(destination: Destination(name: name, coordinate: coordinate),
                                          street: nil, houseNumber: nil, city: nil, countryCode: nil,
                                          isPOI: true,
                                          osmID: tileOSMID,
                                          placeProvider: .openFreeMap,
                                          category: category,
                                          brand: attributes["brand"] as? String)
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let distance = location.distance(from: tappedLocation)
                result.selectionDistanceFromTap = distance
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
                cameraAnimationGeneration &+= 1
                cameraAnimationInFlight = false
                cameraUpdatePending = false
                if gesture is UIPanGestureRecognizer { parent.onMapPan() }
                parent.state.cameraState = .freeLook
                parent.state.cameraIntent = nil
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            updatePOIDensity(on: mapView)
            updateCyclingPaths(on: mapView)
            updateMapRoadPOIs(on: mapView)
            applyCameraIntent(to: mapView)
        }

        private func updateStreetLabels(on map: MLNMapView) {
            streetLabels.update(on: map, state: parent.state, padding: parent.viewportPadding,
                                dark: parent.colorScheme == .dark,
                                enabled: parent.scene.energyPolicy.mapRenderingEnabled
                                    && parent.state.transportMode == .car
                                    && (parent.state.status == .navigating || parent.state.status == .rerouting))
        }

        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
            updateStreetLabels(on: mapView)
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            updatePOIZoomDensity(on: mapView)
            updatePositionMarker(bearing: puckEngine.frame()?.bearing)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            navigationStyle.reset()
            streetLabels.reset()
            updatePOIDensity(on: mapView)
            updateMapRoadPOIs(on: mapView)
            trafficRasterTemplate = nil
            trafficRasterVisible = nil
            updateTrafficRasterLayer(on: mapView)
            weatherRenderer.update(map: mapView, configuration: parent.scene.weather, samples: parent.scene.weatherSamples)
            routeLayerRenderer.didLoadStyle(on: mapView,
                                            context: RouteLayerRenderContext(state: parent.state, settings: parent.settings,
                                                                            colorScheme: parent.colorScheme, previousStatus: lastStatus))
        }

        func update(_ map: MLNMapView) {
            let energyPolicy = parent.scene.energyPolicy
            let preferredFramesPerSecond = energyPolicy.mapFramesPerSecond > 0
                ? energyPolicy.mapFramesPerSecond : 1
            map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(
                rawValue: preferredFramesPerSecond)
            map.prefetchesTiles = energyPolicy.enablesMapPrefetch
            map.isUserInteractionEnabled = energyPolicy.mapRenderingEnabled
            let displayLinkRate = Float(max(1, energyPolicy.mapFramesPerSecond))
            puckDisplayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: displayLinkRate, maximum: displayLinkRate, preferred: displayLinkRate)
            puckDisplayLink?.isPaused = !energyPolicy.mapRenderingEnabled
            updateStreetLabels(on: map)
            guard energyPolicy.mapRenderingEnabled else { return }

            let results = parent.scene.placeMarkers
            shownPlaceResults = results
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

            if let car = parent.scene.parkedCar {
                if parkedCarPin == nil || shownParkedCarID != car.id || parkedCarPin?.subtitle != car.mapTimestamp {
                    if let parkedCarPin { map.removeAnnotation(parkedCarPin) }
                    let pin = MLNPointAnnotation()
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

            let requestedStyleURL = parent.styleURL
            if lastStyleURL != requestedStyleURL {
                map.styleURL = requestedStyleURL
                lastStyleURL = requestedStyleURL
                navigationStyle.reset()
            }
            updatePOIDensity(on: map)
            updatePOIMarkerAppearance(on: map)
            updateCyclingPaths(on: map)
            updateMapRoadPOIs(on: map)
            let routeLayerContext = RouteLayerRenderContext(state: parent.state, settings: parent.settings,
                                                           colorScheme: parent.colorScheme, previousStatus: lastStatus)
            weatherRenderer.update(map: map, configuration: parent.scene.weather, samples: parent.scene.weatherSamples)
            routeLayerRenderer.updateRoutes(on: map, context: routeLayerContext)
            updateTrafficLine(on: map)
            routeLayerRenderer.updateTrafficSegments(on: map, context: routeLayerContext)
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
            routeLayerRenderer.updateIncidentLines(on: map, incidents: shownIncidents)
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
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
            shownRoadAlerts = Array(roadAlerts)
            scheduleTrafficAnnotationUpdate(on: map)
            scheduleTransitAnnotationUpdate(on: map)
            updateSelectedTransitLine(on: map)

            updatePuck(on: map)
            updateDestinationMarker(on: map)

            applyCameraIntent(to: map)

            if lastStatus != parent.state.status || lastColorScheme != parent.colorScheme {
                if parent.state.route != nil {
                    routeLayerRenderer.refreshStyle(on: map, context: routeLayerContext)
                }
                map.setNeedsDisplay()
            }
            if lastStatus == .routePreview && parent.state.status == .navigating {
                routeLayerRenderer.animateNavigationStart(on: map, context: routeLayerContext)
            }
            lastStatus = parent.state.status
            lastColorScheme = parent.colorScheme
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
            guard let distance = alert.distanceAlongRoute else { return "" }
            let remaining = max(0, distance - routeDistance)
            let distanceText = remaining >= 1_000
                ? String(format: "%.1f km", remaining / 1_000)
                : "\(Int(remaining.rounded())) m"
            return distanceText
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

        private func updateTransitStopPins(on map: MLNMapView) {
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let isTransitRoutePreview = parent.state.transportMode == .transit
                && (parent.state.status == .destinationPreview || parent.state.status == .routeCalculating
                    || parent.state.status == .routePreview)
            let isPlanningCarRoute = parent.state.transportMode == .car
                && (parent.state.status == .destinationPreview || parent.state.status == .routeCalculating
                    || parent.state.status == .routePreview)
            let context = TransitStopLayerRenderContext(
                selectedStopID: parent.selectedTransitStopID,
                activeStopID: parent.activeTransitStopID,
                alightingStopID: parent.alightingTransitStopID,
                selectedRouteID: parent.selectedTransitRouteID,
                selectedTripStopIDs: parent.selectedTransitTripStopIDs,
                showsOnlyRouteEndpoints: showsOnlyRouteEndpoints,
                displayContext: parent.settings.context,
                transportMode: parent.state.transportMode,
                isPlanningCarRoute: isPlanningCarRoute,
                isNavigating: isNavigating,
                isTransitRoutePreview: isTransitRoutePreview,
                routeStopIDs: transitRouteStopIDs,
                userCoordinate: parent.state.location?.coordinate,
                routeEndpointCoordinates: transitRouteEndpointCoordinates
            )
            transitStopRenderer.update(on: map, stops: parent.transitStops, context: context)
        }

        private func scheduleTransitAnnotationUpdate(on map: MLNMapView) {
            guard transitAnnotationUpdateWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map else { return }
                self.transitAnnotationUpdateWorkItem = nil
                guard self.parent.scene.energyPolicy.mapRenderingEnabled else { return }
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

        private func updatePOIDensity(on map: MLNMapView) {
            guard let style = map.style else { return }
            let activelyNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            navigationStyle.apply(to: style, settings: parent.settings, dark: usesDarkMapAppearance,
                                  activelyNavigating: activelyNavigating, zoom: map.zoomLevel)
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
                where shownPlaceResults.indices.contains(index) {
                guard shownPlaceResults[index].isPOI,
                      let kind = PlacePOIMapMarkerKind(category: shownPlaceResults[index].category),
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
            let followsSheetGesture = parent.isBottomSheetDragging && routePreviewPaddingChanged
            var effectiveIntent = intent
            if intent.followCoordinate != nil, let frame = puckEngine.frame() {
                effectiveIntent.followCoordinate = frame.coordinate
            }
            effectiveIntent = effectiveIntent.fittingViewport(
                parent.viewportPadding, width: Double(map.bounds.width), height: Double(map.bounds.height))
            if followsSheetGesture {
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
            if cameraAnimationInFlight {
                if routePreviewPaddingChanged || cameraCommandChanged {
                    cameraAnimationGeneration &+= 1
                    cameraAnimationInFlight = false
                    cameraUpdatePending = false
                } else {
                    cameraUpdatePending = true
                    return
                }
            }
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
            cameraAnimationGeneration &+= 1
            let generation = cameraAnimationGeneration
            cameraAnimationInFlight = !followsSheetGesture
            let started = MapLibreCameraAnimator.apply(
                effectiveIntent, state: cameraState, to: map,
                completionHandler: { [weak self, weak map] in
                    DispatchQueue.main.async {
                        guard let self, self.cameraAnimationGeneration == generation else { return }
                        self.cameraAnimationInFlight = false
                        guard self.cameraUpdatePending, let map else { return }
                        self.cameraUpdatePending = false
                        self.applyCameraIntent(to: map)
                    }
                })
            guard started else {
                cameraAnimationInFlight = false
                return
            }
            lastViewportPadding = parent.viewportPadding
            lastMapSize = map.bounds.size
            lastIntent = intent
            lastCameraState = cameraState
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
            if let routeID = routeLayerRenderer.routeID(forETAMarker: annotation) {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onRouteSelect(routeID)
                return
            }
            if let pin = parkedCarPin, annotation === pin {
                mapView.deselectAnnotation(annotation, animated: false)
                parent.onParkedCarSelect()
                return
            }
            if let stop = transitStopRenderer.stop(for: annotation) {
                parent.onTransitStopSelect(stop)
                return
            }
            if let vehicle = parent.transitVehicles.first(where: { transitVehiclePins[$0.id] === annotation }) {
                parent.onTransitVehicleSelect(vehicle)
                return
            }
            guard let index = searchPins.firstIndex(where: { $0 === annotation }),
                  shownPlaceResults.indices.contains(index) else { return }
            parent.onPlaceSelect([shownPlaceResults[index]])
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let marker = routeLayerRenderer.annotationView(for: annotation, on: mapView) { return marker }
            if let pin = parkedCarPin, annotation === pin {
                let identifier = "parked-car"
                let marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MLNAnnotationView(reuseIdentifier: identifier)
                marker.subviews.forEach { $0.removeFromSuperview() }
                marker.frame = CGRect(x: 0, y: 0, width: 80, height: 70)
                marker.centerOffset = CGVector(dx: 0, dy: -35)
                marker.scalesWithViewingDistance = false
                marker.backgroundColor = .clear
                marker.layer.sublayers?.filter { $0.name == "parked-car-bubble" }.forEach { $0.removeFromSuperlayer() }
                let bubble = CAShapeLayer()
                bubble.name = "parked-car-bubble"
                let path = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 78, height: 58), cornerRadius: 18)
                path.move(to: CGPoint(x: 31, y: 57))
                path.addLine(to: CGPoint(x: 40, y: 69))
                path.addLine(to: CGPoint(x: 49, y: 57))
                path.close()
                bubble.path = path.cgPath
                bubble.fillColor = PlacePOIMapPalette.accentColor(dark: usesDarkMapAppearance).cgColor
                bubble.strokeColor = UIColor.white.cgColor
                bubble.lineWidth = 2
                bubble.shadowColor = UIColor.black.cgColor
                bubble.shadowOpacity = 0.25
                bubble.shadowRadius = 4
                bubble.shadowOffset = CGSize(width: 0, height: 2)
                marker.layer.insertSublayer(bubble, at: 0)

                let icon = UIImageView(image: UIImage(systemName: "car.side.fill"))
                icon.tintColor = .white
                icon.contentMode = .scaleAspectFit
                icon.frame = CGRect(x: 28, y: 6, width: 24, height: 23)
                marker.addSubview(icon)
                let label = UILabel(frame: CGRect(x: 4, y: 29, width: 72, height: 16))
                label.text = "Auto"
                label.textAlignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 12)
                marker.addSubview(label)
                let time = UILabel(frame: CGRect(x: 4, y: 44, width: 72, height: 13))
                time.text = pin.subtitle.flatMap { $0 }
                time.textAlignment = .center
                time.textColor = UIColor.white.withAlphaComponent(0.9)
                time.font = .systemFont(ofSize: 10, weight: .medium)
                marker.addSubview(time)
                marker.isAccessibilityElement = true
                marker.accessibilityLabel = "Zaparkowany samochód, \(pin.subtitle.flatMap { $0 } ?? "")"
                marker.accessibilityHint = "Otwórz kartę samochodu"
                marker.accessibilityTraits = .button
                return marker
            }
            if let index = trafficEventPins.firstIndex(where: { $0 === annotation }),
               shownTrafficEventGroups.indices.contains(index),
               let event = (shownTrafficEventGroups[index].filter { $0.presentation.roadSign != nil }
                    .max(by: { $0.presentation.clusterPriority < $1.presentation.clusterPriority })
                    ?? shownTrafficEventGroups[index].max(by: {
                   $0.presentation.clusterPriority < $1.presentation.clusterPriority
               })) {
                return trafficMarkerView(for: annotation,
                                         reuseIdentifier: "traffic-event-\(event.id)",
                                         presentation: event.presentation,
                                         clusterCount: shownTrafficEventGroups[index].count > 1
                                            ? shownTrafficEventGroups[index].count : nil)
            }

            if let closurePin, annotation === closurePin {
                return trafficMarkerView(for: annotation,
                                         reuseIdentifier: "traffic-road-closure",
                                         symbolName: "nosign",
                                         color: UIColor(naviHex: NaviAstraColorPalette.closure))
            }

            if let index = searchPins.firstIndex(where: { $0 === annotation }) {
                if shownPlaceResults.indices.contains(index),
                   shownPlaceResults[index].isPOI,
                   let kind = PlacePOIMapMarkerKind(category: shownPlaceResults[index].category) {
                    return placePOIMarkerView(for: annotation, kind: kind, dark: usesDarkMapAppearance)
                }
                let marker = MLNAnnotationView(reuseIdentifier: nil)
                marker.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
                marker.backgroundColor = PlacePOIMapPalette.accentColor(dark: usesDarkMapAppearance)
                marker.layer.cornerRadius = 16
                let label = UILabel(frame: marker.bounds)
                label.text = String(index + 1)
                label.textAlignment = .center
                label.textColor = .white
                label.font = .boldSystemFont(ofSize: 15)
                marker.addSubview(label)
                return marker
            }

            if let marker = transitStopRenderer.annotationView(for: annotation, on: mapView) { return marker }

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
                let marker: NavigationMarkerNativeView
                if let existing = view.subviews.first as? NavigationMarkerNativeView {
                    marker = existing
                } else {
                    view.subviews.forEach { $0.removeFromSuperview() }
                    marker = NavigationMarkerNativeView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
                    view.addSubview(marker)
                }
                vehicleMarker = marker
                vehicleAnnotationView = view
                view.annotation = annotation
                view.scalesWithViewingDistance = false
                view.rotatesToMatchCamera = false
                updatePositionMarker(bearing: puckEngine.frame()?.bearing)
                return view
            }
            if let routeOriginPin, annotation === routeOriginPin {
                let identifier = "route-origin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MLNAnnotationView(reuseIdentifier: identifier)
                if view.subviews.isEmpty {
                    let marker = UIImageView(image: UIImage(systemName: "a.circle.fill"))
                    marker.tintColor = UIColor(naviHex: parent.colorScheme == .dark
                        ? NaviAstraColorPalette.textPrimaryNight : NaviAstraColorPalette.textPrimaryDay)
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
            marker.image = UIImage(systemName: arrived ? "checkmark.circle.fill" : "flag.fill")
            marker.tintColor = UIColor(naviHex: arrived ? NaviAstraColorPalette.success :
                (parent.colorScheme == .dark ? NaviAstraColorPalette.textPrimaryNight : NaviAstraColorPalette.textPrimaryDay))
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
            if let roadSign = presentation.roadSign {
                let marker = RoadSignMapLibreAnnotationView(reuseIdentifier: reuseIdentifier)
                let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
                marker.render(symbol: roadSign,
                              size: roadSign.displaySize(isNavigating: isNavigating),
                              clusterCount: clusterCount,
                              directionUncertain: presentation.isDirectionUncertain)
                marker.isAccessibilityElement = true
                marker.accessibilityLabel = annotation.title ?? "Znak drogowy"
                marker.accessibilityHint = annotation.subtitle.flatMap { $0 }
                return marker
            }
            let marker = MLNAnnotationView(reuseIdentifier: reuseIdentifier)
            let size = CGFloat(clusterCount == nil ? presentation.markerSize : 38)
            marker.frame = CGRect(x: 0, y: 0, width: size, height: size)
            marker.backgroundColor = UIColor(
                red: CGFloat((presentation.colorHex >> 16) & 0xff) / 255,
                green: CGFloat((presentation.colorHex >> 8) & 0xff) / 255,
                blue: CGFloat(presentation.colorHex & 0xff) / 255, alpha: 1)
            marker.layer.cornerRadius = size / 2
            marker.layer.borderWidth = presentation.isCritical ? 2.5 : 1.5
            let danger = UIColor(naviHex: NaviAstraColorPalette.danger)
            marker.layer.borderColor = (presentation.isCritical ? danger : UIColor.white).cgColor
            marker.layer.shadowColor = (presentation.isCritical ? danger : marker.backgroundColor)?.cgColor
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
            } else if let text = presentation.markerText {
                let label = UILabel(frame: marker.bounds)
                label.text = text
                label.textAlignment = .center
                label.textColor = .white
                label.font = .systemFont(ofSize: text.count > 2 ? 10 : 13, weight: .bold)
                label.adjustsFontSizeToFitWidth = true
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
            if let signMarker = view as? RoadSignMapLibreAnnotationView {
                signMarker.setRoadSignSelected(true)
                return
            }
            let scale = 42 / max(1, view.bounds.width)
            UIView.animate(withDuration: 0.16) { view.transform = CGAffineTransform(scaleX: scale, y: scale) }
        }

        func mapView(_ mapView: MLNMapView, didDeselect view: MLNAnnotationView) {
            if let signMarker = view as? RoadSignMapLibreAnnotationView {
                signMarker.setRoadSignSelected(false)
                return
            }
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
            let background = kind.colorHex(dark: dark)
            marker.backgroundColor = UIColor(red: CGFloat((background >> 16) & 0xff) / 255,
                                              green: CGFloat((background >> 8) & 0xff) / 255,
                                              blue: CGFloat(background & 0xff) / 255, alpha: 1)
            marker.layer.cornerRadius = 18
            marker.layer.borderWidth = 1.8
            let color = dark ? UIColor(naviHex: 0x17212B) : UIColor.white
            let rim = UIColor(naviHex: PlacePOIMapPalette.backgroundHex(dark: dark))
            marker.layer.borderColor = rim.cgColor
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

        // MapLibre exposes callout eligibility through its delegate; MLNAnnotationView has no canShowCallout property.
        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            transitVehiclePins.values.contains { $0 === annotation }
                || transitStopRenderer.contains(annotation)
                || trafficEventPins.contains { $0 === annotation }
                || (closurePin.map { $0 === annotation } ?? false)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            updatePositionMarker(bearing: puckEngine.frame()?.bearing)
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            scheduleSearchMapCenterUpdate(center)
            let visibleBounds = mapView.visibleCoordinateBounds
            parent.onTransitViewportChange(TransitMapViewport(
                south: visibleBounds.sw.latitude,
                west: visibleBounds.sw.longitude,
                north: visibleBounds.ne.latitude,
                east: visibleBounds.ne.longitude,
                zoom: Double(mapView.zoomLevel)))

            // Region changes also come from automatic route fitting and sheet resizing.
            // Only userGesture should enter free look and collapse the sheet.
            updatePOIDensity(on: mapView)
            updateIncidentPins(on: mapView)
            scheduleTrafficAnnotationUpdate(on: mapView)
            scheduleTransitAnnotationUpdate(on: mapView)
            updateCyclingPaths(on: mapView)
            updateMapRoadPOIs(on: mapView)
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

        func stopDeferredAnnotationUpdates() {
            trafficAnnotationUpdateWorkItem?.cancel()
            trafficAnnotationUpdateWorkItem = nil
            transitAnnotationUpdateWorkItem?.cancel()
            transitAnnotationUpdateWorkItem = nil
            searchMapCenterWorkItem?.cancel()
            searchMapCenterWorkItem = nil
        }

        private func scheduleTrafficAnnotationUpdate(on map: MLNMapView) {
            // Use the latest state when the work runs. A stream of camera/location
            // updates must neither rebuild markers every frame nor starve the refresh.
            guard trafficAnnotationUpdateWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map else { return }
                self.trafficAnnotationUpdateWorkItem = nil
                guard self.parent.scene.energyPolicy.mapRenderingEnabled else { return }
                self.updateTrafficEventPins(on: map)
            }
            trafficAnnotationUpdateWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        private func updateTrafficEventPins(on map: MLNMapView) {
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
            let events = MainActor.assumeIsolated { () -> [TrafficMapEvent] in
                var events: [TrafficMapEvent] = []
                let routePOIIDs = Set(shownRoadAlerts.map { $0.mapPOIID ?? $0.id })
                let bounds = map.visibleCoordinateBounds
                let latitudeMargin = abs(bounds.ne.latitude - bounds.sw.latitude) * 0.5
                let longitudeSpan = bounds.ne.longitude - bounds.sw.longitude
                let longitudeMargin = abs(longitudeSpan) * 0.5
                for poi in mapRoadPOIs where !routePOIIDs.contains(poi.id) {
                    // Reject distant downloaded POIs before crossing into MapLibre's
                    // projection API. The screen-space pass below applies the exact margin.
                    guard poi.coordinate.latitude >= bounds.sw.latitude - latitudeMargin,
                          poi.coordinate.latitude <= bounds.ne.latitude + latitudeMargin else { continue }
                    if longitudeSpan > 0 && longitudeSpan < 180 {
                        guard poi.coordinate.longitude >= bounds.sw.longitude - longitudeMargin,
                              poi.coordinate.longitude <= bounds.ne.longitude + longitudeMargin else { continue }
                    }
                    events.append(TrafficMapEvent(poi))
                }
                for incident in shownIncidents {
                    events.append(TrafficMapEvent(incident))
                }
                events.append(contentsOf: shownRoadAlerts.map {
                    TrafficMapEvent($0, routeDistance: parent.state.roadAlertRouteDistance)
                })
                return events
            }
            let groups = clusteredTrafficEvents(events, on: map, isNavigating: isNavigating)
            let groupIDs = groups.map {
                $0.map { "\($0.id):\($0.presentation.colorHex):\($0.presentation.priority)" }
                    .sorted().joined(separator: ",")
            }
            var retainedPins = Dictionary(uniqueKeysWithValues: zip(shownTrafficEventGroupIDs, trafficEventPins))
            var addedPins: [MLNPointAnnotation] = []
            let pins = groupIDs.map { id in
                if let pin = retainedPins.removeValue(forKey: id) { return pin }
                let pin = MLNPointAnnotation()
                addedPins.append(pin)
                return pin
            }
            if !retainedPins.isEmpty { map.removeAnnotations(Array(retainedPins.values)) }
            // Publish the lookup before adding annotations: MapLibre can request views immediately.
            trafficEventPins = pins
            shownTrafficEventGroupIDs = groupIDs
            shownTrafficEventGroups = groups
            for (group, pin) in zip(groups, pins) {
                let coordinate = trafficEventCenter(group)
                if pin.coordinate.latitude != coordinate.latitude || pin.coordinate.longitude != coordinate.longitude {
                    pin.coordinate = coordinate.cl
                }
                let title: String
                let subtitle: String
                if group.count == 1, let event = group.first {
                    title = event.title
                    subtitle = event.subtitle
                } else {
                    title = group.allSatisfy(\.isMapPOI)
                        ? "Punkty drogowe (\(group.count))"
                        : "\(group.count) zdarzenia drogowe"
                    subtitle = trafficEventClusterSubtitle(group)
                }
                if pin.title != title { pin.title = title }
                if pin.subtitle != subtitle { pin.subtitle = subtitle }
            }
            if !addedPins.isEmpty { map.addAnnotations(addedPins) }
        }

        private func clusteredTrafficEvents(
            _ events: [TrafficMapEvent],
            on map: MLNMapView,
            isNavigating: Bool
        ) -> [[TrafficMapEvent]] {
            let overviewClustering = map.zoomLevel < 13.2 && !isNavigating
            let groupingDistance: CGFloat = overviewClustering ? 44 : 22
            let visibleArea = map.bounds.insetBy(dx: -64, dy: -64)
            // Keep downloaded data, but group/display only points near the viewport.
            let visible = events.compactMap { event -> (event: TrafficMapEvent, point: CGPoint)? in
                let point = map.convert(event.coordinate.cl, toPointTo: map)
                guard point.x.isFinite, point.y.isFinite, visibleArea.contains(point) else { return nil }
                return (event, point)
            }
            struct Cell: Hashable {
                let x: Int
                let y: Int
            }
            func cell(for point: CGPoint) -> Cell {
                Cell(x: Int(floor(point.x / groupingDistance)), y: Int(floor(point.y / groupingDistance)))
            }
            var buckets: [Cell: Set<Int>] = [:]
            for index in visible.indices {
                buckets[cell(for: visible[index].point), default: []].insert(index)
            }
            var remaining = Set(visible.indices)
            var groups: [[TrafficMapEvent]] = []
            // Preserve deterministic order without repeatedly scanning remaining.min().
            for first in visible.indices where remaining.contains(first) {
                remaining.remove(first)
                buckets[cell(for: visible[first].point)]?.remove(first)
                var component = [first]
                var frontier = [first]
                while let current = frontier.popLast() {
                    let origin = cell(for: visible[current].point)
                    for dx in -1...1 {
                        for dy in -1...1 {
                            let neighbor = Cell(x: origin.x + dx, y: origin.y + dy)
                            let candidates = (buckets[neighbor] ?? []).sorted()
                            for candidate in candidates {
                                let a = visible[current]
                                let b = visible[candidate]
                                let areNearbySigns = a.event.presentation.roadSign != nil && b.event.presentation.roadSign != nil
                                let areNearbyPOIs = a.event.isMapPOI && b.event.isMapPOI
                                guard overviewClustering || areNearbySigns || areNearbyPOIs,
                                      hypot(a.point.x - b.point.x, a.point.y - b.point.y) < groupingDistance else { continue }
                                buckets[neighbor]?.remove(candidate)
                                remaining.remove(candidate)
                                frontier.append(candidate)
                                component.append(candidate)
                            }
                        }
                    }
                }
                groups.append(component.sorted().map { visible[$0].event })
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
        private func routeLinePresentation(for polyline: MLNPolyline,
                                           context: RouteLayerRenderContext) -> LineStyle? {
            if let style = routeLayerRenderer.presentation(for: polyline, context: context) { return style }
            if let line = accuracyHaloLine, line.polyline === polyline {
                return routeLayerRenderer.presentation(for: line, context: context)
            }
            if let line = trafficLines.first(where: { $0.polyline === polyline }) {
                return routeLayerRenderer.presentation(for: line, context: context)
            }
            return nil
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if let line = annotation as? MLNPolyline, cyclingPathLines.contains(where: { $0 === line }) {
                return UIColor(naviHex: parent.colorScheme == .dark
                    ? NaviAstraColorPalette.cyclingRouteNight
                    : NaviAstraColorPalette.cyclingRouteDay).withAlphaComponent(0.92)
            }
            if let transitLine, transitLine === annotation {
                return self.color(hex: parent.transitLineColor ?? NaviAstraColorPalette.transitFallback,
                                  opacity: 0.9)
            }
            guard let line = annotation as? MLNPolyline else {
                return UIColor(naviHex: RouteColorPalette.activeLight)
            }
            let context = RouteLayerRenderContext(state: parent.state, settings: parent.settings,
                                                  colorScheme: parent.colorScheme, previousStatus: lastStatus)
            guard let style = routeLinePresentation(for: line, context: context) else {
                return UIColor(naviHex: RouteColorPalette.activeLight)
            }
            return color(hex: style.hex, opacity: style.opacity)
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            if cyclingPathLines.contains(where: { $0 === annotation }) { return 4 }
            if let transitLine, transitLine === annotation { return 5 }
            let context = RouteLayerRenderContext(state: parent.state, settings: parent.settings,
                                                  colorScheme: parent.colorScheme, previousStatus: lastStatus)
            return routeLinePresentation(for: annotation, context: context)?.width ?? 2
        }

        func stopCyclingPathUpdates() {
            cyclingPathTask?.cancel()
            cyclingPathTask = nil
        }

        private func updateCyclingPaths(on map: MLNMapView) {
            guard parent.settings.overlays.cycling else {
                stopCyclingPathUpdates()
                cyclingPathQueryID = nil
                if !cyclingPathLines.isEmpty {
                    map.removeAnnotations(cyclingPathLines)
                    cyclingPathLines = []
                }
                setCyclingPathStatus(.disabled)
                return
            }

            let visibleBounds = map.visibleCoordinateBounds
            let center = Coordinate(latitude: map.centerCoordinate.latitude,
                                    longitude: map.centerCoordinate.longitude)
            guard let query = OSMCyclingQuery.visible(
                center: center,
                latitudeDelta: visibleBounds.ne.latitude - visibleBounds.sw.latitude,
                longitudeDelta: visibleBounds.ne.longitude - visibleBounds.sw.longitude
            ) else {
                stopCyclingPathUpdates()
                cyclingPathQueryID = "zoomed-out"
                if !cyclingPathLines.isEmpty {
                    map.removeAnnotations(cyclingPathLines)
                    cyclingPathLines = []
                }
                setCyclingPathStatus(.zoomIn)
                return
            }
            guard cyclingPathQueryID != query.id else { return }

            cyclingPathQueryID = query.id
            cyclingPathTask?.cancel()
            map.removeAnnotations(cyclingPathLines)
            cyclingPathLines = []
            setCyclingPathStatus(.loading)
            cyclingPathTask = Task { [weak self, weak map] in
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    let result = try await OSMCyclingPathProvider.shared.paths(in: query)
                    guard !Task.isCancelled, let self, let map,
                          self.cyclingPathQueryID == query.id,
                          self.parent.settings.overlays.cycling else { return }
                    map.removeAnnotations(self.cyclingPathLines)
                    self.cyclingPathLines = result.paths.map { path in
                        var points = path.coordinates.map(\.cl)
                        let line = MLNPolyline(coordinates: &points, count: UInt(points.count))
                        line.title = "Ścieżka rowerowa"
                        return line
                    }
                    map.addAnnotations(self.cyclingPathLines)
                    self.setCyclingPathStatus(.loaded(count: result.paths.count,
                                                      truncated: result.truncated))
                } catch {
                    guard !Task.isCancelled, let self, let map,
                          self.cyclingPathQueryID == query.id else { return }
                    map.removeAnnotations(self.cyclingPathLines)
                    self.cyclingPathLines = []
                    self.setCyclingPathStatus(.unavailable)
                }
            }
        }

        private func setCyclingPathStatus(_ status: OSMCyclingPathsStatus) {
            guard cyclingPathStatus != status else { return }
            cyclingPathStatus = status
            parent.onCyclingPathsStatus(status)
        }

        func stopMapRoadPOIUpdates() {
            mapRoadPOITask?.cancel()
            mapRoadPOITask = nil
        }

        private func updateMapRoadPOIs(on map: MLNMapView) {
            let visibleBounds = map.visibleCoordinateBounds
            let center = Coordinate(latitude: map.centerCoordinate.latitude,
                                    longitude: map.centerCoordinate.longitude)
            guard let query = MapRoadPOIQuery.visible(
                center: center,
                latitudeDelta: visibleBounds.ne.latitude - visibleBounds.sw.latitude,
                longitudeDelta: visibleBounds.ne.longitude - visibleBounds.sw.longitude,
                categories: parent.settings.roadPOICategories
            ) else {
                stopMapRoadPOIUpdates()
                setMapRoadPOIStatus(parent.settings.roadPOICategories.isEmpty ? .disabled : .zoomIn)
                guard mapRoadPOIQueryID != nil || !mapRoadPOIs.isEmpty else { return }
                mapRoadPOIQueryID = nil
                mapRoadPOIs = []
                scheduleTrafficAnnotationUpdate(on: map)
                return
            }
            guard mapRoadPOIQueryID != query.id ||
                    (mapRoadPOIStatus.needsRetry && (mapRoadPOIRetryAfter ?? .distantFuture) <= .now)
            else { return }

            let queryChanged = mapRoadPOIQueryID != query.id
            mapRoadPOIQueryID = query.id
            stopMapRoadPOIUpdates()
            if queryChanged {
                // Keep visible, eligible points while the replacement request is loading.
                mapRoadPOIs = mapRoadPOIs.filter { query.contains($0) }
            }
            setMapRoadPOIStatus(.loading)
            scheduleTrafficAnnotationUpdate(on: map)
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
                    self.scheduleTrafficAnnotationUpdate(on: map)
                    if !result.unavailableSources.isEmpty {
                        self.mapRoadPOIRetryAfter = Date().addingTimeInterval(60)
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                        catch { return }
                        guard !Task.isCancelled, self.mapRoadPOIQueryID == query.id else { return }
                        self.mapRoadPOITask = nil
                        self.updateMapRoadPOIs(on: map)
                    }
                } catch {
                    guard !Task.isCancelled, let self, let map,
                          self.mapRoadPOIQueryID == query.id else { return }
                    // A failed refresh must not remove previously downloaded points.
                    self.mapRoadPOIRetryAfter = Date().addingTimeInterval(30)
                    self.setMapRoadPOIStatus(.unavailable)
                    self.scheduleTrafficAnnotationUpdate(on: map)
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
        private func updateTrafficLine(on map: MLNMapView) {
            guard parent.settings.overlays.traffic, let flow = parent.state.traffic?.flow, flow.coordinates.count > 1 else {
                map.removeAnnotations(trafficLines.map(\.polyline))
                trafficLines = []
                trafficCoordinates = nil
                trafficColorHex = nil
                return
            }
            guard trafficCoordinates != flow.coordinates || trafficColorHex != flow.overlayColorHex else { return }
            map.removeAnnotations(trafficLines.map(\.polyline))
            let isPatterned = flow.roadClosure || flow.overlayColorHex == RouteColorPalette.trafficHeavy
            let paths = isPatterned
                ? RouteMapGeometry.dashedSegments(flow.coordinates, dashLength: 42, gapLength: 28)
                : [flow.coordinates]
            trafficLines = paths.compactMap { coordinates in
                guard coordinates.count > 1 else { return nil }
                var points = coordinates.map(\.cl)
                let polyline = MLNPolyline(coordinates: &points, count: UInt(points.count))
                return StyledLine(polyline: polyline, coordinates: coordinates, kind: .traffic, routeID: nil,
                                  transitionFrom: nil, transitionStartedAt: nil)
            }
            trafficCoordinates = flow.coordinates
            trafficColorHex = flow.overlayColorHex
            map.addAnnotations(trafficLines.map(\.polyline))
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
                pin.subtitle = "Zgłoszone zamknięcie odcinka drogi."
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
  private func color(hex: UInt32, opacity: CGFloat) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: opacity)
        }

    }
}
#endif
