import Foundation

extension NavigationSession {
    func updateTrafficTileURLTemplates() {
        state.trafficLightTileURLTemplate = trafficProvider?.rasterFlowTileURLTemplate(style: .light)
        state.trafficDarkTileURLTemplate = trafficProvider?.rasterFlowTileURLTemplate(style: .dark)
        state.trafficLightIncidentTileURLTemplate = trafficProvider?.rasterIncidentTileURLTemplate(style: .light)
        state.trafficDarkIncidentTileURLTemplate = trafficProvider?.rasterIncidentTileURLTemplate(style: .dark)
    }

    func refreshTraffic(force: Bool = false, forceRouteRefresh: Bool = true) {
        if force || state.traffic?.incidents.contains(where: { !$0.isActive() }) == true { publishTrafficSnapshot() }
        // Current traffic cannot describe a route planned for another departure/arrival time.
        guard state.status != .routePreview || state.journeyTimeMode == .now else { return }
        let energyPolicy = energyPolicyEngine.currentPolicy
        let isOnDemandMapRequest = force && energyPolicy.mode == .mapBrowsing
        guard energyPolicy.trafficRefreshInterval != nil || isOnDemandMapRequest else { return }
        guard state.transportMode == .car || state.status == .idle else { return }
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
        let samplingBudget = TrafficSamplingBudget.resolved(isNavigating: state.status == .navigating || state.status == .rerouting,
            isForeground: appIsForeground, problemDetected: routeTrafficIncidents.contains {
                ($0.distanceAlongRoute ?? 0) >= startDistance && ($0.isRoadClosure || ($0.delaySeconds ?? 0) >= 120)
            })
        state.trafficSamplingBudget = samplingBudget.maximumRequests
        let knownIncidents = routeTrafficIncidents
        let measuredSegments = routeTrafficFlowUpdatedAt.map { Date().timeIntervalSince($0) <= 240 } == true
            ? routeTrafficFlowSegments : []
        let flowQueriesTask = Task.detached(priority: .utility) {
            RouteTrafficMonitor.flowQueries(for: route, from: startDistance,
                                            through: endDistance, incidents: knownIncidents, measuredSegments: measuredSegments, budget: samplingBudget)
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
                let colors = shouldFetchFlow
                    ? RouteTrafficMonitor.displaySegments(on: route, from: startDistance,
                        through: endDistance, queries: flowQueries, samples: flowSamples, geometry: geometry)
                    : []
                return (matchedIncidents, segments, colors)
            }
            let (matchedIncidents, routeFlowSegments, routeColorSegments) = await processingTask.value
            guard generation == self.trafficGeneration,
                  self.state.route?.id == routeID else { return }

            self.routeTrafficIncidents = matchedIncidents
            self.routeTrafficDataAvailable = canPublishRouteIncidents
            self.routeTrafficUpdatedAt = canPublishRouteIncidents ? Date() : nil

            if shouldFetchFlow {
                self.routeFlowRouteID = routeID
                self.lastRouteFlowFetch = Date()
                self.routeTrafficFlowSegments = routeFlowSegments
                self.routeTrafficColorSegments = routeColorSegments
                self.routeTrafficFlowUpdatedAt = routeFlowSegments.isEmpty && routeColorSegments.isEmpty ? nil : Date()
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
                if self.state.status == .routePreview || (!closureAhead && self.state.status == .navigating),
                   let location = self.state.location?.coordinate ?? route.coordinates.first {
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
        let boxes = state.location.map { [TrafficBoundingBox.around($0.coordinate, radiusMeters: 3_500)] } ?? []
        let local = LocalRoadReportStore.shared.incidents(in: boxes)
        guard nearby != nil || routeDataIsFresh || routeFlowDataIsFresh || !local.isEmpty else {
            state.traffic = nil
            return
        }
        var incidentsByID: [String: TrafficIncident] = [:]
        let matchedLocal = state.route.map { route in
            RouteTrafficMonitor.matching(local, to: route, from: 0, through: RouteProgressGeometry(route).length,
                                         routeGeometry: RouteProgressGeometry(route))
        } ?? []
        for incident in ((nearby?.incidents ?? []) + local + (routeDataIsFresh ? routeTrafficIncidents : []) + matchedLocal)
            where incident.isActive(at: now) && (!incident.sources.contains(.local) || local.contains(where: { $0.id == incident.id })) {
            incidentsByID[incident.id] = incident
        }
        let routeUpdatedAt = routeDataIsFresh ? (routeTrafficUpdatedAt ?? .distantPast) : .distantPast
        let flowUpdatedAt = routeFlowDataIsFresh ? (routeTrafficFlowUpdatedAt ?? .distantPast) : .distantPast
        var colors = routeFlowDataIsFresh ? routeTrafficColorSegments : []
        // Publish a nearby measured road before the full route corridor completes.
        if let route = state.route, let flow = nearby?.flow,
           Date().timeIntervalSince(flow.updatedAt) <= 180,
           let location = state.location?.coordinate {
            let geometry = RouteProgressGeometry(route)
            if let projection = geometry.project(location), projection.distanceFromRoute <= 30 {
                let distance = projection.alongRoute
                let query = RouteTrafficFlowQuery(distanceAlongRoute: distance, coordinate: projection.coordinate)
                let sample = RouteTrafficFlowSample(distanceAlongRoute: distance, flow: flow)
                colors += RouteTrafficMonitor.displaySegments(on: route,
                    from: max(0, distance - 1_000), through: min(geometry.length, distance + 1_000),
                    queries: [query], samples: [sample], geometry: geometry)
            }
        }
        state.traffic = TrafficSnapshot(
            flow: nearby?.flow,
            incidents: Array(incidentsByID.values),
            routeFlowSegments: routeFlowDataIsFresh ? routeTrafficFlowSegments : [],
            updatedAt: local.isEmpty ? max(nearby?.updatedAt ?? .distantPast, max(routeUpdatedAt, flowUpdatedAt)) : now,
            partialError: nearby?.partialError,
            incidentDataAvailable: (nearby?.incidentDataAvailable ?? false) || routeDataIsFresh || !local.isEmpty,
            routeColorSegments: colors)
    }

    func selectTrafficAdjustedRoute(from snapshot: TrafficSnapshot,
                                    currentRoute: NavigationRoute,
                                    location: Coordinate) {
        let isPreview = state.status == .routePreview
        guard state.transportMode == .car, isPreview || state.status == .navigating,
              state.journeyTimeMode == .now,
              isPreview || state.routingPreferences.advanced.effectiveRoutePreference != .shortest,
              state.route?.id == currentRoute.id else { return }
        let origin = isPreview ? (currentRoute.coordinates.first ?? location) : location
        let start = isPreview ? 0 : (RouteProgressGeometry(currentRoute).project(origin)?.alongRoute ?? 0)
        let baseline = RoadRouteETA.estimate(currentRoute, from: start, traffic: nil)
        let observed = RoadRouteETA.estimate(currentRoute, from: start, traffic: snapshot)
        let closureAhead = confirmedClosureAhead(in: snapshot, on: currentRoute,
                                                  progress: isPreview ? nil : state.progress) != nil
        let preservesManualSelection = isPreview && learningExplicitlySelectedRouteID == currentRoute.id
        if preservesManualSelection && closureAhead { publishManualPreviewClosureWarning(for: currentRoute.id) }
        let shouldGenerateCandidates = !preservesManualSelection &&
            Date().timeIntervalSince(lastTrafficCandidateRefresh) >= 300 &&
            ((isPreview && closureAhead) || (!isPreview && baseline.isFinite && observed.isFinite &&
                observed - baseline >= max(120, baseline * 0.15)))
        let existing = state.routeOptions.isEmpty ? [currentRoute] : state.routeOptions
        guard isPreview || existing.count > 1 || shouldGenerateCandidates else { return }
        guard let provider = trafficProvider, !trafficComparisonInFlight,
              Date().timeIntervalSince(lastTrafficComparison) >= 180 else { return }
        trafficComparisonInFlight = true
        lastTrafficComparison = Date()
        if shouldGenerateCandidates { lastTrafficCandidateRefresh = Date() }
        trafficRouteSelectionGeneration += 1
        let selectionGeneration = trafficRouteSelectionGeneration
        let generation = trafficGeneration
        let planGeneration = requestGeneration
        let currentRouteID = currentRoute.id
        let requestedPreferences = state.routingPreferences
        let requestedSelection = learningExplicitlySelectedRouteID
        let requestedStatus = state.status
        let accuracy = state.location?.accuracy ?? 70
        let heading = isPreview ? nil : routingHeading(from: origin)
        let token = TransitPlanningCancellationToken()
        trafficCandidateCancellationToken = token
        trafficComparisonTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.trafficGeneration && selectionGeneration == self.trafficRouteSelectionGeneration {
                    self.trafficComparisonInFlight = false
                    self.trafficComparisonTask = nil
                }
                if self.trafficCandidateCancellationToken === token { self.trafficCandidateCancellationToken = nil }
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !token.isCancelled && generation == self.trafficGeneration &&
                    selectionGeneration == self.trafficRouteSelectionGeneration &&
                    planGeneration == self.requestGeneration && self.state.route?.id == currentRouteID &&
                    self.state.status == requestedStatus && self.state.journeyTimeMode == .now &&
                    self.state.routingPreferences == requestedPreferences &&
                    self.learningExplicitlySelectedRouteID == requestedSelection
            }
            let comparisonStarted = ProcessInfo.processInfo.systemUptime
            do {
                try await RoadRoutingContext.$cancellationToken.withValue(token) {
                    var candidates = existing
                    if shouldGenerateCandidates, let destination = self.state.destination {
                        let closures = self.knownRoadClosures.values.filter { $0.isFresh() }
                        let avoidances = try closures.map { try $0.avoidance() }
                        let polygons = avoidances.flatMap(\.polygons)
                        guard polygons.count <= 256 else { return }
                        let stops = isPreview ? self.state.waypoints : self.unvisitedStops(from: origin)
                        let fresh = try await RoadRoutingContext.$closurePolygons.withValue(polygons) {
                            try await self.calculateRoutes(from: origin,
                                to: self.destinationRouteCoordinate(for: destination),
                                through: stops.map(\.coordinate), commitEVStops: false)
                        }
                        guard isCurrent() else { return }
                        candidates = fresh.filter { route in !avoidances.contains { $0.intersects(route) } } + existing
                        let target = self.destinationRouteCoordinate(for: destination)
                        if !isPreview, let congestion = CongestionDetourCandidate.largest(on: currentRoute,
                            after: start, traffic: snapshot,
                            mandatoryCoordinates: [origin, target] + stops.map(\.coordinate)) {
                            do {
                                if let detour = try await self.congestionDetour(from: origin, to: target,
                                    through: stops.map(\.coordinate), avoiding: congestion) {
                                    candidates.insert(detour, at: 0)
                                }
                            } catch {
                                try RoadRoutingContext.checkCancellation()
                                // This optional candidate cannot discard ordinary route options.
                            }
                            guard isCurrent() else { return }
                        }
                    }
                    candidates = Array(RouteSimilarity.diverse([currentRoute] + candidates.filter { $0.id != currentRouteID },
                                                               preserving: [currentRouteID]).prefix(4))
                    var starts: [UUID: Double] = [:]
                    candidates = candidates.filter { route in
                        if isPreview {
                            guard let first = route.coordinates.first, first.distance(to: origin) <= 100 else { return false }
                            starts[route.id] = 0
                            return true
                        }
                        let geometry = RouteProgressGeometry(route)
                        guard let projection = geometry.project(origin, within: max(50, accuracy * 2)),
                              projection.distanceFromRoute <= max(50, accuracy * 2),
                              RoadRouteETA.canFollow(route, projection: projection, heading: heading) else { return false }
                        starts[route.id] = projection.alongRoute
                        return true
                    }
                    guard isPreview || candidates.count > 1, starts[currentRouteID] != nil, isCurrent() else { return }
                    let snapshots = try await TrafficRouteEvaluator.snapshots(for: candidates, starts: starts,
                        provider: provider, isNavigating: !isPreview, isForeground: self.appIsForeground,
                        requireComparableCoverage: !isPreview)
                    guard isCurrent(), isPreview ||
                        (self.state.location?.coordinate.distance(to: origin) ?? .infinity) < 100 else { return }
                    for route in candidates {
                        guard let traffic = snapshots[route.id] else { continue }
                        for closure in ConfirmedRoadClosure.evidence(in: traffic, route: route) {
                            self.knownRoadClosures[closure.id] = closure
                        }
                    }
                    guard let currentTraffic = snapshots[currentRouteID] else { return }
                    let currentClosed = self.confirmedClosureAhead(in: currentTraffic, on: currentRoute,
                        progress: isPreview ? nil : self.state.progress) != nil
                    if preservesManualSelection {
                        if currentClosed { self.publishManualPreviewClosureWarning(for: currentRouteID) }
                        else if self.state.errorMessage == Self.manualPreviewClosureMessage { self.state.errorMessage = nil }
                    }
                    // Closures remain actionable even when speed samples are missing. ETA comparison
                    // still requires the same coverage for every displayed candidate.
                    guard !isPreview || TrafficRouteEvaluator.hasComparableCoverage(routes: candidates,
                        starts: starts, traffic: snapshots) else { return }
                    guard let comparisonUpdatedAt = snapshots.values.map(\.updatedAt).min(),
                          !isPreview || (0...120).contains(Date().timeIntervalSince(comparisonUpdatedAt)) else { return }
                    let ranked = DrivingLearningEngine.shared.ranked(candidates,
                        preference: requestedPreferences.advanced.effectiveRoutePreference, from: starts, traffic: snapshots)
                    guard let selected = preservesManualSelection ? currentRoute : ranked.first,
                          let selectedTraffic = snapshots[selected.id] else { return }
                    let currentETA = RoadRouteETA.estimate(currentRoute, from: starts[currentRouteID] ?? 0,
                                                           traffic: currentTraffic)
                    let selectedETA = RoadRouteETA.estimate(selected, from: starts[selected.id] ?? 0,
                                                            traffic: selectedTraffic)
                    guard selectedETA.isFinite || (preservesManualSelection && currentClosed) else { return }
                    if !isPreview {
                        if currentClosed {
                            self.handleConfirmedClosure(in: currentTraffic, near: origin)
                            return
                        }
                        guard selected.id != currentRouteID, currentETA.isFinite,
                              currentETA - selectedETA >= max(120, currentETA * 0.15) else { return }
                    }
                    guard isCurrent() else { return }
                    RoutingDiagnostics.shared.publish(.make(routes: ranked,
                        preference: requestedPreferences.advanced.effectiveRoutePreference,
                        selected: selected.id, source: isPreview ? "traffic-preview" : "traffic-switch",
                        calculationSeconds: ProcessInfo.processInfo.systemUptime - comparisonStarted,
                        samplingBudget: self.state.trafficSamplingBudget,
                        gpsMatchQuality: self.state.routeMatch?.match.confidence, starts: starts, traffic: snapshots,
                        personalOrder: DrivingLearningEngine.shared.settings.enabled ? ranked.map(\.id) : nil,
                        personalEvidence: DrivingLearningEngine.shared.diagnosticAssessments(ranked,
                            preference: requestedPreferences.advanced.effectiveRoutePreference, starts: starts, traffic: snapshots)))
                    if !isPreview, self.state.voiceEnabled {
                        self.voice.announceFasterRoute(savedSeconds: currentETA - selectedETA, routeID: selected.id)
                    }
                    self.arrivalDetector.reset()
                    if !isPreview { self.learningAllowsDeviations = false }
                    let routesToPublish = preservesManualSelection ? candidates : ranked
                    let publishedRoutes = routesToPublish.compactMap { route -> NavigationRoute? in
                        let eta = RoadRouteETA.estimate(route, from: starts[route.id] ?? 0, traffic: snapshots[route.id])
                        // Keep a manually selected closed route available with its finite base time
                        // and the explicit warning, never an infinity in a route card.
                        guard eta.isFinite || (preservesManualSelection && route.id == currentRouteID && currentClosed)
                            else { return nil }
                        var displayed = route
                        displayed.trafficPreviewEstimate = nil
                        if isPreview && eta.isFinite {
                            displayed.trafficPreviewEstimate = .init(travelTime: eta, updatedAt: comparisonUpdatedAt)
                        }
                        return displayed
                    }
                    self.state.route = publishedRoutes.first { $0.id == selected.id } ?? selected
                    self.state.routeOptions = publishedRoutes
                    self.state.evChargingStops = selected.chargingStops.map(\.destination)
                    if selected.id != currentRouteID {
                        self.loadRoadData(for: selected)
                        self.invalidateSpeedLimit()
                        if let currentLocation = self.state.location { self.refreshSpeedLimit(for: currentLocation) }
                    }
                    self.trafficProjectionRouteID = nil
                    self.routeTrafficIncidents = selectedTraffic.incidents
                    self.routeTrafficDataAvailable = true
                    self.routeTrafficUpdatedAt = selectedTraffic.updatedAt
                    self.routeTrafficFlowSegments = selectedTraffic.routeFlowSegments
                    self.routeTrafficColorSegments = selectedTraffic.routeFlowSegments
                    self.routeTrafficFlowUpdatedAt = selectedTraffic.updatedAt
                    self.routeFlowRouteID = selected.id
                    self.lastRouteFlowFetch = selectedTraffic.updatedAt
                    self.lastRouteTrafficFetch = selectedTraffic.updatedAt
                    self.publishTrafficSnapshot()
                    self.updateProgress()
                    if isPreview { self.updateCameraIntent() }
                }
            } catch {
                // Retain the user's current route when observations or candidate generation fail.
            }
        }
    }

