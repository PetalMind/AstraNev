#if os(macOS)
import AppKit
import Foundation
import MapKit
import QuartzCore

nonisolated enum MacRouteLineKind: Hashable {
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

/// Manages route and road incident geometry, overlays, styles, and transitions on MapKit.
final class MacRouteRenderer {
    private var parent: MapLibreView
    private weak var map: MKMapView?
    private var routeOverlays: [StyledOverlay] = []
    private var incidentOverlays: [String: [StyledOverlay]] = [:]
    private var incidentOverlayRenderItems: [MacIncidentLineRenderItem] = []
    private var shownRouteTrafficSegments: [RouteTrafficSegment] = []
    private var traveledOverlay: StyledOverlay?
    private var trafficOverlay: StyledOverlay?
    private var accuracyHaloOverlay: StyledOverlay?
    private var accuracyHaloCenter: Coordinate?
    private var accuracyHaloRadius: Double?
    private var shownRouteIDs: [UUID]?
    private var shownActiveTargetID: UUID?
    private var shownRevealStep = 1_000
    private var activeGeometryProgressRouteID: UUID?
    private var activeGeometryProgressStep: Int?
    private var traveledRouteID: UUID?
    private var traveledProgressStep: Int?
    private var trafficCoordinates: [Coordinate]?
    private var trafficColorHex: UInt32?
    private var routeTransitionTimer: Timer?

    init(parent: MapLibreView) {
        self.parent = parent
    }

    func updateContext(_ parent: MapLibreView) {
        self.parent = parent
    }

    func updateRoutes(on map: MKMapView, previousStatus: NavigationStatus?) {
        self.map = map
        let routes = parent.state.alternatives + (parent.state.route.map { [$0] } ?? [])
        let routeIDs = routes.map(\.id)
        let revealStep = Int((parent.state.routeRevealProgress * 1_000).rounded())
        let activeTargetID = parent.state.route.flatMap { activeRouteLegs(for: $0).targetID }
        let routesChanged = shownRouteIDs != routeIDs || shownActiveTargetID != activeTargetID
        let revealChanged = shownRevealStep != revealStep
        if routesChanged {
            let oldActiveID = shownRouteIDs?.last
            let animateSelection = previousStatus == .routePreview && parent.state.status == .routePreview &&
                oldActiveID != parent.state.route?.id
            let animateReroute = previousStatus == .rerouting && parent.state.status == .navigating &&
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
    }

    func updateTrafficOverlay(on map: MKMapView) {
        self.map = map
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

    func updateRouteTrafficOverlays(on map: MKMapView) {
        self.map = map
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

    func updateAccuracyHalo(on map: MKMapView) {
        self.map = map
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

    func updateIncidentOverlays(on map: MKMapView, incidents: [TrafficIncident]) {
        self.map = map
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

    func configure(_ renderer: MKPolylineRenderer, for polyline: MKPolyline) {
        guard let styled = styledOverlay(for: polyline) else { return }
        apply(presentedStyle(for: styled), to: renderer)
        if styled.kind == .active || styled.kind == .activeCasing || styled.kind == .activeHighlight {
            renderer.strokeEnd = parent.state.status == .routePreview
                ? CGFloat(parent.state.routeRevealProgress) : 1
        }
    }

    func refreshAll(on map: MKMapView) {
        self.map = map
        for overlay in allStyledOverlays {
            updateRenderer(for: overlay, on: map)
        }
    }

    func animateNavigationStart() {
        let startedAt = Date()
        for index in routeOverlays.indices {
            let kind = routeOverlays[index].kind
            let startingStyle = lineStyle(for: kind, navigating: false)
            routeOverlays[index].transitionFrom = startingStyle
            routeOverlays[index].transitionStartedAt = startedAt
        }
        animateRouteSelection()
    }

    private var allStyledOverlays: [StyledOverlay] {
        routeOverlays + incidentOverlays.values.flatMap { $0 }
            + [traveledOverlay, trafficOverlay, accuracyHaloOverlay].compactMap { $0 }
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
        RouteMapGeometry.activeLeg(in: route.coordinates,
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

    private func styledOverlay(for polyline: MKPolyline) -> StyledOverlay? {
        allStyledOverlays.first { $0.polyline === polyline }
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
#endif
