import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct RoutingSelectionCriticalTests {
    private let road = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.03, longitude: 21)]

    @Test func comfortCannotTradeOneTurnForMinutesOrExceedTimeAndDistanceLimits() {
        func score(_ time: Double, _ distance: Double, _ turns: Double) -> RouteScore {
            RouteScore(travelTime: time, distance: distance, trafficDelay: nil, maneuverCost: turns,
                       roadQualityCost: nil, reliabilityCost: nil, tollCost: nil)
        }
        let oneTurn = score(600, 10_000, 8)
        for preference in [RoutePreference.balanced, .comfortable, .personalized] {
            // Even within the detour limit, removing one turn is not worth a minute.
            let values = RouteScoringEngine.rankingValues([oneTurn, score(660, 10_000, 0)], preference: preference)
            #expect(values[0] < values[1])
            let excessive = RouteScoringEngine.rankingValues([oneTurn, score(900, 15_000, 0)], preference: preference)
            #expect(excessive[0].isFinite && !excessive[1].isFinite)
        }
        let shortTrip = [score(600, 10_000, 1_000), score(691, 10_000, 0), score(750, 10_000, 0)]
        #expect(RouteScoringEngine.recommendationEligibility(shortTrip, preference: .balanced) == [true, false, false])
        #expect(RouteScoringEngine.recommendationEligibility(shortTrip, preference: .comfortable) == [true, true, true])
        let longTrip = [score(10_000, 100_000, 2_000), score(10_301, 100_000, 0),
                        score(10_601, 100_000, 0), score(10_001, 105_001, 0), score(10_001, 110_001, 0)]
        #expect(RouteScoringEngine.recommendationEligibility(longTrip, preference: .balanced) == [true, false, false, false, false])
        #expect(RouteScoringEngine.recommendationEligibility(longTrip, preference: .comfortable) == [true, true, false, true, false])
    }

    @Test func comfortCandidateRequestsKeepVehicleExclusionsTimeAndWaypoints() throws {
        var preferences = RoutingPreferences()
        preferences.advanced.routePreference = .comfortable
        preferences.advanced.vehicle = .truck
        preferences.advanced.truckHeight = 3.8
        preferences.advanced.arrivalSide = .same
        preferences.avoidHighways = true
        preferences.avoidTolls = true
        preferences.avoidFerries = true
        preferences.avoidUnpaved = true
        let provider = ValhallaRouteProvider(endpoint: URL(string: "https://example.invalid")!)
        let waypoint = Coordinate(latitude: 52.01, longitude: 21)
        let closure = [[[21.0, 52.0], [21.001, 52.0], [21.001, 52.001], [21.0, 52.0]]]
        try RoadRoutingContext.$closurePolygons.withValue(closure) {
            try RoadRoutingContext.$planningTime.withValue(ValhallaPlanningTime(type: 1, value: "2026-11-02T09:30")) {
                for profile in ValhallaRouteCandidateCosting.profiles(for: .comfortable) {
                    let request = try provider.makeRouteRequest(from: road[0], to: road[1], through: [waypoint],
                        mode: .car, preferences: preferences, avoiding: [waypoint], candidateCosting: profile)
                    let body = try #require(request.httpBody)
                    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    let options = try #require((payload["costing_options"] as? [String: [String: Any]])?["truck"])
                    #expect(payload["costing"] as? String == "truck")
                    #expect(options["height"] as? Double == 3.8)
                    #expect(options["use_highways"] as? Double == 0)
                    #expect(options["use_tolls"] as? Double == 0)
                    #expect(options["use_ferry"] as? Double == 0)
                    #expect(options["exclude_unpaved"] as? Bool == true)
                    #expect(payload["exclude_polygons"] as? [[[Double]]] == closure)
                    #expect((payload["exclude_locations"] as? [[String: Double]])?.count == 1)
                    #expect((payload["date_time"] as? [String: Any])?["type"] as? Int == 1)
                    #expect(payload["prioritize_bidirectional"] == nil)
                    #expect(payload["alternates"] as? Int == 0)
                    let locations = try #require(payload["locations"] as? [[String: Any]])
                    #expect(locations.count == 3)
                    #expect(locations[1]["type"] == nil) // User stop stays a stop, not a personal via hint.
                    #expect(locations[2]["preferred_side"] as? String == "same")
                    #expect(options["gate_cost"] == nil && options["fixed_speed"] == nil) // ETA model stays intact.
                }
            }
        }
        #expect(ValhallaRouteCandidateCosting.profiles(for: .fastest).isEmpty)
        #expect(ValhallaRouteCandidateCosting.profiles(for: .shortest).isEmpty)
        preferences.advanced.routePreference = .personalized
        let decoded = try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.advanced.effectiveRoutePreference == .personalized)
    }

    #if os(iOS)
    @Test(arguments: [170, 171, 442])
    func roadMatchingRetryKeepsTheRequestedItineraryAndRestrictions(errorCode: Int) async throws {
        var requests: [URLRequest] = []
        let provider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
            requests.append(request)
            if requests.count == 1 {
                return Self.routeReply(request, status: 400, body: #"{"error_code":\#(errorCode)}"#)
            }
            let route = #"{"trip":{"legs":[{"shape":"??_ibE?","maneuvers":[]}],"summary":{"length":11,"time":100}}}"#
            return Self.routeReply(request, status: 200, body: route)
        }
        var preferences = RoutingPreferences()
        preferences.advanced.arrivalSide = .same
        preferences.avoidTolls = true
        let stops = errorCode == 170 ? [] : [Coordinate(latitude: 52.015, longitude: 21)]
        let heading = errorCode == 442 ? 359.9 : 89.5
        let closure = [[[20.0, 51.0], [20.01, 51.0], [20.01, 51.01], [20.0, 51.0]]]
        let routes = try await RoadRoutingContext.$allowsPersonalization.withValue(false) {
            try await RoadRoutingContext.$closurePolygons.withValue(closure) {
                try await RoadRoutingContext.$heading.withValue(heading) {
                    try await provider.calculateRoutes(from: road[0], to: road[1], through: stops,
                        mode: .car, preferences: preferences, avoiding: [Coordinate(latitude: 51, longitude: 20)])
                }
            }
        }
        #expect(routes.first?.distance == 11_000)
        try #require(requests.count == 2)
        let firstBody = try #require(requests[0].httpBody)
        let retryBody = try #require(requests[1].httpBody)
        var expected = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        var locations = try #require(expected["locations"] as? [[String: Any]])
        #expect(locations.count == stops.count + 2)
        #expect(locations.allSatisfy { $0["radius"] == nil })
        #expect(locations.first?["heading"] as? Int == (errorCode == 442 ? 0 : 90))
        #expect(expected["alternates"] as? Int == (stops.isEmpty ? 2 : 0))
        for index in locations.indices { locations[index]["radius"] = 50 }
        expected["locations"] = locations
        expected["alternates"] = 0
        expected.removeValue(forKey: "prioritize_bidirectional")
        let retry = try #require(JSONSerialization.jsonObject(with: retryBody) as? NSDictionary)
        #expect(retry.isEqual(to: expected))
    }

    @Test func roadMatchingRetryStopsAfterOneAttemptAndSkipsUnrelatedFailures() async {
        let noRoad = #"{"error_code":171}"#
        for (status, body, expectedCount) in [
            (400, noRoad, 2), (400, #"{"error_code":154}"#, 1),
            (400, "Bad Request", 1), (429, noRoad, 1), (503, noRoad, 1)
        ] {
            var count = 0
            let provider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
                count += 1
                guard count <= expectedCount else { throw URLError(.badServerResponse) }
                return Self.routeReply(request, status: status, body: body)
            }
            await #expect(throws: ValhallaServerError.self) {
                try await provider.calculateRoutes(from: road[0], to: road[1], mode: .car)
            }
            #expect(count == expectedCount)
        }
    }

    @Test func cancellationAfterFailedRoadMatchPreventsRetry() async {
        let token = TransitPlanningCancellationToken()
        var count = 0
        let provider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
            count += 1
            token.cancel()
            return Self.routeReply(request, status: 400, body: #"{"error_code":171}"#)
        }
        await RoadRoutingContext.$cancellationToken.withValue(token) {
            await #expect(throws: CancellationError.self) {
                try await provider.calculateRoutes(from: road[0], to: road[1], mode: .car)
            }
        }
        #expect(count == 1)
    }

    private static func routeReply(_ request: URLRequest, status: Int, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    // Each polyline visits (52.002, 21) before following its own road to the destination.
    private static let centralTrip = #"{"legs":[{"shape":"_oydbB_sv`g@_|B?_|B?o_h@?owH?","maneuvers":[]}],"summary":{"length":3.4,"time":200}}"#
    private static let westernTrip = #"{"legs":[{"shape":"_oydbB_sv`g@_|B?_|B~oRo_h@?owH_pR","maneuvers":[]}],"summary":{"length":4.4,"time":230}}"#
    private static let easternTrip = #"{"legs":[{"shape":"_oydbB_sv`g@_|B?_|B_pRo_h@?owH~oR","maneuvers":[]}],"summary":{"length":4.5,"time":240}}"#

    private static func payload(for request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func offRouteRecalculationRecoversFromPerimeterLimitAndSelectsOnlyASafeAlternative() async throws {
        let session = perimeterSession()
        defer { session.resetRoadSafetyData() }
        let origin = road[0], destination = road[1]
        let stop = Destination(name: "Postój", coordinate: Coordinate(latitude: 52.002, longitude: 21))
        let oldRoad = [Coordinate(latitude: 52, longitude: 20.998), stop.coordinate, destination]
        session.state.route = NavigationRoute(coordinates: oldRoad, distance: 3_600, expectedTravelTime: 260, maneuvers: [])
        session.state.waypoints = [stop]
        session.state.routingPreferences.avoidTolls = true
        session.state.routingPreferences.advanced.vehicle = .truck
        session.state.routingPreferences.advanced.truckHeight = 3.75
        session.state.routingPreferences.advanced.arrivalSide = .same
        let manual = ValhallaAvoidArea(name: "Moja strefa", vertices: [
            Coordinate(latitude: 52.010, longitude: 20.989), Coordinate(latitude: 52.010, longitude: 20.991),
            Coordinate(latitude: 52.014, longitude: 20.991), Coordinate(latitude: 52.014, longitude: 20.989)])
        session.state.routingPreferences.advanced.avoidAreas = [manual]
        var requests: [[String: Any]] = []
        session.routeProvider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
            requests.append(try Self.payload(for: request))
            if requests.count == 1 {
                return Self.routeReply(request, status: 400, body: #"{"error_code":167}"#)
            }
            // All three shapes visit the stop. The central road crosses the closure, the
            // western road crosses the manual area and the eastern road is clear.
            let reply = #"{"trip":\#(Self.centralTrip),"alternates":[{"trip":\#(Self.westernTrip)},{"trip":\#(Self.easternTrip)}]}"#
            return Self.routeReply(request, status: 200, body: reply)
        }
        let time = ValhallaPlanningTime(type: 1, value: "2026-11-12T09:30")
        await RoadRoutingContext.$planningTime.withValue(time) {
            await session.reroute(from: origin)
        }
        #expect(session.state.errorMessage == nil)
        #expect(session.state.status == .navigating)
        #expect(session.state.route?.distance == 4_500)
        #expect(session.state.routeOptions.map(\.distance) == [4_500])
        #expect(session.state.waypoints == [stop])
        try #require(requests.count == 2)
        let originalRings = try #require(requests[0]["exclude_polygons"] as? [[[Double]]])
        #expect(originalRings.count > 1 && originalRings.contains(manual.closedRing))
        #expect(requests[1]["exclude_polygons"] as? [[[Double]]] == [manual.closedRing])
        let locations = try #require(requests[1]["locations"] as? [[String: Any]])
        #expect(locations.compactMap { $0["lat"] as? Double } == [origin.latitude, stop.coordinate.latitude, destination.latitude])
        #expect(locations.last?["preferred_side"] as? String == "same")
        #expect(requests[1]["costing"] as? String == "truck")
        let costs = try #require((requests[1]["costing_options"] as? [String: [String: Any]])?["truck"])
        #expect(costs["use_tolls"] as? Double == 0 && costs["height"] as? Double == 3.75)
        #expect((requests[1]["date_time"] as? [String: Any])?["value"] as? String == time.value)
    }

    @Test(arguments: [false, true])
    func targetedRetryKeepsCheckingEvenTheClosureOmittedFromItsRequest(crossesOmittedClosure: Bool) async throws {
        let session = perimeterSession()
        let westernClosure = try RoadClosureAvoidance(geometry: [
            Coordinate(latitude: 52.011, longitude: 20.99), Coordinate(latitude: 52.013, longitude: 20.99)])
        var requests: [[[[Double]]]] = []
        session.routeProvider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
            let payload = try Self.payload(for: request)
            requests.append(payload["exclude_polygons"] as? [[[Double]]] ?? [])
            switch requests.count {
            case 1:
                return Self.routeReply(request, status: 400, body: #"{"error_code":167}"#)
            case 2:
                return Self.routeReply(request, status: 200, body: #"{"trip":\#(Self.centralTrip)}"#)
            case 3:
                let trip = crossesOmittedClosure ? Self.westernTrip : Self.easternTrip
                return Self.routeReply(request, status: 200, body: #"{"trip":\#(trip)}"#)
            default:
                throw URLError(.badServerResponse)
            }
        }
        let result = await RoadRoutingContext.$closurePolygons.withValue(westernClosure.polygons) {
            try? await session.calculateRoutes(from: road[0], to: road[1])
        }
        try #require(requests.count == 3)
        #expect(requests[0].count == 2 && requests[0].contains(westernClosure.polygons[0]))
        #expect(requests[1].isEmpty)
        let barrier = try RoadExclusionPolygon(ring: #require(requests[2].first))
        #expect(requests[2].count == 1)
        #expect(barrier.intersects(NavigationRoute(coordinates: road, distance: 3_330,
                                                  expectedTravelTime: 200, maneuvers: [])))
        #expect(!requests[2].contains(westernClosure.polygons[0]))
        if crossesOmittedClosure {
            #expect(result == nil)
        } else {
            #expect(result?.map(\.distance) == [4_500])
        }
    }

    @Test func retryCanGuideAnAlternativeAroundASingleLongClosedRoad() async throws {
        let session = perimeterSession()
        let closed = [Coordinate(latitude: 52.012, longitude: 20.5), Coordinate(latitude: 52.012, longitude: 21.001)]
        let incident = TrafficIncident(id: "long", description: "Zamknięcie", coordinate: closed[0],
            delaySeconds: nil, category: .roadClosed, severity: .major, geometry: closed, observedAt: .now)
        session.knownRoadClosures = [incident.id: ConfirmedRoadClosure(incident: incident, observedAt: .now, maximumAge: 120)]
        var rings: [[[[Double]]]] = []
        session.routeProvider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
            rings.append(try Self.payload(for: request)["exclude_polygons"] as? [[[Double]]] ?? [])
            switch rings.count {
            case 1: return Self.routeReply(request, status: 400, body: #"{"error_code":167}"#)
            case 2: return Self.routeReply(request, status: 200, body: #"{"trip":\#(Self.centralTrip)}"#)
            case 3: return Self.routeReply(request, status: 200, body: #"{"trip":\#(Self.easternTrip)}"#)
            default: throw URLError(.badServerResponse)
            }
        }
        let result = try await session.calculateRoutes(from: road[0], to: road[1])
        #expect(result.map(\.distance) == [4_500])
        try #require(rings.count == 3)
        #expect(rings[0].count == 1 && rings[1].isEmpty)
        #expect(!rings[2].isEmpty && rings[2] != rings[0])
        let crossing = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 200, maneuvers: [])
        let barriers = try rings[2].map { try RoadExclusionPolygon(ring: $0) }
        #expect(barriers.contains { $0.intersects(crossing) })
        #expect(rings[2].flatMap { $0 }.allSatisfy { abs($0[0] - 21) < 0.01 })
    }

    @Test func perimeterRetryIsBoundedAndNeverWeakensUserAreasOrRetriesAnotherHTTPStatus() async throws {
        for (hasClosure, status, expectedCount) in [(true, 400, 2), (false, 400, 1), (true, 500, 1)] {
            let session = perimeterSession()
            if !hasClosure { session.knownRoadClosures.removeAll() }
            let manual = ValhallaAvoidArea(name: "Strefa", vertices: [road[0], road[1],
                Coordinate(latitude: 52.02, longitude: 21.01)])
            session.state.routingPreferences.advanced.avoidAreas = [manual]
            var count = 0
            session.routeProvider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
                count += 1
                guard count <= expectedCount else { throw URLError(.badServerResponse) }
                let payload = try Self.payload(for: request)
                #expect((payload["exclude_polygons"] as? [[[Double]]])?.contains(manual.closedRing) == true)
                return Self.routeReply(request, status: status, body: #"{"error_code":167}"#)
            }
            await session.reroute(from: road[0])
            #expect(count == expectedCount)
            #expect(session.state.route == nil)
            let message = try #require(session.state.errorMessage)
            #expect(!message.contains("HTTP"))
        }
    }

    @Test func cancellationAtThePerimeterLimitStopsRecalculationBeforeTheProbe() async {
        let session = perimeterSession()
        let token = TransitPlanningCancellationToken()
        var count = 0
        session.routeProvider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
            count += 1
            token.cancel()
            return Self.routeReply(request, status: 400, body: #"{"error_code":167}"#)
        }
        await RoadRoutingContext.$cancellationToken.withValue(token) {
            await #expect(throws: CancellationError.self) {
                try await session.calculateRoutes(from: road[0], to: road[1])
            }
        }
        #expect(count == 1)
    }

    @Test func blockedEVProbeLeavesThePreviouslyAcceptedChargingItineraryInPlace() async throws {
        let session = perimeterSession()
        session.state.routingPreferences.evPlanningEnabled = true
        session.state.routingPreferences.evRangeKilometers = 400
        let previousCharger = Destination(name: "Zaplanowana ładowarka", coordinate: road[1])
        session.state.evChargingStops = [previousCharger]
        let stop = Destination(name: "Postój", coordinate: Coordinate(latitude: 52.002, longitude: 21))
        session.state.waypoints = [stop]
        var count = 0
        session.routeProvider = ValhallaRouteProvider(endpoint: URL(string: "https://routing.invalid")!) { request in
            count += 1
            guard count <= 3 else { throw URLError(.badServerResponse) }
            let payload = try Self.payload(for: request)
            let locations = try #require(payload["locations"] as? [[String: Any]])
            #expect(locations.compactMap { $0["lat"] as? Double } == [self.road[0].latitude, stop.coordinate.latitude, self.road[1].latitude])
            if count == 1 {
                return Self.routeReply(request, status: 400, body: #"{"error_code":167}"#)
            }
            // Feasible with the available battery, but crosses the known closure.
            return Self.routeReply(request, status: 200, body: #"{"trip":\#(Self.centralTrip)}"#)
        }
        do {
            _ = try await session.calculateRoutes(from: road[0], to: road[1])
            Issue.record("Zaakceptowano trasę przez potwierdzone zamknięcie")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("zamk"))
        }
        #expect((2...3).contains(count))
        #expect(session.state.evChargingStops == [previousCharger])
        #expect(session.state.waypoints == [stop])
    }

    private func perimeterSession() -> NavigationSession {
        let dependencies = NavigationSessionDependencies.live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil)
        let session = NavigationSession(dependencies: .init(routeProvider: dependencies.routeProvider,
            transitProvider: dependencies.transitProvider, transitDataProvider: dependencies.transitDataProvider,
            speedLimitProvider: dependencies.speedLimitProvider, roadDataProvider: PerimeterTestRoadData(),
            trafficProvider: nil, trafficProviderFactory: dependencies.trafficProviderFactory,
            voiceGuidance: dependencies.voiceGuidance))
        session.state.destination = Destination(name: "Cel", coordinate: road[1])
        session.state.transportMode = .car
        session.state.status = .navigating
        session.state.routingPreferences = RoutingPreferences()
        let closed = [Coordinate(latitude: 52.011, longitude: 21), Coordinate(latitude: 52.013, longitude: 21)]
        let incident = TrafficIncident(id: "known", description: "Zamknięcie", coordinate: closed[0],
            delaySeconds: nil, category: .roadClosed, severity: .major, geometry: closed, observedAt: .now)
        session.knownRoadClosures[incident.id] = ConfirmedRoadClosure(incident: incident, observedAt: .now, maximumAge: 120)
        return session
    }

    private struct PerimeterTestRoadData: RoadDataProvider {
        func load(for route: [Coordinate]) async throws -> RoadDataSnapshot { throw RoutingError.network }
    }

    @Test func previewTrafficTimeAndDescriptionsExpireTogetherWithoutChangingTheRoutingBase() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var congested = NavigationRoute(coordinates: road, distance: 10_000, expectedTravelTime: 600,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Jedź prosto", type: 8)])
        let alternative = NavigationRoute(coordinates: road, distance: 10_000, expectedTravelTime: 660,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Jedź prosto", type: 8)])
        congested.trafficPreviewEstimate = .init(travelTime: 900, updatedAt: now)
        #expect(congested.previewTravelTime(at: now) == 900)
        #expect(congested.expectedTravelTime == 600)
        #expect(RouteScoringEngine.score(congested).travelTime == 600)
        #expect(congested.previewTravelTime(at: now.addingTimeInterval(120)) == 900)
        #expect(congested.previewTravelTime(at: now.addingTimeInterval(120.001)) == 600)
        let fresh = RouteVariantDescriptions.describe([congested, alternative], mode: .car, at: now)
        #expect(fresh[alternative.id]?.traits.contains(.fastest) == true)
        #expect(fresh[congested.id]?.traits.contains(.fastest) == false)
        #expect(fresh[congested.id]?.explanation.contains("dłużej o") == true)
        let expired = RouteVariantDescriptions.describe([congested, alternative], mode: .car,
            at: now.addingTimeInterval(121))
        #expect(expired[congested.id]?.traits.contains(.fastest) == true)
        #expect(expired[alternative.id]?.traits.contains(.fastest) == false)
        for invalidTime in [Double.infinity, -.infinity, .nan, -1] {
            congested.trafficPreviewEstimate = .init(travelTime: invalidTime, updatedAt: now)
            #expect(congested.previewTravelTime(at: now) == 600)
        }
        congested.trafficPreviewEstimate = .init(travelTime: 900, updatedAt: now.addingTimeInterval(1))
        #expect(congested.previewTravelTime(at: now) == 600)
    }

    @Test func manualPreviewRefreshesMeasuredETAAndExpiresTheWholeComparisonTogether() async throws {
        let selected = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 600, maneuvers: [])
        let alternative = NavigationRoute(coordinates: [road[0], Coordinate(latitude: 52.001, longitude: 21.006),
            Coordinate(latitude: 52.029, longitude: 21.006), road[1]], distance: 4_000,
            expectedTravelTime: 660, maneuvers: [])
        let provider = PreviewComparisonTrafficProvider(routes: [selected, alternative], slowRouteID: selected.id)
        let session = previewSession(routes: [selected, alternative], provider: provider)
        session.selectTrafficAdjustedRoute(from: emptyTrafficSnapshot(), currentRoute: selected, location: road[0])
        let comparison = try #require(session.trafficComparisonTask)
        await comparison.value

        #expect(provider.flowBatchStartedAt.count == 2)
        #expect(session.state.route?.id == selected.id)
        #expect(session.learningExplicitlySelectedRouteID == selected.id)
        #expect(session.state.route?.expectedTravelTime == 600)
        let displayedSelected = try #require(session.state.route)
        let displayedAlternative = try #require(session.state.routeOptions.first { $0.id == alternative.id })
        #expect(displayedSelected.previewTravelTime > displayedAlternative.previewTravelTime)
        #expect(displayedAlternative.previewTravelTime > alternative.expectedTravelTime)
        let timestamps = session.state.routeOptions.compactMap { $0.trafficPreviewEstimate?.updatedAt }
        #expect(timestamps.count == 2)
        #expect(Set(timestamps).count == 1)
        let cohort = try #require(timestamps.first)
        // The first snapshot was completed before the second provider request began.
        // A shared newest timestamp would incorrectly extend the first measurement's life.
        #expect(cohort <= (try #require(provider.flowBatchStartedAt.last)))
        for route in session.state.routeOptions {
            #expect(route.freshTrafficPreviewEstimate(at: cohort.addingTimeInterval(120)) != nil)
            #expect(route.previewTravelTime(at: cohort.addingTimeInterval(120.001)) == route.expectedTravelTime)
        }
        let labels = RouteVariantDescriptions.describe(session.state.routeOptions, mode: .car, at: cohort)
        #expect(labels[alternative.id]?.traits.contains(.fastest) == true)
    }

    @Test(arguments: [true, false])
    func manuallySelectedClosedPreviewKeepsItsIdentityAndWarnsEvenWithoutFlow(suppliesFlow: Bool) async throws {
        var selected = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 600, maneuvers: [])
        selected.trafficPreviewEstimate = .init(travelTime: 900, updatedAt: .now)
        let closure = TrafficIncident(id: "manual-closed", description: "Droga zamknięta",
            coordinate: Coordinate(latitude: 52.01, longitude: 21), delaySeconds: nil,
            category: .roadClosed, severity: .major, geometry: [
                Coordinate(latitude: 52.01, longitude: 21), Coordinate(latitude: 52.02, longitude: 21)], observedAt: .now)
        let provider = PreviewComparisonTrafficProvider(routes: [selected], slowRouteID: selected.id,
            closures: [closure], suppliesFlow: suppliesFlow)
        let session = previewSession(routes: [selected], provider: provider)
        session.selectTrafficAdjustedRoute(from: emptyTrafficSnapshot(), currentRoute: selected, location: road[0])
        let comparison = try #require(session.trafficComparisonTask)
        await comparison.value

        #expect(provider.flowBatchStartedAt.count == 1)
        #expect(session.state.route?.id == selected.id)
        #expect(session.state.routeOptions.map(\.id) == [selected.id])
        #expect(session.state.route?.previewTravelTime == 600)
        #expect(session.state.route?.trafficPreviewEstimate == nil)
        #expect(session.state.routeOptions.allSatisfy { $0.previewTravelTime.isFinite })
        #expect(session.state.errorMessage ==
            "Wybrana trasa prowadzi przez potwierdzone zamknięcie drogi. Wybierz inny wariant.")
        #expect(session.knownRoadClosures[closure.id] != nil)
    }

    private func previewSession(routes: [NavigationRoute], provider: any TrafficProvider) -> NavigationSession {
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        session.trafficProvider = provider
        session.state.status = .routePreview
        session.state.transportMode = .car
        session.state.journeyTimeMode = .now
        session.state.routingPreferences = RoutingPreferences()
        session.state.routingPreferences.advanced.routePreference = .fastest
        session.state.route = routes.first
        session.state.routeOptions = routes
        session.learningExplicitlySelectedRouteID = routes.first?.id
        return session
    }

    private func emptyTrafficSnapshot() -> TrafficSnapshot {
        TrafficSnapshot(flow: nil, incidents: [], updatedAt: .now, partialError: nil, incidentDataAvailable: true)
    }

    @Test func variantExplanationUsesTheSameBoundedComfortRankingAndRealDifferences() throws {
        let fast = NavigationRoute(coordinates: road, distance: 10_000, expectedTravelTime: 600,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Skręć", type: 10)])
        let slow = NavigationRoute(coordinates: road, distance: 15_000, expectedTravelTime: 900,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Jedź prosto", type: 8)])
        let descriptions = RouteVariantDescriptions.describe([fast, slow], mode: .car)
        #expect(descriptions[fast.id]?.traits.contains(.comfortable) == true)
        #expect(descriptions[slow.id]?.traits.contains(.comfortable) == false)
        let explanation = try #require(descriptions[slow.id]?.explanation)
        #expect(explanation.contains("dłużej o"))
        #expect(explanation.contains("dalej o 5 km"))
        #expect(explanation.contains("manewry kierunkowe: 0 zamiast 1"))
    }
    #endif

    @Test func preferencesSurvivePersistenceAndRankingPreservesActualETA() throws {
        var preferences = try JSONDecoder().decode(RoutingPreferences.self, from: Data("{\"advanced\":{\"shortest\":true}}".utf8))
        #expect(preferences.advanced.effectiveRoutePreference == .shortest)
        preferences.advanced.shortest = false
        preferences.advanced.routePreference = .balanced
        let decoded = try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.advanced.effectiveRoutePreference == .balanced)
        var payload: [String: Any] = [:]
        try decoded.applyValhallaOptions(to: &payload, mode: .car)
        #expect((payload["costing_options"] as? [String: [String: Any]])?["auto"]?["shortest"] as? Bool == false)
        let busy = NavigationRoute(coordinates: road, distance: 19_000, expectedTravelTime: 31 * 60,
            maneuvers: (0..<41).map { _ in Maneuver(shapeIndex: 0, instruction: "Skręt", type: 10) })
        let easy = NavigationRoute(coordinates: road, distance: 22_000, expectedTravelTime: 33 * 60,
            maneuvers: (0..<8).map { _ in Maneuver(shapeIndex: 0, instruction: "Skręt", type: 10) })
        #expect(RouteScoringEngine.ranked([busy, easy], preference: .fastest).first?.id == busy.id)
        #expect(RouteScoringEngine.ranked([busy, easy], preference: .balanced).first?.id == easy.id)
        #expect(RouteScoringEngine.ranked([easy, busy], preference: .shortest).first?.id == busy.id)
        #expect(RouteScoringEngine.score(easy).travelTime == 33 * 60)
        #expect(RouteScoringEngine.score(easy).trafficDelay == nil)
        #expect(RouteScoringEngine.score(easy).roadQualityCost == nil)
        var knownRough = easy
        knownRough.id = UUID()
        knownRough.maneuvers = [Maneuver(shapeIndex: 0, instruction: "Droga gruntowa", type: 8,
            information: ManeuverInformation(distanceMeters: 2_000, rough: true))]
        #expect(RouteScoringEngine.score(knownRough).roadQualityCost == 60)
        // Unknown quality on another route disables that component for the comparison.
        #expect(RouteScoringEngine.ranked([knownRough, easy], preference: .balanced).first?.id == knownRough.id)
        knownRough.maneuvers[0].information?.distanceMeters = nil
        #expect(RouteScoringEngine.score(knownRough).roadQualityCost == nil)
        let stale = TrafficSnapshot(flow: nil, incidents: [], updatedAt: Date().addingTimeInterval(-300),
                                    partialError: nil, incidentDataAvailable: true)
        #expect(RouteScoringEngine.score(easy, traffic: stale).trafficDelay == nil)

    }

    @Test func diversityKeepsTheRecommendedRouteAndDistinctRoadsAndChargingStops() {
        let first = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 300, maneuvers: [])
        let duplicate = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 301, maneuvers: [])
        let via = [road[0], Coordinate(latitude: 52.015, longitude: 21.01), road[1]]
        let other = NavigationRoute(coordinates: via, distance: 3_700, expectedTravelTime: 320, maneuvers: [])
        let kept = RouteSimilarity.diverse([first, duplicate, other])
        #expect(kept.map(\.id) == [first.id, other.id])
        #expect(RouteSimilarity.overlap(first, duplicate) > 0.99)
        #expect(RouteSimilarity.overlap(first, other) < 0.8)
        var ev = duplicate
        ev.chargingStops = [EVChargingStop(id: "charger", destination: Destination(name: "Ładowarka", coordinate: road[0]),
            connectorTypes: ["ccs"], maximumPowerKW: 100, estimatedChargingTime: 600,
            availabilityKnown: false, publicAccess: true)]
        #expect(RouteSimilarity.diverse([first, ev]).count == 2)
        let reverse = NavigationRoute(coordinates: Array(road.reversed()), distance: 3_330,
                                      expectedTravelTime: 300, maneuvers: [])
        #expect(RouteSimilarity.overlap(first, reverse) < 0.01)
    }

    @Test func samplingAdaptsToRoadsAndIncidentsWithinTheRequestBudget() {
        var city = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 900, maneuvers: [])
        let highway = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 100,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Jedź", type: 8,
                                 information: ManeuverInformation(highway: true))])
        let geometry = RouteProgressGeometry(city)
        let dense = RouteTrafficMonitor.flowQueries(for: city, from: 0, through: geometry.length)
        let sparse = RouteTrafficMonitor.flowQueries(for: highway, from: 0, through: geometry.length)
        #expect(dense.count > sparse.count)
        let measured = RouteTrafficSegment(id: "local-road", routeID: highway.id, startDistance: 0,
            endDistance: geometry.length, coordinates: road, colorHex: 0, isRoadClosure: false, roadClass: "FRC6")
        let local = RouteTrafficMonitor.flowQueries(for: highway, from: 0, through: geometry.length,
                                                     measuredSegments: [measured])
        #expect(local.count > sparse.count)

        let incident = TrafficIncident(id: "jam", description: "Korek", coordinate: road[0], delaySeconds: 90,
            category: .jam, severity: .moderate, geometry: [Coordinate(latitude: 52.012, longitude: 21),
                                                        Coordinate(latitude: 52.014, longitude: 21)])
        let focused = RouteTrafficMonitor.flowQueries(for: highway, from: 0, through: geometry.length,
                                                       incidents: [incident])
        #expect(focused.count > sparse.count)
        city.coordinates = [road[0], Coordinate(latitude: 53, longitude: 21)]
        city.distance = 111_000; city.expectedTravelTime = 20_000
        let budget = RouteTrafficMonitor.flowQueries(for: city, from: 0, through: city.distance)
        #expect(budget.count <= RouteTrafficMonitor.maximumFlowSamples)
        #expect(budget.first?.distanceAlongRoute == 0)
        #expect((budget.last?.distanceAlongRoute ?? 0) > 100_000)
        #expect(zip(budget, budget.dropFirst()).allSatisfy { $0.distanceAlongRoute < $1.distanceAlongRoute })
    }

    @Test func identityAndDirectionAgreeAcrossWarningsTrafficAndETA() {
        let route = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 300,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Jedź A2", type: 8, streetNames: ["A2", "E30"])])
        let geometry = RouteProgressGeometry(route)
        func incident(_ ref: String, _ direction: TrafficGeometryDirection = .unknown) -> TrafficIncident {
            TrafficIncident(id: ref, description: "Zamknięcie", coordinate: road[0], delaySeconds: nil,
                category: .roadClosed, severity: .major, geometry: road,
                roadNumbers: [ref], geometryDirection: direction)
        }
        for (ref, accepted) in [("A2", true), ("E 30", true), ("A4", false), ("E50", false), ("S8", true), ("", true)] {
            let event = incident(ref)
            #expect((RouteTrafficMonitor.incidentProjection(event, geometry: geometry, route: route) != nil) == accepted)
            let snapshot = TrafficSnapshot(flow: nil, incidents: [event], updatedAt: .now,
                                            partialError: nil, incidentDataAvailable: true)
            let matched = RouteTrafficMonitor.matching([event], to: route, from: 0,
                through: geometry.length, routeGeometry: geometry)
            #expect(!matched.isEmpty == accepted)
            if accepted { #expect(matched.first?.roadNumbers == event.roadNumbers) }
            // The event starts at the origin; moving it ahead exercises the ETA closure rule.
            let ahead = TrafficIncident(id: ref, description: event.description,
                coordinate: Coordinate(latitude: 52.005, longitude: 21), delaySeconds: nil,
                category: .roadClosed, severity: .major,
                geometry: [Coordinate(latitude: 52.005, longitude: 21), road[1]], roadNumbers: [ref])
            let traffic = TrafficSnapshot(flow: nil, incidents: [ahead], updatedAt: snapshot.updatedAt,
                                           partialError: nil, incidentDataAvailable: true)
            #expect(RoadRouteETA.estimate(route, from: 0, traffic: traffic).isFinite != accepted)
        }
        #expect(RouteTrafficMonitor.incidentProjection(incident("A2", .backward), geometry: geometry, route: route) == nil)
    }

    @Test func fullClosureRejectsSparseCrossingsAndMergesUserExclusions() throws {
        let closed = [Coordinate(latitude: 52.005, longitude: 21), Coordinate(latitude: 52.025, longitude: 21)]
        let avoidance = try RoadClosureAvoidance(geometry: closed)
        let crossing = NavigationRoute(coordinates: [Coordinate(latitude: 52.015, longitude: 20.99),
            Coordinate(latitude: 52.015, longitude: 21.01)], distance: 1_400, expectedTravelTime: 100, maneuvers: [])
        #expect(avoidance.intersects(crossing)) // Both vertices are far from the closed road.
        let beyond = NavigationRoute(coordinates: [Coordinate(latitude: 52.03, longitude: 20.99),
            Coordinate(latitude: 52.03, longitude: 21.01)], distance: 1_400, expectedTravelTime: 100, maneuvers: [])
        #expect(!avoidance.intersects(beyond))
        let detour = NavigationRoute(coordinates: [Coordinate(latitude: 52.004, longitude: 21.001),
            Coordinate(latitude: 52.026, longitude: 21.001)], distance: 2_400, expectedTravelTime: 100, maneuvers: [])
        #expect(!avoidance.intersects(detour))
        var preferences = RoutingPreferences()
        preferences.advanced.avoidAreas = [ValhallaAvoidArea(name: "Obszar", vertices: [
            Coordinate(latitude: 51, longitude: 20), Coordinate(latitude: 51.001, longitude: 20),
            Coordinate(latitude: 51.001, longitude: 20.001)])]
        try RoadRoutingContext.$closurePolygons.withValue(avoidance.polygons) {
            var payload: [String: Any] = [:]
            try preferences.applyValhallaOptions(to: &payload, mode: .car)
            let polygons = payload["exclude_polygons"] as? [[[Double]]]
            #expect(polygons?.count == avoidance.polygons.count + 1)
            #expect(polygons?.last?.first == polygons?.last?.last)
        }
        #expect(RoadRoutingContext.closurePolygons.isEmpty)
    }
}

