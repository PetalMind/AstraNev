import Foundation

extension NavigationSession {
    func estimatedWalkingRoute(to destination: Destination) async throws -> SearchRouteEstimate? {
        guard let location = state.location,
              Date().timeIntervalSince(location.timestamp) >= 0,
              Date().timeIntervalSince(location.timestamp) <= 15,
              location.accuracy.isFinite, location.accuracy >= 0,
              location.coordinate.isValidParkedCarCoordinate,
              destination.coordinate.isValidParkedCarCoordinate else { return nil }
        let routes: [NavigationRoute]
        if let provider = routeProvider as? AdvancedRouteProvider {
            routes = try await provider.calculateRoutes(
                from: location.coordinate, to: destination.coordinate, through: [], mode: .walking,
                preferences: state.routingPreferences, avoiding: [])
        } else {
            routes = try await routeProvider.calculateRoutes(
                from: location.coordinate, to: destination.coordinate, mode: .walking)
        }
        try Task.checkCancellation()
        guard let route = routes.first,
              route.distance.isFinite, route.distance >= 0,
              route.expectedTravelTime.isFinite, route.expectedTravelTime >= 0 else { return nil }
        return SearchRouteEstimate(travelTime: route.expectedTravelTime, distanceMeters: route.distance)
    }

    func estimatedCarRouteEstimate(to destination: Destination) async -> PlaceRouteEstimate? {
        guard let origin = state.location?.coordinate else { return nil }
        return await estimatedCarRouteEstimate(to: destination, from: origin)
    }

    func estimatedCarRouteEstimate(to destination: Destination,
                                   from origin: Coordinate) async -> PlaceRouteEstimate? {
        let target: Coordinate
        if destination.poi != nil {
            target = await POIAccessResolver.shared.resolve(for: destination, mode: .car)?.coordinate
                ?? destination.coordinate
        } else {
            target = destination.coordinate
        }
        do {
            if let provider = routeProvider as? AdvancedRouteProvider {
                let routes = try await provider.calculateRoutes(
                    from: origin, to: target, through: [], mode: .car,
                    preferences: state.routingPreferences, avoiding: [])
                guard let route = routes.first else { return nil }
                return PlaceRouteEstimate(minutes: max(1, Int(ceil(route.expectedTravelTime / 60))),
                                          distanceMeters: route.distance)
            }
            let routes = try await routeProvider.calculateRoutes(from: origin, to: target, mode: .car)
            guard let route = routes.first else { return nil }
            return PlaceRouteEstimate(minutes: max(1, Int(ceil(route.expectedTravelTime / 60))),
                                      distanceMeters: route.distance)
        } catch {
            return nil
        }
    }

    func selectDestination(_ destination: Destination, applyConfiguredMode: Bool = true) {
        arrivalDetector.reset()
        liveActivity.end()
        state.arrivalLocation = nil
        let isEndingActiveTrip = state.status == .navigating || state.status == .rerouting
        if isEndingActiveTrip {
            finishTrip(arrived: false)
            voice.reset()
            locationManager.stopBackgroundNavigationUpdates()
            locationManager.setHeadingUpdatesEnabled(false)
            mapCameraController.resetWalkingCamera()
            state.deviceHeading = nil
        }
        rerouteController.invalidateRequestsForRouteChange()
        requestGeneration += 1
        navigationTransitionTask?.cancel()
        mapCameraController.cancelNavigationCameraTasks()
        if applyConfiguredMode { applyConfiguredDefaultTransportMode() }
        state.destination = destination
        state.navigationTarget = nil
        state.parkRideCarTarget = nil
        state.waypoints = []
        state.evChargingStops = []
        state.waypointNavigationTargets = [:]
        state.pendingWaypointIDs = []
        state.status = .destinationPreview
        refreshEnergyPolicy()
        state.cameraState = .destinationPreview
        updateCameraIntent()
        state.route = nil
        state.routeOptions = []
        state.transitPlanningPhase = nil
        resetRoadSafetyData()
        state.progress = nil
        state.transitProgress = nil
        state.routeMatch = nil
        previousRouteMatch = nil
        resetOffRouteEvidence()
        routeProgressTracker.invalidateGeometries()
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        state.errorMessage = nil
        invalidateTraffic()
    }

