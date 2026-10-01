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
        guard !appIsForeground || state.cameraState != .startingNavigation else { return }
        guard let trafficProvider else { state.trafficStatus = .notConfigured; return }
        let coordinate = state.location?.coordinate
        let isNavigating = state.status == .navigating || state.status == .rerouting
        let nearbyRefreshInterval = energyPolicy.trafficRefreshInterval ?? 120
        if appIsForeground, let coordinate, !trafficRequestInFlight,
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
            self.updateProgress()
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
        if !appIsForeground {
            return energyPolicyEngine.currentPolicy.trafficRefreshInterval ?? 90
        }
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
        guard let provider = trafficProvider, !trafficComparisonInFlight,
              Date().timeIntervalSince(lastTrafficComparison) >= 180 else { return }
        trafficComparisonInFlight = true
        lastTrafficComparison = Date()
        trafficRouteSelectionGeneration += 1
        let selectionGeneration = trafficRouteSelectionGeneration
        let generation = trafficGeneration
        let currentRouteID = currentRoute.id
        let accuracy = state.location?.accuracy ?? 70
        let heading = routingHeading(from: location)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.trafficGeneration { self.trafficComparisonInFlight = false } }
            var scores: [(route: NavigationRoute, eta: Double)] = []
            var snapshots: [UUID: TrafficSnapshot] = [:]
            for route in routes {
                guard generation == self.trafficGeneration,
                      selectionGeneration == self.trafficRouteSelectionGeneration,
                      self.state.route?.id == currentRouteID, self.state.status == .navigating else { return }
                let geometry = RouteProgressGeometry(route)
                guard let projection = geometry.project(location, within: max(50, accuracy * 2)),
                      projection.distanceFromRoute <= max(50, accuracy * 2),
                      RoadRouteETA.canFollow(route, projection: projection, heading: heading) else { continue }
                let start = projection.alongRoute
                let horizon = min(geometry.length - start,
                                  RouteTrafficMonitor.lookAheadDistance(for: route, progress: nil))
                let end = start + horizon
                let boxes = RouteTrafficMonitor.queryBoxes(for: route.coordinates, from: start, through: end)
                let queries = RouteTrafficMonitor.flowQueries(for: route.coordinates, from: start, through: end)
                async let incidentRequest = provider.incidents(in: boxes)
                async let flowRequest = provider.routeFlowSamples(at: queries)
                let incidents: [TrafficIncident]
                do { incidents = try await incidentRequest } catch { return }
                let samples = await flowRequest
                // A failed or mostly missing corridor must not make an alternative look faster.
                guard !queries.isEmpty, samples.count >= max(1, Int(ceil(Double(queries.count) * 0.75))) else { return }
                let segments = RouteTrafficMonitor.coloredSegments(
                    on: route, from: start, through: end, queries: queries, samples: samples, geometry: geometry)
                guard !segments.isEmpty else { return }
                let matched = RouteTrafficMonitor.matching(incidents, to: route, from: start,
                                                           through: end, routeGeometry: geometry)
                let traffic = TrafficSnapshot(flow: nil, incidents: matched, routeFlowSegments: segments,
                                              updatedAt: Date(), partialError: nil, incidentDataAvailable: true)
                snapshots[route.id] = traffic
                scores.append((route, RoadRouteETA.estimate(route, from: start, traffic: traffic)))
            }
            guard generation == self.trafficGeneration,
                  self.trafficRouteSelectionGeneration == selectionGeneration,
                  self.state.route?.id == currentRouteID, self.state.status == .navigating,
                  self.state.location?.coordinate.distance(to: location) ?? .infinity < 100,
                  let best = scores.min(by: { $0.eta < $1.eta }),
                  best.route.id != currentRouteID, best.eta.isFinite,
                  let currentScore = scores.first(where: { $0.route.id == currentRouteID })?.eta,
                  currentScore.isFinite,
                  currentScore - best.eta >= max(120, currentScore * 0.15) else { return }
            if self.state.voiceEnabled {
                self.voice.announceFasterRoute(savedSeconds: currentScore - best.eta, routeID: best.route.id)
            }
            self.arrivalDetector.reset()
            self.state.route = best.route
            self.state.routeOptions = scores.sorted { $0.eta < $1.eta }.map { $0.route }
            self.state.evChargingStops = best.route.chargingStops.map(\.destination)
            self.loadRoadData(for: best.route)
            self.trafficProjectionRouteID = nil
            self.invalidateSpeedLimit()
            if let currentLocation = self.state.location { self.refreshSpeedLimit(for: currentLocation) }
            if let selectedTraffic = snapshots[best.route.id] {
                self.routeTrafficIncidents = selectedTraffic.incidents
                self.routeTrafficDataAvailable = true
                self.routeTrafficUpdatedAt = selectedTraffic.updatedAt
                self.routeTrafficFlowSegments = selectedTraffic.routeFlowSegments
                self.routeTrafficFlowUpdatedAt = selectedTraffic.updatedAt
                self.routeFlowRouteID = best.route.id
                self.lastRouteFlowFetch = selectedTraffic.updatedAt
            }
            self.lastRouteTrafficFetch = .distantPast
            self.publishTrafficSnapshot()
            self.updateProgress()
            self.refreshTraffic(force: true)
        }
    }
}