    private static let manualPreviewClosureMessage =
        "Wybrana trasa prowadzi przez potwierdzone zamknięcie drogi. Wybierz inny wariant."

    private func publishManualPreviewClosureWarning(for routeID: UUID) {
        state.errorMessage = Self.manualPreviewClosureMessage
        if state.route?.id == routeID { state.route?.trafficPreviewEstimate = nil }
        if let index = state.routeOptions.firstIndex(where: { $0.id == routeID }) {
            state.routeOptions[index].trafficPreviewEstimate = nil
        }
    }

    /// Requests a single temporary congestion-avoidance plan, with a bounded optional budget.
    func congestionDetour(from origin: Coordinate, to target: Coordinate, through stops: [Coordinate],
                          avoiding congestion: CongestionDetourCandidate) async throws -> NavigationRoute? {
        #if os(iOS)
        // The native offline engine cannot interrupt an in-progress graph search.
        guard !OfflineRoutingStore.shared.preferOffline, !OfflineRoutingStore.shared.networkUnavailable else { return nil }
        #endif
        let operation = Task { @MainActor in
            try await RoadRoutingContext.$congestionAvoidancePolygons.withValue(
                RoadRoutingContext.congestionAvoidancePolygons + congestion.area.polygons) {
                try await calculateRoutes(from: origin, to: target, through: stops, commitEVStops: false)
            }
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            operation.cancel()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await operation.value.first { !congestion.area.intersects($0) }
        } onCancel: { operation.cancel() }
    }

}

