import Foundation

extension NavigationSession {
    private func clearRerouteErrorIfNeeded() {
        guard let message = state.errorMessage,
              message.hasPrefix("Nie udało się przeliczyć trasy:") ||
                message.hasPrefix("Nie udało się ominąć zgłoszonego zamknięcia:") else { return }
        state.errorMessage = nil
    }

    func routingHeading(from origin: Coordinate) -> Double? {
        guard let location = state.location, location.accuracy >= 0, location.accuracy <= 45,
              location.speed >= 2.5, Date().timeIntervalSince(location.timestamp) <= 10,
              location.coordinate.distance(to: origin) <= 50,
              location.course.isFinite, (0..<360).contains(location.course),
              location.courseAccuracy < 0 || location.courseAccuracy <= 45 else { return nil }
        return location.course
    }

    func reroute(from origin: Coordinate) async {
        roadRerouteCancellationToken?.cancel()
        let token = TransitPlanningCancellationToken()
        roadRerouteCancellationToken = token
        await RoadRoutingContext.$cancellationToken.withValue(token) {
            await RoadRoutingContext.$heading.withValue(routingHeading(from: origin)) {
                await performReroute(from: origin)
            }
        }
        if roadRerouteCancellationToken === token { roadRerouteCancellationToken = nil }
    }

    private func performReroute(from origin: Coordinate) async {
        let calculationStarted = ProcessInfo.processInfo.systemUptime
        guard let destination = state.destination else { return }
        let generation = rerouteController.beginManualReroute()
        state.status = .rerouting
        updateLiveActivity()
        clearRerouteErrorIfNeeded()
        if state.cameraState != .freeLook { state.cameraState = .rerouting; updateCameraIntent() }
        do {
            let remainingStops = unvisitedStops(from: origin)
            let target = destinationRouteCoordinate(for: destination)
            let routes = try await calculateRoutes(from: origin, to: target,
                                                   through: remainingStops.map(\.coordinate),
                                                   commitEVStops: false)
            guard rerouteController.isCurrent(generation), state.status == .rerouting,
                  state.destination?.id == destination.id else { return }
            guard let firstRoute = routes.first else { throw RoutingError.invalidResponse }
            if state.transportMode == .car, state.routingPreferences.evPlanningEnabled {
                let chargingStops = firstRoute.chargingStops.map { $0.destination }
                let chargingTargets = await POIAccessResolver.shared.resolveMany(
                    for: chargingStops, mode: .car)
                guard rerouteController.isCurrent(generation), state.status == .rerouting,
                      state.destination?.id == destination.id else { return }
                state.evChargingStops = chargingStops
                for (stop, target) in zip(chargingStops, chargingTargets) where stop.poi != nil {
                    state.waypointNavigationTargets[stop.id] = target
                }
            } else {
                clearEVChargingStops()
            }
            arrivalDetector.reset()
            state.route = firstRoute; state.routeOptions = routes
            if state.transportMode == .car {
                RoutingDiagnostics.shared.publish(.make(routes: routes, preference: state.routingPreferences.advanced.effectiveRoutePreference,
                    selected: firstRoute.id, source: "reroute-complete", calculationSeconds: ProcessInfo.processInfo.systemUptime - calculationStarted,
                    personalOrder: DrivingLearningEngine.shared.settings.enabled ? routes.map(\.id) : nil,
                    personalEvidence: DrivingLearningEngine.shared.diagnosticAssessments(routes,
                        preference: state.routingPreferences.advanced.effectiveRoutePreference)))
            }
            state.pendingWaypointIDs = []
            if usesRoadVoiceGuidance { loadRoadData(for: firstRoute) }
            tripSession?.rerouteCount += 1
            invalidateTraffic()
            invalidateSpeedLimit()
            state.status = .navigating
            clearRerouteErrorIfNeeded()
            voice.reset(preservingSpokenAnnouncements: true)
            updateProgress()
            voice.announceReroute(number: tripSession?.rerouteCount ?? 0)
            updateNavigationCameraState()
            if state.transportMode == .car { refreshTraffic(force: true) }
        } catch {
            guard rerouteController.isCurrent(generation), state.status == .rerouting,
                  state.destination?.id == destination.id else { return }
            state.status = .navigating
            updateNavigationCameraState()
            state.errorMessage = "Nie udało się przeliczyć trasy: \(error.localizedDescription)"
        }
    }