    func setRouteOrigin(_ point: RoutePoint?) async {
        if let point {
            state.routeOrigin = point
        } else if let location = state.location {
            state.routeOrigin = RoutePoint(
                Destination(name: "Twoja lokalizacja", coordinate: location.coordinate),
                source: .currentLocation)
        } else {
            state.routeOrigin = nil
        }
        guard let destination = state.destination,
              state.status != .navigating, state.status != .rerouting else { return }
        await preview(destination)
    }

    func swapRoutePoints() async {
        guard let destination = state.destination,
              let previousOrigin = state.routeOrigin ?? state.location.map({
                  RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: $0.coordinate),
                             source: .currentLocation)
              }) else { return }
        let reversedWaypoints = Array(state.waypoints.reversed())
        let replacementOrigin = RoutePoint(destination, source: destination.poi == nil ? .search : .poi)
        state.routeOrigin = replacementOrigin
        selectDestination(previousOrigin.destination, applyConfiguredMode: false)
        state.routeOrigin = replacementOrigin
        state.waypoints = reversedWaypoints
        await preview(previousOrigin.destination)
    }

    func planRoute() async {
        guard let destination = state.destination else { return }
        await preview(destination)
    }

    func addWaypoint(_ destination: Destination) async {
        guard state.transportMode == .car || state.transportMode == .walking || state.transportMode == .bicycle else {
            state.errorMessage = "Przystanki pośrednie są dostępne dla tras samochodowych, pieszych i rowerowych."
            return
        }
        guard state.waypoints.count < 8 else {
            state.errorMessage = "Możesz dodać maksymalnie 8 przystanków pośrednich."
            return
        }
        guard !state.waypoints.contains(where: { $0.coordinate == destination.coordinate }) else { return }
        let isActiveTrip = state.status == .navigating || state.status == .rerouting
        let activeOrigin = isActiveTrip ? state.location?.coordinate : nil
        if isActiveTrip, activeOrigin == nil {
            state.errorMessage = "Poczekaj na ustalenie pozycji GPS, aby dodać przystanek do aktywnej trasy."
            return
        }
        if isActiveTrip {
            state.waypoints.insert(destination, at: 0)
            state.pendingWaypointIDs.removeAll { $0 == destination.id }
            state.pendingWaypointIDs.insert(destination.id, at: 0)
            tripSession?.waypoints.insert(destination, at: 0)
            if let activeOrigin { await reroute(from: activeOrigin) }
            return
        }

        state.waypoints.append(destination)
        if let final = state.destination { await preview(final) }
    }

    func removeWaypoint(_ id: UUID) async {
        state.waypoints.removeAll { $0.id == id }
        state.pendingWaypointIDs.removeAll { $0 == id }
        state.evChargingStops = []
        if let final = state.destination { await preview(final) }
    }

    func moveWaypoint(_ id: UUID, by offset: Int) async {
        guard let index = state.waypoints.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard state.waypoints.indices.contains(target) else { return }
        await reorderWaypoint(id, to: target)
    }

    func reorderWaypoint(_ id: UUID, to targetIndex: Int) async {
        guard let sourceIndex = state.waypoints.firstIndex(where: { $0.id == id }) else { return }
        let boundedTarget = min(max(0, targetIndex), state.waypoints.count - 1)
        guard sourceIndex != boundedTarget else { return }
        let waypoint = state.waypoints.remove(at: sourceIndex)
        state.waypoints.insert(waypoint, at: boundedTarget)
        let pendingWaypointIDs = Set(state.pendingWaypointIDs)
        state.pendingWaypointIDs = state.waypoints.map(\.id).filter { pendingWaypointIDs.contains($0) }
        state.evChargingStops = []
        if let final = state.destination { await preview(final) }
    }

    func reorderRouteStop(_ stopID: String, to targetIndex: Int) async {
        guard state.status == .routePreview,
              let destination = state.destination,
              let origin = state.routeOrigin ?? state.location.map({
                  RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: $0.coordinate),
                             source: .currentLocation)
              }) else { return }

        var stops = [EditableRouteStop(id: "route-origin", destination: origin.destination,
                                       originSource: origin.source)]
        stops += state.waypoints.map {
            EditableRouteStop(id: $0.id.uuidString, destination: $0, originSource: nil)
        }
        stops.append(EditableRouteStop(id: "route-destination", destination: destination,
                                       originSource: nil))

        guard let sourceIndex = stops.firstIndex(where: { $0.id == stopID }) else { return }
        let movedStop = stops.remove(at: sourceIndex)
        let insertionIndex = min(max(targetIndex, 0), stops.count)
        guard sourceIndex != insertionIndex else { return }
        stops.insert(movedStop, at: insertionIndex)

        guard let firstStop = stops.first, let lastStop = stops.last else { return }
        let newWaypoints = Array(stops.dropFirst().dropLast()).map(\.destination)
        let newWaypointIDs = Set(newWaypoints.map(\.id))
        state.routeOrigin = RoutePoint(firstStop.destination,
                                       source: firstStop.originSource ?? (firstStop.destination.poi == nil ? .search : .poi))
        state.waypoints = newWaypoints
        state.destination = lastStop.destination
        let pendingIDs = Set(state.pendingWaypointIDs)
        state.pendingWaypointIDs = state.waypoints.map(\.id).filter { pendingIDs.contains($0) }
        state.waypointNavigationTargets = Dictionary(
            uniqueKeysWithValues: state.waypointNavigationTargets.filter { newWaypointIDs.contains($0.key) })
        state.evChargingStops = []
        await preview(lastStop.destination)
    }

    func optimizeWaypoints() async {
        guard state.waypoints.count >= 2, state.status != .navigating, state.status != .rerouting else { return }
        requestGeneration += 1
        roadPlanningCancellationToken?.cancel()
        let token = TransitPlanningCancellationToken()
        roadPlanningCancellationToken = token
        await RoadRoutingContext.$cancellationToken.withValue(token) {
            await performWaypointOptimization()
        }
        if roadPlanningCancellationToken === token { roadPlanningCancellationToken = nil }
    }

    private func performWaypointOptimization() async {
        guard state.waypoints.count >= 2, let destination = state.destination,
              let origin = await resolvedRouteOriginCoordinate(for: state.transportMode) else { return }
        guard state.transportMode == .car || state.transportMode == .walking || state.transportMode == .bicycle else {
            state.errorMessage = "Optymalizacja przystanków jest dostępna dla tras samochodowych, pieszych i rowerowych."
            return
        }
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            state.errorMessage = "Wybrany serwer nie obsługuje optymalizacji przystanków."
            return
        }
        let generation = requestGeneration
        let waypoints = state.waypoints
        let mode = state.transportMode
        let preferences = state.routingPreferences
        do {
            let target = destinationRouteCoordinate(for: destination)
            let routedWaypoints = await routedDestinations(state.waypoints, mode: state.transportMode)
            let order = try await provider.optimizedWaypointOrder(from: origin, to: target,
                                                                 waypoints: routedWaypoints, mode: mode,
                                                                 preferences: preferences)
            try RoadRoutingContext.checkCancellation()
            guard generation == requestGeneration, state.destination?.id == destination.id,
                  state.waypoints == waypoints, state.transportMode == mode,
                  state.routingPreferences == preferences else { return }
            guard order.count == state.waypoints.count,
                  order.allSatisfy({ $0 >= 0 && $0 < state.waypoints.count }) else { throw RoutingError.invalidResponse }
            state.waypoints = order.map { state.waypoints[$0] }
            await preview(destination)
        } catch {
            guard generation == requestGeneration, RoadRoutingContext.cancellationToken?.isCancelled != true else { return }
            state.errorMessage = "Nie udało się zoptymalizować kolejności: \(error.localizedDescription)"
        }
    }

}

private struct EditableRouteStop {
    let id: String
    let destination: Destination
    let originSource: RoutePointSource?
}
