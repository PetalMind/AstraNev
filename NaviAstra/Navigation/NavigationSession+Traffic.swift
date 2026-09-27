import Foundation

extension NavigationSession {
    func configureTraffic(apiKey: String?) -> Bool {
        guard TrafficCredential.save(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        trafficProvider = trafficProviderFactory.make(apiKey: apiKey)
        updateTrafficTileURLTemplates()
        invalidateTraffic()
        state.traffic = nil
        state.trafficStatus = trafficProvider == nil ? .notConfigured : .updating
        lastTrafficFetch = .distantPast
        if trafficProvider != nil { refreshTraffic(force: true) }
        return true
    }

    func updateTrafficTileURLTemplates() {
        state.trafficLightTileURLTemplate = trafficProvider?.rasterFlowTileURLTemplate(style: .light)
        state.trafficDarkTileURLTemplate = trafficProvider?.rasterFlowTileURLTemplate(style: .dark)
        state.trafficLightIncidentTileURLTemplate = trafficProvider?.rasterIncidentTileURLTemplate(style: .light)
        state.trafficDarkIncidentTileURLTemplate = trafficProvider?.rasterIncidentTileURLTemplate(style: .dark)
    }

    func refreshTraffic(force: Bool = false, forceRouteRefresh: Bool = true) {
        let energyPolicy = energyPolicyEngine.currentPolicy
        let isOnDemandMapRequest = force && energyPolicy.mode == .mapBrowsing
        guard energyPolicy.trafficRefreshInterval != nil || isOnDemandMapRequest else { return }
        guard state.transportMode == .car || state.transportMode == .parkRide || state.status == .idle else { return }
        guard state.cameraState != .startingNavigation else { return }
        guard let trafficProvider else { state.trafficStatus = .notConfigured; return }
        let coordinate = state.location?.coordinate
        let isNavigating = state.status == .navigating || state.status == .rerouting
        let nearbyRefreshInterval = energyPolicy.trafficRefreshInterval ?? 120
        if let coordinate, !trafficRequestInFlight,
           force || Date().timeIntervalSince(lastTrafficFetch) >= nearbyRefreshInterval {
            startNearbyTrafficRefresh(using: trafficProvider, at: coordinate)
        }

        guard let route = state.route,
              state.status == .routePreview || isNavigating else { return }
        let progress = state.progress
        let routeInterval = routeTrafficRefreshInterval(progress: progress)
        if forceRouteRefresh, !routeTrafficRequestInFlight,
           force || Date().timeIntervalSince(lastRouteTrafficFetch) >= routeInterval {
            startRouteTrafficRefresh(using: trafficProvider, route: route, progress: progress)
        }
    }

    private func startNearbyTrafficRefresh(using provider: TrafficProvider, at coordinate: Coordinate) {
        trafficRequestInFlight = true
        lastTrafficFetch = Date()
        if state.traffic == nil { state.trafficStatus = .updating }
        let generation = trafficGeneration
        Task {
            defer { if generation == trafficGeneration { trafficRequestInFlight = false } }
            do {
                let snapshot = try await provider.snapshot(near: coordinate, incidentRadiusMeters: 3_500)
                guard generation == trafficGeneration else { return }
                latestNearbyTrafficSnapshot = snapshot
                publishTrafficSnapshot()
                state.trafficStatus = .available
                if let route = state.route, state.status == .navigating || state.status == .rerouting {
                    let published = state.traffic ?? snapshot
                    if confirmedClosureAhead(in: published, on: route, progress: state.progress) == nil {
                        selectTrafficAdjustedRoute(from: published, currentRoute: route, location: coordinate)
                    }
                }
                updateProgress()
                if let published = state.traffic { handleConfirmedClosure(in: published, near: coordinate) }
            } catch {
                guard generation == trafficGeneration else { return }
                publishTrafficSnapshot()
                state.trafficStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    private func startRouteTrafficRefresh(using provider: TrafficProvider, route: NavigationRoute,
                                          progress: RouteProgress?) {
        let startDistance = max(0, progress?.traveledDistance ?? 0)
        let lookAhead = RouteTrafficMonitor.lookAheadDistance(for: route, progress: progress)
        let endDistance = startDistance + lookAhead
        let shouldFetchFlow = routeFlowRouteID != route.id ||
            Date().timeIntervalSince(lastRouteFlowFetch) >= 180
        routeTrafficRequestInFlight = true
        lastRouteTrafficFetch = Date()
        let generation = trafficGeneration
        let routeID = route.id
        let routeCoordinates = route.coordinates
        let flowQueriesTask = Task.detached(priority: .utility) {
            RouteTrafficMonitor.flowQueries(for: routeCoordinates, from: startDistance,
                                            through: endDistance)
        }
        let boxesTask = Task.detached(priority: .utility) {
            RouteTrafficMonitor.queryBoxes(for: routeCoordinates, from: startDistance,
                                           through: endDistance)
        }
        Task { @MainActor [weak self] in
            let (boxes, flowQueries) = await (boxesTask.value, flowQueriesTask.value)
            guard let self else { return }
            defer {
                if generation == self.trafficGeneration { self.routeTrafficRequestInFlight = false }
            }
            guard generation == self.trafficGeneration,
                  self.state.route?.id == routeID else { return }
            guard !boxes.isEmpty || (shouldFetchFlow && !flowQueries.isEmpty) else {
                self.lastRouteTrafficFetch = .distantPast
                return
            }
            if self.state.traffic == nil { self.state.trafficStatus = .updating }
            async let incidentRequest = provider.incidents(in: boxes)
            async let flowRequest = shouldFetchFlow ? provider.routeFlowSamples(at: flowQueries) : []
            let flowSamples = await flowRequest
            guard generation == self.trafficGeneration,
                  self.state.route?.id == routeID else { return }

            var trafficError: Error?
            let incidents: [TrafficIncident]
            do {
                incidents = try await incidentRequest
            } catch {
                trafficError = error
                incidents = []
            }
            let canPublishRouteIncidents = trafficError == nil
            let processingTask = Task.detached(priority: .utility) {
                let geometry = RouteProgressGeometry(route)
                let matchedIncidents = canPublishRouteIncidents
                    ? RouteTrafficMonitor.matching(incidents, to: route,
                                                   from: startDistance, through: endDistance,
                                                   routeGeometry: geometry)
                    : []
                let segments = shouldFetchFlow
                    ? RouteTrafficMonitor.coloredSegments(on: route, from: startDistance,
                                                         through: endDistance, queries: flowQueries,
                                                         samples: flowSamples, geometry: geometry)
                    : []
                return (matchedIncidents, segments)
            }
            let (matchedIncidents, routeFlowSegments) = await processingTask.value
            guard generation == self.trafficGeneration,
                  self.state.route?.id == routeID else { return }

            self.routeTrafficIncidents = matchedIncidents
            self.routeTrafficDataAvailable = canPublishRouteIncidents
            self.routeTrafficUpdatedAt = canPublishRouteIncidents ? Date() : nil

            if shouldFetchFlow {
                self.routeFlowRouteID = routeID
                self.lastRouteFlowFetch = Date()
                self.routeTrafficFlowSegments = routeFlowSegments
                self.routeTrafficFlowUpdatedAt = self.routeTrafficFlowSegments.isEmpty ? nil : Date()
            }

            self.publishTrafficSnapshot()
            if trafficError == nil || !flowSamples.isEmpty {
                self.state.trafficStatus = .available
            } else if let trafficError {
                self.state.trafficStatus = .unavailable(trafficError.localizedDescription)
            }
            if let published = self.state.traffic {
                let closureAhead = self.confirmedClosureAhead(in: published, on: route,
                                                              progress: self.state.progress) != nil
                if !closureAhead, self.state.status == .navigating,
                   let location = self.state.location?.coordinate {
                    self.selectTrafficAdjustedRoute(from: published, currentRoute: route,
                                                    location: location)
                }
                if let location = self.state.location?.coordinate {
                    self.handleConfirmedClosure(in: published, near: location)
                }
            }
        }
    }

    private func routeTrafficRefreshInterval(progress: RouteProgress?) -> TimeInterval {
        let distance = progress?.traveledDistance ?? 0
        let nearest = routeTrafficIncidents.compactMap { incident -> (Double, Bool)? in
            guard let along = incident.distanceAlongRoute, along > distance else { return nil }
            return (along - distance, incident.isRoadClosure)
        }.min { $0.0 < $1.0 }
        if nearest?.1 == true, (nearest?.0 ?? .infinity) <= 3_000 { return 20 }
        let policyInterval = energyPolicyEngine.currentPolicy.trafficRefreshInterval ?? 60
        if (nearest?.0 ?? .infinity) <= 10_000 { return max(30, policyInterval) }
        return max(state.status == .routePreview ? 90 : 60, policyInterval)
    }

    private func publishTrafficSnapshot() {
        let now = Date()
        let nearby = latestNearbyTrafficSnapshot.flatMap {
            now.timeIntervalSince($0.updatedAt) <= 180 ? $0 : nil
        }
        let routeDataIsFresh = routeTrafficDataAvailable &&
            now.timeIntervalSince(routeTrafficUpdatedAt ?? .distantPast) <= 120
        let routeFlowDataIsFresh = routeTrafficFlowUpdatedAt.map {
            now.timeIntervalSince($0) <= 240
        } ?? false
        guard nearby != nil || routeDataIsFresh || routeFlowDataIsFresh else {
            state.traffic = nil
            return
        }
        var incidentsByID: [String: TrafficIncident] = [:]
        for incident in (nearby?.incidents ?? []) + (routeDataIsFresh ? routeTrafficIncidents : []) {
            incidentsByID[incident.id] = incident
        }
        let routeUpdatedAt = routeDataIsFresh ? (routeTrafficUpdatedAt ?? .distantPast) : .distantPast
        let flowUpdatedAt = routeFlowDataIsFresh ? (routeTrafficFlowUpdatedAt ?? .distantPast) : .distantPast
        state.traffic = TrafficSnapshot(
            flow: nearby?.flow,
            incidents: Array(incidentsByID.values),
            routeFlowSegments: routeFlowDataIsFresh ? routeTrafficFlowSegments : [],
            updatedAt: max(nearby?.updatedAt ?? .distantPast, max(routeUpdatedAt, flowUpdatedAt)),
            partialError: nearby?.partialError,
            incidentDataAvailable: (nearby?.incidentDataAvailable ?? false) || routeDataIsFresh)
    }

    private func selectTrafficAdjustedRoute(from snapshot: TrafficSnapshot,
                                            currentRoute: NavigationRoute,
                                            location: Coordinate) {
        guard state.transportMode == .car, state.status == .navigating,
              state.route?.id == currentRoute.id else { return }
        let routes = state.routeOptions.isEmpty ? [currentRoute] : state.routeOptions
        guard routes.count > 1 else { return }
        trafficRouteSelectionGeneration += 1
        let selectionGeneration = trafficRouteSelectionGeneration
        let trafficGeneration = self.trafficGeneration
        let currentRouteID = currentRoute.id
        let locationAccuracy = state.location?.accuracy ?? 70
        let snapshotTimestamp = state.traffic?.updatedAt ?? latestNearbyTrafficSnapshot?.updatedAt
            ?? snapshot.updatedAt
        let scoringTask = Task.detached(priority: .utility) {
            TrafficRouteETA.scores(for: routes, snapshot: snapshot, at: location,
                                   locationAccuracy: locationAccuracy,
                                   trafficReferenceRouteID: currentRouteID)
        }
        Task { @MainActor [weak self] in
            let scores = await scoringTask.value
            guard let self,
                  self.trafficRouteSelectionGeneration == selectionGeneration,
                  self.trafficGeneration == trafficGeneration,
                  self.state.route?.id == currentRouteID,
                  self.state.status == .navigating,
                  (self.state.traffic?.updatedAt ?? self.latestNearbyTrafficSnapshot?.updatedAt)
                    == snapshotTimestamp,
                  let best = scores.min(by: { $0.eta < $1.eta }),
                  best.route.id != currentRouteID,
                  let currentScore = scores.first(where: { $0.route.id == currentRouteID })?.eta,
                  currentScore.isFinite,
                  currentScore - best.eta >= max(120, currentScore * 0.15) else { return }
            self.state.route = best.route
            self.state.routeOptions = scores.sorted { $0.eta < $1.eta }.map { $0.route }
            self.state.evChargingStops = best.route.chargingStops.map(\.destination)
            self.loadRoadData(for: best.route)
            self.trafficProjectionRouteID = nil
            self.updateProgress()
            self.invalidateSpeedLimit()
            if let currentLocation = self.state.location { self.refreshSpeedLimit(for: currentLocation) }
            self.routeTrafficIncidents = []
            self.routeTrafficDataAvailable = false
            self.routeTrafficUpdatedAt = nil
            self.lastRouteTrafficFetch = .distantPast
            self.publishTrafficSnapshot()
        }
    }
}

private enum TrafficRouteETA {
    nonisolated static func scores(for routes: [NavigationRoute], snapshot: TrafficSnapshot,
                                   at location: Coordinate, locationAccuracy: Double,
                                   trafficReferenceRouteID: UUID)
        -> [(route: NavigationRoute, eta: Double)] {
        routes.map { route in
            (route, estimate(for: route, snapshot: snapshot, at: location,
                             locationAccuracy: locationAccuracy,
                             trafficReferenceRouteID: trafficReferenceRouteID))
        }
    }

    private nonisolated static func estimate(for route: NavigationRoute, snapshot: TrafficSnapshot,
                                             at location: Coordinate, locationAccuracy: Double,
                                             trafficReferenceRouteID: UUID) -> Double {
        let geometry = RouteProgressGeometry(route)
        guard let projection = geometry.project(location, within: max(150, locationAccuracy * 2)),
              projection.distanceFromRoute <= max(150, locationAccuracy * 2), geometry.length > 0 else {
            return .infinity
        }
        let fraction = min(1, max(0, projection.alongRoute / geometry.length))
        let plannedDrivingTime = max(0, route.expectedTravelTime - route.chargingDuration)
        var eta = plannedDrivingTime * (1 - fraction)
        eta += route.chargingStops.reduce(0.0) { total, stop in
            guard let chargeProjection = geometry.project(stop.destination.coordinate),
                  chargeProjection.distanceFromRoute <= 500,
                  chargeProjection.alongRoute > projection.alongRoute + 40 else { return total }
            return total + stop.estimatedChargingTime
        }
        let incidentProjections = snapshot.incidents.compactMap { incident -> (TrafficIncident, RouteProjection)? in
            guard let projectedIncident = geometry.project(incident.coordinate),
                  projectedIncident.distanceFromRoute < 120 else { return nil }
            let knownRouteDistance = route.id == trafficReferenceRouteID ? incident.distanceAlongRoute : nil
            let incidentDistance = knownRouteDistance ?? projectedIncident.alongRoute
            guard incidentDistance > projection.alongRoute + 40 else { return nil }
            let incidentProjection = RouteProjection(
                coordinate: projectedIncident.coordinate,
                distanceFromRoute: projectedIncident.distanceFromRoute,
                alongRoute: incidentDistance,
                segment: projectedIncident.segment)
            return (incident, incidentProjection)
        }
        if incidentProjections.contains(where: { $0.0.isRoadClosure }) { return .infinity }
        if let flow = snapshot.flow, flow.coordinates.count > 1 {
            let flowGeometry = RouteProgressGeometry(coordinates: flow.coordinates)
            if let flowProjection = flowGeometry.project(location, within: 80),
               flowProjection.distanceFromRoute < 80 {
                let currentSpeed = max(5, Double(flow.currentSpeedKph)) / 3.6
                let freeSpeed = Double(max(1, flow.freeFlowSpeedKph)) / 3.6
                eta += max(0, flowGeometry.length / currentSpeed - flowGeometry.length / freeSpeed)
            }
        }
        let delays = incidentProjections.reduce(0.0) { total, item in
            total + Double(max(0, item.0.delaySeconds ?? 0))
        }
        return eta + min(1_800, delays)
    }
}