    func unvisitedStops(from origin: Coordinate) -> [Destination] {
        let evStops = state.transportMode == .car && state.routingPreferences.evPlanningEnabled
            ? state.evChargingStops : []
        let stops = state.waypoints + evStops
        let route = state.route
        let matchedProgress = state.routeMatch.flatMap { match -> Double? in
            guard let route, match.routeID == route.id,
                  let location = state.location,
                  match.locationTimestamp == location.timestamp,
                  location.coordinate.distance(to: origin) <= max(100, location.accuracy * 2),
                  match.match.confidence >= 0.25, state.mapMatchingResult?.ambiguous != true,
                  match.match.projection.distanceFromRoute <= max(40, location.accuracy * 1.5) else {
                return nil
            }
            return match.match.projection.alongRoute
        }
        let lastTrustedProgress = previousRouteMatch.flatMap { previous -> Double? in
            previous.routeID == route?.id ? previous.projection.alongRoute : nil
        }
        let stableProgress = matchedProgress ?? lastTrustedProgress
        if stableProgress == nil && (state.mapMatchingResult?.ambiguous == true ||
            state.routeMatch.map { $0.match.confidence < 0.25 } == true) { return stops }
        return RemainingRouteWaypointPlanner.remainingStops(
            from: origin,
            routeCoordinates: state.route?.coordinates,
            currentAlongRoute: stableProgress,
            stops: stops,
            routedCoordinates: state.waypointNavigationTargets.mapValues(\.coordinate),
            priorityWaypointIDs: state.pendingWaypointIDs)
    }
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate]? = nil,
                                 commitEVStops: Bool = true,
                                 publishDiagnostics: Bool = true) async throws -> [NavigationRoute] {
        let started = ProcessInfo.processInfo.systemUptime
        let preferences = state.routingPreferences, mode = state.transportMode
        let generation = requestGeneration
        knownRoadClosures = knownRoadClosures.filter { $0.value.isFresh() }
        let avoidances = mode == .car ? try knownRoadClosures.values.map { try $0.avoidance() } : []
        var polygons = RoadRoutingContext.closurePolygons
        for polygon in avoidances.flatMap(\.polygons) where !polygons.contains(polygon) { polygons.append(polygon) }
        guard polygons.count <= 256 else {
            throw ValhallaFeatureError.message("Nie udało się bezpiecznie uwzględnić wszystkich zamknięć drogi.")
        }
        let calculated = try await RoadRoutingContext.$closurePolygons.withValue(polygons) {
            try await RoadRoutingContext.$heading.withValue(routingHeading(from: from)) {
                try await calculateRoutesForCurrentPlan(from: from, to: to, through: through,
                                                        commitEVStops: commitEVStops)
            }
        }
        let routes = calculated.filter { route in !avoidances.contains { $0.intersects(route) } }
        guard !routes.isEmpty else { throw RoutingError.invalidResponse }
        if publishDiagnostics, mode == .car, RoadRoutingContext.allowsPersonalization,
           generation == requestGeneration, preferences == state.routingPreferences {
            RoutingDiagnostics.shared.publish(.make(routes: routes, preference: preferences.advanced.effectiveRoutePreference,
                selected: routes.first?.id, source: preferences.evPlanningEnabled ? "ev-plan" : "road-plan",
                calculationSeconds: ProcessInfo.processInfo.systemUptime - started,
                personalOrder: DrivingLearningEngine.shared.settings.enabled ? routes.map(\.id) : nil,
                    personalEvidence: DrivingLearningEngine.shared.diagnosticAssessments(routes,
                        preference: state.routingPreferences.advanced.effectiveRoutePreference)))
        }
        return routes
    }

    private func calculateRoutesForCurrentPlan(from: Coordinate, to: Coordinate, through: [Coordinate]?,
                                              commitEVStops: Bool) async throws -> [NavigationRoute] {
        try RoadRoutingContext.checkCancellation()
        #if os(iOS)
        if state.transportMode == .car, state.routingPreferences.evPlanningEnabled,
           OfflineRoutingStore.shared.preferOffline || OfflineRoutingStore.shared.networkUnavailable {
            throw ValhallaFeatureError.message("Automatyczny dobór ładowarek wymaga internetu. Dla trasy offline wyłącz planowanie ładowania i dodaj potrzebne postoje ręcznie.")
        }
        #endif
        if state.transportMode == .transit {
            return try await transitProvider.calculateRoutes(from: from, to: to,
                                                            departingAt: Date(), preferences: state.routingPreferences.transit)
        }
        let waypoints = state.waypoints
        let evStops = state.evChargingStops
        let mode = state.transportMode
        let preferences = state.routingPreferences
        let generation = requestGeneration
        let routedWaypoints = await routedDestinations(waypoints, mode: mode)
        let routedEVStops = await routedDestinations(evStops, mode: mode)
        try RoadRoutingContext.checkCancellation()
        guard generation == requestGeneration, state.transportMode == mode,
              state.waypoints == waypoints, state.routingPreferences == preferences else { throw CancellationError() }
        let originalStops = waypoints + evStops
        let routedStops = routedWaypoints + routedEVStops
        let stops: [Coordinate]
        if let through {
            stops = through.map { requested in
                guard let index = originalStops.firstIndex(where: { $0.coordinate.distance(to: requested) <= 10 }) else {
                    return requested
                }
                return routedStops[index].coordinate
            }
        } else {
            stops = routedWaypoints.map(\.coordinate)
        }
        if let provider = routeProvider as? AdvancedRouteProvider {
            if state.transportMode == .car, state.routingPreferences.evPlanningEnabled {
                let mandatoryWaypoints = through.map { coordinates in
                    state.waypoints.filter { waypoint in
                        coordinates.contains { $0.distance(to: waypoint.coordinate) <= 10 }
                    }
                } ?? state.waypoints
                let mandatoryIDs = Set(mandatoryWaypoints.map(\.id))
                let mandatoryStops = state.waypoints.filter { mandatoryIDs.contains($0.id) }
                return try await calculateEVRoutes(from: from, to: to, explicitStops: mandatoryStops,
                                                   provider: provider, avoiding: [],
                                                   commitChargingStops: commitEVStops)
            }
            return try await provider.calculateRoutes(from: from, to: to, through: stops,
                                                      mode: state.transportMode,
                                                      preferences: state.routingPreferences, avoiding: [])
        }
        guard stops.isEmpty else { throw RoutingError.invalidResponse }
        return try await routeProvider.calculateRoutes(from: from, to: to, mode: state.transportMode)
    }

    func destinationRouteCoordinate(for destination: Destination) -> Coordinate {
        if destination.poi != nil {
            // If OSM has no access point, keep the route usable and let Valhalla snap the POI pin.
            return state.navigationTarget?.coordinate ?? destination.coordinate
        }
        return destination.coordinate
    }

    func routedDestinations(_ destinations: [Destination], mode: TransportMode) async -> [Destination] {
        let generation = requestGeneration
        let rerouteGeneration = rerouteController.generation
        let poiIndexes = destinations.indices.filter { destinations[$0].poi != nil }
        let approaches: [POIAccessApproach?] = poiIndexes.map { index in
            guard mode == .car else { return nil }
            let origin = index > 0 ? destinations[index - 1].coordinate : routeOriginCoordinate
            return origin.map { POIAccessApproach(origin: $0, bearing: index == 0 ? routingHeading(from: $0) : nil) }
        }
        let targets = await POIAccessResolver.shared.resolveMany(
            for: poiIndexes.map { destinations[$0] }, mode: mode, approaches: approaches)
        let mayCommit = generation == requestGeneration && rerouteGeneration == rerouteController.generation &&
            RoadRoutingContext.cancellationToken?.isCancelled != true
        var routed = destinations
        for (offset, index) in poiIndexes.enumerated() {
            guard let target = targets[offset] else {
                // A missing access target leaves this copy at the original POI coordinate for Valhalla.
                if mayCommit { state.waypointNavigationTargets[destinations[index].id] = nil }
                continue
            }
            routed[index].coordinate = target.coordinate
            if mayCommit, (state.waypoints.contains(where: { $0.id == destinations[index].id }) ||
                state.evChargingStops.contains(where: { $0.id == destinations[index].id })) {
                state.waypointNavigationTargets[destinations[index].id] = target
            }
        }
        return routed
    }

    func resolveAccessTarget(for destination: Destination, mode: TransportMode, from origin: Coordinate? = nil) async ->
        POINavigationTarget? {
        guard destination.poi != nil else { return nil }
        let approach = (origin ?? routeOriginCoordinate).flatMap { coordinate in
            mode == .car ? POIAccessApproach(origin: coordinate, bearing: routingHeading(from: coordinate)) : nil
        }
        let target = await POIAccessResolver.shared.resolve(for: destination, mode: mode, approach: approach)
        return target
    }

    func estimatedSearchRoute(from origin: Coordinate, to destination: Destination,
                              mode: TransportMode) async throws -> SearchRouteEstimate? {
        let departure = state.journeyTimeMode == .now ? Date() : state.journeyTargetTime
        let route: NavigationRoute?
        switch mode {
        case .transit:
            let target: Coordinate
            if destination.poi == nil {
                target = destination.coordinate
            } else {
                target = await POIAccessResolver.shared.resolve(for: destination, mode: .walking)?.coordinate
                    ?? destination.coordinate
            }
            let journeys = try await transitProvider.routes(
                from: origin, to: target, time: departure,
                arriveBy: state.journeyTimeMode == .arriveBy,
                preferences: state.routingPreferences.transit, cancellationToken: nil)
            route = TransitNavigationRouteMapper.routes(from: journeys).first
        case .car, .walking, .bicycle:
            let target = await POIAccessResolver.shared.cachedTarget(for: destination, mode: mode)?.coordinate
                ?? destination.coordinate
            try Task.checkCancellation()
            let routes: [NavigationRoute]
            if let provider = routeProvider as? AdvancedRouteProvider {
                routes = try await provider.calculateRoutes(from: origin, to: target, through: [], mode: mode,
                    preferences: state.routingPreferences, avoiding: [])
            } else {
                routes = try await routeProvider.calculateRoutes(from: origin, to: target, mode: mode)
            }
            route = routes.first
        }
        try Task.checkCancellation()
        guard let route, let metric = RoutedTravelMetrics(time: route.expectedTravelTime, distance: route.distance) else { return nil }
        return SearchRouteEstimate(travelTime: metric.time, distanceMeters: metric.distance)
    }

    private func calculateEVRoutes(from: Coordinate, to: Coordinate, explicitStops: [Destination],
                                   provider: AdvancedRouteProvider,
                                   avoiding: [Coordinate] = [],
                                   commitChargingStops: Bool = true) async throws -> [NavigationRoute] {
        let generation = requestGeneration
        let rerouteGeneration = rerouteController.generation
        let preferences = state.routingPreferences
        let routedExplicitStops = await routedDestinations(explicitStops, mode: .car)
        try RoadRoutingContext.checkCancellation()
        guard generation == requestGeneration, rerouteGeneration == rerouteController.generation else {
            throw CancellationError()
        }
        guard preferences.evRangeKilometers.isFinite, preferences.evRangeKilometers > 0,
              preferences.evConsumptionKWhPer100Km.isFinite, preferences.evConsumptionKWhPer100Km > 0,
              preferences.evMaximumChargingPowerKW.isFinite, preferences.evMaximumChargingPowerKW > 0 else { throw EVPlanningError.rangeNotConfigured }
        let availableRange = availableEVRangeMeters(for: preferences)
        let fullRange = preferences.evRangeKilometers * 1_000
        guard availableRange > 0 else { throw EVPlanningError.batteryDepleted }
        let baseRoutes = try await provider.calculateRoutes(
            from: from, to: to, through: routedExplicitStops.map(\.coordinate), mode: .car,
            preferences: preferences, avoiding: avoiding)
        var feasible: [NavigationRoute] = []
        var lastPlanningError: Error?
        for base in baseRoutes.prefix(3) {
            try RoadRoutingContext.checkCancellation()
            let length = zip(base.coordinates, base.coordinates.dropFirst())
                .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            guard length > 0 else { continue }
            if length <= availableRange * 0.8 {
                feasible.append(base)
                continue
            }
            let chargers: [NearbyPlaceCandidate]
            do {
                chargers = try await OpenStreetMapNearbyPlaceProvider().search(
                    .charging, along: base.coordinates, radius: 3_000, resultLimit: 1_000)
            } catch {
                try RoadRoutingContext.checkCancellation()
                if error is CancellationError { throw error }
                lastPlanningError = error
                continue
            }
            try RoadRoutingContext.checkCancellation()
            let eligible = chargers.compactMap { candidate -> NearbyPlaceCandidate? in
                guard let station = candidate.chargingStation,
                      station.availability != .unavailable, station.publicAccess != false,
                      let power = station.powerKW(for: preferences.evConnectorTypes) else { return nil }
                let selected = Set(preferences.evConnectorTypes.map(ChargingStationCapabilities.normalizedConnector))
                let compatible = station.connectorTypes.filter {
                    selected.isEmpty || selected.contains(ChargingStationCapabilities.normalizedConnector($0))
                }
                var candidate = candidate
                candidate.chargingStation = ChargingStationCapabilities(connectorTypes: compatible,
                    maximumPowerKW: power, chargingPointCount: station.chargingPointCount,
                    publicAccess: station.publicAccess, availability: station.availability,
                    connectorPowerKW: station.connectorPowerKW)
                return candidate
            }.sorted { $0.distanceFromRoute < $1.distanceFromRoute }
            let plans = EVStopPlanner.plans(chargers: eligible, routeLength: length,
                                           initialRange: availableRange, fullRange: fullRange,
                                           consumption: preferences.evConsumptionKWhPer100Km,
                                           maximumPower: preferences.evMaximumChargingPowerKW)
            for selected in plans {
                try RoadRoutingContext.checkCancellation()
                let resolved = await routedDestinations(selected.map(\.destination), mode: .car)
                try RoadRoutingContext.checkCancellation()
                let explicitPositions = routedExplicitStops.map { stop in
                    MapMatcher.project(stop.coordinate, onto: base.coordinates)?.alongRoute ?? .infinity
                }
                // Keep the user's stop order. On loops, first-point projection can reverse it.
                guard zip(explicitPositions, explicitPositions.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
                let ordered = (routedExplicitStops.indices.map {
                    (routedExplicitStops[$0].coordinate, explicitPositions[$0])
                } + selected.indices.map { (resolved[$0].coordinate, selected[$0].distanceFromRoute) })
                    .sorted { $0.1 < $1.1 }
                let routes: [NavigationRoute]
                do {
                    routes = try await provider.calculateRoutes(
                        from: from, to: to, through: ordered.map { $0.0 }, mode: .car,
                        preferences: preferences, avoiding: avoiding)
                } catch {
                    try RoadRoutingContext.checkCancellation()
                    if error is CancellationError { throw error }
                    lastPlanningError = error
                    continue
                }
                for var route in routes {
                    guard let plan = evChargePlan(on: route, chargingCandidates: selected,
                        chargingCoordinates: resolved.map(\.coordinate), fullRange: fullRange,
                        initialRange: availableRange, consumptionKWhPer100Km: preferences.evConsumptionKWhPer100Km,
                        vehicleMaximumPowerKW: preferences.evMaximumChargingPowerKW) else { continue }
                    route.chargingStops = plan.stops
                    route.chargingDuration = plan.duration
                    route.expectedTravelTime += plan.duration
                    feasible.append(route)
                }
            }
        }
        try RoadRoutingContext.checkCancellation()
        guard generation == requestGeneration, rerouteGeneration == rerouteController.generation,
              state.routingPreferences == preferences else { throw CancellationError() }
        guard !feasible.isEmpty else { throw lastPlanningError ?? EVPlanningError.chargersUnavailable }
        let ordered = RoadRoutingContext.allowsPersonalization
            ? DrivingLearningEngine.shared.ranked(feasible, preference: preferences.advanced.effectiveRoutePreference)
            : RouteScoringEngine.ranked(feasible, preference: preferences.advanced.effectiveRoutePreference)
        let ranked = Array(RouteSimilarity.diverse(ordered).prefix(3))
        if commitChargingStops {
            state.evChargingStops = ranked[0].chargingStops.map(\.destination)
            _ = await routedDestinations(state.evChargingStops, mode: .car)
            try RoadRoutingContext.checkCancellation()
        }
        return ranked
    }

    private func evChargePlan(on route: NavigationRoute, chargingCandidates: [NearbyPlaceCandidate], chargingCoordinates: [Coordinate],
                              fullRange: Double, initialRange: Double,
                              consumptionKWhPer100Km: Double,
                              vehicleMaximumPowerKW: Double) -> (stops: [EVChargingStop], duration: TimeInterval)? {
        let routeLength = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard routeLength > 0 else { return nil }
        let stations = chargingCandidates.indices.compactMap { index -> (NearbyPlaceCandidate, Double, ChargingStationCapabilities)? in
            let candidate = chargingCandidates[index]
            guard let station = candidate.chargingStation,
                  let projection = MapMatcher.project(chargingCoordinates[index], onto: route.coordinates),
                  projection.distanceFromRoute <= 1_500,
                  station.maximumPowerKW != nil else { return nil }
            return (candidate, projection.alongRoute, station)
        }.sorted { $0.1 < $1.1 }
        guard stations.count == chargingCandidates.count, !stations.isEmpty else { return nil }
        var progress = 0.0
        var remainingRange = initialRange
        var plans: [EVChargingStop] = []
        for index in stations.indices {
            let (candidate, stationPosition, station) = stations[index]
            let distanceToStation = stationPosition - progress
            guard distanceToStation > 0,
                  distanceToStation <= remainingRange * 0.8 else { return nil }
            let rangeAtStation = remainingRange - distanceToStation
            let nextPosition = index + 1 < stations.count ? stations[index + 1].1 : routeLength
            let distanceToNextStop = nextPosition - stationPosition
            guard distanceToNextStop > 0,
                  distanceToNextStop <= fullRange * 0.8 else { return nil }
            let targetRange = min(fullRange, distanceToNextStop / 0.8)
            let addedRange = max(0, targetRange - rangeAtStation)
            let acceptedPower = min(station.maximumPowerKW ?? 0, vehicleMaximumPowerKW)
            guard acceptedPower > 0 else { return nil }
            // Conservative generic taper estimate: nominal power is not sustained at high SOC.
            let batteryKWh = fullRange / 1_000 / 100 * consumptionKWhPer100Km
            let chargingTime = EVStopPlanner.chargingTime(
                from: rangeAtStation / fullRange, to: targetRange / fullRange,
                batteryKWh: batteryKWh, power: acceptedPower)
            plans.append(EVChargingStop(
                id: candidate.id, destination: candidate.destination,
                connectorTypes: station.connectorTypes, maximumPowerKW: acceptedPower,
                estimatedChargingTime: chargingTime,
                availabilityKnown: station.availability == .available,
                publicAccess: station.publicAccess))
            remainingRange = min(fullRange, rangeAtStation + addedRange)
            progress = stationPosition
        }
        guard routeLength - progress <= remainingRange * 0.8 else { return nil }
        return (plans, plans.reduce(0) { $0 + $1.estimatedChargingTime })
    }

    func handleConfirmedClosure(in snapshot: TrafficSnapshot, near location: Coordinate) {
        guard state.status == .navigating, let route = state.route,
              let progress = state.progress, state.transportMode == .car,
              let provider = routeProvider as? AdvancedRouteProvider,
              let destinationID = state.destination?.id,
              !rerouteController.hasAutomaticClosureReroute else { return }
        guard let closureIncident = confirmedClosureAhead(in: snapshot, on: route, progress: progress) else { return }
        let closureRequestID = "\(route.id.uuidString):\(closureIncident.id)"
        guard let generation = rerouteController.beginAutomaticClosureReroute(for: closureRequestID) else { return }
        let routeID = route.id
        let closures = Array(knownRoadClosures.values.filter { $0.isFresh() })
        let requestedPreferences = state.routingPreferences
        state.status = .rerouting
        updateLiveActivity()
        if state.cameraState != .freeLook {
            state.cameraState = .rerouting
            updateCameraIntent()
        }
        roadRerouteCancellationToken?.cancel()
        let token = TransitPlanningCancellationToken()
        roadRerouteCancellationToken = token
        let heading = routingHeading(from: location)
        rerouteController.setAutomaticClosureTask(Task { @MainActor [weak self] in
            await RoadRoutingContext.$cancellationToken.withValue(token) {
                await RoadRoutingContext.$heading.withValue(heading) {
                    guard let self else { return }
                    defer {
                        self.rerouteController.finishAutomaticClosureReroute(generation: generation)
                        if self.roadRerouteCancellationToken === token { self.roadRerouteCancellationToken = nil }
                        // Preference changes can invalidate this result without starting
                        // another request. Do not leave our navigation state suspended.
                        if self.rerouteController.isCurrent(generation), self.state.status == .rerouting,
                           self.state.route?.id == routeID, self.state.destination?.id == destinationID {
                            self.state.status = .navigating
                            self.updateNavigationCameraState()
                            self.updateLiveActivity()
                        }
                    }

                    do {
                        let avoidances = try closures.map { try $0.avoidance() }
                        let polygons = avoidances.flatMap(\.polygons)
                        guard !polygons.isEmpty, polygons.count <= 256 else {
                            throw ValhallaFeatureError.message("Nie udało się bezpiecznie uwzględnić wszystkich zamknięć drogi.")
                        }
                        let stops = self.unvisitedStops(from: location)
                        let routedStops = await self.routedDestinations(stops, mode: .car)
                        guard self.rerouteController.isCurrent(generation),
                              self.state.status == .rerouting,
                              self.state.route?.id == routeID,
                              self.state.routingPreferences == requestedPreferences,
                              self.state.destination?.id == destinationID else { return }
                        guard let currentDestination = self.state.destination else { return }
                        let destination = self.destinationRouteCoordinate(for: currentDestination)
                        let routes: [NavigationRoute]
                        if self.state.routingPreferences.evPlanningEnabled {
                            let mandatoryStops = stops.filter { stop in
                                self.state.waypoints.contains(where: { $0.id == stop.id })
                            }
                            routes = try await RoadRoutingContext.$closurePolygons.withValue(polygons) {
                                try await self.calculateEVRoutes(from: location, to: destination,
                                    explicitStops: mandatoryStops, provider: provider,
                                    avoiding: [], commitChargingStops: false)
                            }
                        } else {
                            routes = try await RoadRoutingContext.$closurePolygons.withValue(polygons) {
                                try await provider.calculateRoutes(from: location, to: destination,
                                    through: routedStops.map(\.coordinate), mode: .car,
                                    preferences: requestedPreferences, avoiding: [])
                            }
                        }
                        guard self.rerouteController.isCurrent(generation),
                              self.state.status == .rerouting,
                              self.state.route?.id == routeID,
                              self.state.routingPreferences == requestedPreferences,
                              self.state.destination?.id == destinationID else { return }
                        let safeRoutes = routes.filter { route in !avoidances.contains { $0.intersects(route) } }
                        let ranked = DrivingLearningEngine.shared.ranked(safeRoutes,
                            preference: self.state.routingPreferences.advanced.effectiveRoutePreference)
                        guard let alternative = ranked.first else { throw RoutingError.invalidResponse }
                        if self.state.routingPreferences.evPlanningEnabled {
                            let chargingStops = alternative.chargingStops.map(\.destination)
                            let chargingTargets = await POIAccessResolver.shared.resolveMany(
                                for: chargingStops, mode: .car)
                            guard self.rerouteController.isCurrent(generation),
                                  self.state.status == .rerouting,
                                  self.state.route?.id == routeID,
                                  self.state.routingPreferences == requestedPreferences,
                                  self.state.destination?.id == destinationID else { return }
                            self.state.evChargingStops = chargingStops
                            for (stop, target) in zip(chargingStops, chargingTargets) where stop.poi != nil {
                                self.state.waypointNavigationTargets[stop.id] = target
                            }
                        } else {
                            self.clearEVChargingStops()
                        }
                        RoutingDiagnostics.shared.publish(.make(routes: ranked,
                            preference: self.state.routingPreferences.advanced.effectiveRoutePreference,
                            selected: alternative.id, source: "validated-closure-detour", calculationSeconds: nil,
                            personalOrder: DrivingLearningEngine.shared.settings.enabled ? ranked.map(\.id) : nil,
                    personalEvidence: DrivingLearningEngine.shared.diagnosticAssessments(ranked,
                        preference: self.state.routingPreferences.advanced.effectiveRoutePreference)))
                        self.learningAllowsDeviations = false
                        self.state.route = alternative
                        self.state.routeOptions = ranked
                        self.state.pendingWaypointIDs = []
                        self.rerouteController.markClosureRerouted(closureRequestID)
                        self.loadRoadData(for: alternative)
                        self.tripSession?.rerouteCount += 1
                        self.invalidateTraffic()
                        self.invalidateSpeedLimit()
                        self.state.status = .navigating
                        self.clearRerouteErrorIfNeeded()
                        self.voice.reset(preservingSpokenAnnouncements: true)
                        self.updateProgress()
                        self.voice.announceReroute(number: self.tripSession?.rerouteCount ?? 0)
                        self.updateNavigationCameraState()
                        self.refreshTraffic(force: true)
                    } catch {
                        guard self.rerouteController.isCurrent(generation),
                              self.state.status == .rerouting,
                              self.state.route?.id == routeID,
                              self.state.destination?.id == destinationID else { return }
                        self.state.status = .navigating
                        self.updateNavigationCameraState()
                        self.state.errorMessage = "Nie udało się ominąć zgłoszonego zamknięcia: spróbuję ponownie za chwilę."
                        self.rerouteController.scheduleClosureRetry(closureRequestID, after: 60)
                    }
                }
            }
        })
    }

    func confirmedClosureAhead(in snapshot: TrafficSnapshot, on route: NavigationRoute,
                                       progress: RouteProgress?) -> ConfirmedRoadClosure? {
        let traveledDistance = progress?.traveledDistance ?? 0
        let lookAheadEnd = traveledDistance + RouteTrafficMonitor.lookAheadDistance(for: route, progress: progress)
        knownRoadClosures = knownRoadClosures.filter { $0.value.isFresh() }
        for closure in ConfirmedRoadClosure.evidence(in: snapshot, route: route) {
            knownRoadClosures[closure.id] = closure
        }
        return knownRoadClosures.values.compactMap { closure -> (ConfirmedRoadClosure, Double)? in
            guard let distance = closure.distanceAhead(on: route, after: traveledDistance,
                                                       through: lookAheadEnd) else { return nil }
            return (closure, distance)
        }.min { $0.1 < $1.1 }?.0
    }

    func clearEVChargingStops() {
        let chargingStopIDs = Set(state.evChargingStops.map(\.id))
        state.evChargingStops = []
        state.waypointNavigationTargets = state.waypointNavigationTargets.filter {
            !chargingStopIDs.contains($0.key)
        }
    }
}

