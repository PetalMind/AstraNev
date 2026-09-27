import Foundation

extension NavigationSession {
    func searchNearbyPlaces(_ category: NearbyPlaceCategory, nearDestination: Bool = false,
                            searchRadius: Double = 5_000, resultLimit: Int = 25) async {
        let searchID = UUID()
        nearbySearchID = searchID
        state.nearbySuggestions = []
        let destination = state.destination
        guard !nearDestination || destination != nil else {
            state.nearbyStatus = .unavailable("Najpierw wybierz cel podróży.")
            return
        }
        let current = state.location?.coordinate
        let isNavigating = state.status == .navigating || state.status == .rerouting
        let nearestSearch = !nearDestination && !isNavigating
        var coordinates = state.route?.coordinates ?? []
        if isNavigating && !nearDestination {
            guard let current, let projection = MapMatcher.project(current, onto: coordinates) else {
                state.nearbyStatus = .unavailable("Czekam na pozycję GPS na aktywnej trasie.")
                return
            }
            coordinates = [projection.coordinate] + Array(coordinates.dropFirst(projection.segment + 1))
        }
        guard nearDestination || nearestSearch || coordinates.count > 1 else {
            state.nearbyStatus = .unavailable("Najpierw wyznacz trasę, aby znaleźć miejsca po drodze.")
            return
        }
        guard !nearestSearch || current != nil else {
            state.nearbyStatus = .unavailable("Poczekaj na ustalenie pozycji GPS i spróbuj ponownie.")
            return
        }
        let preferences = state.routingPreferences
        let pendingStopDestinations = current.map { unvisitedStops(from: $0) } ?? []
        state.nearbyStatus = .searching
        do {
            let candidates: [NearbyPlaceCandidate]
            if nearDestination, let destination {
                candidates = try await NearbyPlaceSearchProvider().search(
                    category, around: destination.coordinate, radius: 2_000, resultLimit: resultLimit)
            } else if nearestSearch, let current {
                candidates = try await NearbyPlaceSearchProvider().search(
                    category, around: current, radius: searchRadius, resultLimit: resultLimit)
            } else {
                candidates = try await OpenStreetMapNearbyPlaceProvider()
                    .search(category, along: coordinates, radius: 1_500)
            }
            try Task.checkCancellation()
            guard nearbySearchID == searchID else { return }
            state.nearbySuggestions = candidates.enumerated().map { index, candidate in
                RouteStopSuggestion(candidate: candidate,
                                    estimateStatus: nearestSearch && index < 8 ? .calculating : .unavailable)
            }
            state.nearbyStatus = .available
            if nearestSearch {
                guard let current, !candidates.isEmpty else { return }
                await estimateNearbyTravel(for: Array(candidates.prefix(8)), from: current,
                                           preferences: state.routingPreferences, searchID: searchID)
                return
            }
            guard !nearestSearch, !candidates.isEmpty, let destination, let current, state.transportMode == .car,
                  let provider = routeProvider as? AdvancedRouteProvider else { return }
            let destinationCoordinate = destinationRouteCoordinate(for: destination)
            let pendingStops = await routedDestinations(pendingStopDestinations, mode: .car).map(\.coordinate)
            let selected = Array(candidates.prefix(8))
            for index in selected.indices { state.nearbySuggestions[index].estimateStatus = .calculating }
            let resolvedSelected = await POIAccessResolver.shared.resolveMany(
                for: selected.map(\.destination), mode: .car)
            try Task.checkCancellation()
            guard nearbySearchID == searchID else { return }
            let routedSelected: [(selectedIndex: Int, candidate: NearbyPlaceCandidate, coordinate: Coordinate)] =
                selected.indices.compactMap { index in
                    if selected[index].destination.poi != nil {
                        return (index, selected[index], resolvedSelected[index]?.coordinate
                                ?? selected[index].destination.coordinate)
                    }
                    return (index, selected[index], selected[index].destination.coordinate)
                }
            guard !routedSelected.isEmpty else { return }
            do {
                if pendingStops.isEmpty, let matrix = provider as? ValhallaRouteProvider {
                    let targets = routedSelected.map { $0.coordinate }
                    async let outbound = matrix.searchMatrix(sources: [current], targets: targets + [destinationCoordinate],
                                                              mode: .car, preferences: preferences)
                    async let onward = matrix.searchMatrix(sources: targets, targets: [destinationCoordinate],
                                                           mode: .car, preferences: preferences)
                    let (first, second) = try await (outbound, onward)
                    try Task.checkCancellation()
                    guard nearbySearchID == searchID else { return }
                    if let baseline = first[0][targets.count].time {
                        for (rowIndex, routed) in routedSelected.enumerated() {
                            if let arrival = first[0][rowIndex].time,
                               let continuation = second[rowIndex][0].time {
                                state.nearbySuggestions[routed.selectedIndex].detourSeconds =
                                    max(0, arrival + continuation - baseline)
                            }
                        }
                    }
                } else {
                    let baseline = try await provider.calculateRoutes(from: current, to: destinationCoordinate,
                        through: pendingStops, mode: .car, preferences: preferences, avoiding: []).first?.expectedTravelTime
                    if let baseline {
                        // Limit server load while letting independent estimates complete together.
                        for start in stride(from: 0, to: routedSelected.count, by: 3) {
                            try Task.checkCancellation()
                            guard nearbySearchID == searchID else { return }
                            await withTaskGroup(of: (Int, Double?).self) { group in
                            for index in start..<min(start + 3, routedSelected.count) {
                                    let routed = routedSelected[index]
                                    group.addTask { @MainActor in
                                        do {
                                            let first = try await provider.calculateRoutes(from: current,
                                                to: routed.coordinate, through: nearDestination ? pendingStops : [],
                                                mode: .car, preferences: preferences, avoiding: []).first
                                            let second = nearDestination ? 0 : try await provider.calculateRoutes(
                                                from: routed.coordinate, to: destinationCoordinate,
                                                through: pendingStops, mode: .car, preferences: preferences, avoiding: []).first?.expectedTravelTime
                                            guard let first, let second else { return (index, nil) }
                                            return (index, max(0, first.expectedTravelTime + second - baseline))
                                        } catch { return (index, nil) }
                                    }
                                }
                                for await (index, detour) in group {
                                    guard nearbySearchID == searchID, !Task.isCancelled else { continue }
                                    let selectedIndex = routedSelected[index].selectedIndex
                                    state.nearbySuggestions[selectedIndex].detourSeconds = detour
                                    state.nearbySuggestions[selectedIndex].estimateStatus =
                                        detour == nil ? .unavailable : .notRequested
                                }
                            }
                        }
                    }
                }
            } catch {
                // A routing failure must never discard places already found.
            }
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
            for index in state.nearbySuggestions.indices {
                state.nearbySuggestions[index].estimateStatus = state.nearbySuggestions[index].detourSeconds == nil ? .unavailable : .notRequested
            }
            state.nearbySuggestions.sort { lhs, rhs in
                switch (lhs.detourSeconds, rhs.detourSeconds) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.candidate.distanceFromRoute < rhs.candidate.distanceFromRoute
                }
            }
        } catch {
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
            state.nearbyStatus = .unavailable(error.localizedDescription)
        }
    }

    func estimateNearbyTravel(for candidateID: String) async {
        guard let origin = state.location?.coordinate,
              let suggestion = state.nearbySuggestions.first(where: { $0.id == candidateID }),
              (suggestion.travelTime == nil || suggestion.travelDistance == nil) else { return }
        await estimateNearbyTravel(for: [suggestion.candidate], from: origin,
                                   preferences: state.routingPreferences, searchID: nearbySearchID)
    }

    private func estimateNearbyTravel(for candidates: [NearbyPlaceCandidate], from origin: Coordinate,
                                      preferences: RoutingPreferences, searchID: UUID) async {
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            for index in state.nearbySuggestions.indices {
                state.nearbySuggestions[index].estimateStatus = .unavailable
            }
            return
        }
        for candidate in candidates {
            guard let index = state.nearbySuggestions.firstIndex(where: { $0.id == candidate.id }) else { continue }
            state.nearbySuggestions[index].estimateStatus = .calculating
        }
        do {
            let poiIndexes = candidates.indices.filter { candidates[$0].destination.poi != nil }
            let poiDestinations = poiIndexes.map { candidates[$0].destination }
            let resolvedPOIs = await POIAccessResolver.shared.resolveMany(for: poiDestinations, mode: .car)
            try Task.checkCancellation()
            guard nearbySearchID == searchID else { return }
            var poiCoordinates: [Int: Coordinate] = [:]
            for (offset, index) in poiIndexes.enumerated() {
                poiCoordinates[index] = resolvedPOIs[offset]?.coordinate
                    ?? candidates[index].destination.coordinate
            }
            let routedCandidates: [(index: Int, candidate: NearbyPlaceCandidate, coordinate: Coordinate)] =
                candidates.indices.compactMap { index in
                    if candidates[index].destination.poi != nil {
                        return (index, candidates[index], poiCoordinates[index]
                                ?? candidates[index].destination.coordinate)
                    }
                    return (index, candidates[index], candidates[index].destination.coordinate)
                }
            guard !routedCandidates.isEmpty else { return }
            if let matrix = routeProvider as? ValhallaRouteProvider {
                let rows = try await matrix.searchMatrix(sources: [origin],
                    targets: routedCandidates.map { $0.coordinate }, mode: .car,
                    preferences: preferences)
                try Task.checkCancellation()
                guard nearbySearchID == searchID else { return }
                for (rowIndex, routed) in routedCandidates.enumerated() {
                    let estimate = rows[0][rowIndex]
                    guard let suggestionIndex = state.nearbySuggestions.firstIndex(where: { $0.id == routed.candidate.id }) else { continue }
                    state.nearbySuggestions[suggestionIndex].travelTime = estimate.time
                    state.nearbySuggestions[suggestionIndex].travelDistance = estimate.distance.map { $0 * 1_000 }
                }
            } else {
                for start in stride(from: 0, to: routedCandidates.count, by: 3) {
                    try Task.checkCancellation()
                    guard nearbySearchID == searchID else { return }
                    await withTaskGroup(of: (Int, TimeInterval?, Double?).self) { group in
                        for index in start..<min(start + 3, routedCandidates.count) {
                            let routed = routedCandidates[index]
                            group.addTask { @MainActor in
                                do {
                                    let route = try await provider.calculateRoutes(from: origin,
                                        to: routed.coordinate, through: [], mode: .car,
                                        preferences: preferences, avoiding: []).first
                                    return (index, route?.expectedTravelTime, route?.distance)
                                } catch {
                                    return (index, nil, nil)
                                }
                            }
                        }
                        for await (index, travelTime, travelDistance) in group {
                            guard nearbySearchID == searchID, !Task.isCancelled else { continue }
                            guard let suggestionIndex = state.nearbySuggestions.firstIndex(where: {
                                $0.id == routedCandidates[index].candidate.id
                            }) else { continue }
                            state.nearbySuggestions[suggestionIndex].travelTime = travelTime
                            state.nearbySuggestions[suggestionIndex].travelDistance = travelDistance
                        }
                    }
                }
            }
        } catch {
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
        }
        guard nearbySearchID == searchID, !Task.isCancelled else { return }
        for candidate in candidates {
            guard let index = state.nearbySuggestions.firstIndex(where: { $0.id == candidate.id }) else { continue }
            let suggestion = state.nearbySuggestions[index]
            state.nearbySuggestions[index].estimateStatus = suggestion.travelTime != nil && suggestion.travelDistance != nil
                ? .notRequested : .unavailable
        }
    }

    func selectNearbyPlace(_ destination: Destination, asFinalParking: Bool) async {
        let active = state.status == .navigating || state.status == .rerouting
        if !active && !asFinalParking {
            state.waypoints = []
            state.evChargingStops = []
            state.waypointNavigationTargets = [:]
            state.pendingWaypointIDs = []
            await preview(destination)
            return
        }
        if asFinalParking {
            if active, let location = state.location?.coordinate {
                let previousDestinationID = state.destination?.id
                let targets = await resolveAccessTargets(for: destination, mode: state.transportMode)
                guard (state.status == .navigating || state.status == .rerouting),
                      state.destination?.id == previousDestinationID else { return }
                state.destination = destination
                state.navigationTarget = targets.navigation
                state.parkRideCarTarget = targets.parkRideCar
                state.evChargingStops = []
                state.waypointNavigationTargets = [:]
                tripSession?.destination = destination
                await reroute(from: location)
            } else {
                state.evChargingStops = []
                state.waypointNavigationTargets = [:]
                await preview(destination)
            }
            return
        }
        if active {
            await addWaypoint(destination)
        } else {
            await preview(destination)
        }
    }

}