#if os(iOS)
@MainActor
private final class PreviewComparisonTrafficProvider: TrafficProvider {
    let routes: [NavigationRoute]
    let slowRouteID: UUID
    let closures: [TrafficIncident]
    let suppliesFlow: Bool
    private(set) var flowBatchStartedAt: [Date] = []

    init(routes: [NavigationRoute], slowRouteID: UUID, closures: [TrafficIncident] = [], suppliesFlow: Bool = true) {
        self.routes = routes
        self.slowRouteID = slowRouteID
        self.closures = closures
        self.suppliesFlow = suppliesFlow
    }

    func snapshot(near: Coordinate, incidentRadiusMeters: Double) async throws -> TrafficSnapshot {
        TrafficSnapshot(flow: nil, incidents: closures, updatedAt: .now, partialError: nil, incidentDataAvailable: true)
    }
    func incidents(in boxes: [TrafficBoundingBox]) async throws -> [TrafficIncident] { closures }
    func routeFlowSamples(at queries: [RouteTrafficFlowQuery]) async -> [RouteTrafficFlowSample] {
        flowBatchStartedAt.append(.now)
        // Give separate candidate observations distinguishable acquisition times.
        try? await Task.sleep(for: .milliseconds(10))
        guard suppliesFlow, let route = routes.min(by: { first, second in
            let a = RouteProgressGeometry(first), b = RouteProgressGeometry(second)
            return queries.reduce(0) { $0 + (a.project($1.coordinate)?.distanceFromRoute ?? .infinity) } <
                queries.reduce(0) { $0 + (b.project($1.coordinate)?.distanceFromRoute ?? .infinity) }
        }) else { return [] }
        let geometry = RouteProgressGeometry(route)
        let points = stride(from: 0.0, through: geometry.length, by: 10).compactMap { geometry.coordinate(at: $0) } +
            [route.coordinates.last!]
        let flow = TrafficFlow(currentSpeedKph: route.id == slowRouteID ? 5 : 10, freeFlowSpeedKph: 50,
            confidence: 1, roadClosure: false, coordinates: points, updatedAt: .now)
        return queries.map { RouteTrafficFlowSample(distanceAlongRoute: $0.distanceAlongRoute, flow: flow) }
    }
    func rasterFlowTileURLTemplate(style: TrafficTileStyle) -> String? { nil }
    func rasterIncidentTileURLTemplate(style: TrafficTileStyle) -> String? { nil }
}
#endif