nonisolated enum RemainingRouteWaypointPlanner {
    static func remainingStops(from origin: Coordinate, routeCoordinates: [Coordinate]?,
                               currentAlongRoute: Double? = nil,
                               stops: [Destination], routedCoordinates: [UUID: Coordinate],
                               priorityWaypointIDs: [UUID] = []) -> [Destination] {
        guard let routeCoordinates, routeCoordinates.count > 1 else { return stops }
        let currentPosition = currentAlongRoute.flatMap { $0.isFinite ? $0 : nil }
            ?? MapMatcher.project(origin, onto: routeCoordinates)?.alongRoute
        guard let currentPosition else { return stops }
        let priority = priorityWaypointIDs.enumerated().reduce(into: [UUID: Int]()) { ranks, item in
            if ranks[item.element] == nil { ranks[item.element] = item.offset }
        }
        return stops.enumerated().compactMap { index, waypoint ->
            (Destination, routePosition: Double, priority: Int?, inputOrder: Int)? in
            let coordinate = routedCoordinates[waypoint.id] ?? waypoint.coordinate
            guard let projection = MapMatcher.project(coordinate, onto: routeCoordinates),
                  priority[waypoint.id] != nil || projection.alongRoute > currentPosition + 50 else {
                return nil
            }
            return (waypoint, projection.alongRoute, priority[waypoint.id], index)
        }.sorted { lhs, rhs in
            switch (lhs.priority, rhs.priority) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.inputOrder < rhs.inputOrder
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                if lhs.routePosition != rhs.routePosition { return lhs.routePosition < rhs.routePosition }
                return lhs.inputOrder < rhs.inputOrder
            }
        }.map(\.0)
    }
}
