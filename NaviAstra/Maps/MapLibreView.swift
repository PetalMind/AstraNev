#if os(iOS)
import Foundation
import MapLibre
import SwiftUI
import UIKit

private nonisolated enum RouteLineKind: Equatable {
    case activeCasing, active, activeHighlight, future, alternative, traveled, traffic, departed, accuracy
    case journeyCasing(walking: Bool, cycling: Bool)
    case journeyLeg(color: UInt32, walking: Bool, cycling: Bool)
}

private struct TransitStopRenderKey: Equatable {
    let center: Coordinate
    let zoom: Double
    let selectedStopID: String?
    let selectedRouteID: String?
    let selectedTripStopIDs: Set<String>
    let transitStopCount: Int
    let showsOnlyRouteEndpoints: Bool
}

struct MapLibreView: UIViewRepresentable {
    let state: NavigationState
    let transitVehicles: [TransitVehicle]
    let transitStops: [TransitStop]
    let selectedTransitStopID: String?
    let selectedTransitRouteID: String?
    let selectedTransitTripID: String?
    let selectedTransitTripStopIDs: Set<String>
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
        private var lastTransitStopRenderKey: TransitStopRenderKey?
        private var transitLine: MLNPolyline?
        private var shownTransitRouteID: String?
        private var shownTransitLineCoordinates: [Coordinate] = []
        private var closurePin: MLNPointAnnotation?
        private var searchPins: [MLNPointAnnotation] = []
        private var searchIDs: [UUID] = []
        private var incidentPins: [MLNPointAnnotation] = []
        private var shownIncidentIDs: [String] = []
        private var shownIncidents: [TrafficIncident] = []
        private var roadAlertPins: [MLNPointAnnotation] = []
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
        private var trafficRasterTemplate: String?
        private var trafficRasterVisible: Bool?
        private var lastStatus: NavigationStatus?
        private var lastColorScheme: ColorScheme?
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
        private var lastSelectedTransitStopID: String?

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
            let appAnnotations = searchPins + incidentPins + Array(transitVehiclePins.values)
                + roadAlertPins + Array(transitStopPins.values) + [destinationPin, vehiclePin, closurePin].compactMap { $0 }
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

            let routeDistance = parent.state.progress?.traveledDistance ?? 0
            let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
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
                    let pin = MLNPointAnnotation()
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
                    let pin = MLNPointAnnotation()
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

