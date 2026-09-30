import Foundation

@MainActor
final class MapCameraController {
    private let state: NavigationState
    private let routeMatchProvider: @MainActor () -> (routeID: UUID, projection: RouteProjection, timestamp: Date)?
    private let routeGeometryProvider: @MainActor (NavigationRoute) -> RouteProgressGeometry
    private let refreshTransitVehicles: @MainActor (Coordinate) -> Void
    let walkingCameraController = WalkingCameraController()
    private let navigationCameraEngine = NavigationCameraEngine()

    private var routeRevealTask: Task<Void, Never>?
    private var routeProjectionTask: Task<RouteProjection?, Never>?
    private var cameraUpdateTask: Task<Void, Never>?
    private var maneuverTransitionTask: Task<Void, Never>?
    private var cameraManeuverID: Int?
    private var navigationHeadingFilter = NavigationCameraHeadingFilter()
    private var navigationIntentSmoother = NavigationCameraIntentSmoother()
    private var headingRouteID: UUID?
    private var lastNavigationCameraFix: (routeID: UUID, timestamp: Date)?
    private var lastSmoothingTransportMode: TransportMode?
    private var transferOverviewLegID: UUID?
    private var transferOverviewStartedAt: Date?
    private var transferOverviewStartDistance: Double?
    private var transferOverviewConsumedLegID: UUID?
    private var transferOverviewTask: Task<Void, Never>?
    private var parkRideCameraGeometry: RouteProgressGeometry?
    private var parkRideGeometryRouteID: UUID?
    private var parkRideGeometryLegID: UUID?

    init(state: NavigationState,
         routeMatchProvider: @escaping @MainActor () -> (routeID: UUID, projection: RouteProjection, timestamp: Date)?,
         routeGeometryProvider: @escaping @MainActor (NavigationRoute) -> RouteProgressGeometry,
         refreshTransitVehicles: @escaping @MainActor (Coordinate) -> Void) {
        self.state = state
        self.routeMatchProvider = routeMatchProvider
        self.routeGeometryProvider = routeGeometryProvider
        self.refreshTransitVehicles = refreshTransitVehicles
    }

    func updateWalkingCamera(location: NavigationLocation?, deviceHeading: Double?,
                             isNewLocationFix: Bool = true) {
        walkingCameraController.update(location: location, deviceHeading: deviceHeading,
                                       isNewLocationFix: isNewLocationFix)
    }

    func resetWalkingCamera() {
        walkingCameraController.reset()
    }

    func setCurrentManeuver(_ id: Int?) {
        cameraManeuverID = id
    }

    func cancelNavigationCameraTasks() {
        routeProjectionTask?.cancel()
        cameraUpdateTask?.cancel()
    }

    func cancelManeuverTransition() {
        maneuverTransitionTask?.cancel()
        maneuverTransitionTask = nil
    }

    func cancelRouteReveal() {
        routeRevealTask?.cancel()
        routeRevealTask = nil
    }

    func waitForNavigationCameraUpdate() async {
        await cameraUpdateTask?.value
    }

    func setFreeLook() {
        guard state.status == .navigating || state.status == .rerouting else { return }
        navigationCameraEngine.setMode(.freeLook)
        state.cameraState = .freeLook
        state.cameraIntent = nil
    }

    func returnToFollow() {
        synchronizeCameraEngineMode()
        state.cameraCommandID &+= 1
        guard state.status == .navigating || state.status == .rerouting else {
            state.cameraState = .browse
            updateCameraIntent()
            return
        }
        updateNavigationCameraState(force: true)
    }

    func showRouteOverview() {
        guard state.route != nil else { return }
        navigationCameraEngine.setMode(.overview)
        state.cameraCommandID &+= 1
        state.cameraState = .routeOverview
        updateCameraIntent()
    }

    func focusMap(on coordinate: Coordinate, zoom: Double = 15.5) {
        state.cameraCommandID &+= 1
        if state.status != .navigating && state.status != .rerouting {
            state.cameraState = .browse
        }
        state.cameraIntent = CameraIntent(target: coordinate, zoom: zoom, pitch: 0,
                                          bearing: 0, padding: .navigation)
    }

    func updateCameraIntent(using precomputedRouteProjection: RouteProjection? = nil) {
        synchronizeCameraEngineMode()

        let routeID = state.route?.id
        if headingRouteID != routeID {
            navigationHeadingFilter.reset()
            navigationIntentSmoother.reset()
            lastNavigationCameraFix = nil
            headingRouteID = routeID
            parkRideCameraGeometry = nil
            parkRideGeometryRouteID = nil
            parkRideGeometryLegID = nil
            resetTransferOverview()
        }
        if lastSmoothingTransportMode != state.transportMode {
            navigationIntentSmoother.reset()
            lastSmoothingTransportMode = state.transportMode
            resetTransferOverview()
        }

        let location = state.cameraLocation ?? state.location
        let routeProjection = precomputedRouteProjection ?? cameraRouteProjection

        if let carIntent = carNavigationCameraIntent(
            location: location,
            routeProjection: routeProjection,
            cameraState: state.cameraState) {
            state.cameraIntent = carIntent
            return
        }
        if state.transportMode == .car,
           (state.status == .navigating || state.status == .rerouting),
           state.cameraState.usesNavigationPerspective,
           state.route?.journey == nil {
            state.cameraIntent = nil
            return
        }

        if let transitPlan = transitNavigationCameraPlan(location: location),
           state.cameraState.usesNavigationPerspective {
            state.cameraIntent = navigationIntentSmoother.update(
                transitPlan.intent,
                timestamp: Date().timeIntervalSinceReferenceDate,
                profile: transitPlan.followsWalkingRoute ? .walking : .transit,
                initialAnimationDuration: state.cameraState == .startingNavigation ? 0.65 : nil,
                animationDuration: navigationAnimationDuration(for: location, routeID: routeID))
            return
        }

        let routeHeading = CameraPlanner.routeHeading(location: location, route: state.route,
                                                       projection: routeProjection)
        let navigationBearing: Double?
        if state.cameraState.usesNavigationPerspective {
            navigationBearing = navigationHeadingFilter.update(routeHeading: routeHeading,
                                                               location: location)
        } else {
            navigationHeadingFilter.reset()
            lastNavigationCameraFix = nil
            navigationBearing = nil
        }
        let intent = CameraPlanner.intent(
            for: state.cameraState,
            location: location,
            destination: state.destination,
            route: state.route,
            alternatives: state.alternatives,
            progress: state.progress,
            previousBearing: state.cameraIntent?.bearing ?? 0,
            precomputedRouteProjection: routeProjection,
            navigationBearing: navigationBearing,
            navigationAnimationDuration: navigationAnimationDuration(for: location, routeID: routeID),
            transportMode: state.transportMode,
            walkingCamera: walkingCameraSnapshot)
        if let intent, state.transportMode == .walking,
           (state.status == .navigating || state.status == .rerouting),
           state.cameraState.usesNavigationPerspective {
            state.cameraIntent = navigationIntentSmoother.update(
                intent,
                timestamp: Date().timeIntervalSinceReferenceDate,
                profile: .walking,
                initialAnimationDuration: state.cameraState == .startingNavigation ? 0.65 : nil,
                animationDuration: navigationAnimationDuration(for: location, routeID: routeID))
        } else {
            state.cameraIntent = intent
        }
    }

