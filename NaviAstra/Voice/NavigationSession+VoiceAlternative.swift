#if os(iOS)
import Foundation

enum VoiceAlternativeRouteError: LocalizedError {
    case unavailable, noAlternative, stale, location, transit

    var errorDescription: String? {
        switch self {
        case .unavailable: "Nie mogę teraz obliczyć innej trasy. Bieżąca trasa i postoje pozostają bez zmian."
        case .noAlternative: "Nie znalazłam innej trasy, która zachowuje cel i wszystkie pozostałe postoje."
        case .stale: "Propozycja trasy jest już nieaktualna. Powiedz ponownie „inna trasa”, aby obliczyć ją z aktualnej pozycji."
        case .location: "Czekam na aktualną, dokładną pozycję GPS, aby zaproponować inną trasę."
        case .transit: "Podczas przejazdu komunikacją miejską nie mogę głosowo zmienić połączenia."
        }
    }
}

/// A proposal is an isolated calculation, never a live route option until the
/// driver accepts it. The plan and geometry are checked again at that boundary.
@MainActor
struct VoiceAlternativeRouteProposal {
    let route: NavigationRoute
    let additionalChargingStops: [Destination]
    let plan: VoicePlanSnapshot
    let rerouteGeneration: Int
    let remainingStops: [Destination]
    let stopTargets: [Coordinate]
    let navigationTargets: [UUID: POINavigationTarget]
    let chargingTargets: [Coordinate]
    let requiredEnergyStop: Coordinate?
    var createdAt: Date
}

