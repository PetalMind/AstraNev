#if os(iOS)
import Foundation
import MapLibre
import QuartzCore
import SwiftUI
import UIKit

nonisolated enum RouteLineKind: Equatable {
    case activeCasing, active, activeHighlight, future, alternative, traveledCasing, traveled, traffic, departed, accuracy
    case routeTraffic(color: UInt32)
    case incidentCasing, incident(color: UInt32)
    case journeyCasing(walking: Bool, cycling: Bool)
    case journeyLeg(color: UInt32, walking: Bool, cycling: Bool)
    case journeyPattern
}

struct IncidentLineRenderItem: Equatable {
    let id: String
    let coordinates: [Coordinate]
    let colorHex: UInt32
    let isRoadClosure: Bool
}

private struct AlternativeRouteRenderItem: Equatable {
    let id: UUID
    let coordinates: [Coordinate]
}

private struct RouteTrafficRenderItem: Equatable {
    let id: String
    let startDistance: Double
    let endDistance: Double
    let coordinates: [Coordinate]
    let colorHex: UInt32
    let dashed: Bool
}

struct StyledLine {
    let polyline: MLNPolyline
    let coordinates: [Coordinate]
    let kind: RouteLineKind
    let routeID: UUID?
    var transitionFrom: LineStyle?
    var transitionStartedAt: Date?
}

struct LineStyle {
    let hex: UInt32
    let opacity: CGFloat
    let width: CGFloat
}

struct RouteLayerRenderContext {
    let state: NavigationState
    let settings: MapSettings
    let colorScheme: ColorScheme
    let previousStatus: NavigationStatus?
}

private struct RouteETAMapItem {
    let data: RouteETAMarkerData
    let annotation: MLNPointAnnotation
}

@MainActor
final class RouteLayerRenderer {
    private var routeLines: [StyledLine] = []
    private var routeETAMapItems: [RouteETAMapItem] = []
    private var shownRouteETAMarkers: [RouteETAMarkerData]?
    private var shownRouteETAMarkerDark: Bool?
    private var incidentLinesByID: [String: [StyledLine]] = [:]
    private var incidentLineRenderItems: [IncidentLineRenderItem] = []
    private var activeRouteSource: MLNShapeSource?
    private var completedRouteSource: MLNShapeSource?
    private var completedRouteTailSource: MLNShapeSource?
    private var routeGeometry: RouteProgressGeometry?
    private var activeLegGeometry: RouteProgressGeometry?
    private var completedShapeRouteID: UUID?
    private var shownCompletedChunkEnd: Double?
    private static let completedChunkSegmentCount = 128
    private var activeRouteStyleKey = ""
    private var alternativeRenderItems: [AlternativeRouteRenderItem] = []
    private var alternativeStyleKey = ""
    private var shownRouteIDs: [UUID]?
    private var shownActiveTargetID: UUID?
    private var shownRevealStep = 1_000
    private var activeGeometryProgressRouteID: UUID?
    private var activeGeometryProgressStep: Int?
    private var routeTrafficRenderItems: [RouteTrafficRenderItem] = []
    private var routeTransitionTimer: Timer?
    private var context: RouteLayerRenderContext!
    private var parent: RouteLayerRenderContext { context }