/// One ETA calculation for navigation and alternative selection.
nonisolated enum RoadRouteETA {
    static func canFollow(_ route: NavigationRoute, projection: RouteProjection, heading: Double?) -> Bool {
        guard let heading else { return true }
        guard route.coordinates.indices.contains(projection.segment + 1) else { return false }
        let a = route.coordinates[projection.segment]
        let b = route.coordinates[projection.segment + 1]
        let dx = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
        let dy = b.latitude - a.latitude
        let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let difference = abs(heading - bearing)
        return min(difference, 360 - difference) <= 55
    }

    static func drivingTime(_ route: NavigationRoute, from start: Double, through end: Double) -> Double {
        guard end > start else { return 0 }
        let length = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard length > 0 else { return 0 }
        let baseline = max(0, route.expectedTravelTime - route.chargingDuration)
        var result = 0.0
        var covered = 0.0
        var cursor = start
        for segment in route.travelSegments.sorted(by: { $0.startDistance < $1.startDistance }) {
            let lower = max(cursor, segment.startDistance)
            let upper = min(end, segment.endDistance)
            guard upper > lower, segment.endDistance > segment.startDistance else { continue }
            result += segment.duration * (upper - lower) / (segment.endDistance - segment.startDistance)
            covered += upper - lower
            cursor = upper
        }
        return result + max(0, end - start - covered) / length * baseline
    }

    static func estimate(_ route: NavigationRoute, from start: Double,
                         traffic: TrafficSnapshot?, paceMultiplier: Double = 1) -> Double {
        let geometry = RouteProgressGeometry(route)
        let end = geometry.length
        var time = drivingTime(route, from: start, through: end) * paceMultiplier
        var flowIntervals: [(Double, Double)] = []
        if let traffic, Date().timeIntervalSince(traffic.updatedAt) <= 240 {
            var cursor = start
            for segment in traffic.routeFlowSegments.filter({ $0.routeID == route.id })
                .sorted(by: { $0.startDistance < $1.startDistance }) {
                let lower = max(cursor, segment.startDistance)
                let upper = min(end, segment.endDistance)
                guard upper > lower else { continue }
                if segment.isRoadClosure { return .infinity }
                guard let speed = segment.currentSpeedKph, speed.isFinite, speed >= 0 else { continue }
                // Replace the engine's time on the measured interval, without counting it twice.
                let measured = (upper - lower) / (max(1, speed) / 3.6)
                time += max(0, measured - drivingTime(route, from: lower, through: upper) * paceMultiplier)
                flowIntervals.append((lower, upper))
                cursor = upper
            }
            if traffic.incidentDataAvailable, Date().timeIntervalSince(traffic.updatedAt) <= 120 {
                var seen = Set<String>()
                for incident in traffic.incidents where seen.insert(incident.id).inserted {
                    guard let projection = geometry.project(incident.coordinate),
                          projection.distanceFromRoute <= RouteTrafficMonitor.routeMatchToleranceMeters else { continue }
                    let position = incident.distanceAlongRoute ?? projection.alongRoute
                    guard position > start + 40 else { continue }
                    if incident.isRoadClosure { return .infinity }
                    let isMeasured = flowIntervals.contains { position >= $0.0 && position <= $0.1 }
                    if !isMeasured { time += Double(max(0, incident.delaySeconds ?? 0)) }
                }
            }
        }
        for stop in route.chargingStops {
            if let projection = geometry.project(stop.destination.coordinate),
               projection.alongRoute > start + 40 {
                time += stop.estimatedChargingTime
            }
        }
        return max(0, time)
    }
}
