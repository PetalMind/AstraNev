import Foundation

extension NavigationEngine {
    func configureTraffic(apiKey: String?) -> Bool {
        guard TrafficCredential.save(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let normalizedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        trafficProvider = normalizedKey == nil || normalizedKey!.isEmpty ? nil : TomTomTrafficProvider(apiKey: normalizedKey!)
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
        guard state.transportMode == .car || state.status == .idle else { return }
        guard let trafficProvider else { state.trafficStatus = .notConfigured; return }
        let coordinate = state.location?.coordinate
        let isNavigating = state.status == .navigating || state.status == .rerouting
        let nearbyRefreshInterval: TimeInterval = isNavigating ? 60 : 120
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
            do {
                let incidents = try await incidentRequest
                self.routeTrafficIncidents = RouteTrafficMonitor.matching(
                    incidents, to: route, from: startDistance, through: endDistance)
                self.routeTrafficDataAvailable = true
                self.routeTrafficUpdatedAt = Date()
            } catch {
                trafficError = error
                self.routeTrafficIncidents = []
                self.routeTrafficDataAvailable = false
                self.routeTrafficUpdatedAt = nil
            }

            if shouldFetchFlow {
                self.routeFlowRouteID = routeID
                self.lastRouteFlowFetch = Date()
                self.routeTrafficFlowSegments = RouteTrafficMonitor.coloredSegments(
                    on: route, from: startDistance, through: endDistance,
                    queries: flowQueries, samples: flowSamples)
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
        if (nearest?.0 ?? .infinity) <= 10_000 { return 30 }
        return state.status == .routePreview ? 90 : 60
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
        let scores = routes.map { route in
            (route, trafficAdjustedETA(for: route, snapshot: snapshot, at: location))
        }
        guard let best = scores.min(by: { $0.1 < $1.1 }), best.0.id != currentRoute.id,
              let currentScore = scores.first(where: { $0.0.id == currentRoute.id })?.1,
              currentScore.isFinite,
              currentScore - best.1 >= max(120, currentScore * 0.15) else { return }
        state.route = best.0
        state.routeOptions = scores.sorted { $0.1 < $1.1 }.map(\.0)
        state.evChargingStops = best.0.chargingStops.map(\.destination)
        loadRoadData(for: best.0)
        trafficProjectionRouteID = nil
        updateProgress()
        invalidateSpeedLimit()
        if let currentLocation = state.location { refreshSpeedLimit(for: currentLocation) }
        routeTrafficIncidents = []
        routeTrafficDataAvailable = false
        routeTrafficUpdatedAt = nil
        lastRouteTrafficFetch = .distantPast
        publishTrafficSnapshot()
    }

    private func trafficAdjustedETA(for route: NavigationRoute, snapshot: TrafficSnapshot,
                                    at location: Coordinate) -> Double {
        guard let projection = MapMatcher.project(location, onto: route.coordinates),
              projection.distanceFromRoute <= max(150, (state.location?.accuracy ?? 70) * 2) else {
            return .infinity
        }
        let geometryDistance = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard geometryDistance > 0 else { return .infinity }
        let fraction = min(1, max(0, projection.alongRoute / geometryDistance))
        let plannedDrivingTime = max(0, route.expectedTravelTime - route.chargingDuration)
        var eta = plannedDrivingTime * (1 - fraction)
        eta += route.chargingStops.reduce(0.0) { total, stop in
            guard let chargeProjection = MapMatcher.project(stop.destination.coordinate, onto: route.coordinates),
                  chargeProjection.alongRoute > projection.alongRoute + 40 else { return total }
            return total + stop.estimatedChargingTime
        }
        let closures = snapshot.incidents.compactMap { incident -> Double? in
            guard incident.isRoadClosure,
                  let incidentProjection = MapMatcher.project(incident.coordinate, onto: route.coordinates),
                  incidentProjection.distanceFromRoute < 120,
                  incidentProjection.alongRoute > projection.alongRoute + 40 else { return nil }
            return incidentProjection.alongRoute
        }
        if !closures.isEmpty { return .infinity }
        if let flow = snapshot.flow,
           let flowProjection = MapMatcher.project(location, onto: flow.coordinates),
           flowProjection.distanceFromRoute < 80,
           flow.coordinates.count > 1 {
            let flowDistance = zip(flow.coordinates, flow.coordinates.dropFirst())
                .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            let currentSpeed = max(5, Double(flow.currentSpeedKph)) / 3.6
            let freeSpeed = Double(max(1, flow.freeFlowSpeedKph)) / 3.6
            eta += max(0, flowDistance / currentSpeed - flowDistance / freeSpeed)
        }
        let delays = snapshot.incidents.reduce(0.0) { total, incident in
            guard let incidentProjection = MapMatcher.project(incident.coordinate, onto: route.coordinates),
                  incidentProjection.distanceFromRoute < 120,
                  incidentProjection.alongRoute > projection.alongRoute + 40 else { return total }
            return total + Double(max(0, incident.delaySeconds ?? 0))
        }
        return eta + min(1_800, delays)
    }

}
