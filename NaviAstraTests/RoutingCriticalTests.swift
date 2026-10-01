import Foundation
import Testing
@testable import NaviAstra

/// Regressions in navigation decisions and EV reachability, not UI behavior.
@MainActor
struct RoutingCriticalTests {
    @Test func remainingETAUsesSegmentTimesAndMeasuredTrafficWithoutDoubleCounting() throws {
        let coordinates = [Coordinate(latitude: 52, longitude: 21),
                           Coordinate(latitude: 52.01, longitude: 21),
                           Coordinate(latitude: 52.02, longitude: 21)]
        var route = NavigationRoute(coordinates: coordinates, distance: 2_224,
                                    expectedTravelTime: 1_000, maneuvers: [])
        let length = RouteProgressGeometry(route).length
        let half = length / 2
        route.travelSegments = [RouteTravelSegment(startDistance: 0, endDistance: half, duration: 100),
                                RouteTravelSegment(startDistance: half, endDistance: length, duration: 900)]
        #expect(abs(RoadRouteETA.estimate(route, from: half, traffic: nil) - 900) < 0.001)
        let segment = RouteTrafficSegment(id: "flow", routeID: route.id, startDistance: half,
            endDistance: length, coordinates: Array(coordinates.suffix(2)), colorHex: 0,
            isRoadClosure: false, currentSpeedKph: half / 1_800 * 3.6, freeFlowSpeedKph: 50)
        let incident = TrafficIncident(id: "jam", description: "Korek", coordinate: coordinates[2],
            delaySeconds: 600, category: .jam, severity: .major, distanceAlongRoute: length)
        let traffic = TrafficSnapshot(flow: nil, incidents: [incident], routeFlowSegments: [segment],
                                      updatedAt: Date(), partialError: nil, incidentDataAvailable: true)
        #expect(abs(RoadRouteETA.estimate(route, from: half, traffic: traffic) - 1_800) < 0.001)
        let stale = TrafficSnapshot(flow: nil, incidents: [incident], routeFlowSegments: [segment],
                                    updatedAt: Date().addingTimeInterval(-300), partialError: nil,
                                    incidentDataAvailable: true)
        #expect(abs(RoadRouteETA.estimate(route, from: half, traffic: stale) - 900) < 0.001)
        let reverse = RouteProjection(coordinate: coordinates[0], distanceFromRoute: 0, alongRoute: 0, segment: 0)
        #expect(!RoadRouteETA.canFollow(route, projection: reverse, heading: 180))
    }

    @Test func evPlansReachableStationsBeyondOldCutoffAndRetainsFallbacks() {
        func charger(_ id: String, _ position: Double, _ power: Double) -> NearbyPlaceCandidate {
            NearbyPlaceCandidate(id: id,
                destination: Destination(name: id, coordinate: Coordinate(latitude: 52, longitude: 21)),
                category: .charging, distanceFromRoute: position,
                chargingStation: ChargingStationCapabilities(connectorTypes: ["ccs"], maximumPowerKW: power,
                    chargingPointCount: 1, publicAccess: true, availability: .unknown))
        }
        let stations = [charger("early", 180_000, 50), charger("reachable", 220_000, 150)]
        let plans = EVStopPlanner.plans(chargers: stations, routeLength: 400_000,
                                       initialRange: 300_000, fullRange: 300_000,
                                       consumption: 18, maximumPower: 150)
        #expect(plans.contains { $0.map(\.id) == ["reachable"] })
        #expect(plans.contains { $0.map(\.id) == ["early"] })
        #expect(EVStopPlanner.plans(chargers: [charger("unreachable", 250_000, 150)],
            routeLength: 400_000, initialRange: 300_000, fullRange: 300_000,
            consumption: 18, maximumPower: 150).isEmpty)
        let lowSOC = EVStopPlanner.chargingTime(from: 0.2, to: 0.4, batteryKWh: 60, power: 100)
        let highSOC = EVStopPlanner.chargingTime(from: 0.8, to: 1, batteryKWh: 60, power: 100)
        #expect(highSOC > lowSOC)
        #expect(lowSOC > 12 / 100 * 3_600 + 300)
    }

    @Test func supersededRoadRequestsRejectResultsAndCancelTheirWork() async throws {
        let token = TransitPlanningCancellationToken()
        let child = Task { () throws -> Void in
            try await RoadRoutingContext.$cancellationToken.withValue(token) {
                token.cancel()
                // Even cancellation registered after a superseding request must fire immediately.
                let cancelledTask = Task { try await Task.sleep(for: .seconds(30)) }
                let handler = token.addCancellationHandler { cancelledTask.cancel() }
                defer { token.removeCancellationHandler(handler) }
                do { try await cancelledTask.value; Issue.record("Superseded work continued") }
                catch is CancellationError { }
                try RoadRoutingContext.checkCancellation()
            }
        }
        do { try await child.value; Issue.record("Cancelled result accepted") }
        catch is CancellationError { }
    }
    @Test func lateOptimizationCannotRewriteANewTrip() async throws {
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        let provider = SuspendedWaypointOptimizer()
        session.routeProvider = provider
        session.state.transportMode = .car
        let origin = Destination(name: "Start", coordinate: Coordinate(latitude: 52, longitude: 21))
        let oldDestination = Destination(name: "Old", coordinate: Coordinate(latitude: 52.03, longitude: 21))
        let newDestination = Destination(name: "New", coordinate: Coordinate(latitude: 53, longitude: 22))
        let stops = [Destination(name: "A", coordinate: Coordinate(latitude: 52.01, longitude: 21)),
                     Destination(name: "B", coordinate: Coordinate(latitude: 52.02, longitude: 21))]
        session.state.routeOrigin = RoutePoint(origin, source: .search)
        session.state.destination = oldDestination
        session.state.waypoints = stops
        session.state.status = .routePreview
        let optimization = Task { await session.optimizeWaypoints() }
        await provider.waitUntilRequested()
        session.selectDestination(newDestination, applyConfiguredMode: false)
        let replacement = [stops[1], stops[0]]
        session.state.waypoints = replacement
        provider.finish([1, 0])
        await optimization.value
        #expect(session.state.destination?.id == newDestination.id)
        #expect(session.state.waypoints == replacement)
        #expect(session.state.status == .destinationPreview)
        #expect(session.state.errorMessage == nil)
    }

}


@MainActor
private final class SuspendedWaypointOptimizer: AdvancedRouteProvider {
    private var result: CheckedContinuation<[Int], Error>?
    private var requested: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        if result != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func finish(_ order: [Int]) { result?.resume(returning: order); result = nil }

    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination],
                                mode: TransportMode, preferences: RoutingPreferences) async throws -> [Int] {
        try await withCheckedThrowingContinuation {
            result = $0
            requested?.resume()
            requested = nil
        }
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        Issue.record("A stale optimization started another route request")
        throw RoutingError.invalidResponse
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, mode: mode)
    }
}