        private func updateTransitStopPins(on map: MLNMapView) {
            let zoom = map.zoomLevel
            let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
            let renderKey = TransitStopRenderKey(center: center, zoom: zoom,
                                                  selectedStopID: parent.selectedTransitStopID,
                                                  selectedRouteID: parent.selectedTransitRouteID,
                                                  selectedTripStopIDs: parent.selectedTransitTripStopIDs,
                                                  transitStopCount: parent.transitStops.count,
                                                  showsOnlyRouteEndpoints: showsOnlyRouteEndpoints)
            guard lastTransitStopRenderKey != renderKey else { return }
            lastTransitStopRenderKey = renderKey

            let visibleRadius = max(500, 12_000 / pow(2, max(0, zoom - 12)))
            let candidates = (showsOnlyRouteEndpoints ? [] : parent.transitStops).compactMap { stop -> (TransitStop, Double)? in
                let isSelected = stop.id == parent.selectedTransitStopID
                if !parent.selectedTransitTripStopIDs.isEmpty,
                   !parent.selectedTransitTripStopIDs.contains(stop.id), !isSelected { return nil }
                if parent.selectedTransitTripStopIDs.isEmpty,
                   let routeID = parent.selectedTransitRouteID,
                   !stop.lineIDs.contains(routeID), !isSelected { return nil }
                guard isSelected || zoom >= 12.2 && (zoom >= 14.2 || stop.isMajor) else { return nil }
                guard !isSelected else { return (stop, 0) }
                let distance = center.distance(to: stop.coordinate)
                guard distance <= visibleRadius else { return nil }
                return (stop, distance)
            }
            let stops = candidates.sorted { $0.1 < $1.1 }.prefix(500).map(\.0)
            let byID = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let removedIDs = transitStopPins.keys.filter { byID[$0] == nil }
            let removedPins = removedIDs.compactMap { transitStopPins.removeValue(forKey: $0) }
            if !removedPins.isEmpty { map.removeAnnotations(removedPins) }
            for stop in byID.values {
                if let pin = transitStopPins[stop.id] {
                    if pin.coordinate.latitude != stop.coordinate.latitude || pin.coordinate.longitude != stop.coordinate.longitude {
                        pin.coordinate = stop.coordinate.cl
                    }
                    if pin.title != stop.name { pin.title = stop.name }
                    let subtitle = stop.lines.prefix(5).joined(separator: " · ")
                    if pin.subtitle != subtitle { pin.subtitle = subtitle }
                    if let marker = map.view(for: pin), lastSelectedTransitStopID != parent.selectedTransitStopID {
                        styleTransitStopMarker(marker, selected: stop.id == parent.selectedTransitStopID)
                    }
                } else {
                    let pin = MLNPointAnnotation()
                    pin.coordinate = stop.coordinate.cl
                    pin.title = stop.name
                    pin.subtitle = stop.lines.prefix(5).joined(separator: " · ")
                    transitStopPins[stop.id] = pin
                    map.addAnnotation(pin)
                }
            }
            lastSelectedTransitStopID = parent.selectedTransitStopID
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

        private func styleTransitStopMarker(_ marker: UIView, selected: Bool) {
            marker.frame = CGRect(x: 0, y: 0, width: selected ? 26 : 20, height: selected ? 26 : 20)
            marker.backgroundColor = selected ? .systemBlue : .white
            marker.layer.cornerRadius = marker.frame.width / 2
            marker.layer.borderWidth = 3
            marker.layer.borderColor = UIColor.systemBlue.cgColor
            marker.layer.shadowColor = UIColor.black.cgColor
            marker.layer.shadowOpacity = 0.24
            marker.layer.shadowRadius = 2
        }

        private func updatePOIDensity(on map: MLNMapView) {
            guard let style = map.style else { return }
            let dark = parent.settings.appearance == .night ||
                (parent.settings.appearance == .auto && parent.colorScheme == .dark)
            navigationStyle.apply(to: style, settings: parent.settings, dark: dark, zoom: map.zoomLevel)
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
            if let stop = parent.transitStops.first(where: { transitStopPins[$0.id] === annotation }) {
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
            if let index = incidentPins.firstIndex(where: { $0 === annotation }),
               shownIncidents.indices.contains(index) {
                let incident = shownIncidents[index]
                return trafficMarkerView(for: annotation,
                                         reuseIdentifier: "traffic-incident-\(incident.category.rawValue)",
                                         symbolName: incident.isRoadClosure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                                         color: incident.isRoadClosure ? .systemRed : .systemOrange)
            }

            if let closurePin, annotation === closurePin {
                return trafficMarkerView(for: annotation,
                                         reuseIdentifier: "traffic-road-closure",
                                         symbolName: "xmark.octagon.fill",
                                         color: .systemRed)
            }

            if let index = searchPins.firstIndex(where: { $0 === annotation }) {
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
                styleTransitStopMarker(marker, selected: parent.selectedTransitStopID == stopID)
                return marker
            }

            if let alertIndex = roadAlertPins.firstIndex(where: { $0 === annotation }),
               shownRoadAlerts.indices.contains(alertIndex) {
                let alert = shownRoadAlerts[alertIndex]
                let marker = MLNAnnotationView(reuseIdentifier: "road-alert-\(alert.type.rawValue)")
                marker.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
                marker.backgroundColor = .systemOrange
                marker.layer.cornerRadius = 15
                marker.layer.borderWidth = 1.5
                marker.layer.borderColor = UIColor.white.cgColor
                marker.layer.shadowColor = UIColor.black.cgColor
                marker.layer.shadowOpacity = 0.22
                marker.layer.shadowRadius = 3
                let image = UIImageView(image: UIImage(systemName: alert.type.symbolName))
                image.tintColor = .white
                image.contentMode = .scaleAspectFit
                image.frame = CGRect(x: 7, y: 7, width: 16, height: 16)
                marker.addSubview(image)
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

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            transitVehiclePins.values.contains { $0 === annotation }
                || transitStopPins.values.contains { $0 === annotation }
                || roadAlertPins.contains { $0 === annotation }
                || incidentPins.contains { $0 === annotation }
                || (closurePin.map { $0 === annotation } ?? false)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            scheduleSearchMapCenterUpdate(center)

            if programmaticCamera { programmaticCamera = false }
            updatePOIDensity(on: mapView)
            scheduleTransitAnnotationUpdate(on: mapView)
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
            let isVisible = parent.settings.overlays.traffic && !isNavigating
            let incidentTemplate = parent.colorScheme == .dark
                ? parent.state.trafficDarkIncidentTileURLTemplate
                : parent.state.trafficLightIncidentTileURLTemplate
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
        let background = color(dark ? 0x111D29 : 0xF2F4F1)
        let text = color(dark ? 0xD5E3EC : 0x344D5B)
        let muted = color(dark ? 0x8B9FAA : 0x788B93)
        let water = color(dark ? 0x16384A : 0xB9DFEC)
        let majorRoad = color(dark ? 0x799AA8 : 0xFFFFFF)
        let minorRoad = color(dark ? 0x354B59 : 0xFFFFFF)
        let values = categories.flatMap(\.tileValues)
        let categoryPredicate = values.isEmpty ? NSPredicate(value: false) :
            NSPredicate(format: "class IN %@ OR subclass IN %@", values, values)

        for layer in style.layers {
            let id = layer.identifier
            if let layer = layer as? MLNBackgroundStyleLayer {
                layer.backgroundColor = NSExpression(forConstantValue: background)
            }
            // The low-zoom raster would otherwise retain its daytime colors at night.
            if id == "natural_earth" { layer.isVisible = !dark }
            if let layer = layer as? MLNFillStyleLayer {
                let source = layer.sourceLayerIdentifier ?? ""
                let fill: UIColor
                switch source {
                case "water", "waterway": fill = water
                case "park": fill = color(dark ? 0x203F37 : 0xCCE3C9)
                case "landcover":
                    if id.contains("wood") { fill = color(dark ? 0x1D3931 : 0xBAD7BF) }
                    else if id.contains("sand") { fill = color(dark ? 0x3D3B30 : 0xEDE4C7) }
                    else if id.contains("ice") { fill = color(dark ? 0x30434B : 0xE6F0F1) }
                    else { fill = color(dark ? 0x294235 : 0xD9E8CE) }
                case "landuse": fill = color(dark ? 0x23313B : 0xE8ECE5)
                case "building": fill = color(dark ? 0x364B59 : 0xD5DEE0)
                case "aeroway": fill = color(dark ? 0x2B3C48 : 0xDCE4E8)
                default: continue
                }
                layer.fillColor = NSExpression(forConstantValue: fill)
                if source == "building" {
                    layer.fillOpacity = NSExpression(forConstantValue: navigating ? 0.42 : 0.75)
                    layer.fillOutlineColor = NSExpression(forConstantValue: color(dark ? 0x4A606B : 0xC2CFD4))
                }
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer {
                layer.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                layer.fillExtrusionColor = NSExpression(forConstantValue: color(dark ? 0x4A6271 : 0xC2D1D9))
                layer.fillExtrusionOpacity = NSExpression(forConstantValue: navigating ? 0.42 : 0.72)
                layer.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
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
                    let rank = NSPredicate(format: "rank <= %d", density == 0 ? 3 : (density == 1 ? 19 : 1000))
                    let original = originalPredicates[id] ?? NSPredicate(value: true)
                    layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [original, categoryPredicate, rank])
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

    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif
