import Foundation

extension NavigationEngine {
    func setFreeLook() {
        guard state.status == .navigating || state.status == .rerouting else { return }
        state.cameraState = .freeLook
        state.cameraIntent = nil
    }

    func returnToFollow() {
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
        let routeProjection = precomputedRouteProjection ?? cameraRouteProjection
        state.cameraIntent = CameraPlanner.intent(for: state.cameraState, location: state.cameraLocation ?? state.location,
                                                  destination: state.destination, route: state.route,
                                                  alternatives: state.alternatives, progress: state.progress,
                                                  previousBearing: state.cameraIntent?.bearing ?? 0,
                                                  precomputedRouteProjection: routeProjection,
                                                  transportMode: state.transportMode,
                                                  walkingCamera: walkingCameraSnapshot)
    }

    private var walkingCameraSnapshot: WalkingCameraSnapshot? {
        guard state.transportMode == .walking,
              state.status == .navigating || state.status == .rerouting else { return nil }
        return walkingCameraController.snapshot()
    }

    private var cameraRouteProjection: RouteProjection? {
        guard !state.weakGPS, let route = state.route, let location = state.location,
              let previousRouteMatch,
              previousRouteMatch.routeID == route.id,
              previousRouteMatch.timestamp == location.timestamp else { return nil }
        return previousRouteMatch.projection
    }

    func prepareNavigationCamera(for route: NavigationRoute) {
        navigationCameraProjectionTask?.cancel()
        navigationCameraUpdateTask?.cancel()
        if let projection = cameraRouteProjection {
            updateCameraIntent(using: projection)
            return
        }

        // Set a responsive location-centered camera immediately. When no fresh route
        // match is available, prepare the full route projection off the main actor.
        state.cameraIntent = CameraPlanner.intent(
            for: .startingNavigation, location: state.cameraLocation ?? state.location,
            destination: state.destination, route: nil, alternatives: [], progress: state.progress,
            previousBearing: state.cameraIntent?.bearing ?? 0,
            transportMode: state.transportMode, walkingCamera: walkingCameraSnapshot)

        guard let location = state.cameraLocation ?? state.location else { return }
        let routeID = route.id
        let locationTimestamp = location.timestamp
        let coordinate = location.coordinate
        let routeCoordinates = route.coordinates
        let projectionTask = Task.detached(priority: .userInitiated) {
            MapMatcher.project(coordinate, onto: routeCoordinates)
        }
        navigationCameraProjectionTask = projectionTask
        navigationCameraUpdateTask = Task { @MainActor [weak self] in
            let projection = await projectionTask.value
            guard !Task.isCancelled, let self,
                  self.state.status == .navigating,
                  self.state.cameraState == .startingNavigation,
                  self.state.route?.id == routeID else { return }
            if self.state.location?.timestamp == locationTimestamp {
                if let projection, !self.state.weakGPS {
                    self.previousRouteMatch = (routeID, projection, locationTimestamp)
                }
            }
            // Keep the first camera animation intact. The navigation camera will
            // consume this projection after its startup animation has settled.
        }
    }

    func updateNavigationCameraState(force: Bool = false) {
        guard force || state.cameraState != .freeLook else { return }
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
            refreshTransitVehicles(near: coordinate)
        }

        let holdsCamera = (previousState == .maneuverNow && state.cameraState == .maneuverNow) ||
            (previousState == .leavingManeuver && state.cameraState == .leavingManeuver)
        if !holdsCamera {
            updateCameraIntent()
        }
    }

    private func scheduleFollowAfterManeuver() {
        maneuverTransitionTask?.cancel()
        maneuverTransitionTask = Task { @MainActor [weak self] in
            let delay: Duration = self?.state.transportMode == .walking ? .seconds(3) : .milliseconds(650)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.state.cameraState == .leavingManeuver else { return }
            self.state.cameraState = self.state.weakGPS ? .weakGPS : .followNavigation
            self.updateCameraIntent()
        }
    }

    func revealRoute() {
        revealTask?.cancel()
        state.routeRevealProgress = 0
        revealTask = Task { @MainActor [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            let duration = 1.35
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self, self.state.status == .routePreview else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let progress = min(1, elapsed / duration)
                self.state.routeRevealProgress = progress
                if progress >= 1 { return }
            }
        }
    }
}