    func updateRoutes(on map: MLNMapView, context: RouteLayerRenderContext) {
        self.context = context
        let routes = parent.state.alternatives + (parent.state.route.map { [$0] } ?? [])
        let routeIDs = routes.map(\.id)
        let revealStep = Int((parent.state.routeRevealProgress * 1_000).rounded())
        let activeTargetID = parent.state.route.flatMap { activeRouteLegs(for: $0).targetID }
        let routesChanged = shownRouteIDs != routeIDs || shownActiveTargetID != activeTargetID
        let revealChanged = shownRevealStep != revealStep
        let trafficChanged = updateRouteTrafficRenderItems()
        if routesChanged {
            let oldActiveID = shownRouteIDs?.last
            let animateSelection = parent.previousStatus == .routePreview && parent.state.status == .routePreview &&
                oldActiveID != parent.state.route?.id
            let animateReroute = parent.previousStatus == .rerouting && parent.state.status == .navigating &&
                oldActiveID != parent.state.route?.id
            let previousLines = routeLines
            let previousActive = previousLines.first(where: { $0.routeID == oldActiveID && $0.kind == .active })
            map.removeAnnotations(routeLines.map(\.polyline))
            routeLines.removeAll()
            activeGeometryProgressRouteID = nil
            activeGeometryProgressStep = nil
            activeRouteSource?.shape = nil
            completedRouteSource?.shape = nil
            completedRouteTailSource?.shape = nil
            activeLegGeometry = nil
            completedShapeRouteID = nil
            shownCompletedChunkEnd = nil
            if routeGeometry?.routeID != parent.state.route?.id { routeGeometry = nil }
            if animateReroute, let previousActive {
                let dark = parent.colorScheme == .dark
                let fadedBlue = LineStyle(hex: activeRouteColor(dark: dark), opacity: 0.3, width: 11)
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
        if revealChanged || trafficChanged {
            if !routesChanged {
                if let route = parent.state.route { updateActiveRouteShape(route, on: map) }
            }
            shownRevealStep = revealStep
        }

        updateActiveRouteGeometryProgress(on: map)
        updateAlternativeRouteLayers(on: map)
        updatePlanningETAMarkers(on: map)
    }

    private func updatePlanningETAMarkers(on map: MLNMapView) {
        let markers = RouteETAMarkerData.planningMarkers(in: parent.state)
        let isDark = parent.colorScheme == .dark
        guard markers != shownRouteETAMarkers || isDark != shownRouteETAMarkerDark else { return }

        map.removeAnnotations(routeETAMapItems.map(\.annotation))
        routeETAMapItems = markers.map { data in
            let annotation = MLNPointAnnotation()
            annotation.coordinate = data.coordinate.cl
            annotation.title = data.timeText
            annotation.subtitle = data.isSelected ? "Wybrana trasa" : "Alternatywna trasa"
            return RouteETAMapItem(data: data, annotation: annotation)
        }
        shownRouteETAMarkers = markers
        shownRouteETAMarkerDark = isDark
        map.addAnnotations(routeETAMapItems.map(\.annotation))
    }

    func annotationView(for annotation: MLNAnnotation, on _: MLNMapView) -> MLNAnnotationView? {
        guard let item = routeETAMapItems.first(where: { $0.annotation === annotation }) else { return nil }
        let width = max(58, CGFloat(item.data.timeText.count) * 7.5 + 20)
        let marker = MLNAnnotationView(reuseIdentifier: "route-eta")
        marker.frame = CGRect(x: 0, y: 0, width: width, height: 30)
        marker.centerOffset = CGVector(dx: 0, dy: -3)
        let dark = parent.colorScheme == .dark
        let background = item.data.isSelected
            ? activeRouteColor(dark: dark)
            : (dark ? RouteColorPalette.alternativeDark : RouteColorPalette.alternativeLight)
        marker.backgroundColor = color(hex: background, opacity: item.data.isSelected ? 1 : 0.96)
        marker.layer.cornerRadius = 15
        marker.layer.borderWidth = item.data.isSelected ? 1.5 : 1
        marker.layer.borderColor = UIColor.white.withAlphaComponent(item.data.isSelected ? 0.96 : 0.72).cgColor
        marker.layer.shadowColor = UIColor.black.cgColor
        marker.layer.shadowOpacity = 0.24
        marker.layer.shadowRadius = 4
        marker.layer.shadowOffset = CGSize(width: 0, height: 2)

        let label = UILabel(frame: marker.bounds)
        label.text = item.data.timeText
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: item.data.isSelected ? .bold : .semibold)
        marker.addSubview(label)
        marker.isAccessibilityElement = true
        marker.accessibilityLabel =
            "\(item.data.isSelected ? "Wybrana trasa" : "Alternatywna trasa"), \(item.data.timeText)"
        marker.alpha = 0
        marker.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.24, delay: 0,
                           usingSpringWithDamping: 0.78, initialSpringVelocity: 0.35,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                marker.alpha = 1
                marker.transform = .identity
            }
        }
        return marker
    }

    func routeID(forETAMarker annotation: MLNAnnotation) -> UUID? {
        routeETAMapItems.first(where: { $0.annotation === annotation })?.data.routeID
    }

    func containsETAMarker(at point: CGPoint, on map: MLNMapView) -> Bool {
        routeETAMapItems.contains { item in
            let width = max(58, CGFloat(item.data.timeText.count) * 7.5 + 20)
            let coordinatePoint = map.convert(item.annotation.coordinate, toPointTo: map)
            let frame = CGRect(x: coordinatePoint.x - width / 2,
                               y: coordinatePoint.y - 18,
                               width: width,
                               height: 30).insetBy(dx: -4, dy: -4)
            return frame.contains(point)
        }
    }

    private func updateAlternativeRouteLayers(on map: MLNMapView) {
        guard let style = map.style else { return }
        let sourceID = "naviastra-alternative-route-source"
        let source: MLNShapeSource
        if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource { source = existing }
        else {
            source = MLNShapeSource(identifier: sourceID, shape: nil, options: nil)
            style.addSource(source)
        }
        let routes = parent.state.alternatives
        let items = routes.map { AlternativeRouteRenderItem(id: $0.id, coordinates: $0.coordinates) }
        if items != alternativeRenderItems || source.shape == nil {
            let features = routes.filter { $0.coordinates.count > 1 }.map { route in
                var points = route.coordinates.map(\.cl)
                let feature = MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
                feature.attributes = ["routeID": route.id.uuidString]
                return feature
            }
            source.shape = MLNShapeCollectionFeature(shapes: features)
            alternativeRenderItems = items
        }
        let id = "naviastra-alternative-route-line"
        let layer: MLNLineStyleLayer
        if let existing = style.layer(withIdentifier: id) as? MLNLineStyleLayer { layer = existing }
        else {
            layer = MLNLineStyleLayer(identifier: id, source: source)
            alternativeStyleKey = ""
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineDashPattern = NSExpression(forConstantValue: [5, 3])
            layer.lineColorTransition = MLNTransitionMake(0.3, 0)
            layer.lineOpacityTransition = MLNTransitionMake(0.3, 0)
            if let active = style.layer(withIdentifier: "naviastra-active-route-casing") {
                style.insertLayer(layer, below: active)
            } else { style.addLayer(layer) }
        }
        let presentation = lineStyle(for: .alternative)
        let styleKey = "\(presentation.hex):\(presentation.opacity):\(presentation.width)"
        if alternativeStyleKey != styleKey {
            layer.lineColor = NSExpression(forConstantValue: color(hex: presentation.hex, opacity: 1))
            layer.lineOpacity = NSExpression(forConstantValue: presentation.opacity)
            layer.lineWidth = NSExpression(forConstantValue: presentation.width)
            alternativeStyleKey = styleKey
        }
    }

    func routeID(near point: CGPoint, on map: MLNMapView) -> UUID? {
        guard parent.state.status == .routePreview else { return nil }
        var routes = parent.state.routeOptions
        if let selected = parent.state.route, !routes.contains(where: { $0.id == selected.id }) {
            routes.append(selected)
        }

        let touchRect = CGRect(origin: point, size: .zero).insetBy(dx: -22, dy: -22)
        let hits = map.visibleFeatures(in: touchRect,
            styleLayerIdentifiers: ["naviastra-alternative-route-line", "naviastra-active-route-line"])
        let hitIDs = Set(hits.compactMap { ($0.attributes["routeID"] as? String).flatMap(UUID.init(uuidString:)) })
        if !hitIDs.isEmpty {
            routes = routes.filter { hitIDs.contains($0.id) || $0.id == parent.state.route?.id }
        }
        var closestRouteID: UUID?
        var closestDistance = CGFloat.greatestFiniteMagnitude
        let selectedID = parent.state.route?.id
        for route in routes where route.coordinates.count > 1 {
            let screenPoints = route.coordinates.map { map.convert($0.cl, toPointTo: map) }
            for (start, end) in zip(screenPoints, screenPoints.dropFirst()) {
                let distance = distance(from: point, toSegmentFrom: start, to: end)
                let isCloser = distance < closestDistance - 0.5
                let activeRouteIsAsClose = route.id == selectedID &&
                    abs(distance - closestDistance) < 0.5
                if closestRouteID == nil || isCloser || activeRouteIsAsClose {
                    closestDistance = distance
                    closestRouteID = route.id
                }
            }
        }
        return closestDistance <= 22 ? closestRouteID : nil
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + projection * dx), point.y - (start.y + projection * dy))
    }

    func animateNavigationStart(on map: MLNMapView, context: RouteLayerRenderContext) {
        self.context = context
        animateNavigationStart(on: map)
    }

    func refreshStyle(on map: MLNMapView, context: RouteLayerRenderContext) {
        self.context = context
        if let route = parent.state.route { updateActiveRouteShape(route, on: map) }
        updateAlternativeRouteLayers(on: map)
    }

    func didLoadStyle(on map: MLNMapView, context: RouteLayerRenderContext) {
        self.context = context
        activeRouteSource = nil
        completedRouteSource = nil
        completedRouteTailSource = nil
        completedShapeRouteID = nil
        shownCompletedChunkEnd = nil
        activeRouteStyleKey = ""
        alternativeRenderItems = []
        alternativeStyleKey = ""
        activeGeometryProgressRouteID = nil
        activeGeometryProgressStep = nil
        _ = updateRouteTrafficRenderItems()
        if let route = parent.state.route { updateActiveRouteShape(route, on: map) }
        updateAlternativeRouteLayers(on: map)
    }

    func presentation(for polyline: MLNPolyline, context: RouteLayerRenderContext) -> LineStyle? {
        self.context = context
        guard let line = styledLine(for: polyline) else { return nil }
        return presentedStyle(for: line)
    }

    func presentation(for line: StyledLine, context: RouteLayerRenderContext) -> LineStyle {
        self.context = context
        return presentedStyle(for: line)
    }

    func updateIncidentLines(on map: MLNMapView, incidents: [TrafficIncident]) {
        let renderItems = incidents.filter { $0.geometry.count > 1 }.map {
            IncidentLineRenderItem(id: $0.id, coordinates: $0.geometry,
                                   colorHex: TrafficMapPresentation($0).colorHex,
                                   isRoadClosure: $0.category == .roadClosed)
        }.sorted { $0.id < $1.id }
        guard renderItems != incidentLineRenderItems else { return }
        map.removeAnnotations(incidentLinesByID.values.flatMap { $0.map(\.polyline) })
        incidentLinesByID.removeAll()
        incidentLineRenderItems = renderItems
        for item in renderItems {
            let paths = item.isRoadClosure
                ? RouteMapGeometry.dashedSegments(item.coordinates, dashLength: 58, gapLength: 34)
                : [item.coordinates]
            incidentLinesByID[item.id] = paths.flatMap { path in
                [makeIncidentLine(path, kind: .incidentCasing, on: map),
                 makeIncidentLine(path, kind: .incident(color: item.colorHex), on: map)]
            }
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
        let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
        return RouteMapGeometry.activeLeg(in: route.coordinates,
                                          from: isNavigating ? parent.state.location?.coordinate : nil,
                                          through: parent.state.waypoints + parent.state.evChargingStops)
    }

    private func updateActiveRouteShape(_ route: NavigationRoute, on map: MLNMapView) {
        guard let style = map.style else { return }
        if parent.state.transportMode == .transit, route.journey != nil {
            (style.source(withIdentifier: "naviastra-active-route-source") as? MLNShapeSource)?.shape = nil
            (style.source(withIdentifier: "naviastra-completed-route-source") as? MLNShapeSource)?.shape = nil
            (style.source(withIdentifier: "naviastra-completed-route-tail-source") as? MLNShapeSource)?.shape = nil
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
        let completedTailSourceID = "naviastra-completed-route-tail-source"
        let completedTailSource: MLNShapeSource
        if let existing = style.source(withIdentifier: completedTailSourceID) as? MLNShapeSource {
            completedTailSource = existing
        } else {
            completedTailSource = MLNShapeSource(identifier: completedTailSourceID, shape: nil, options: nil)
            style.addSource(completedTailSource)
        }
        completedRouteTailSource = completedTailSource
        if routeGeometry?.routeID != route.id { routeGeometry = RouteProgressGeometry(route) }
        guard let geometry = routeGeometry else { return }
        if activeLegGeometry == nil {
            let legs = activeRouteLegs(for: route)
            activeLegGeometry = legs.targetID == nil ? geometry : RouteProgressGeometry(coordinates: legs.active)
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
            // Previously traveled geometry must not cover the remaining route at crossings or loops.
            style.insertLayer(completedCasing, below: casing)
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
            style.insertLayer(completedLine, below: casing)
        }
        for (id, sourceLayer) in [("naviastra-completed-route-tail-casing", completedCasing),
                                  ("naviastra-completed-route-tail-line", completedLine)] {
            if style.layer(withIdentifier: id) == nil {
                let layer = MLNLineStyleLayer(identifier: id, source: completedTailSource)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.insertLayer(layer, above: sourceLayer)
                activeRouteStyleKey = ""
            }
        }
        updateActiveRouteStyle(on: map)

        let progress = parent.state.status == .routePreview ? parent.state.routeRevealProgress : 1
        let isNavigating = parent.state.status == .navigating || parent.state.status == .rerouting
        guard let activeGeometry = activeLegGeometry else { return }
        if isNavigating {
            let progressDistance = geometry.length * parent.state.routeGeometryProgress
            source.shape = coloredShape(for: activeGeometry, from: progressDistance,
                                        through: activeGeometry.length)
            updateCompletedRoute(geometry, distance: progressDistance, on: style)
        } else {
            source.shape = coloredShape(for: activeGeometry, from: 0,
                                        through: activeGeometry.length * max(0, min(1, progress)))
            completedSource.shape = nil
            completedTailSource.shape = nil
            completedShapeRouteID = nil
            shownCompletedChunkEnd = nil
        }
        activeGeometryProgressRouteID = isNavigating ? route.id : nil
        if isNavigating {
            let stepDistance = route.distance > 0
                ? route.distance * parent.state.routeGeometryProgress
                : geometry.length * parent.state.routeGeometryProgress
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

    private func coloredShape(for geometry: RouteProgressGeometry, from start: Double,
                              through end: Double) -> MLNShape? {
        let segments = RouteTrafficMapGeometry.measuredSegments(in: parent.state)
        let parts = RouteTrafficMapGeometry.coloredLine(geometry, from: start, through: end,
            segments: segments, defaultColor: activeRouteColor(dark: parent.colorScheme == .dark))
        let features = parts.map { part in
            var points = part.coordinates.map(\.cl)
            let feature = MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
            feature.attributes = ["routeColor": String(format: "#%06X", part.colorHex),
                                  "routeID": parent.state.route?.id.uuidString ?? ""]
            return feature
        }
        return features.isEmpty ? nil : MLNShapeCollectionFeature(shapes: features)
    }

    /// Completed chunks remain in the source for the whole route. Only the current
    /// chunk is cropped on GPS updates, so the work does not grow with trip duration.
    private func updateCompletedRoute(_ geometry: RouteProgressGeometry, distance: Double, on style: MLNStyle) {
        guard geometry.coordinates.count > 1, let completedRouteSource, let completedRouteTailSource else { return }
        let chunkSize = Self.completedChunkSegmentCount
        if completedShapeRouteID != geometry.routeID {
            let features = stride(from: 0, to: geometry.coordinates.count - 1, by: chunkSize).map { start in
                let end = min(start + chunkSize, geometry.coordinates.count - 1)
                var coordinates = geometry.coordinates[start...end].map(\.cl)
                let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                feature.attributes = ["endDistance": geometry.cumulativeDistances[end]]
                return feature
            }
            completedRouteSource.shape = MLNShapeCollectionFeature(shapes: features)
            completedShapeRouteID = geometry.routeID
            shownCompletedChunkEnd = nil
        }
        let vertex = max(0, geometry.firstVertex(after: distance) - 1)
        let chunkStart = min(geometry.coordinates.count - 1, vertex / chunkSize * chunkSize)
        let finished = distance >= geometry.length
        let completedEnd = finished ? geometry.length : geometry.cumulativeDistances[chunkStart]
        if shownCompletedChunkEnd != completedEnd {
            let predicate = NSPredicate(format: "endDistance <= %@", NSNumber(value: completedEnd))
            (style.layer(withIdentifier: "naviastra-completed-route-casing") as? MLNLineStyleLayer)?.predicate = predicate
            (style.layer(withIdentifier: "naviastra-completed-route-line") as? MLNLineStyleLayer)?.predicate = predicate
            shownCompletedChunkEnd = completedEnd
        }
        completedRouteTailSource.shape = finished ? nil : shape(for: geometry.corridor(
            from: completedEnd, through: min(geometry.length, distance)))
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
        let key = "\(parent.colorScheme)-\(parent.state.status)-\(parent.state.transportMode)-\(casingStyle.hex)-\(casingStyle.opacity)-\(casingStyle.width)-\(activeStyle.hex)-\(activeStyle.opacity)-\(activeStyle.width)-\(highlightStyle.hex)-\(highlightStyle.opacity)-\(highlightStyle.width)-\(completedCasingStyle.opacity)-\(completedCasingStyle.width)-\(completedStyle.opacity)-\(completedStyle.width)"
        guard key != activeRouteStyleKey else { return }
        activeRouteStyleKey = key
        casing.lineColor = NSExpression(forConstantValue: color(hex: casingStyle.hex, opacity: 1))
        casing.lineOpacity = NSExpression(forConstantValue: casingStyle.opacity)
        casing.lineWidth = NSExpression(forConstantValue: casingStyle.width)
        line.lineColor = NSExpression(mglJSONObject: ["to-color", ["get", "routeColor"]])
        line.lineOpacity = NSExpression(forConstantValue: activeStyle.opacity)
        line.lineWidth = NSExpression(forConstantValue: activeStyle.width)
        let walkingPattern: [NSNumber]? = parent.state.transportMode == .walking
            ? [NSNumber(value: 1.4), NSNumber(value: 1.2)] : nil
        line.lineDashPattern = walkingPattern.map { NSExpression(forConstantValue: $0) }
        highlight.lineColor = NSExpression(forConstantValue: color(hex: highlightStyle.hex, opacity: 1))
        highlight.lineOpacity = NSExpression(forConstantValue: highlightStyle.opacity)
        highlight.lineWidth = NSExpression(forConstantValue: highlightStyle.width)
        let cyclingPattern: [NSNumber]? = parent.state.transportMode == .bicycle
            ? [NSNumber(value: 1.4), NSNumber(value: 2.2)] : nil
        highlight.lineDashPattern = cyclingPattern.map { NSExpression(forConstantValue: $0) }
        completedCasing.lineColor = NSExpression(forConstantValue: color(hex: completedCasingStyle.hex, opacity: 1))
        completedCasing.lineOpacity = NSExpression(forConstantValue: completedCasingStyle.opacity)
        completedCasing.lineWidth = NSExpression(forConstantValue: completedCasingStyle.width)
        completedLine.lineColor = NSExpression(forConstantValue: color(hex: completedStyle.hex, opacity: 1))
        completedLine.lineOpacity = NSExpression(forConstantValue: completedStyle.opacity)
        completedLine.lineWidth = NSExpression(forConstantValue: completedStyle.width)
        completedLine.lineDashPattern = walkingPattern.map { NSExpression(forConstantValue: $0) }
        for (id, presentation) in [("naviastra-completed-route-tail-casing", completedCasingStyle),
                                   ("naviastra-completed-route-tail-line", completedStyle)] {
            guard let layer = style.layer(withIdentifier: id) as? MLNLineStyleLayer else { continue }
            layer.lineColor = NSExpression(forConstantValue: color(hex: presentation.hex, opacity: 1))
            layer.lineOpacity = NSExpression(forConstantValue: presentation.opacity)
            layer.lineWidth = NSExpression(forConstantValue: presentation.width)
            layer.lineDashPattern = id.hasSuffix("-line") ? walkingPattern.map { NSExpression(forConstantValue: $0) } : nil
        }
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
            let color = walking
                ? (parent.colorScheme == .dark ? RouteColorPalette.walkingDark : RouteColorPalette.walkingLight)
                : (cycling
                    ? (parent.colorScheme == .dark ? RouteColorPalette.cyclingDark : RouteColorPalette.cyclingLight)
                    : (leg.lineColorHex ?? NaviAstraColorPalette.transitFallback))
            let paths = walking
                ? RouteMapGeometry.dashedSegments(split.remaining, dashLength: 4, gapLength: 6)
                : [split.remaining]
            for path in paths where path.count > 1 {
                let kind = RouteLineKind.journeyLeg(color: color, walking: walking, cycling: cycling)
                let casingKind = RouteLineKind.journeyCasing(walking: walking, cycling: cycling)
                let casing = lineStyle(for: casingKind)
                let invisibleCasing = LineStyle(hex: casing.hex, opacity: 0, width: casing.width)
                addLine(path, kind: casingKind, routeID: routeID,
                        transitionFrom: transitionStyle == nil ? nil : invisibleCasing, to: map)
                addLine(path, kind: kind, routeID: routeID, transitionFrom: transitionStyle, to: map)
                if cycling {
                    for pattern in RouteMapGeometry.dashedSegments(path, dashLength: 24, gapLength: 44) {
                        addLine(pattern, kind: .journeyPattern, routeID: routeID, to: map)
                    }
                }
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
            // scheduledTimer runs on the main run loop where it was created.
            MainActor.assumeIsolated {
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
    }

    private func animateNavigationStart(on map: MLNMapView) {
        let startedAt = Date()
        for index in routeLines.indices {
            let kind = routeLines[index].kind
            let startingStyle = lineStyle(for: kind, navigating: false)
            routeLines[index].transitionFrom = startingStyle
            routeLines[index].transitionStartedAt = startedAt
        }
        map.setNeedsDisplay()
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
                case .journeyCasing, .journeyLeg, .journeyPattern, .traveledCasing, .traveled: return true
                default: return false
                }
            }
            map.removeAnnotations(previousJourneyLines.map(\.polyline))
            routeLines.removeAll { line in
                guard line.routeID == route.id else { return false }
                switch line.kind {
                case .journeyCasing, .journeyLeg, .journeyPattern, .traveledCasing, .traveled: return true
                default: return false
                }
            }
            _ = addJourneyLegs(journey.legs, routeID: route.id, transitionStyle: nil, to: map)
            return
        }

        let routeDistance = route.distance > 0 ? route.distance : routeGeometry?.length ?? 0
        let step = Int((routeDistance * parent.state.routeGeometryProgress / 2).rounded(.down))
        guard activeGeometryProgressRouteID != route.id || activeGeometryProgressStep != step else { return }
        activeGeometryProgressRouteID = route.id
        activeGeometryProgressStep = step
        updateActiveRouteShape(route, on: map)
    }

    private func updateRouteTrafficRenderItems() -> Bool {
        let items = RouteTrafficMapGeometry.measuredSegments(in: parent.state).map {
            RouteTrafficRenderItem(id: $0.id, startDistance: $0.startDistance, endDistance: $0.endDistance,
                coordinates: $0.coordinates,
                colorHex: $0.colorHex, dashed: $0.isRoadClosure)
        }
        guard items != routeTrafficRenderItems else { return false }
        routeTrafficRenderItems = items
        return true
    }

    private func styledLine(for polyline: MLNPolyline) -> StyledLine? {
        if let line = routeLines.first(where: { $0.polyline === polyline }) { return line }
        if let line = incidentLinesByID.values.joined().first(where: { $0.polyline === polyline }) { return line }
        return nil
    }

    private func lineStyle(for kind: RouteLineKind, navigating navigationOverride: Bool? = nil) -> LineStyle {
        let navigating = navigationOverride ?? (parent.state.status == .navigating || parent.state.status == .rerouting)
        let dark = parent.colorScheme == .dark
        switch kind {
        case .activeCasing:
            return LineStyle(hex: activeRouteCasingColor(dark: dark),
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
            let casing = !dark && (walking || cycling) ? NaviAstraColorPalette.surfaceDay
                : (dark ? RouteColorPalette.casingDark : RouteColorPalette.casingLight)
            return LineStyle(hex: casing,
                             opacity: walking ? 0.76 : 0.82, width: width + (walking ? 3 : 4))
        case .journeyLeg(let color, let walking, let cycling):
            return LineStyle(hex: color, opacity: 1,
                             width: journeyLegWidth(walking: walking, cycling: cycling, navigating: navigating))
        case .journeyPattern:
            return LineStyle(hex: 0xFFFFFF, opacity: parent.colorScheme == .dark ? 0.68 : 0.82, width: 1.5)
        case .alternative:
            return LineStyle(hex: dark ? RouteColorPalette.alternativeDark : RouteColorPalette.alternativeLight,
                             opacity: navigating ? 0 : 0.46, width: 4)
        case .accuracy:
            return LineStyle(hex: dark ? NaviAstraColorPalette.userLocationNight
                                       : NaviAstraColorPalette.userLocationDay,
                             opacity: 0.15, width: 6)
        case .incidentCasing:
            return LineStyle(hex: 0xFFFFFF, opacity: 0.9, width: navigating ? 10 : 8)
        case .incident(let color):
            return LineStyle(hex: color, opacity: 0.96, width: navigating ? 7 : 5)
        case .traveledCasing:
            return LineStyle(hex: dark ? 0x9AA3AC : RouteColorPalette.traveled,
                             opacity: 0.45,
                             width: activeRouteWidth(navigating: navigating) * 0.75 + 1)
        case .traveled:
            return LineStyle(hex: dark ? 0x9AA3AC : RouteColorPalette.traveled,
                             opacity: 0.9,
                             width: max(1, activeRouteWidth(navigating: navigating) * 0.75))
        case .traffic:
            let color = parent.state.traffic?.flow?.overlayColorHex ?? RouteColorPalette.trafficFree
            return LineStyle(hex: color, opacity: 1, width: trafficLineWidth(for: color))
        case .routeTraffic(let color):
            return LineStyle(hex: color, opacity: 0.98, width: trafficLineWidth(for: color))
        case .departed:
            return LineStyle(hex: dark ? RouteColorPalette.alternativeDark : RouteColorPalette.alternativeLight,
                             opacity: 0, width: 6)
        }
    }

    private func activeRouteColor(dark: Bool) -> UInt32 {
        return switch parent.state.transportMode {
        case .car, .transit:
            dark ? RouteColorPalette.activeDark : RouteColorPalette.activeLight
        case .walking:
            dark ? RouteColorPalette.walkingDark : RouteColorPalette.walkingLight
        case .bicycle:
            dark ? RouteColorPalette.cyclingDark : RouteColorPalette.cyclingLight
        }
    }

    private func activeRouteCasingColor(dark: Bool) -> UInt32 {
        if !dark {
            switch parent.state.transportMode {
            case .walking, .bicycle: return NaviAstraColorPalette.surfaceDay
            case .car, .transit: break
            }
        }
        return dark ? RouteColorPalette.casingDark : RouteColorPalette.casingLight
    }

    private func trafficLineWidth(for color: UInt32) -> CGFloat {
        switch color {
        case RouteColorPalette.trafficFree: 3
        case RouteColorPalette.trafficModerate: 4
        case RouteColorPalette.trafficSlow: 5.5
        case RouteColorPalette.trafficHeavy: 6.5
        case RouteColorPalette.closure: 7
        default: 4
        }
    }

    private func activeRouteWidth(navigating: Bool) -> CGFloat {
        switch parent.state.transportMode {
        case .car, .transit: navigating ? 11 : 8
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

}
#endif
