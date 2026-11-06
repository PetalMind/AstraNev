#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

// Reuse the serialized voice suite because its fixtures temporarily change
// shared transport/offline preferences and restore them on close.
extension VoiceSavedNavigationCriticalTests {
    @Test
    func activeAlternativeWaitsForYesAndPreservesDestinationStopsAndRecording() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let provider = prepareActiveAlternative(fixture)
        let state = fixture.session.state
        let originalRoute = state.route
        let destination = state.destination
        let stops = state.waypoints
        let tripID = fixture.session.tripSession?.id
        let startedAt = fixture.session.tripSession?.startedAt

        await fixture.submit("Astra, znajdź inną trasę")

        #expect(fixture.assistant.canConfirm)
        #expect(state.route?.id == originalRoute?.id)
        #expect(state.status == .navigating)
        #expect(provider.requests.last?.stops == stops.map(\.coordinate))
        #expect(provider.requests.last?.destination == destination?.coordinate)
        guard case .activeAlternativeRoute(let proposal) = fixture.assistant.pending?.change else {
            Issue.record("Aktywna alternatywa musi czekać na głosowe potwierdzenie.")
            return
        }

        await fixture.submit("Tak")

        #expect(state.route?.id == proposal.route.id)
        #expect(state.status == .navigating)
        #expect(state.destination == destination)
        #expect(state.waypoints == stops)
        #expect(fixture.session.tripSession?.id == tripID)
        #expect(fixture.session.tripSession?.startedAt == startedAt)
        #expect(fixture.session.tripSession?.destination == destination)
        #expect(fixture.session.tripSession?.waypoints == stops)
        #expect(fixture.session.tripSession?.distanceMeters == 123)
        #expect(fixture.session.tripSession?.rerouteCount == 1)
        #expect(state.progress?.geometryRouteID == proposal.route.id)
        #expect(!fixture.assistant.canConfirm)
        #expect(provider.requests.count == 1)
    }

    @Test
    func activeAlternativeRoutesOnlyThroughUnvisitedStopsWithoutDeletingThePlan() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let provider = prepareActiveAlternative(fixture)
        provider.behavior = .passesVisitedStop
        let state = fixture.session.state
        let allStops = state.waypoints
        moveAlternativeDriver(fixture.session, to: .init(latitude: 52.0072, longitude: 21), alongRoute: 800)
        let origin = try #require(state.location?.coordinate)
        let proposal = try await fixture.session.voiceAlternativeRoute()

        #expect(provider.requests.last?.origin == origin)
        #expect(provider.requests.last?.stops == [allStops[1].coordinate])
        try await fixture.session.applyVoiceAlternativeRoute(proposal)

        #expect(state.route?.id == proposal.route.id)
        #expect(state.waypoints == [allStops[1]])
        #expect(fixture.session.tripSession?.waypoints == allStops)
        #expect(fixture.session.nextVoiceWaypoint?.id == allStops[1].id)
        // The alternative happens to pass the old stop again. A later reroute
        // still receives only the pending itinerary, not the full trip history.
        #expect(proposal.route.coordinates.contains(allStops[0].coordinate))
        #expect(fixture.session.unvisitedStops(from: origin).map(\.id) == [allStops[1].id])
    }

    @Test
    func cancelingAnOfferedActiveAlternativeKeepsTheCurrentRouteAndPlan() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        _ = prepareActiveAlternative(fixture)
        let before = VoicePlanSnapshot(fixture.session)
        await fixture.submit("Inna trasa")
        #expect(fixture.assistant.canConfirm)

        await fixture.submit("Anuluj")
        await fixture.submit("Tak")

        #expect(fixture.session.state.route?.id == before.route?.id)
        #expect(before.matchesPlan(fixture.session))
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
    }

    @Test
    func missingUnsafeOrFailedAlternativeNeverChangesTheActiveTrip() async throws {
        for behavior in [ActiveAlternativeProvider.Behavior.sameOnly, .omitsStops, .reversesStops, .fails] {
            let fixture = try SavedVoiceFixture(places: [])
            defer { fixture.close() }
            let provider = prepareActiveAlternative(fixture)
            provider.behavior = behavior
            let before = VoicePlanSnapshot(fixture.session)

            await fixture.submit("Inna trasa")

            #expect(!fixture.assistant.canConfirm)
            #expect(fixture.session.state.route?.id == before.route?.id)
            #expect(before.matchesPlan(fixture.session))
            #expect(fixture.session.state.status == .navigating)
            #expect(fixture.session.tripSession?.rerouteCount == 0)
            #expect(!fixture.replies.isEmpty)
        }
    }

    @Test
    func changedPlanRouteOrRoutingGenerationRejectsTheOfferedAlternative() async throws {
        let mutations: [(NavigationSession) -> Void] = [
            { $0.state.destination?.coordinate = .init(latitude: 52.03, longitude: 21) },
            { $0.state.waypoints.reverse() },
            { $0.state.route?.id = UUID() },
            { $0.state.routingPreferences.avoidTolls.toggle() },
            { $0.state.pendingWaypointIDs = $0.state.waypoints.map(\.id) },
            { session in
                if let stop = session.state.waypoints.first {
                    session.state.waypointNavigationTargets[stop.id] = POINavigationTarget(
                        coordinate: .init(latitude: 52.0051, longitude: 21), type: .frontEntrance, confidence: 1)
                }
            },
            { $0.requestGeneration += 1 },
            { _ = $0.rerouteController.beginManualReroute() },
            { $0.state.status = .rerouting }
        ]
        for mutate in mutations {
            let fixture = try SavedVoiceFixture(places: [])
            defer { fixture.close() }
            _ = prepareActiveAlternative(fixture)
            let proposal = try await fixture.session.voiceAlternativeRoute()
            mutate(fixture.session)
            let changed = VoicePlanSnapshot(fixture.session)

            do {
                try await fixture.session.applyVoiceAlternativeRoute(proposal)
                Issue.record("Nieaktualna propozycja nie może nadpisać zmienionej podróży.")
            } catch {}

            #expect(fixture.session.state.route?.id == changed.route?.id)
            #expect(changed.matchesPlan(fixture.session))
            #expect(fixture.session.state.status == changed.status)
        }
    }

    @Test
    func staleGPSAndPassingTheAlternativeBranchRejectConfirmation() async throws {
        for staleGPS in [true, false] {
            let fixture = try SavedVoiceFixture(places: [])
            defer { fixture.close() }
            _ = prepareActiveAlternative(fixture)
            let proposal = try await fixture.session.voiceAlternativeRoute()
            let routeID = fixture.session.state.route?.id
            if staleGPS {
                fixture.session.state.location?.timestamp = .now.addingTimeInterval(-60)
            } else {
                // Continue along the old road after the offered branch diverges.
                moveAlternativeDriver(fixture.session, to: .init(latitude: 52.003, longitude: 21), alongRoute: 334)
            }

            do {
                try await fixture.session.applyVoiceAlternativeRoute(proposal)
                Issue.record("Potwierdzenie wymaga świeżego GPS i nadal dostępnego wariantu.")
            } catch {}

            #expect(fixture.session.state.route?.id == routeID)
            #expect(fixture.session.state.status == .navigating)
            #expect(fixture.session.tripSession?.rerouteCount == 0)
        }
    }

    @Test
    func movementAlongTheSharedApproachStillAllowsTheConfirmedRoute() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        _ = prepareActiveAlternative(fixture)
        let proposal = try await fixture.session.voiceAlternativeRoute()
        moveAlternativeDriver(fixture.session, to: .init(latitude: 52.0004, longitude: 21), alongRoute: 44)

        try await fixture.session.applyVoiceAlternativeRoute(proposal)

        #expect(fixture.session.state.route?.id == proposal.route.id)
        #expect(fixture.session.state.status == .navigating)
        #expect((fixture.session.state.progress?.traveledDistance ?? 0) > 20)
    }

    @Test
    func passingTheDetourAndRejoiningTheOldRoadInvalidatesTheProposal() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        _ = prepareActiveAlternative(fixture)
        fixture.session.state.waypoints = []
        fixture.session.tripSession?.waypoints = []
        let proposal = try await fixture.session.voiceAlternativeRoute()
        let originalRouteID = fixture.session.state.route?.id
        // Both geometries now share their remaining road. The old detour behind
        // the driver must not count as a meaningful active alternative.
        moveAlternativeDriver(fixture.session, to: .init(latitude: 52.018, longitude: 21), alongRoute: 2_002)

        do {
            try await fixture.session.applyVoiceAlternativeRoute(proposal)
            Issue.record("Minęliśmy już różnicę między trasami; propozycja musi wygasnąć.")
        } catch {}

        #expect(fixture.session.state.route?.id == originalRouteID)
        #expect(fixture.session.tripSession?.rerouteCount == 0)
    }

    @Test
    func activeAlternativeKeepsScheduledChargingVisitAlongsideManualStops() async throws {
        let live = NavigationSessionDependencies.live(routeEndpoint: URL(string: "https://routing.invalid")!,
                                                     trafficAPIKey: nil)
        let dependencies = NavigationSessionDependencies(routeProvider: live.routeProvider,
            transitProvider: live.transitProvider, transitDataProvider: live.transitDataProvider,
            speedLimitProvider: live.speedLimitProvider, roadDataProvider: VoiceAlternativeRoadData(),
            trafficProvider: nil, trafficProviderFactory: live.trafficProviderFactory, voiceGuidance: live.voiceGuidance)
        let session = NavigationSession(dependencies: dependencies)
        let previousOffline = OfflineRoutingStore.shared.preferOffline
        OfflineRoutingStore.shared.preferOffline = false
        defer {
            session.tripSession = nil
            session.stop()
            OfflineRoutingStore.shared.preferOffline = previousOffline
        }
        let provider = prepareActiveAlternative(session: session, origin: .init(latitude: 52, longitude: 21))
        session.state.transportMode = .car
        session.tripSession?.transportMode = .car
        session.state.routingPreferences.evPlanningEnabled = true
        session.state.routingPreferences.evRangeKilometers = 400
        session.state.routingPreferences.evBatteryPercent = 100
        session.resetEVBatteryEstimate()
        let charger = Destination(name: "Zaplanowana ładowarka", coordinate: .init(latitude: 52.015, longitude: 21))
        session.state.evChargingStops = [charger]
        session.state.route?.chargingStops = [EVChargingStop(id: "existing-charger", destination: charger,
            connectorTypes: ["ccs"], maximumPowerKW: 150, estimatedChargingTime: 120,
            availabilityKnown: true, publicAccess: true)]
        session.state.route?.chargingDuration = 120
        let manualStops = session.state.waypoints
        let destination = session.state.destination
        let tripID = session.tripSession?.id

        let proposal = try await session.voiceAlternativeRoute()

        #expect(provider.requests.last?.stops == (manualStops + [charger]).map(\.coordinate))
        #expect(session.state.evChargingStops == [charger])
        #expect(proposal.route.chargingStops.contains { $0.destination.id == charger.id })
        #expect(proposal.route.chargingDuration >= 120)

        try await session.applyVoiceAlternativeRoute(proposal)

        #expect(session.state.destination == destination)
        #expect(session.state.waypoints == manualStops)
        #expect(session.state.evChargingStops == [charger])
        #expect(session.tripSession?.id == tripID)
        #expect(session.tripSession?.waypoints == manualStops)
        #expect(session.unvisitedStops(from: .init(latitude: 52, longitude: 21)).map(\.id)
                == (manualStops + [charger]).map(\.id))
    }

    @Test
    func invalidGPSAndTransitRejectActiveAlternativeBeforeRouting() async throws {
        for unavailable in 0..<3 {
            let fixture = try SavedVoiceFixture(places: [])
            defer { fixture.close() }
            let provider = prepareActiveAlternative(fixture)
            if unavailable == 0 { fixture.session.state.location = nil }
            else if unavailable == 1 { fixture.session.state.location?.accuracy = 100 }
            else { fixture.session.state.transportMode = .transit }
            let routeID = fixture.session.state.route?.id

            do {
                _ = try await fixture.session.voiceAlternativeRoute()
                Issue.record("Nie można obliczać alternatywy bez wymaganej pozycji lub dla transportu publicznego.")
            } catch {}

            #expect(provider.requests.isEmpty)
            #expect(fixture.session.state.route?.id == routeID)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func canceledAlternativeCalculationCannotPresentOrApplyItsLateResult() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let provider = prepareActiveAlternative(fixture)
        provider.suspends = true
        let before = VoicePlanSnapshot(fixture.session)
        fixture.assistant.submit("Inna trasa")
        let operation = try #require(fixture.assistant.task)
        await provider.waitUntilRequested()

        await fixture.submit("Anuluj")
        provider.resume()
        await operation.value

        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.session.state.route?.id == before.route?.id)
        #expect(before.matchesPlan(fixture.session))
        #expect(fixture.session.state.status == .navigating)
        #expect(fixture.session.tripSession?.rerouteCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func newDestinationWhileAlternativeLoadsCannotReceiveTheOldProposal() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let provider = prepareActiveAlternative(fixture)
        provider.suspends = true
        fixture.assistant.submit("Inna trasa")
        let operation = try #require(fixture.assistant.task)
        await provider.waitUntilRequested()
        let replacement = Destination(name: "Nowy cel", coordinate: .init(latitude: 53, longitude: 20))
        fixture.session.selectDestination(replacement, applyConfiguredMode: false)

        provider.resume()
        await operation.value

        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.session.state.destination == replacement)
        #expect(fixture.session.state.status == .destinationPreview)
    }

    private func prepareActiveAlternative(_ fixture: SavedVoiceFixture) -> ActiveAlternativeProvider {
        prepareActiveAlternative(session: fixture.session, origin: fixture.origin)
    }

    private func prepareActiveAlternative(session: NavigationSession, origin: Coordinate) -> ActiveAlternativeProvider {
        let provider = ActiveAlternativeProvider()
        session.routeProvider = provider
        session.trafficProvider = nil
        session.plannedTripCalculation = true
        session.appIsForeground = false
        session.state.transportMode = .walking
        session.state.routingPreferences = RoutingPreferences()
        session.state.voiceEnabled = false
        session.voice.setEnabled(false)
        session.state.gpsQuality = .good
        let destination = Destination(name: "Cel", coordinate: .init(latitude: 52.02, longitude: 21))
        let route = ActiveAlternativeProvider.route([origin, destination.coordinate])
        session.state.route = route
        session.state.routeOptions = [route]
        session.state.destination = destination
        session.state.waypoints = [
            Destination(name: "Pierwszy postój", coordinate: .init(latitude: 52.005, longitude: 21)),
            Destination(name: "Drugi postój", coordinate: .init(latitude: 52.01, longitude: 21))
        ]
        session.state.pendingWaypointIDs = []
        session.state.status = .navigating
        session.tripSession = TripSession(destination: destination, waypoints: session.state.waypoints,
            originalExpectedTravelTime: route.expectedTravelTime, startedAt: .now.addingTimeInterval(-100),
            lastLocation: nil, tracksDriving: false, transportMode: .walking)
        session.tripSession?.distanceMeters = 123
        moveAlternativeDriver(session, to: origin, alongRoute: 0)
        return provider
    }

    private func moveAlternativeDriver(_ session: NavigationSession, to coordinate: Coordinate, alongRoute: Double) {
        let now = Date()
        session.state.location = NavigationLocation(coordinate: coordinate, speed: 1.5,
            course: 0, accuracy: 5, timestamp: now)
        guard let route = session.state.route else { return }
        let projection = RouteProjection(coordinate: coordinate, distanceFromRoute: 0,
                                         alongRoute: alongRoute, segment: 0)
        session.state.routeMatch = NavigationRouteMatch(routeID: route.id, locationTimestamp: now,
            match: RouteMatch(projection: projection, confidence: 1))
        session.previousRouteMatch = (route.id, projection, now)
    }
}