extension NavigationSession {
    func voiceAlternativeRoute() async throws -> VoiceAlternativeRouteProposal {
        try Task.checkCancellation()
        guard state.transportMode != .transit else { throw VoiceAlternativeRouteError.transit }
        guard state.status == .navigating, let current = state.route,
              let destination = state.destination else { throw VoiceAlternativeRouteError.unavailable }
        guard let location = voiceEditingLocation,
              voiceAlternativeProjection(on: current, location: location) != nil else {
            throw VoiceAlternativeRouteError.location
        }
        let plan = VoicePlanSnapshot(self)
        let rerouteGeneration = rerouteController.generation
        let remaining = unvisitedStops(from: location.coordinate)
        let createdAt = Date()
        let quote = makeVoiceQuoteSession(preferences: state.routingPreferences, removingWaypointID: nil)
        // EV routing normally reselects automatic chargers. Treat every existing
        // remaining stop as mandatory here, in its original route order, so a
        // proposed alternative cannot quietly remove a scheduled charging visit.
        quote.state.waypoints = remaining
        quote.state.evChargingStops = []
        let cancellation = TransitPlanningCancellationToken()
        do {
            let routes = try await withTaskCancellationHandler {
                try await RoadRoutingContext.$cancellationToken.withValue(cancellation) {
                    try await RoadRoutingContext.$planningTime.withValue(nil) {
                        try await RoadRoutingContext.$preferenceDate.withValue(nil) {
                            try await RoadRoutingContext.$publishesAssessments.withValue(false) {
                                try await quote.calculateRoutes(from: location.coordinate,
                                    to: quote.destinationRouteCoordinate(for: destination),
                                    through: remaining.map(\.coordinate), commitEVStops: false,
                                    publishDiagnostics: false)
                            }
                        }
                    }
                }
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            let targets = remaining.map { quote.state.waypointNavigationTargets[$0.id]?.coordinate ?? $0.coordinate }
            let oldCharging = current.chargingStops.filter { stop in
                remaining.contains { $0.id == stop.destination.id }
            }
            for calculated in routes {
                guard calculated.id != current.id,
                      calculated.coordinates.first.map({ $0.distance(to: location.coordinate) <= 100 }) == true else { continue }
                quote.commitEVChargingStops(for: calculated)
                let chargingTargets = calculated.chargingStops.map { $0.navigationTarget?.coordinate ?? $0.destination.coordinate }
                var route = calculated
                let missingCharges = oldCharging.filter { old in
                    !route.chargingStops.contains { new in
                        new.id == old.id || new.destination.id == old.destination.id ||
                        new.destination.coordinate.distance(to: old.destination.coordinate) <= 20
                    }
                }
                // The energy planner's result stays authoritative; retaining a
                // previously planned visit must also retain its spoken time cost.
                route.chargingStops += missingCharges
                let retainedDuration = missingCharges.reduce(0) { $0 + $1.estimatedChargingTime }
                route.chargingDuration += retainedDuration
                route.expectedTravelTime += retainedDuration
                route.trafficPreviewEstimate = nil
                let geometry = RouteProgressGeometry(route)
                route.chargingStops.sort {
                    (geometry.nearestProjection(to: $0.destination.coordinate)?.alongRoute ?? .infinity) <
                    (geometry.nearestProjection(to: $1.destination.coordinate)?.alongRoute ?? .infinity)
                }
                let additional = calculated.chargingStops.filter { charging in
                    !oldCharging.contains { $0.id == charging.id } &&
                    !remaining.contains { $0.id == charging.destination.id ||
                        $0.coordinate.distance(to: charging.destination.coordinate) <= 20 }
                }.map(\.destination)
                let proposal = VoiceAlternativeRouteProposal(route: route, additionalChargingStops: additional,
                    plan: plan, rerouteGeneration: rerouteGeneration, remainingStops: remaining,
                    stopTargets: targets, navigationTargets: quote.state.waypointNavigationTargets,
                    chargingTargets: chargingTargets,
                    requiredEnergyStop: chargingTargets.first,
                    createdAt: createdAt)
                // Plan invalidation is a stale proposal, not a provider failing
                // to supply a distinct alternative.
                try validateVoiceAlternativePlan(proposal)
                guard let freshLocation = voiceEditingLocation,
                      voiceAlternativeGeometryIsUsable(proposal, location: freshLocation) else { continue }
                guard voiceAlternativeAvoidsClosures(route) else { continue }
                return proposal
            }
            try validateVoiceAlternativePlan(VoiceAlternativeRouteProposal(route: current,
                additionalChargingStops: [], plan: plan, rerouteGeneration: rerouteGeneration,
                remainingStops: remaining, stopTargets: targets, navigationTargets: [:],
                chargingTargets: [], requiredEnergyStop: nil, createdAt: createdAt))
            throw VoiceAlternativeRouteError.noAlternative
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? VoiceAlternativeRouteError { throw error }
            throw VoiceAlternativeRouteError.unavailable
        }
    }

    func applyVoiceAlternativeRoute(_ proposal: VoiceAlternativeRouteProposal) async throws {
        try Task.checkCancellation()
        try validateVoiceAlternativePlan(proposal)
        guard let location = voiceEditingLocation else { throw VoiceAlternativeRouteError.location }
        guard voiceAlternativeGeometryIsUsable(proposal, location: location) else {
            throw VoiceAlternativeRouteError.stale
        }
        guard voiceAlternativeAvoidsClosures(proposal.route) else { throw VoiceAlternativeRouteError.stale }
        // No suspension follows these checks: accepting the proposal is one
        // atomic main-actor transition, without ending/restarting trip recording.
        roadRerouteCancellationToken?.cancel()
        roadRerouteCancellationToken = nil
        rerouteController.beginManualReroute()
        rerouteController.recordRerouteRequest()
        invalidateTraffic()
        lastTrafficComparison = Date()
        lastTrafficCandidateRefresh = Date()
        invalidateSpeedLimit()
        arrivalDetector.reset()
        resetOffRouteEvidence()
        routeProgressTracker.invalidateGeometries()
        previousRouteMatch = nil
        state.routeMatch = nil
        state.mapMatchingResult = nil
        state.route = proposal.route
        state.routeOptions = [proposal.route]
        // A completed stop must not become pending again merely because the
        // new road passes near it later. Keep the full history in tripSession.
        let remainingIDs = Set(proposal.remainingStops.map(\.id))
        state.waypoints = proposal.plan.waypoints.filter { remainingIDs.contains($0.id) }
        let remainingEV = proposal.plan.evChargingStops.filter { stop in
            proposal.remainingStops.contains { $0.id == stop.id }
        }
        state.evChargingStops = remainingEV + proposal.additionalChargingStops
        for (id, target) in proposal.navigationTargets { state.waypointNavigationTargets[id] = target }
        // These priorities pin newly inserted stops only until their route is
        // calculated. Every such stop was validated in the accepted geometry.
        state.pendingWaypointIDs = []
        state.errorMessage = nil
        learningAllowsDeviations = false
        learningExplicitlySelectedRouteID = proposal.route.id
        tripSession?.rerouteCount += 1
        tripSession?.routeQuality.invalidateForPlanChange()
        voice.reset(preservingSpokenAnnouncements: true)
        if usesRoadVoiceGuidance { loadRoadData(for: proposal.route) }
        updateProgress()
        updateNavigationCameraState()
        updateCameraIntent()
        refreshEnergyPolicy()
        updateLiveActivity()
        if state.transportMode == .car { refreshTraffic(force: true) }
    }

    private func validateVoiceAlternativePlan(_ proposal: VoiceAlternativeRouteProposal) throws {
        let plan = proposal.plan
        guard (0...90).contains(Date().timeIntervalSince(proposal.createdAt)),
              state.status == .navigating, plan.status == .navigating,
              plan.matchesPlan(self), requestGeneration == plan.requestGeneration,
              rerouteController.isCurrent(proposal.rerouteGeneration),
              state.route?.id == plan.route?.id,
              state.navigationTarget == plan.navigationTarget,
              state.pendingWaypointIDs == plan.pendingWaypointIDs,
              state.evChargingStops == plan.evChargingStops,
              state.waypointNavigationTargets == plan.waypointNavigationTargets,
              tripSession?.destination == plan.tripDestination,
              tripSession?.waypoints == plan.tripWaypoints else { throw VoiceAlternativeRouteError.stale }
        guard let location = voiceEditingLocation else { throw VoiceAlternativeRouteError.location }
        guard unvisitedStops(from: location.coordinate) == proposal.remainingStops else {
            throw VoiceAlternativeRouteError.stale
        }
    }

    private func voiceAlternativeAvoidsClosures(_ route: NavigationRoute) -> Bool {
        knownRoadClosures.values.filter { $0.isFresh() }.allSatisfy { closure in
            guard let avoidance = try? closure.avoidance() else { return false }
            return !avoidance.intersects(route)
        }
    }

    private func voiceAlternativeProjection(on route: NavigationRoute, location: NavigationLocation) -> RouteProjection? {
        guard state.mapMatchingResult?.ambiguous != true else { return nil }
        let radius = max(25, min(50, location.accuracy * 1.5))
        let geometry = RouteProgressGeometry(route)
        let matches = geometry.projections(near: location.coordinate, within: radius)
            .filter { RoadRouteETA.canFollow(route, projection: $0, heading: routingHeading(from: location.coordinate)) }
        guard let best = matches.min(by: { $0.distanceFromRoute < $1.distanceFromRoute }),
              !matches.contains(where: { abs($0.alongRoute - best.alongRoute) > 100 &&
                  $0.distanceFromRoute <= best.distanceFromRoute + 10 }) else { return nil }
        return best
    }

    private func voiceAlternativeGeometryIsUsable(_ proposal: VoiceAlternativeRouteProposal,
                                                 location: NavigationLocation) -> Bool {
        let route = proposal.route
        guard route.coordinates.count >= 2, route.coordinates.allSatisfy(\.isValidParkedCarCoordinate),
              route.expectedTravelTime.isFinite, route.expectedTravelTime > 0,
              route.distance.isFinite, route.distance > 0,
              let current = state.route, let destination = state.destination,
              let originalProjection = voiceAlternativeProjection(on: current, location: location),
              let projection = voiceAlternativeProjection(on: route, location: location),
              let end = route.coordinates.last,
              end.distance(to: destinationRouteCoordinate(for: destination)) <= 100 else { return false }
        let geometry = RouteProgressGeometry(route)
        var previous = projection.alongRoute
        for coordinate in proposal.stopTargets {
            guard let next = geometry.projections(near: coordinate, within: 50)
                .filter({ $0.alongRoute >= previous - 5 })
                .min(by: { $0.alongRoute < $1.alongRoute }) else { return false }
            previous = next.alongRoute
        }
        var previousCharge = projection.alongRoute
        for coordinate in proposal.chargingTargets {
            guard let next = geometry.projections(near: coordinate, within: 50)
                .filter({ $0.alongRoute >= previousCharge - 5 })
                .min(by: { $0.alongRoute < $1.alongRoute }) else { return false }
            previousCharge = next.alongRoute
        }
        // Only future geometry counts. A different road already passed during
        // the spoken confirmation is not a reason to replace the current route.
        let oldGeometry = RouteProgressGeometry(current)
        let oldRemainder = NavigationRoute(coordinates: oldGeometry.corridor(from: originalProjection.alongRoute,
            through: oldGeometry.length), distance: 1, expectedTravelTime: 1, maneuvers: [])
        let newRemainder = NavigationRoute(coordinates: geometry.corridor(from: projection.alongRoute,
            through: geometry.length), distance: 1, expectedTravelTime: 1, maneuvers: [])
        guard oldRemainder.coordinates.count >= 2, newRemainder.coordinates.count >= 2,
              RouteSimilarity.overlap(oldRemainder, newRemainder) < 0.98 else { return false }
        if state.transportMode == .car, state.routingPreferences.evPlanningEnabled {
            let firstEnergyDistance: Double
            if let coordinate = proposal.requiredEnergyStop {
                guard let first = geometry.nearestProjection(to: coordinate),
                      first.alongRoute > projection.alongRoute else { return false }
                firstEnergyDistance = first.alongRoute - projection.alongRoute
            } else {
                firstEnergyDistance = geometry.length - projection.alongRoute
            }
            guard firstEnergyDistance <= availableEVRangeMeters(for: state.routingPreferences) * 0.8 else { return false }
        }
        return true
    }
}
#endif
