import Foundation

struct TransitRouteProvider: TransitRouteProviding, TransitDataProviding {
    let region: TransitRegion
    let walkingRoutingEndpoint: URL
    private let repository: TransitRepository

    init(region: TransitRegion = .lodz,
         walkingRoutingEndpoint: URL = URL(string: UserDefaults.standard.string(forKey: "routingServer")
            ?? "https://valhalla1.openstreetmap.de")!,
         repository: TransitRepository? = nil) {
        self.region = region
        self.walkingRoutingEndpoint = walkingRoutingEndpoint
        self.repository = repository ?? TransitRepository(region: region)
    }

    func usingWalkingRoutingEndpoint(_ endpoint: URL) -> TransitRouteProviding {
        TransitRouteProvider(region: region, walkingRoutingEndpoint: endpoint, repository: repository)
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, parkRide: Bool = false,
                         departingAt: Date = Date(),
                         onProgress: TransitPlanningProgressHandler? = nil,
                         onProvisionalRoutes: TransitProvisionalRoutesHandler? = nil) async throws -> [NavigationRoute] {
        guard !parkRide else { throw TransitRoutingError.noParkRide }
        return try await repository.calculateRoutes(from: from, to: to,
                                                    departingAt: departingAt,
                                                    walkingRoutingEndpoint: walkingRoutingEndpoint,
                                                    onProgress: onProgress,
                                                    onProvisionalRoutes: onProvisionalRoutes)
    }

    func vehiclePositions(near coordinate: Coordinate) async -> TransitVehicleFeed {
        await repository.vehiclePositions(near: coordinate)
    }

    func departures(at stopID: String, limit: Int = 10) async -> [TransitDeparture] {
        await repository.departures(at: stopID, limit: limit)
    }

    func departures(at stopIDs: [String], limit: Int = 10) async -> [TransitDeparture] {
        await repository.departures(at: stopIDs, limit: limit)
    }

    func alerts(for stopID: String) async -> [String] {
        await repository.alerts(for: stopID)
    }

    func alerts(for stopIDs: [String]) async -> [String] {
        await repository.alerts(for: stopIDs)
    }

    func railwayScheduleAttribution() async -> String? {
        await repository.railwayScheduleAttribution()
    }

    func search(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults {
        await repository.search(query, near: coordinate)
    }

    func lineDetails(for routeID: String) async -> TransitLineDetails? {
        await repository.lineDetails(for: routeID)
    }

    func vehicleDetails(id: String) async -> TransitTripDetails? {
        await repository.vehicleDetails(id: id)
    }

    func tripDetails(for departure: TransitDeparture) async -> TransitTripDetails? {
        await repository.tripDetails(for: departure)
    }

    func tripDetails(tripID: String, serviceDate: String, fromStopSequence: Int) async -> TransitTripDetails? {
        await repository.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                     fromStopSequence: fromStopSequence)
    }
}
