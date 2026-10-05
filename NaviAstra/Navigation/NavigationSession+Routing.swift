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
                  match.match.confidence > 0,
                  match.match.projection.distanceFromRoute <= max(40, location.accuracy * 1.5) else {
                return nil
            }
            return match.match.projection.alongRoute
        }
        return RemainingRouteWaypointPlanner.remainingStops(
            from: origin,
            routeCoordinates: state.route?.coordinates,
            currentAlongRoute: matchedProgress,
            stops: stops,
            routedCoordinates: state.waypointNavigationTargets.mapValues(\.coordinate),
            priorityWaypointIDs: state.pendingWaypointIDs)
    }
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate]? = nil,
                                 commitEVStops: Bool = true) async throws -> [NavigationRoute] {
        try await RoadRoutingContext.$heading.withValue(routingHeading(from: from)) {
            try await calculateRoutesForCurrentPlan(from: from, to: to, through: through,
                                                    commitEVStops: commitEVStops)
        }
    }

    private func calculateRoutesForCurrentPlan(from: Coordinate, to: Coordinate, through: [Coordinate]?,
                                              commitEVStops: Bool) async throws -> [NavigationRoute] {
        try RoadRoutingContext.checkCancellation()
        if state.transportMode == .transit {
            return try await transitProvider.calculateRoutes(from: from, to: to,
                                                            departingAt: Date())
        }
        if state.transportMode == .parkRide {
            return try await calculateParkRideRoutes(from: from, to: to)
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
        let targets = await POIAccessResolver.shared.resolveMany(
            for: poiIndexes.map { destinations[$0] }, mode: mode)
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

    func resolveAccessTargets(for destination: Destination, mode: TransportMode) async ->
        (navigation: POINavigationTarget?, parkRideCar: POINavigationTarget?) {
        guard destination.poi != nil else { return (nil, nil) }
        if mode == .parkRide {
            let walkingTarget = await POIAccessResolver.shared.resolve(for: destination, mode: .walking)
            let carTarget = await POIAccessResolver.shared.resolve(for: destination, mode: .car)
            return (walkingTarget, carTarget)
        }
        let target = await POIAccessResolver.shared.resolve(for: destination, mode: mode)
        return (target, nil)
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
                preferences: .init(), cancellationToken: nil)
            route = TransitNavigationRouteMapper.routes(from: journeys).first
        case .parkRide:
            let targets = await resolveAccessTargets(for: destination, mode: .parkRide)
            route = try await calculateParkRideRoutes(
                from: origin, to: targets.navigation?.coordinate ?? destination.coordinate,
                departingAt: departure, destination: destination,
                parkRideCarTarget: targets.parkRideCar?.coordinate).first
        case .car, .walking, .bicycle:
            return nil
        }
        guard let route, route.expectedTravelTime.isFinite, route.distance.isFinite else { return nil }
        return SearchRouteEstimate(travelTime: route.expectedTravelTime, distanceMeters: route.distance)
    }

    func calculateParkRideRoutes(from: Coordinate, to: Coordinate,
                                 departingAt requestedDeparture: Date = Date(),
                                 destination: Destination? = nil,
                                 parkRideCarTarget: Coordinate? = nil,
                                 cancellationToken: TransitPlanningCancellationToken? = nil) async throws -> [NavigationRoute] {
        try cancellationToken?.checkCancellation()
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            throw TransitRoutingError.noParkRide
        }
        let carDestination: Coordinate
        let selectedDestination = destination ?? state.destination
        if selectedDestination?.poi != nil {
            carDestination = parkRideCarTarget ?? state.parkRideCarTarget?.coordinate
                ?? selectedDestination?.coordinate ?? to
        } else {
            carDestination = to
        }
        let baseRoute: NavigationRoute
        do {
            guard let route = try await provider.calculateRoutes(
                from: from, to: carDestination, through: [], mode: .car,
                preferences: state.routingPreferences, avoiding: []).first else {
                throw TransitRoutingError.noParkRide
            }
            baseRoute = route
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TransitRoutingError.noParkRide
        }
        let finalApproach = routeSuffix(baseRoute.coordinates, length: 40_000)
        async let corridorSearch = try? OpenStreetMapNearbyPlaceProvider()
            .search(.parkRide, along: finalApproach, radius: 5_000)
        async let destinationSearch = try? OpenStreetMapNearbyPlaceProvider()
            .search(.parkRide, around: to, radius: 15_000)
        let parkings: [NearbyPlaceCandidate]
        let (corridorCandidates, destinationCandidates) = await (corridorSearch, destinationSearch)
        try Task.checkCancellation()
        try cancellationToken?.checkCancellation()
        var uniqueParkings: [String: NearbyPlaceCandidate] = [:]
        for parking in (corridorCandidates ?? []) + (destinationCandidates ?? []) {
            uniqueParkings[parking.id] = parking
        }
        parkings = Array(uniqueParkings.values).sorted {
            to.distance(to: $0.destination.coordinate) < to.distance(to: $1.destination.coordinate)
        }
        guard !parkings.isEmpty else { throw TransitRoutingError.noParkRide }
        var selectedParkings = Array(parkings.prefix(4))
        let corridor = (corridorCandidates ?? []).sorted { $0.distanceFromRoute < $1.distanceFromRoute }
        for fraction in [0.0, 0.33, 0.66, 1.0] where !corridor.isEmpty {
            let parking = corridor[Int(Double(corridor.count - 1) * fraction)]
            if !selectedParkings.contains(where: { $0.id == parking.id }) { selectedParkings.append(parking) }
        }
        let parkingTargets = await POIAccessResolver.shared.resolveMany(
            for: selectedParkings.map(\.destination), mode: .car)
        try Task.checkCancellation()
        try cancellationToken?.checkCancellation()
        let departure = requestedDeparture
        var combined: [NavigationRoute] = []
        for index in selectedParkings.indices {
            try Task.checkCancellation()
            try cancellationToken?.checkCancellation()
            let parking = selectedParkings[index]
            let parkingTarget = parkingTargets[index]?.coordinate ?? parking.destination.coordinate
            let carRoutes: [NavigationRoute]
            do {
                carRoutes = try await provider.calculateRoutes(
                    from: from, to: parkingTarget, through: [], mode: .car,
                    preferences: state.routingPreferences, avoiding: [])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            try cancellationToken?.checkCancellation()
            guard let carRoute = carRoutes.first else { continue }
            let parkingArrival = departure.addingTimeInterval(carRoute.expectedTravelTime)
            let transitDeparture = parkingArrival.addingTimeInterval(5 * 60)
            let transitRoutes: [NavigationRoute]
            do {
                transitRoutes = try await transitProvider.calculateRoutes(
                    from: parkingTarget, to: to, departingAt: transitDeparture,
                    cancellationToken: cancellationToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TransitRouteError {
                guard case .noRoute = error else { throw error }
                continue
            } catch {
                continue
            }
            try cancellationToken?.checkCancellation()
            for transitRoute in transitRoutes.prefix(2) {
                guard let journey = transitRoute.journey else { continue }
                let carLeg = JourneyLeg(mode: "CAR", line: "P+R", from: "Początek",
                                        to: parking.destination.name, departure: departure,
                                        arrival: parkingArrival, realTime: false,
                                        coordinates: carRoute.coordinates)
                var coordinates = carRoute.coordinates
                coordinates.append(contentsOf: transitRoute.coordinates.dropFirst())
                combined.append(NavigationRoute(
                    coordinates: coordinates,
                    distance: carRoute.distance + transitRoute.distance,
                    expectedTravelTime: journey.arrival.timeIntervalSince(departure),
                    maneuvers: carRoute.maneuvers,
                    journey: Journey(departure: departure, arrival: journey.arrival,
                                     legs: [carLeg] + journey.legs,
                                     scheduleIsCached: journey.scheduleIsCached,
                                     realtimeFeedAvailable: journey.realtimeFeedAvailable,
                                     realtimeFeedUpdatedAt: journey.realtimeFeedUpdatedAt,
                                     alertsFeedAvailable: journey.alertsFeedAvailable,
                                     alerts: journey.alerts,
                                     walkingDuration: journey.walkingDuration,
                                     waitingDuration: journey.waitingDuration + 5 * 60 +
                                        max(0, journey.departure.timeIntervalSince(transitDeparture)),
                                     transferCount: journey.transferCount,
                                     realtimeFreshness: journey.realtimeFreshness,
                                     frequencyEstimateHeadwaySeconds: journey.frequencyEstimateHeadwaySeconds),
                    travelSegments: carRoute.travelSegments,
                    information: carRoute.information.map {
                        var information = $0
                        information.scopeDescription = "Odcinek samochodowy P+R"
                        return information
                    }
                ))
            }
        }
        guard !combined.isEmpty else { throw TransitRoutingError.noParkRide }
        return combined.sorted { parkRideCost($0) < parkRideCost($1) }.prefix(3).map { $0 }
    }

    private func routeSuffix(_ route: [Coordinate], length: Double) -> [Coordinate] {
        guard route.count > 1, length > 0, let last = route.last else { return route }
        var reversed = [last]
        var remaining = length
        for index in stride(from: route.count - 2, through: 0, by: -1) {
            let start = route[index]
            let end = route[index + 1]
            let segmentLength = start.distance(to: end)
            if segmentLength >= remaining, segmentLength > 0 {
                let fraction = 1 - remaining / segmentLength
                reversed.append(Coordinate(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction))
                return Array(reversed.reversed())
            }
            reversed.append(start)
            remaining -= segmentLength
        }
        return Array(reversed.reversed())
    }

    private func parkRideCost(_ route: NavigationRoute) -> Double {
        guard let journey = route.journey else { return route.expectedTravelTime }
        let carTime = journey.legs.filter { $0.mode == "CAR" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        let rideTime = journey.legs.filter { $0.mode != "CAR" && $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        return carTime + rideTime + journey.walkingDuration * 1.6
            + journey.waitingDuration * 1.25 + Double(journey.transferCount) * 240
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
        let availableRange = preferences.availableEVRangeKilometers * 1_000
        let fullRange = preferences.evRangeKilometers * 1_000
        guard availableRange > 0 else { throw EVPlanningError.rangeNotConfigured }
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
            let eligible = chargers.filter { candidate in
                guard let station = candidate.chargingStation,
                      station.availability != .unavailable, station.publicAccess != false,
                      let power = station.maximumPowerKW, power > 0,
                      !station.connectorTypes.isEmpty else { return false }
                if preferences.evConnectorTypes.isEmpty { return true }
                let connectors = Set(station.connectorTypes)
                return preferences.evConnectorTypes.contains { selected in
                    selected == "ccs" ? (connectors.contains("ccs") || connectors.contains("type2_combo"))
                        : connectors.contains(selected)
                }
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
        let ranked = Array(feasible.sorted { $0.expectedTravelTime < $1.expectedTravelTime }.prefix(3))
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
        guard let generation = rerouteController.beginAutomaticClosureReroute(for: closureIncident.id) else { return }
        let routeID = route.id
        let closureGeometry = closureIncident.geometry.isEmpty
            ? [closureIncident.coordinate] : closureIncident.geometry
        let excluded = stride(from: 0, to: closureGeometry.count,
                              by: max(1, Int(ceil(Double(closureGeometry.count) / 20))))
            .map { closureGeometry[$0] }
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
                    }

                    do {
                        let stops = self.unvisitedStops(from: location)
                        let routedStops = await self.routedDestinations(stops, mode: .car)
                        guard self.rerouteController.isCurrent(generation),
                              self.state.status == .rerouting,
                              self.state.route?.id == routeID,
                              self.state.destination?.id == destinationID else { return }
                        guard let currentDestination = self.state.destination else { return }
                        let destination = self.destinationRouteCoordinate(for: currentDestination)
                        let routes: [NavigationRoute]
                        if self.state.routingPreferences.evPlanningEnabled {
                            let mandatoryStops = stops.filter { stop in
                                self.state.waypoints.contains(where: { $0.id == stop.id })
                            }
                            routes = try await self.calculateEVRoutes(
                                from: location, to: destination,
                                explicitStops: mandatoryStops, provider: provider,
                                avoiding: excluded, commitChargingStops: false)
                        } else {
                            routes = try await provider.calculateRoutes(
                                from: location, to: destination,
                                through: routedStops.map(\.coordinate), mode: .car,
                                preferences: self.state.routingPreferences,
                                avoiding: excluded)
                        }
                        guard self.rerouteController.isCurrent(generation),
                              self.state.status == .rerouting,
                              self.state.route?.id == routeID,
                              self.state.destination?.id == destinationID else { return }
                        guard let alternative = routes.first(where: { candidate in
                            let geometry = RouteProgressGeometry(candidate)
                            return !excluded.contains { coordinate in
                                guard let projection = geometry.project(coordinate) else { return false }
                                return projection.distanceFromRoute < 30
                            }
                        }) else { throw RoutingError.invalidResponse }
                        if self.state.routingPreferences.evPlanningEnabled {
                            let chargingStops = alternative.chargingStops.map(\.destination)
                            let chargingTargets = await POIAccessResolver.shared.resolveMany(
                                for: chargingStops, mode: .car)
                            guard self.rerouteController.isCurrent(generation),
                                  self.state.status == .rerouting,
                                  self.state.route?.id == routeID,
                                  self.state.destination?.id == destinationID else { return }
                            self.state.evChargingStops = chargingStops
                            for (stop, target) in zip(chargingStops, chargingTargets) where stop.poi != nil {
                                self.state.waypointNavigationTargets[stop.id] = target
                            }
                        } else {
                            self.clearEVChargingStops()
                        }
                        self.state.route = alternative
                        self.state.routeOptions = routes
                        self.state.pendingWaypointIDs = []
                        self.rerouteController.markClosureRerouted(closureIncident.id)
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
                        self.state.errorMessage = "Nie udało się ominąć zgłoszonego zamknięcia: \(error.localizedDescription)"
                        self.rerouteController.scheduleClosureRetry(closureIncident.id, after: 60)
                    }
                }
            }
        })
    }

    func confirmedClosureAhead(in snapshot: TrafficSnapshot, on route: NavigationRoute,
                                       progress: RouteProgress?) -> TrafficIncident? {
        let traveledDistance = progress?.traveledDistance ?? 0
        let lookAheadEnd = traveledDistance + RouteTrafficMonitor.lookAheadDistance(for: route, progress: progress)
        return snapshot.incidents.compactMap { incident -> (TrafficIncident, Double)? in
            let updatedAt = incident.distanceAlongRoute != nil
                ? routeTrafficUpdatedAt
                : latestNearbyTrafficSnapshot?.updatedAt
            guard let updatedAt, Date().timeIntervalSince(updatedAt) <= 120 else { return nil }
            guard incident.isRoadClosure,
                  let distance = closureDistanceAlongRoute(for: incident, on: route),
                  distance > traveledDistance + 100,
                  distance < lookAheadEnd else { return nil }
            return (incident, distance)
        }.min { $0.1 < $1.1 }?.0
    }

    private func closureDistanceAlongRoute(for incident: TrafficIncident,
                                           on route: NavigationRoute) -> Double? {
        if let alongRoute = incident.distanceAlongRoute { return alongRoute }
        let geometry = incident.geometry.isEmpty ? [incident.coordinate] : incident.geometry
        guard let projection = geometry.compactMap({
            routeProgressTracker.projectRoadCoordinate(route: route, coordinate: $0)
        })
            .min(by: { $0.distanceFromRoute < $1.distanceFromRoute }),
              projection.distanceFromRoute <= RouteTrafficMonitor.routeMatchToleranceMeters else { return nil }
        return projection.alongRoute
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