    private func transitNavigationCameraPlan(location: NavigationLocation?) -> TransitCameraPlan? {
        guard state.transportMode == .transit || state.transportMode == .parkRide,
              (state.status == .navigating || state.status == .rerouting),
              state.cameraState.usesNavigationPerspective,
              let route = state.route, let journey = route.journey else {
            resetTransferOverview()
            return nil
        }

        guard let progress = state.transitProgress,
              journey.legs.indices.contains(progress.legIndex) else {
            resetTransferOverview()
            guard let location else { return nil }
            return TransitCameraPlan(
                phase: .locating,
                intent: CameraIntent(target: location.coordinate, zoom: 16, pitch: 15,
                                     bearing: 0, padding: .navigation))
        }

        let leg = journey.legs[progress.legIndex]
        let isTransferWalk = leg.mode.uppercased() == "WALK" &&
            journey.legs[..<progress.legIndex].contains { $0.mode.uppercased() != "WALK" } &&
            journey.legs.dropFirst(progress.legIndex + 1).contains { $0.mode.uppercased() != "WALK" }
        let showTransferOverview: Bool
        if isTransferWalk {
            if transferOverviewLegID != leg.id {
                transferOverviewLegID = leg.id
                transferOverviewStartedAt = .now
                transferOverviewStartDistance = progress.legDistance
                transferOverviewConsumedLegID = nil
                scheduleTransferOverviewEnd(for: leg.id)
            }
            let elapsed = Date().timeIntervalSince(transferOverviewStartedAt ?? .now)
            let distanceTravelled = progress.legDistance - (transferOverviewStartDistance ?? progress.legDistance)
            let hasStartedWalking = distanceTravelled >= 8 ||
                (CameraPlanner.usableSpeed(from: location) >= 1.2 && elapsed >= 0.6)
            showTransferOverview = transferOverviewConsumedLegID != leg.id &&
                elapsed < 2.6 && !hasStartedWalking
            if !showTransferOverview {
                transferOverviewConsumedLegID = leg.id
                transferOverviewTask?.cancel()
                transferOverviewTask = nil
            }
        } else {
            resetTransferOverview()
            showTransferOverview = false
        }

        return TransitCameraPolicy.plan(
            route: route,
            progress: progress,
            location: location,
            vehicles: state.transitVehicles,
            nearbyStops: state.transitStops,
            previousBearing: state.cameraIntent?.bearing ?? 0,
            showTransferOverview: showTransferOverview)
    }

    private func resetTransferOverview() {
        transferOverviewTask?.cancel()
        transferOverviewTask = nil
        transferOverviewLegID = nil
        transferOverviewStartedAt = nil
        transferOverviewStartDistance = nil
        transferOverviewConsumedLegID = nil
    }

