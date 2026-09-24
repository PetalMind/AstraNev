#if os(macOS)
import AppKit
import CoreLocation
import Foundation
import MapKit
import QuartzCore
import SwiftUI

private final class TransitStopMapAnnotationView: MKAnnotationView {
    private var shownPresentation: TransitStopMapPresentation?

    func render(_ presentation: TransitStopMapPresentation) {
        guard shownPresentation != presentation else { return }
        shownPresentation = presentation
        subviews.forEach { $0.removeFromSuperview() }
        let iconWidth = presentation.modes.count > 1
            ? CGFloat(presentation.modes.count) * 15 + 12 : CGFloat(presentation.markerSize)
        let iconHeight = CGFloat(presentation.markerSize)
        let titleHeight: CGFloat = presentation.name == nil ? 0 : 16
        let badgeHeight: CGFloat = presentation.showsAlightingBadge ? 17 : 0
        let titleWidth = presentation.name.map { CGFloat(min(170, max(60, $0.count * 7))) } ?? 0
        let contentWidth = max(iconWidth, titleWidth)
        frame = NSRect(x: 0, y: 0, width: contentWidth,
                       height: iconHeight + titleHeight + badgeHeight
                         + (titleHeight > 0 || badgeHeight > 0 ? 3 : 0))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 2
        if presentation.isActive && !presentation.isAlighting {
            let pulse = CABasicAnimation(keyPath: "shadowRadius")
            pulse.fromValue = 1.5
            pulse.toValue = 4
            pulse.duration = 1.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer?.add(pulse, forKey: "transit-active-stop-pulse")
        }

        let capsule = NSView(frame: NSRect(x: (contentWidth - iconWidth) / 2,
                                           y: frame.height - iconHeight,
                                           width: iconWidth, height: iconHeight))
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        capsule.layer?.cornerRadius = presentation.isMultimodal || presentation.modes.contains(.rail)
            ? iconHeight / 2 : 8
        capsule.layer?.borderWidth = presentation.isActive || presentation.isAlighting ? 3
            : presentation.isSelected ? 2.5 : 1.5
        let accent: NSColor = presentation.isAlighting ? .systemPurple
            : presentation.isActive ? .systemOrange
            : presentation.isSelected ? .systemBlue
            : transitMarkerColor(for: presentation.modes.first)
        capsule.layer?.borderColor = accent.cgColor
        addSubview(capsule)

        let imageSize: CGFloat = presentation.modes.count > 1 ? 13 : min(19, iconHeight * 0.58)
        let spacing: CGFloat = 1
        let symbolsWidth = CGFloat(presentation.modes.count) * imageSize
            + CGFloat(max(0, presentation.modes.count - 1)) * spacing
        var x = (iconWidth - symbolsWidth) / 2
        for mode in presentation.modes {
            let image = NSImageView(frame: NSRect(x: x, y: (iconHeight - imageSize) / 2,
                                                  width: imageSize, height: imageSize))
            image.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: imageSize, weight: .semibold))
            image.contentTintColor = transitMarkerColor(for: mode)
            image.imageScaling = .scaleProportionallyUpOrDown
            capsule.addSubview(image)
            x += imageSize + spacing
        }

        if presentation.showsAlightingBadge {
            let badge = NSTextField(labelWithString: "WYSIĄDŹ")
            badge.frame = NSRect(x: (contentWidth - 64) / 2, y: titleHeight + 1, width: 64, height: 14)
            badge.alignment = .center
            badge.font = .systemFont(ofSize: 8, weight: .bold)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.systemPurple.cgColor
            badge.layer?.cornerRadius = 6
            addSubview(badge)
        }
        if let name = presentation.name {
            let label = NSTextField(labelWithString: name)
            label.frame = NSRect(x: 0, y: 0, width: contentWidth, height: titleHeight)
            label.alignment = .center
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
            label.layer?.cornerRadius = 5
            addSubview(label)
        }
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityRole(.button)
    }

    private func transitMarkerColor(for mode: TransitStopMode?) -> NSColor {
        guard let mode else { return .systemBlue }
        return NSColor(calibratedRed: CGFloat((mode.accentHex >> 16) & 0xff) / 255,
                       green: CGFloat((mode.accentHex >> 8) & 0xff) / 255,
                       blue: CGFloat(mode.accentHex & 0xff) / 255, alpha: 1)
    }
}