@MainActor
private final class ActiveAlternativeProvider: AdvancedRouteProvider {
    enum Behavior { case alternative, sameOnly, omitsStops, reversesStops, passesVisitedStop, fails }
    struct Request {
        let origin: Coordinate
        let destination: Coordinate
        let stops: [Coordinate]
    }
    var behavior: Behavior = .alternative
    var requests: [Request] = []
    var suspends = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        if suspended != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resume() { suspended?.resume(); suspended = nil }

    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, through: [], mode: mode,
                                  preferences: RoutingPreferences(), avoiding: [])
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        requests.append(Request(origin: from, destination: to, stops: through))
        if suspends {
            await withCheckedContinuation {
                suspended = $0
                requested?.resume()
                requested = nil
            }
        }
        if behavior == .fails { throw RoutingError.network }
        if behavior == .sameOnly { return [Self.route([from] + through + [to])] }
        let stops: [Coordinate]
        switch behavior {
        case .omitsStops: stops = []
        case .reversesStops: stops = Array(through.reversed())
        default: stops = through
        }
        var coordinates = [from]
        var previous = from
        for (index, target) in (stops + [to]).enumerated() {
            if index == 0 {
                // Share enough of the initial road for a stationary driver to
                // accept the offered route before the first divergence.
                coordinates.append(Coordinate(latitude: from.latitude + (target.latitude - from.latitude) * 0.2,
                                              longitude: from.longitude))
            }
            coordinates.append(Coordinate(latitude: (previous.latitude + target.latitude) / 2,
                                          longitude: max(previous.longitude, target.longitude) + 0.008))
            if index == 0 && behavior == .passesVisitedStop {
                coordinates.append(.init(latitude: 52.005, longitude: 21))
                coordinates.append(.init(latitude: 52.006, longitude: 21.008))
            }
            if index == stops.count {
                coordinates.append(Coordinate(latitude: previous.latitude + (target.latitude - previous.latitude) * 0.8,
                                              longitude: target.longitude))
            }
            coordinates.append(target)
            previous = target
        }
        return [Self.route(coordinates)]
    }

    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int] { [] }

    static func route(_ coordinates: [Coordinate]) -> NavigationRoute {
        let distance = zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        return NavigationRoute(coordinates: coordinates, distance: distance,
                               expectedTravelTime: distance / 1.5, maneuvers: [])
    }
}

private struct VoiceAlternativeRoadData: RoadDataProvider {
    func load(for route: [Coordinate]) async throws -> RoadDataSnapshot { throw RoutingError.network }
}
#endif