    private func scheduleTransferOverviewEnd(for legID: UUID) {
        transferOverviewTask?.cancel()
        transferOverviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2_600))
            guard !Task.isCancelled, let self, self.transferOverviewLegID == legID else { return }
            self.transferOverviewConsumedLegID = legID
            self.updateCameraIntent()
        }
    }

    private func carNavigationCameraIntent(location: NavigationLocation?,
                                           routeProjection: RouteProjection?,
                                           cameraState: NavigationCameraState) -> CameraIntent? {
        let activeJourneyLeg = state.transitProgress.flatMap { progress in
            state.route?.journey?.legs.indices.contains(progress.legIndex) == true
                ? state.route?.journey?.legs[progress.legIndex] : nil
        }
        let isParkRideCarLeg = state.transportMode == .parkRide &&
            state.transitProgress?.legIndex == 0 && activeJourneyLeg?.mode.uppercased() == "CAR"
        guard state.transportMode == .car || isParkRideCarLeg,
              (state.status == .navigating || state.status == .rerouting),
              cameraState.usesNavigationPerspective,
              let route = state.route, route.journey == nil || isParkRideCarLeg,
              let location else {
            if state.transportMode != .car || state.route?.journey != nil {
                navigationCameraEngine.clearRoute()
            }
            return nil
        }

        let geometry: RouteProgressGeometry
        if isParkRideCarLeg, let leg = activeJourneyLeg {
            if parkRideGeometryRouteID != route.id || parkRideGeometryLegID != leg.id {
                var carLegRoute = route
                carLegRoute.coordinates = leg.coordinates
                navigationCameraEngine.clearRoute()
                parkRideCameraGeometry = RouteProgressGeometry(carLegRoute)
                parkRideGeometryRouteID = route.id
                parkRideGeometryLegID = leg.id
            }
            guard let parkRideCameraGeometry else { return nil }
            geometry = parkRideCameraGeometry
        } else {
            geometry = routeGeometryProvider(route)
        }
        navigationCameraEngine.setRouteGeometry(geometry)
        let projection = isParkRideCarLeg
            ? state.transitProgress?.routeProjection ?? routeProjection ?? matchedRouteProjection(for: route)
            : routeProjection ?? matchedRouteProjection(for: route)
        let progressIsForRoute = state.progress?.geometryRouteID == route.id
        let baseDistance = isParkRideCarLeg
            ? state.transitProgress?.legDistance ?? projection?.alongRoute ?? 0
            : projection?.alongRoute ??
                (progressIsForRoute ? state.progress?.traveledDistance : nil) ?? 0
        let speed = CameraPlanner.usableSpeed(from: location)
        let fixTimestamp = state.location?.timestamp ?? location.timestamp
        let age = max(0, Date().timeIntervalSince(fixTimestamp))
        let routeDistance = baseDistance + min(15, age) * speed
        let maneuver = progressIsForRoute ? state.progress?.nextManeuver : nil
        let maneuverDistance = maneuver.map { _ in state.progress?.distanceToNextManeuver ?? 0 }
        let input = NavigationCameraInput(
            matchedCoordinate: geometry.coordinate(at: routeDistance) ?? projection?.coordinate ?? location.coordinate,
            routeDistance: routeDistance,
            speed: speed,
            course: CameraPlanner.usableCourse(from: location, speed: speed),
            distanceToNextManeuver: maneuverDistance,
            maneuverAngle: maneuver.flatMap { geometry.maneuverAngle(atCoordinateIndex: $0.shapeIndex) },
            isRoundabout: maneuver?.kind.isRoundabout == true,
            isMotorwayExit: maneuver?.kind.isExit == true,
            viewportPadding: .navigation,
            timestamp: Date().timeIntervalSinceReferenceDate,
            cameraState: cameraState)
        return navigationCameraEngine.update(input)
    }

    private func synchronizeCameraEngineMode() {
        switch state.cameraState {
        case .freeLook:
            navigationCameraEngine.setMode(.freeLook)
        case .routeOverview:
            navigationCameraEngine.setMode(.overview)
        default:
            navigationCameraEngine.setMode(.following)
        }
    }

    private func matchedRouteProjection(for route: NavigationRoute) -> RouteProjection? {
        guard let location = state.location else { return nil }
        if let match = state.routeMatch,
           match.routeID == route.id,
           match.locationTimestamp == location.timestamp {
            return match.match.projection
        }
        if let previous = routeMatchProvider(),
           previous.routeID == route.id,
           previous.timestamp == location.timestamp {
            return previous.projection
        }
        return nil
    }

    func prepareNavigationCamera(for route: NavigationRoute,
                                 onProjectionReady: @escaping @MainActor (UUID, RouteProjection, Date) -> Void) {
        cancelNavigationCameraTasks()
        navigationCameraEngine.resetForNavigation()
        if headingRouteID != route.id {
            navigationHeadingFilter.reset()
            lastNavigationCameraFix = nil
            headingRouteID = route.id
        }
        if let location = state.cameraLocation ?? state.location {
            lastNavigationCameraFix = (route.id, location.timestamp)
        }
        if let projection = cameraRouteProjection {
            updateCameraIntent(using: projection)
            return
        }

        // Center immediately, then calculate the route projection away from the main actor.
        state.cameraIntent = CameraPlanner.intent(
            for: .startingNavigation,
            location: state.cameraLocation ?? state.location,
            destination: state.destination,
            route: nil,
            alternatives: [],
            progress: state.progress,
            previousBearing: state.cameraIntent?.bearing ?? 0,
            transportMode: state.transportMode,
            walkingCamera: walkingCameraSnapshot)

        // Transit progress carries an indexed projection for the active leg. A
        // second full scan of the combined journey shape is unnecessary here.
        guard route.journey == nil else { return }

        guard let location = state.cameraLocation ?? state.location else { return }
        let routeID = route.id
        let locationTimestamp = location.timestamp
        let coordinate = location.coordinate
        let routeCoordinates = route.coordinates
        let projectionTask = Task.detached(priority: .userInitiated) {
            MapMatcher.project(coordinate, onto: routeCoordinates)
        }
        routeProjectionTask = projectionTask
        cameraUpdateTask = Task { @MainActor [weak self] in
            let projection = await projectionTask.value
            guard !Task.isCancelled, let self,
                  self.state.status == .navigating,
                  self.state.cameraState == .startingNavigation,
                  self.state.route?.id == routeID else { return }
            guard self.state.location?.timestamp == locationTimestamp,
                  !self.state.weakGPS,
                  let projection else { return }
            onProjectionReady(routeID, projection, locationTimestamp)
        }
    }

    func updateNavigationCameraState(force: Bool = false) {
        // Preserve an explicitly requested route overview until the user returns
        // to navigation follow; progress and location updates must not replace it.
        guard force || (state.cameraState != .freeLook && state.cameraState != .routeOverview) else { return }
        let previousState = state.cameraState
        let nextManeuver = state.progress?.nextManeuver
        let passedManeuver = cameraManeuverID != nil && cameraManeuverID != nextManeuver?.id
        cameraManeuverID = nextManeuver?.id

        if state.status == .rerouting { state.cameraState = .rerouting }
        else if state.weakGPS && (previousState == .maneuverNow || previousState == .leavingManeuver) {
            state.cameraState = previousState
        }
        else if state.weakGPS { state.cameraState = .weakGPS }
        else if (state.progress?.remainingDistance ?? .infinity) < 500 &&
                    (state.progress?.distanceToNextManeuver ?? .infinity) > 300 {
            state.cameraState = .approachingDestination
        }
        else if previousState == .leavingManeuver { state.cameraState = .leavingManeuver }
        else if passedManeuver && (previousState == .approachingManeuver || previousState == .maneuverNow) {
            state.cameraState = .leavingManeuver
            scheduleFollowAfterManeuver()
        } else if let nextManeuver {
            let distance = state.progress?.distanceToNextManeuver ?? .infinity
            let maneuverDistanceThreshold = state.transportMode == .walking ? 20.0 : 22.0
            let approachDistanceThreshold = state.transportMode == .walking
                ? 120.0 : (nextManeuver.kind.isExit ? 1_600.0 : 300.0)
            if distance <= maneuverDistanceThreshold {
                state.cameraState = .maneuverNow
            } else if distance <= approachDistanceThreshold {
                state.cameraState = .approachingManeuver
            } else {
                state.cameraState = .followNavigation
            }
        } else {
            state.cameraState = .followNavigation
        }

        if let coordinate = state.cameraLocation?.coordinate ?? state.location?.coordinate {
            refreshTransitVehicles(coordinate)
        }
        let holdsCamera = (previousState == .maneuverNow && state.cameraState == .maneuverNow) ||
            (previousState == .leavingManeuver && state.cameraState == .leavingManeuver)
        if !holdsCamera { updateCameraIntent() }
    }

    func revealRoute() {
        cancelRouteReveal()
        state.routeRevealProgress = 0
        routeRevealTask = Task { @MainActor [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            let duration = 1.35
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self, self.state.status == .routePreview else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / duration)
                self.state.routeRevealProgress = progress
                if progress >= 1 { return }
            }
        }
    }

    private var walkingCameraSnapshot: WalkingCameraSnapshot? {
        guard state.transportMode == .walking,
              state.status == .navigating || state.status == .rerouting else { return nil }
        return walkingCameraController.snapshot()
    }

    private var cameraRouteProjection: RouteProjection? {
        guard !state.weakGPS, let route = state.route, let location = state.location,
              let previousRouteMatch = routeMatchProvider(),
              previousRouteMatch.routeID == route.id,
              previousRouteMatch.timestamp == location.timestamp else { return nil }
        return previousRouteMatch.projection
    }

    private func navigationAnimationDuration(for location: NavigationLocation?,
                                             routeID: UUID?) -> TimeInterval? {
        guard state.cameraState.usesNavigationPerspective,
              let location, let routeID else { return nil }
        let previousFix = lastNavigationCameraFix
        lastNavigationCameraFix = (routeID, location.timestamp)
        guard let previousFix, previousFix.routeID == routeID else { return nil }
        let interval = location.timestamp.timeIntervalSince(previousFix.timestamp)
        guard interval.isFinite, interval > 0.04 else { return nil }
        return min(0.8, max(0.18, interval * 0.68))
    }

    private func scheduleFollowAfterManeuver() {
        cancelManeuverTransition()
        maneuverTransitionTask = Task { @MainActor [weak self] in
            let delay: Duration = self?.state.transportMode == .walking ? .seconds(3) : .milliseconds(650)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.state.cameraState == .leavingManeuver else { return }
            self.state.cameraState = self.state.weakGPS ? .weakGPS : .followNavigation
            self.updateCameraIntent()
        }
    }
}
