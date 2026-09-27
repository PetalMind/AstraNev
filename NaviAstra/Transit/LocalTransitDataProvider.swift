import Foundation

/// Local feeds remain available for the map, stop search, vehicle display, and details.
/// Route planning is handled separately by TransitousRouteProvider.
struct LocalTransitDataProvider: TransitDataProviding {
    let region: TransitRegion
    private let repository: TransitRepository

    init(region: TransitRegion = .lodz, repository: TransitRepository? = nil) {
        self.region = region
        self.repository = repository ?? TransitRepository(region: region)
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

    func tripDetails(tripID: String, serviceDate: String,
                     fromStopSequence: Int) async -> TransitTripDetails? {
        await repository.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                     fromStopSequence: fromStopSequence)
    }

    func tripDetails(tripID: String, serviceDate: String, fromStopSequence: Int,
                     scheduleShiftSeconds: Int, frequencyStartSeconds: Int?,
                     frequencyHeadwaySeconds: Int?, isFrequencyEstimate: Bool) async -> TransitTripDetails? {
        var details = await repository.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                                   fromStopSequence: fromStopSequence,
                                                   scheduleShiftSeconds: scheduleShiftSeconds,
                                                   frequencyStartSeconds: frequencyStartSeconds,
                                                   frequencyHeadwaySeconds: frequencyHeadwaySeconds)
        details?.isFrequencyEstimate = isFrequencyEstimate
        return details
    }
}
