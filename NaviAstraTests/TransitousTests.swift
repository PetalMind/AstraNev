import Foundation
import Testing
@testable import NaviAstra

struct TransitousTests {
    @Test func mapsDirectTransitJourney() throws {
        let journeys = try mappedJourneys([itinerary(id: "direct", transfers: 0,
            legs: [leg(mode: "TRAM", from: "Łódź Fabryczna", to: "Piotrkowska Centrum",
                       line: "10A")])])

        #expect(journeys.count == 1)
        #expect(journeys[0].transfers == 0)
        #expect(journeys[0].legs.map(\.mode) == [.tram])
        #expect(journeys[0].legs[0].line == "10A")
    }

    @Test func mapsJourneyWithOneTransfer() throws {
        let journeys = try mappedJourneys([itinerary(id: "transfer", transfers: 1,
            legs: [leg(mode: "TRAM", from: "Fabryczna", to: "Piotrkowska Centrum", line: "10A"),
                   leg(mode: "BUS", from: "Piotrkowska Centrum", to: "Retkinia", line: "80")])])

        #expect(journeys[0].transfers == 1)
        #expect(journeys[0].legs.map(\.mode) == [.tram, .bus])
    }

    @Test func mapsWalkAndTramAccessLegs() throws {
        let journeys = try mappedJourneys([itinerary(id: "walk-tram", transfers: 0,
            legs: [leg(mode: "WALK", from: "Start", to: "Fabryczna"),
                   leg(mode: "TRAM", from: "Fabryczna", to: "Centrum", line: "12")])])

        #expect(journeys[0].legs.map(\.mode) == [.walk, .tram])
        #expect(journeys[0].walkingDuration == 300)
        #expect(journeys[0].walkingDistance == 460)
    }

    @Test func mapsBusAndTramJourney() throws {
        let journeys = try mappedJourneys([itinerary(id: "bus-tram", transfers: 1,
            legs: [leg(mode: "BUS", from: "Start", to: "Centrum", line: "65A"),
                   leg(mode: "TRAM", from: "Centrum", to: "Cel", line: "14")])])

        #expect(journeys[0].legs.map(\.mode) == [.bus, .tram])
        #expect(journeys[0].transfers == 1)
    }

    @Test func mapsRailAndUrbanTransitJourney() throws {
        let journeys = try mappedJourneys([itinerary(id: "rail-urban", transfers: 1,
            legs: [leg(mode: "REGIONAL_RAIL", from: "Łódź Widzew", to: "Łódź Fabryczna", line: "ŁKA"),
                   leg(mode: "BUS", from: "Łódź Fabryczna", to: "Cel", line: "80")])])

        #expect(journeys[0].legs.map(\.mode) == [.train, .bus])
        #expect(journeys[0].legs[0].line == "ŁKA")
    }