/// One ETA calculation for navigation and alternative selection.
nonisolated enum RoadRouteETA {
    struct PreparedRoute {
        let geometry: RouteProgressGeometry
        let travelSegments: [RouteTravelSegment]

        init(_ route: NavigationRoute, geometry: RouteProgressGeometry? = nil) {
            self.geometry = geometry ?? RouteProgressGeometry(route)
            travelSegments = route.travelSegments.sorted { $0.startDistance < $1.startDistance }
        }
    }

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
        drivingTime(route, prepared: PreparedRoute(route), from: start, through: end)
    }

    private static func drivingTime(_ route: NavigationRoute, prepared: PreparedRoute,
                                   from start: Double, through end: Double) -> Double {
        guard end > start else { return 0 }
        let length = prepared.geometry.length
        guard length > 0 else { return 0 }
        let baseline = max(0, route.expectedTravelTime - route.chargingDuration)
        var result = 0.0
        var covered = 0.0
        var cursor = start
        for segment in prepared.travelSegments {
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
        estimate(route, prepared: PreparedRoute(route), from: start,
                 traffic: traffic, paceMultiplier: paceMultiplier)
    }

    static func estimate(_ route: NavigationRoute, prepared: PreparedRoute, from start: Double,
                         traffic: TrafficSnapshot?, paceMultiplier: Double = 1) -> Double {
        let geometry = prepared.geometry
        let end = geometry.length
        if let traffic, ConfirmedRoadClosure.evidence(in: traffic, route: route).contains(where: {
            $0.distanceAhead(on: route, after: start, through: end) != nil
        }) { return .infinity }
        var time = drivingTime(route, prepared: prepared, from: start, through: end) * paceMultiplier
        var flowIntervals: [(Double, Double)] = []
        if let traffic, Date().timeIntervalSince(traffic.updatedAt) <= 240 {
            var cursor = start
            for segment in traffic.routeFlowSegments.filter({ $0.routeID == route.id })
                .sorted(by: { $0.startDistance < $1.startDistance }) {
                guard (-5...240).contains(Date().timeIntervalSince(segment.measuredAt ?? traffic.updatedAt)) else { continue }
                let lower = max(cursor, segment.startDistance)
                let upper = min(end, segment.endDistance)
                guard upper > lower else { continue }
                if segment.isRoadClosure { continue }
                guard let speed = segment.currentSpeedKph, speed.isFinite, speed >= 0 else { continue }
                // Replace the engine's time on the measured interval, without counting it twice.
                let measured = (upper - lower) / (max(1, speed) / 3.6)
                time += max(0, measured - drivingTime(route, prepared: prepared,
                    from: lower, through: upper) * paceMultiplier)
                flowIntervals.append((lower, upper))
                cursor = upper
            }
            if traffic.incidentDataAvailable, Date().timeIntervalSince(traffic.updatedAt) <= 120 {
                var seen = Set<String>()
                for incident in traffic.incidents where seen.insert(incident.id).inserted {
                    guard (-5...120).contains(Date().timeIntervalSince(incident.observedAt ?? traffic.updatedAt)) else { continue }
                    guard let projection = RouteTrafficMonitor.incidentProjection(incident, geometry: geometry, route: route) else { continue }
                    let position = projection.alongRoute
                    guard position > start + 40 else { continue }
                    if incident.isRoadClosure { continue }
                    let isMeasured = flowIntervals.contains { position >= $0.0 && position <= $0.1 }
                    if !isMeasured { time += Double(max(0, incident.routingDelaySeconds ?? 0)) }
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
