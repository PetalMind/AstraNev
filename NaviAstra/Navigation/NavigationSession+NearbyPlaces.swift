import Foundation
import OSLog

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
                    .search(category, along: coordinates, radius: searchRadius, resultLimit: resultLimit)
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
            let selected = Array(candidates.prefix(25))
            for index in selected.indices { state.nearbySuggestions[index].estimateStatus = .calculating }
            let resolvedSelected = await cachedNearbyAccessTargets(for: selected)
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
                    if let baseline = first.first?.last?.time, baseline.isFinite, baseline >= 0 {
                        for (rowIndex, routed) in routedSelected.enumerated() {
                            guard let row = first.first, row.indices.contains(rowIndex), second.indices.contains(rowIndex) else { continue }
                            let metric = RoutedTravelMetrics(time: row[rowIndex].time, distance: row[rowIndex].distance.map { $0 * 1_000 })
                            state.nearbySuggestions[routed.selectedIndex].travelTime = metric?.time
                            state.nearbySuggestions[routed.selectedIndex].travelDistance = metric?.distance
                            if let arrival = metric?.time,
                               let continuation = second[rowIndex].first?.time, continuation.isFinite, continuation >= 0 {
                                state.nearbySuggestions[routed.selectedIndex].detourSeconds =
                                    max(0, arrival + continuation - baseline)
                            }
                        }
                    }
                } else {
                    let baseline = try await provider.calculateRoutes(from: current, to: destinationCoordinate,
                        through: pendingStops, mode: .car, preferences: preferences, avoiding: []).first?.expectedTravelTime
                    if let baseline, baseline.isFinite, baseline >= 0 {
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
                                            guard let first, let second, second.isFinite, second >= 0,
                                                  let metric = RoutedTravelMetrics(time: first.expectedTravelTime, distance: first.distance) else { return (index, nil) }
                                            return (index, max(0, metric.time + second - baseline))
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
                case (nil, nil): lhs.id < rhs.id
                }
            }
        } catch {
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
            Logger(subsystem: "NaviAstra", category: "NearbyPlaces")
                .error("Wyszukiwanie miejsc nie powiodło się: \(String(describing: error), privacy: .private)")
            let message = (error as? NearbyPlaceError)?.errorDescription
                ?? "Wyszukiwanie miejsc jest chwilowo niedostępne. Spróbuj ponownie."
            state.nearbyStatus = .unavailable(message)
        }
    }

    func estimateNearbyTravel(for candidateID: String) async {
        guard let origin = state.location?.coordinate,
              let suggestion = state.nearbySuggestions.first(where: { $0.id == candidateID }),
              suggestion.estimateStatus != .calculating,
              (suggestion.travelTime == nil || suggestion.travelDistance == nil) else { return }
        await estimateNearbyTravel(for: [suggestion.candidate], from: origin,
                                   preferences: state.routingPreferences, searchID: nearbySearchID)
    }

    private func estimateNearbyTravel(for candidates: [NearbyPlaceCandidate], from origin: Coordinate,
                                      preferences: RoutingPreferences, searchID: UUID) async {
        let mode = state.transportMode
        for candidate in candidates {
            guard let index = state.nearbySuggestions.firstIndex(where: { $0.id == candidate.id }) else { continue }
            state.nearbySuggestions[index].estimateStatus = .calculating
        }
        do {
            let resolvedPOIs = await cachedNearbyAccessTargets(for: candidates, mode: mode)
            try Task.checkCancellation()
            guard nearbySearchID == searchID else { return }
            if mode != .transit, let matrix = routeProvider as? ValhallaRouteProvider {
                let coordinates = candidates.indices.map { index in
                    resolvedPOIs.indices.contains(index) ? resolvedPOIs[index]?.coordinate ?? candidates[index].destination.coordinate
                        : candidates[index].destination.coordinate
                }
                let rows = try await matrix.searchMatrix(sources: [origin], targets: coordinates,
                    mode: mode, preferences: preferences)
                try Task.checkCancellation()
                guard nearbySearchID == searchID else { return }
                for index in candidates.indices {
                    guard let suggestionIndex = state.nearbySuggestions.firstIndex(where: { $0.id == candidates[index].id }) else { continue }
                    let cell = rows.first.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                    let metric = RoutedTravelMetrics(time: cell?.time, distance: cell?.distance.map { $0 * 1_000 })
                    state.nearbySuggestions[suggestionIndex].travelTime = metric?.time
                    state.nearbySuggestions[suggestionIndex].travelDistance = metric?.distance
                }
            } else {
                for start in stride(from: 0, to: candidates.count, by: 3) {
                    try Task.checkCancellation()
                    guard nearbySearchID == searchID else { return }
                    await withTaskGroup(of: (Int, RoutedTravelMetrics?).self) { group in
                        for index in start..<min(start + 3, candidates.count) {
                            let destination = candidates[index].destination
                            group.addTask { @MainActor in
                                do {
                                    let estimate = try await self.estimatedSearchRoute(from: origin, to: destination, mode: mode)
                                    return (index, RoutedTravelMetrics(time: estimate?.travelTime, distance: estimate?.distanceMeters))
                                } catch { return (index, nil) }
                            }
                        }
                        for await (index, metric) in group {
                            guard nearbySearchID == searchID, !Task.isCancelled,
                                  let suggestionIndex = state.nearbySuggestions.firstIndex(where: { $0.id == candidates[index].id }) else { continue }
                            state.nearbySuggestions[suggestionIndex].travelTime = metric?.time
                            state.nearbySuggestions[suggestionIndex].travelDistance = metric?.distance
                            state.nearbySuggestions[suggestionIndex].estimateStatus = metric == nil ? .unavailable : .notRequested
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
            state.nearbySuggestions[index].estimateStatus =
                RoutedTravelMetrics(time: suggestion.travelTime, distance: suggestion.travelDistance) == nil ? .unavailable : .notRequested
        }
        state.nearbySuggestions.sort { lhs, rhs in
            if lhs.travelTime != rhs.travelTime { return (lhs.travelTime ?? .infinity) < (rhs.travelTime ?? .infinity) }
            if lhs.travelDistance != rhs.travelDistance { return (lhs.travelDistance ?? .infinity) < (rhs.travelDistance ?? .infinity) }
            return lhs.id < rhs.id
        }
    }

    private func cachedNearbyAccessTargets(for candidates: [NearbyPlaceCandidate], mode: TransportMode = .car) async -> [POINavigationTarget?] {
        // A list estimate uses Valhalla's road snapping or an already known access
        // point. Fetch full entrance geometry only for the place selected for routing.
        var targets: [POINavigationTarget?] = []
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            targets.append(await POIAccessResolver.shared.cachedTarget(for: candidate.destination, mode: mode == .transit ? .walking : mode))
        }
        return targets
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
                let targets = await resolveAccessTarget(for: destination, mode: state.transportMode)
                guard (state.status == .navigating || state.status == .rerouting),
                      state.destination?.id == previousDestinationID else { return }
                state.destination = destination
                state.navigationTarget = targets
                state.evChargingStops = []
                state.waypointNavigationTargets = [:]
                tripSession?.routeQuality.invalidateForPlanChange()
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