private nonisolated enum MacRouteLineKind: Equatable {
    case activeCasing, active, activeHighlight, future, alternative, traveled, traffic, departed, accuracy
    case journeyCasing(walking: Bool, cycling: Bool)
    case journeyLeg(color: UInt32, walking: Bool, cycling: Bool)
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
}

/// The iOS MapLibre binary has no macOS slice. This adapter renders the shared navigation state.
struct MapLibreView: NSViewRepresentable {
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

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: MapLibreView
        weak var map: MKMapView?
        private var routeOverlays: [StyledOverlay] = []
        private var traveledOverlay: StyledOverlay?
        private var trafficOverlay: StyledOverlay?
        private var accuracyHaloOverlay: StyledOverlay?
        private var accuracyHaloCenter: Coordinate?
        private var accuracyHaloRadius: Double?
        private var destinationPin: MKPointAnnotation?
        private var positionPin: MKPointAnnotation?
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
        private var traveledRouteID: UUID?
        private var traveledEnd: Coordinate?
        private var projectionRouteID: UUID?
        private var projectionLocation: Coordinate?
        private var cachedRouteProjection: RouteProjection?
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
            let search = MKLocalSearch(request: MKLocalPointsOfInterestRequest(center: coordinate, radius: max(20, radius)))
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
                                        incidentTemplate: incidentTemplate,
                                        visible: parent.settings.overlays.traffic && !isNavigating)
            if lastPOICategories != parent.settings.visiblePOICategories {
                let categories = parent.settings.visiblePOICategories.flatMap { category -> [MKPointOfInterestCategory] in
                    switch category {
                    case .fuel: [.gasStation]
                    case .parking: [.parking]
                    case .charging: [.evCharger]
                    case .food: [.restaurant, .cafe, .bakery]
                    case .shopping: [.store]
                    case .health: [.hospital, .pharmacy]
                    case .attractions: [.museum, .theater, .park, .nationalPark]
                    case .transit: [.publicTransport, .airport]
                    case .lodging: [.hotel, .campground]
                    }
                }
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

            updateTraveledOverlay(on: map)
            updateTrafficOverlay(on: map)
            if showsOnlyRouteEndpoints {
                removeClosurePin(from: map)
            } else {
                updateClosurePin(on: map)
            }
            updateAccuracyHalo(on: map)

            if let destination = parent.state.destination, parent.state.status != .idle {
                if destinationPin == nil {
                    let pin = MKPointAnnotation(); pin.title = destination.name
                    destinationPin = pin; map.addAnnotation(pin)
                }
                destinationPin?.coordinate = destination.coordinate.cl
            } else if let pin = destinationPin { map.removeAnnotation(pin); destinationPin = nil }

            let routeDistance = parent.state.progress?.traveledDistance ?? 0
            let incidents = parent.settings.overlays.traffic
                ? (parent.state.traffic?.incidents ?? []).filter { incident in
                    guard isNavigating else { return true }
                    guard let distance = incident.distanceAlongRoute else { return false }
                    return distance > routeDistance && distance <= routeDistance + 12_000
                }
                : []
            let incidentIDs = incidents.map(\.id)
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
            let roadAlerts = (!showsOnlyRouteEndpoints ? parent.state.roadSafetyAlerts : [])
                .filter { alert in
                    guard let distance = alert.distanceAlongRoute else { return false }
                    return distance >= routeDistance - 60 && distance <= routeDistance + 20_000
                }
                .sorted { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
                .prefix(40)
            let alertIDs = roadAlerts.map(\.id)
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

            let puckLocation = parent.state.weakGPS ? parent.state.cameraLocation : parent.state.location
            let isFollowingRoute = parent.state.status == .navigating || parent.state.status == .rerouting
            if let location = puckLocation {
                let coordinate: Coordinate
                if isFollowingRoute, let route = parent.state.route {
                    coordinate = projection(for: location.coordinate, on: route)?.coordinate ?? location.coordinate
                } else {
                    coordinate = location.coordinate
                }
                if positionPin == nil {
                    let pin = MKPointAnnotation(); pin.title = "Twoja pozycja"
                    positionPin = pin; map.addAnnotation(pin)
                }
                positionPin?.coordinate = coordinate.cl
            }

            applyCameraIntent(to: map)

            if let positionPin, let view = map.view(for: positionPin) {
                view.centerOffset = isFollowingRoute ? CGPoint(x: 0, y: 16) : .zero
                let relativeBearing = puckLocation.flatMap { location -> CLLocationDirection? in
                    guard isFollowingRoute, location.course.isFinite, location.course >= 0 else { return nil }
                    return location.course - map.camera.heading
                }
                let angle = relativeBearing.map { Int($0.rounded()) }
                if lastPositionMarkerAngle != angle || lastPositionMarkerIsNavigating != isFollowingRoute {
                    view.image = positionMarkerImage(navigating: isFollowingRoute, relativeBearing: relativeBearing)
                    lastPositionMarkerAngle = angle
                    lastPositionMarkerIsNavigating = isFollowingRoute
                }
            }
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

        private func updateTransitStopPins(on map: MKMapView) {
            let zoom = log2(360 / max(0.00001, map.region.span.longitudeDelta))
            let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
            let renderKey = TransitStopRenderKey(center: center, zoom: zoom,
                                                  selectedStopID: parent.selectedTransitStopID,
                                                  activeStopID: parent.activeTransitStopID,
                                                  alightingStopID: parent.alightingTransitStopID,
                                                  selectedRouteID: parent.selectedTransitRouteID,
                                                  selectedTripStopIDs: parent.selectedTransitTripStopIDs,
                                                  transitStopCount: parent.transitStops.count,
                                                  showsOnlyRouteEndpoints: showsOnlyRouteEndpoints)
            guard lastTransitStopRenderKey != renderKey else { return }
            lastTransitStopRenderKey = renderKey

            let visibleRadius = max(500, 12_000 / pow(2, max(0, zoom - 12)))
            let candidates = parent.transitStops.compactMap { stop -> (TransitStop, Double)? in
                let isSelected = stop.id == parent.selectedTransitStopID
                let isActive = stop.id == parent.activeTransitStopID
                let isAlighting = stop.id == parent.alightingTransitStopID
                let isHighlighted = isSelected || isActive || isAlighting
                guard !showsOnlyRouteEndpoints || isHighlighted else { return nil }
                if !parent.selectedTransitTripStopIDs.isEmpty,
                   !parent.selectedTransitTripStopIDs.contains(stop.id), !isHighlighted { return nil }
                if parent.selectedTransitTripStopIDs.isEmpty,
                   let routeID = parent.selectedTransitRouteID,
                   !stop.lineIDs.contains(routeID), !isHighlighted { return nil }
                guard isHighlighted || stop.shouldShowOnMap(zoom: zoom) else { return nil }
                guard !isHighlighted else { return (stop, 0) }
                let distance = center.distance(to: stop.coordinate)
                guard distance <= visibleRadius else { return nil }
                return (stop, distance)
            }
            let groupedCandidates = TransitStop.mapGroups(from: candidates.map(\.0))
            let stops = groupedCandidates.compactMap { group -> (TransitStop, Double)? in
                guard let nearest = group.min(by: { center.distance(to: $0.coordinate) < center.distance(to: $1.coordinate) }) else {
                    return nil
                }
                let highlighted = group.first { $0.id == parent.alightingTransitStopID }
                    ?? group.first { $0.id == parent.activeTransitStopID }
                    ?? group.first { $0.id == parent.selectedTransitStopID }
                let representative = highlighted ?? nearest
                let groupedStop = representative.mapGroup(members: group)
                return (groupedStop, center.distance(to: groupedStop.coordinate))
            }.sorted { $0.1 < $1.1 }.prefix(500).map(\.0)
            let byID = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let removedIDs = transitStopPins.keys.filter { byID[$0] == nil }
            let removedPins = removedIDs.compactMap { transitStopPins.removeValue(forKey: $0) }
            removedIDs.forEach { transitStopMapStops.removeValue(forKey: $0) }
            removedIDs.forEach { transitStopMarkerStates.removeValue(forKey: $0) }
            if !removedPins.isEmpty { map.removeAnnotations(removedPins) }
            for stop in byID.values {
                transitStopMapStops[stop.id] = stop
                let memberIDs = Set(stop.detailStopIDs)
                let presentation = stop.mapPresentation(zoom: zoom,
                                                        selected: parent.selectedTransitStopID.map(memberIDs.contains) ?? false,
                                                        active: parent.activeTransitStopID.map(memberIDs.contains) ?? false,
                                                        alighting: parent.alightingTransitStopID.map(memberIDs.contains) ?? false)
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
            CameraAnimator.apply(effectiveIntent, state: cameraState, to: map)
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

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
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

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let index = incidentPins.firstIndex(where: { $0 === annotation }),
               shownIncidents.indices.contains(index) {
                let incident = shownIncidents[index]
                let marker = MKMarkerAnnotationView(annotation: annotation,
                                                    reuseIdentifier: "traffic-incident-\(incident.category.rawValue)")
                marker.glyphImage = NSImage(systemSymbolName: incident.isRoadClosure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                                            accessibilityDescription: incident.mapTitle)
                marker.markerTintColor = incident.isRoadClosure ? .systemRed : .systemOrange
                marker.canShowCallout = true
                marker.displayPriority = .defaultHigh
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
                let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
                marker.glyphText = String(index + 1)
                marker.markerTintColor = .systemBlue
                return marker
            }

            if let (stopID, _) = transitStopPins.first(where: { $0.value === annotation }),
               let stop = transitStopMapStops[stopID] {
                let marker = TransitStopMapAnnotationView(annotation: annotation,
                                                          reuseIdentifier: "transit-stop-\(stopID)")
                let memberIDs = Set(stop.detailStopIDs)
                marker.render(stop.mapPresentation(zoom: log2(360 / max(0.00001, mapView.region.span.longitudeDelta)),
                                                   selected: parent.selectedTransitStopID.map(memberIDs.contains) ?? false,
                                                   active: parent.activeTransitStopID.map(memberIDs.contains) ?? false,
                                                   alighting: parent.alightingTransitStopID.map(memberIDs.contains) ?? false))
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
                let marker = MKMarkerAnnotationView(annotation: annotation,
                                                    reuseIdentifier: "road-alert-\(alert.type.rawValue)")
                marker.glyphImage = NSImage(systemSymbolName: alert.type.symbolName,
                                            accessibilityDescription: alert.type.title)
                marker.markerTintColor = .systemOrange
                marker.canShowCallout = true
                marker.displayPriority = .defaultHigh
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
            guard let pin = destinationPin, annotation === pin else { return nil }
            let identifier = "destination"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.image = destinationMarkerImage(arrived: parent.state.status == .arrived)
            lastDestinationMarkerIsArrived = parent.state.status == .arrived
            view.displayPriority = .required
            return view
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
            let symbol = NSImage(systemSymbolName: arrived ? "checkmark.circle.fill" : "mappin.circle.fill",
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
            for leg in legs where leg.coordinates.count > 1 {
                let mode = leg.mode.lowercased()
                let walking = isWalkingLeg(mode)
                let cycling = mode.contains("bicycle") || mode.contains("bike")
                let color = walking ? RouteColorPalette.walking : cycling ? RouteColorPalette.cycling : RouteColorPalette.activeLight
                let paths = walking ? RouteMapGeometry.dashedSegments(leg.coordinates) : [leg.coordinates]
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

        private func updateTraveledOverlay(on map: MKMapView) {
            guard let route = parent.state.route,
                  parent.state.status == .navigating || parent.state.status == .rerouting,
                  let location = parent.state.location,
                  let projection = projection(for: location.coordinate, on: route),
                  projection.distanceFromRoute <= max(100, location.accuracy * 2),
                  projection.alongRoute > 15 else {
                removeTraveledOverlay(from: map)
                return
            }

            if traveledRouteID == route.id, let traveledEnd, traveledEnd.distance(to: projection.coordinate) < 15 { return }
            removeTraveledOverlay(from: map)
            let coordinates = Array(route.coordinates.prefix(projection.segment + 1)) + [projection.coordinate]
            guard coordinates.count > 1 else { return }
            var points = coordinates.map(\.cl)
            let polyline = MKPolyline(coordinates: &points, count: points.count)
            let styled = StyledOverlay(polyline: polyline, coordinates: coordinates, kind: .traveled, routeID: route.id,
                                       transitionFrom: nil, transitionStartedAt: nil)
            traveledOverlay = styled
            traveledRouteID = route.id
            traveledEnd = projection.coordinate
            map.addOverlay(polyline)
            if let trafficOverlay {
                map.removeOverlay(trafficOverlay.polyline)
                map.addOverlay(trafficOverlay.polyline)
            }
        }

        private func removeTraveledOverlay(from map: MKMapView) {
            if let traveledOverlay { map.removeOverlay(traveledOverlay.polyline) }
            traveledOverlay = nil
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
            routeOverlays + [traveledOverlay, trafficOverlay, accuracyHaloOverlay].compactMap { $0 }
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
private enum CameraAnimator {
    static func apply(_ intent: CameraIntent, state: NavigationCameraState, to map: MKMapView) {
        if !intent.bounds.isEmpty, state == .destinationPreview || state == .routeOverview || state == .arrived {
            let camera = map.camera
            camera.pitch = CGFloat(intent.pitch)
            camera.heading = intent.bearing
            map.setCamera(camera, animated: false)
            let rect = intent.bounds.map { MKMapPoint($0.cl) }.reduce(MKMapRect.null) {
                $0.union(MKMapRect(x: $1.x, y: $1.y, width: 1, height: 1))
            }
            map.setVisibleMapRect(rect,
                edgePadding: NSEdgeInsets(top: CGFloat(intent.padding.top), left: CGFloat(intent.padding.left),
                                          bottom: CGFloat(intent.padding.bottom), right: CGFloat(intent.padding.right)), animated: true)
            return
        }
        let camera = map.camera
        camera.centerCoordinate = intent.target.cl
        camera.pitch = CGFloat(intent.pitch)
        camera.heading = intent.bearing
        camera.centerCoordinateDistance = max(150, 40_000_000 / pow(2, intent.zoom))
        if state == .browse {
            // MapKit has no padded setCamera overload. Fit a north-up local rectangle
            // into the unobscured viewport instead of the whole window.
            let point = MKMapPoint(intent.target.cl)
            let metersPerPoint = MKMetersPerMapPointAtLatitude(intent.target.latitude)
            let width = camera.centerCoordinateDistance / max(0.001, metersPerPoint)
            let availableWidth = max(100, Double(map.bounds.width) - intent.padding.left - intent.padding.right)
            let availableHeight = max(100, Double(map.bounds.height) - intent.padding.top - intent.padding.bottom)
            let height = width * availableHeight / availableWidth
            map.setVisibleMapRect(MKMapRect(x: point.x - width / 2, y: point.y - height / 2,
                                           width: width, height: height),
                                  edgePadding: NSEdgeInsets(top: intent.padding.top, left: intent.padding.left,
                                                            bottom: intent.padding.bottom, right: intent.padding.right),
                                  animated: true)
        } else {
            map.setCamera(camera, animated: true)
        }
    }
}

#endif