    @Test func reportsNoRouteWhenAPIReturnsNoJourneys() async throws {
        let provider = TransitousRouteProvider(configuration: testConfiguration(),
                                               transport: TransitousTestTransport(.success(data: response([]))))
        await #expect(throws: TransitRouteError.noRoute) {
            try await provider.routes(from: lodzCenter, to: lodzDestination, time: testDate,
                                      arriveBy: false, preferences: .init(), cancellationToken: nil)
        }
    }

    @Test func preservesRealtimeAndScheduledTimesSeparately() throws {
        let journeys = try mappedJourneys([itinerary(id: "realtime", transfers: 0,
            legs: [leg(mode: "TRAM", from: "Fabryczna", to: "Centrum", line: "10A",
                       realtime: true, delay: 180)])])
        let leg = try #require(journeys.first?.legs.first)

        #expect(journeys[0].realtimeAvailable)
        #expect(leg.realtimeAvailable)
        #expect(leg.estimatedDeparture == testDate.addingTimeInterval(180))
        #expect(leg.scheduledDeparture == testDate)
        #expect(leg.delaySeconds == 180)

        let onTimeJourney = try mappedJourneys([itinerary(id: "realtime-on-time", transfers: 0,
            legs: [leg(mode: "TRAM", from: "Fabryczna", to: "Centrum", line: "10A",
                       realtime: true)])])[0]
        #expect(onTimeJourney.legs[0].realtimeAvailable)
        #expect(onTimeJourney.legs[0].delaySeconds == 0)
        #expect(onTimeJourney.legs[0].intermediateStops[0].hasRealtime)
    }

    @Test func worksWithoutRealtimeFields() throws {
        let journeys = try mappedJourneys([itinerary(id: "scheduled", transfers: 0,
            legs: [leg(mode: "BUS", from: "Start", to: "Cel", line: "80")])])
        let leg = try #require(journeys.first?.legs.first)

        #expect(!journeys[0].realtimeAvailable)
        #expect(!leg.realtimeAvailable)
        #expect(leg.delaySeconds == nil)
        #expect(leg.estimatedDeparture == leg.scheduledDeparture)
    }

    @Test func cancellationCancelsInFlightTransport() async throws {
        let transport = TransitousTestTransport(.suspended)
        let client = TransitousClient(configuration: testConfiguration(), transport: transport)
        let cancellation = TransitPlanningCancellationToken()
        let request = Task {
            try await client.plan(from: lodzCenter, to: lodzDestination, time: testDate,
                                  arriveBy: false, preferences: .init(), cancellationToken: cancellation)
        }
        try await Task.sleep(for: .milliseconds(250))
        cancellation.cancel()

        do {
            _ = try await request.value
            Issue.record("Cancelled Transitous request unexpectedly returned a response")
        } catch is CancellationError {
            #expect(true)
        }
    }

    @Test func rejectsMalformedJSONResponse() async throws {
        let client = TransitousClient(configuration: testConfiguration(),
            transport: TransitousTestTransport(.success(data: Data("{bad".utf8))))
        await #expect(throws: TransitRouteError.decoding) {
            try await client.plan(from: lodzCenter, to: lodzDestination, time: testDate,
                                  arriveBy: false, preferences: .init(), cancellationToken: nil)
        }
    }

    @Test func appliesRateLimitCooldownOnHTTP429() async throws {
        let transport = TransitousTestTransport(.http(status: 429, data: Data(), headers: ["Retry-After": "30"]))
        let client = TransitousClient(configuration: testConfiguration(), transport: transport)

        for _ in 0..<2 {
            do {
                _ = try await client.plan(from: lodzCenter, to: lodzDestination, time: testDate,
                                          arriveBy: false, preferences: .init(), cancellationToken: nil)
                Issue.record("HTTP 429 unexpectedly returned a plan")
            } catch let error as TransitRouteError {
                guard case let .rateLimited(retryAfter) = error else {
                    Issue.record("HTTP 429 mapped to the wrong error: \(error)")
                    continue
                }
                #expect((retryAfter ?? 0) >= 29)
            }
        }
        let requestCount = await transport.requestCount
        #expect(requestCount == 1)
    }

    @Test func mapsTimedOutNetworkRequestToTimeout() async throws {
        let client = TransitousClient(configuration: testConfiguration(),
                                      transport: TransitousTestTransport(.timeout))
        await #expect(throws: TransitRouteError.timeout) {
            try await client.plan(from: lodzCenter, to: lodzDestination, time: testDate,
                                  arriveBy: false, preferences: .init(), cancellationToken: nil)
        }
    }

    @Test func requestUsesTransitousV6AndArriveByParameters() async throws {
        let transport = TransitousTestTransport(.success(data: response([])))
        let client = TransitousClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.plan(from: lodzCenter, to: lodzDestination, time: testDate,
                                  arriveBy: true, preferences: .init(), cancellationToken: nil)
        let lastRequest = await transport.lastRequest
        let request = try #require(lastRequest)
        let components = try #require(URLComponents(url: try #require(request.url),
                                                    resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(components.path == "/api/v6/plan")
        #expect(query["arriveBy"] == "true")
        #expect(query["maxDirectTime"] == "0")
        #expect(query["time"] == "2026-09-27T10:00:00Z")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "NaviAstra/test (https://example.org/naviastra)")
    }

    @Test func lodzExamplesCanBeRunAsOptInLiveIntegration() async throws {
        guard ProcessInfo.processInfo.environment["NAVI_ASTRA_RUN_TRANSITOUS_INTEGRATION"] == "1",
              let contact = ProcessInfo.processInfo.environment["TRANSITOUS_CONTACT"],
              !contact.isEmpty else { return }
        let provider = TransitousRouteProvider(
            configuration: TransitousClientConfiguration(contact: contact))
        let destinations = [
            Coordinate(latitude: 51.7590, longitude: 19.5100), // Widzew
            Coordinate(latitude: 51.7410, longitude: 19.3970), // Retkinia
            Coordinate(latitude: 51.8000, longitude: 19.4600)  // Bałuty
        ]

        for destination in destinations {
            let journeys = try await provider.routes(from: lodzCenter, to: destination,
                                                     time: Self.nextIntegrationDeparture,
                                                     arriveBy: false, preferences: .init(),
                                                     cancellationToken: nil)
            #expect(!journeys.isEmpty)
            #expect(journeys.count <= 5)
            #expect(journeys.contains { journey in journey.legs.contains(where: \.isTransit) })
        }
    }

    private let lodzCenter = Coordinate(latitude: 51.7592, longitude: 19.4560)
    private let lodzDestination = Coordinate(latitude: 51.7708, longitude: 19.4650)
    private let testDate = ISO8601DateFormatter().date(from: "2026-09-27T10:00:00Z")!

    private static var nextIntegrationDeparture: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw") ?? .current
        let now = Date()
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now)
            ?? now.addingTimeInterval(24 * 60 * 60)
        guard todayAtEight > now.addingTimeInterval(5 * 60) else {
            return calendar.date(byAdding: .day, value: 1, to: todayAtEight)
                ?? now.addingTimeInterval(24 * 60 * 60)
        }
        return todayAtEight
    }

    private func mappedJourneys(_ itineraries: [[String: Any]]) throws -> [TransitJourney] {
        try TransitousMapper.journeys(from: JSONDecoder().decode(
            TransitousPlanResponseDTO.self, from: response(itineraries)))
    }

    private func response(_ itineraries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["itineraries": itineraries, "direct": []])
    }

    private func itinerary(id: String, transfers: Int, legs: [[String: Any]]) -> [String: Any] {
        ["duration": 1800, "startTime": "2026-09-27T10:00:00Z",
         "endTime": "2026-09-27T10:30:00Z", "transfers": transfers,
         "id": id, "legs": legs]
    }

    private func leg(mode: String, from: String, to: String, line: String? = nil,
                     realtime: Bool = false, delay: Int = 0) -> [String: Any] {
        let scheduledDeparture = testDate
        let departure = scheduledDeparture.addingTimeInterval(realtime ? TimeInterval(delay) : 0)
        let scheduledArrival = testDate.addingTimeInterval(900)
        let arrival = scheduledArrival.addingTimeInterval(realtime ? TimeInterval(delay) : 0)
        let start = Coordinate(latitude: 51.7592, longitude: 19.4560)
        let end = Coordinate(latitude: 51.7708, longitude: 19.4650)
        var result: [String: Any] = [
            "mode": mode,
            "from": ["name": from, "stopId": "stop-from", "lat": start.latitude,
                     "lon": start.longitude, "departure": Self.iso(departure),
                     "scheduledDeparture": Self.iso(scheduledDeparture)],
            "to": ["name": to, "stopId": "stop-to", "lat": end.latitude,
                   "lon": end.longitude, "arrival": Self.iso(arrival),
                   "scheduledArrival": Self.iso(scheduledArrival)],
            "duration": 900,
            "startTime": Self.iso(departure),
            "endTime": Self.iso(arrival),
            "scheduledStartTime": Self.iso(scheduledDeparture),
            "scheduledEndTime": Self.iso(scheduledArrival),
            "realTime": realtime,
            "distance": 460,
            "headsign": "Retkinia",
            "agencyName": "MPK Łódź",
            "tripId": "trip-1",
            "legGeometry": ["points": "", "precision": 6, "length": 0],
            "intermediateStops": [],
            "alerts": []
        ]
        if let line {
            result["routeShortName"] = line
            result["displayName"] = line
            result["routeId"] = "route-\(line)"
            result["routeColor"] = "#336699"
        }
        return result
    }

    private func testConfiguration() -> TransitousClientConfiguration {
        TransitousClientConfiguration(
            baseURL: URL(string: "https://test.transitous.invalid/api/")!,
            applicationVersion: "test",
            contact: "https://example.org/naviastra")
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private enum TransitousTestResponse: Sendable {
    case success(data: Data)
    case http(status: Int, data: Data, headers: [String: String])
    case timeout
    case suspended
}

private actor TransitousTestTransport: TransitousTransport {
    private let response: TransitousTestResponse
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    init(_ response: TransitousTestResponse) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        lastRequest = request
        switch response {
        case let .success(data):
            return (data, try makeHTTPResponse(status: 200, headers: [:]))
        case let .http(status, data, headers):
            return (data, try makeHTTPResponse(status: status, headers: headers))
        case .timeout:
            throw URLError(.timedOut)
        case .suspended:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                throw URLError(.cancelled)
            }
            return (Data(), try makeHTTPResponse(status: 200, headers: [:]))
        }
    }

    private func makeHTTPResponse(status: Int,
                                  headers: [String: String]) throws -> HTTPURLResponse {
        let response = HTTPURLResponse(url: URL(string: "https://test.transitous.invalid/api/v6/plan")!,
                                       statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)
        guard let response else { throw TransitRouteError.invalidResponse }
        return response
    }
}
