import Foundation

extension NavigationSession {
    private func clearRerouteErrorIfNeeded() {
        guard let message = state.errorMessage,
              message.hasPrefix("Nie udało się przeliczyć trasy:") ||
                message.hasPrefix("Nie udało się ominąć zgłoszonego zamknięcia:") else { return }
        state.errorMessage = nil
    }

    func reroute(from origin: Coordinate) async {
        guard let destination = state.destination else { return }
        let generation = rerouteController.beginManualReroute()
        state.status = .rerouting
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
                let chargingStops = firstRoute.chargingStops.map(\.destination)
                let chargingTargets = await POIAccessResolver.shared.resolveMany(
                    for: chargingStops, mode: .car)
                guard rerouteController.isCurrent(generation), state.status == .rerouting,
                      state.destination?.id == destination.id else { return }
                state.evChargingStops = chargingStops
                for (stop, target) in zip(chargingStops, chargingTargets) where stop.poi != nil {
                    state.waypointNavigationTargets[stop.id] = target
                }
            }
            state.route = firstRoute; state.routeOptions = routes
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
        let stops = state.waypoints + state.evChargingStops
        guard let route = state.route,
              let current = MapMatcher.project(origin, onto: route.coordinates) else { return stops }
        return stops.compactMap { stop -> (Destination, Double)? in
            let coordinate = state.waypointNavigationTargets[stop.id]?.coordinate ?? stop.coordinate
            guard let projection = MapMatcher.project(coordinate, onto: route.coordinates),
                  projection.alongRoute > current.alongRoute + 50 else { return nil }
            return (stop, projection.alongRoute)
        }.sorted { $0.1 < $1.1 }.map { $0.0 }
    }
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate]? = nil,
                                 commitEVStops: Bool = true) async throws -> [NavigationRoute] {
        if state.transportMode == .transit {
            return try await transitProvider.calculateRoutes(from: from, to: to,
                                                            departingAt: Date())
        }
        if state.transportMode == .parkRide {
            return try await calculateParkRideRoutes(from: from, to: to)
        }
        let routedWaypoints = await routedDestinations(state.waypoints, mode: state.transportMode)
        let routedEVStops = await routedDestinations(state.evChargingStops, mode: state.transportMode)
        let originalStops = state.waypoints + state.evChargingStops
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
        let poiIndexes = destinations.indices.filter { destinations[$0].poi != nil }
        let targets = await POIAccessResolver.shared.resolveMany(
            for: poiIndexes.map { destinations[$0] }, mode: mode)
        var routed = destinations
        for (offset, index) in poiIndexes.enumerated() {
            guard let target = targets[offset] else {
                // A missing access target leaves this copy at the original POI coordinate for Valhalla.
                state.waypointNavigationTargets[destinations[index].id] = nil
                continue
            }
            routed[index].coordinate = target.coordinate
            if state.waypoints.contains(where: { $0.id == destinations[index].id }) ||
                state.evChargingStops.contains(where: { $0.id == destinations[index].id }) {
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
        let departure = state.journeyTimeMode == .departAt ? state.journeyTargetTime : Date()
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
            route = try await transitProvider.calculateRoutes(from: origin, to: target,
                                                               departingAt: departure).first
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
                                 parkRideCarTarget: Coordinate? = nil) async throws -> [NavigationRoute] {
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
        var uniqueParkings: [String: NearbyPlaceCandidate] = [:]
        for parking in (corridorCandidates ?? []) + (destinationCandidates ?? []) {
            uniqueParkings[parking.id] = parking
        }
        parkings = Array(uniqueParkings.values).sorted {
            to.distance(to: $0.destination.coordinate) < to.distance(to: $1.destination.coordinate)
        }
        guard !parkings.isEmpty else { throw TransitRoutingError.noParkRide }
        let selectedParkings = Array(parkings.prefix(12))
        let parkingTargets = await POIAccessResolver.shared.resolveMany(
            for: selectedParkings.map(\.destination), mode: .car)
        try Task.checkCancellation()
        let departure = requestedDeparture
        var combined: [NavigationRoute] = []
        for index in selectedParkings.indices {
            try Task.checkCancellation()
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
            guard let carRoute = carRoutes.first else { continue }
            let parkingArrival = departure.addingTimeInterval(carRoute.expectedTravelTime)
            let transitRoutes: [NavigationRoute]
            do {
                transitRoutes = try await transitProvider.calculateRoutes(
                    from: parkingTarget, to: to, departingAt: parkingArrival)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
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
                                     waitingDuration: journey.waitingDuration,
                                     transferCount: journey.transferCount,
                                     realtimeFreshness: journey.realtimeFreshness)
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
        let destinationTarget: Coordinate
        if let destination = state.destination, destination.poi != nil {
            destinationTarget = destinationRouteCoordinate(for: destination)
        } else {
            destinationTarget = to
        }
        let routedExplicitStops = await routedDestinations(explicitStops, mode: .car)
        let preferences = state.routingPreferences
        guard preferences.evRangeKilometers > 0 else { throw EVPlanningError.rangeNotConfigured }
        guard preferences.evConsumptionKWhPer100Km > 0,
              preferences.evMaximumChargingPowerKW > 0 else {
            throw EVPlanningError.consumptionNotConfigured
        }
        let baseRoutes = try await provider.calculateRoutes(from: from, to: destinationTarget,
                                                            through: routedExplicitStops.map(\.coordinate), mode: .car,
                                                            preferences: preferences, avoiding: avoiding)
        guard let baseRoute = baseRoutes.first else { throw RoutingError.invalidResponse }
        let availableRange = preferences.availableEVRangeKilometers * 1_000
        let fullRange = preferences.evRangeKilometers * 1_000
        guard availableRange > 0, fullRange > 0 else { throw EVPlanningError.rangeNotConfigured }
        let baseLength = zip(baseRoute.coordinates, baseRoute.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard baseLength > 0 else { throw RoutingError.invalidResponse }
        guard baseLength > availableRange * 0.8 else {
            if commitChargingStops { state.evChargingStops = [] }
            return baseRoutes
        }

        let chargers = try await OpenStreetMapNearbyPlaceProvider().search(.charging, along: baseRoute.coordinates,
                                                                           radius: 1_200)
        let eligibleChargers = chargers.filter { candidate in
            guard let station = candidate.chargingStation,
                  station.availability != .unavailable,
                  station.publicAccess != false,
                  let power = station.maximumPowerKW, power > 0,
                  !station.connectorTypes.isEmpty else { return false }
            guard !preferences.evConnectorTypes.isEmpty else { return true }
            let stationConnectors = Set(station.connectorTypes)
            return preferences.evConnectorTypes.contains { selected in
                switch selected {
                case "ccs": stationConnectors.contains("ccs") || stationConnectors.contains("type2_combo")
                case "type2": stationConnectors.contains("type2") || stationConnectors.contains("type2_combo")
                default: stationConnectors.contains(selected)
                }
            }
        }.sorted { $0.distanceFromRoute < $1.distanceFromRoute }
        var selected: [NearbyPlaceCandidate] = []
        var progress = 0.0
        var segmentRange = availableRange
        while baseLength - progress > segmentRange * 0.8 {
            let limit = progress + segmentRange * 0.68
            let selectedIDs = Set(selected.map(\.id))
            let reachable = eligibleChargers.filter { candidate in
                candidate.distanceFromRoute > progress + 300 && candidate.distanceFromRoute <= limit &&
                    !selectedIDs.contains(candidate.id)
            }
            guard let furthestProgress = reachable.map(\.distanceFromRoute).max() else {
                throw EVPlanningError.chargersUnavailable
            }
            let nearFurthest = reachable.filter { furthestProgress - $0.distanceFromRoute <= 1_000 }
            guard let next = nearFurthest.max(by: {
                ($0.chargingStation?.maximumPowerKW ?? 0) < ($1.chargingStation?.maximumPowerKW ?? 0)
            }) else { throw EVPlanningError.chargersUnavailable }
            selected.append(next)
            progress = next.distanceFromRoute
            segmentRange = fullRange
            if selected.count > 10 { throw EVPlanningError.chargersUnavailable }
        }
        let routedChargingStops = await routedDestinations(selected.map(\.destination), mode: .car)
        let orderedStops = (routedExplicitStops.map { destination -> (Coordinate, Double) in
            let along = MapMatcher.project(destination.coordinate, onto: baseRoute.coordinates)?.alongRoute ?? .infinity
            return (destination.coordinate, along)
        } + selected.indices.map { index in
            (routedChargingStops[index].coordinate, selected[index].distanceFromRoute)
        })
            .sorted { $0.1 < $1.1 }
        let routes = try await provider.calculateRoutes(from: from, to: destinationTarget,
                                                        through: orderedStops.map { $0.0 },
                                                        mode: .car, preferences: preferences, avoiding: avoiding)
        var energyFeasible: [NavigationRoute] = []
        for var route in routes {
            guard let chargePlan = evChargePlan(on: route, chargingCandidates: selected,
                                                fullRange: fullRange, initialRange: availableRange,
                                                consumptionKWhPer100Km: preferences.evConsumptionKWhPer100Km,
                                                vehicleMaximumPowerKW: preferences.evMaximumChargingPowerKW) else {
                continue
            }
            route.chargingStops = chargePlan.stops
            route.chargingDuration = chargePlan.duration
            route.expectedTravelTime += chargePlan.duration
            energyFeasible.append(route)
        }
        guard !energyFeasible.isEmpty else { throw EVPlanningError.chargersUnavailable }
        let rankedRoutes = energyFeasible.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
        if commitChargingStops {
            state.evChargingStops = rankedRoutes[0].chargingStops.map(\.destination)
            _ = await routedDestinations(state.evChargingStops, mode: .car)
        }
        return rankedRoutes
    }

    private func evChargePlan(on route: NavigationRoute, chargingCandidates: [NearbyPlaceCandidate],
                              fullRange: Double, initialRange: Double,
                              consumptionKWhPer100Km: Double,
                              vehicleMaximumPowerKW: Double) -> (stops: [EVChargingStop], duration: TimeInterval)? {
        let routeLength = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard routeLength > 0 else { return nil }
        let stations = chargingCandidates.compactMap { candidate -> (NearbyPlaceCandidate, Double, ChargingStationCapabilities)? in
            guard let station = candidate.chargingStation,
                  let projection = MapMatcher.project(candidate.destination.coordinate, onto: route.coordinates),
                  projection.distanceFromRoute <= 1_500,
                  station.maximumPowerKW != nil else { return nil }
            return (candidate, projection.alongRoute, station)
        }.sorted { $0.1 < $1.1 }
        guard !stations.isEmpty else { return nil }
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
            let energyKWh = addedRange / 1_000 / 100 * consumptionKWhPer100Km
            let chargingTime = energyKWh / acceptedPower * 3_600
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
        state.status = .rerouting
        if state.cameraState != .freeLook {
            state.cameraState = .rerouting
            updateCameraIntent()
        }
        rerouteController.setAutomaticClosureTask(Task { @MainActor [weak self] in
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
                        avoiding: [closureIncident.coordinate], commitChargingStops: false)
                } else {
                    routes = try await provider.calculateRoutes(
                        from: location, to: destination,
                        through: routedStops.map(\.coordinate), mode: .car,
                        preferences: self.state.routingPreferences,
                        avoiding: [closureIncident.coordinate])
                }
                guard self.rerouteController.isCurrent(generation),
                      self.state.status == .rerouting,
                      self.state.route?.id == routeID,
                      self.state.destination?.id == destinationID else { return }
                guard let alternative = routes.first else { throw RoutingError.invalidResponse }
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
                }
                self.state.route = alternative
                self.state.routeOptions = routes
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
        guard let projection = geometry.compactMap({ MapMatcher.project($0, onto: route.coordinates) })
            .min(by: { $0.distanceFromRoute < $1.distanceFromRoute }),
              projection.distanceFromRoute <= RouteTrafficMonitor.routeMatchToleranceMeters else { return nil }
        return projection.alongRoute
    }
}
