import Observation
import Foundation

@MainActor
@Observable
final class TransitStore {
    private let repository: TransitDataProviding
    private var detailRequestID = UUID()
    @ObservationIgnored private var mapStopsTask: Task<Void, Never>?
    @ObservationIgnored private var mapStopsRequestID = UUID()

    var region: TransitRegion { repository.region }
    private(set) var mapStops: [TransitStop] = []

    var selectedSheet: TransitSheetSelection?
    var selectedStopID: String?
    var selectedRouteID: String?
    var selectedTripID: String?
    var selectedTripStopIDs: Set<String> = []
    var selectedLine: TransitLineDetails?
    var selectedTripCoordinates: [Coordinate] = []
    var liveTripDetails: TransitTripDetails?

    init(repository: TransitDataProviding) {
        self.repository = repository
    }

    func open(_ stop: TransitStop) {
        detailRequestID = UUID()
        selectedStopID = stop.id
        selectedRouteID = nil
        selectedTripID = nil
        selectedTripStopIDs = []
        selectedLine = nil
        selectedTripCoordinates = []
        selectedSheet = .stop(stop)
    }

    func open(_ vehicle: TransitVehicle) async {
        detailRequestID = UUID()
        let requestID = detailRequestID
        selectedStopID = nil
        selectedRouteID = vehicle.routeID
        selectedTripID = vehicle.tripID
        selectedTripStopIDs = []
        selectedLine = nil
        selectedTripCoordinates = []
        selectedSheet = .vehicle(vehicle)

        async let line = repository.lineDetails(for: vehicle.routeID)
        async let trip = repository.vehicleDetails(id: vehicle.id)
        let (lineDetails, tripDetails) = await (line, trip)
        guard detailRequestID == requestID else { return }
        apply(line: lineDetails, trip: tripDetails)
    }

    func open(_ line: TransitLineSearchResult) async -> TransitLineDetails? {
        detailRequestID = UUID()
        let requestID = detailRequestID
        selectedStopID = nil
        selectedRouteID = line.id
        selectedTripID = nil
        selectedTripStopIDs = []
        selectedLine = nil
        selectedTripCoordinates = []

        guard let details = await repository.lineDetails(for: line.id),
              detailRequestID == requestID else { return nil }
        selectedLine = details
        selectedSheet = .line(details)
        return details
    }

    func open(_ departure: TransitDeparture) async {
        detailRequestID = UUID()
        let requestID = detailRequestID
        selectedStopID = departure.stopID
        selectedRouteID = departure.routeID
        selectedTripID = departure.tripID
        selectedTripStopIDs = []
        selectedLine = nil
        selectedTripCoordinates = []
        selectedSheet = .departure(departure)

        async let line = repository.lineDetails(for: departure.routeID)
        async let trip = repository.tripDetails(for: departure)
        let (lineDetails, tripDetails) = await (line, trip)
        guard detailRequestID == requestID else { return }
        apply(line: lineDetails, trip: tripDetails)
        selectedSheet = .departure(departure)
    }

    func selectJourney(_ leg: JourneyLeg, tripDetails: TransitTripDetails?, lineDetails: TransitLineDetails?) {
        selectedRouteID = leg.routeID
        selectedTripID = leg.tripID
        selectedTripStopIDs = Set((tripDetails?.pastStops ?? []).map(\.stopID)
            + (tripDetails?.currentStopID.map { [$0] } ?? [])
            + (tripDetails?.nextStops ?? []).map(\.stopID))
        selectedLine = lineDetails
        selectedTripCoordinates = tripDetails?.coordinates ?? []
        liveTripDetails = tripDetails
    }

    func clearJourneySelection() {
        selectedRouteID = nil
        selectedTripID = nil
        selectedTripStopIDs = []
        selectedLine = nil
        selectedTripCoordinates = []
        liveTripDetails = nil
    }

    func search(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults {
        await repository.search(query, near: coordinate)
    }

    func updateMapStops(in viewport: TransitMapViewport) {
        mapStopsTask?.cancel()
        mapStopsRequestID = UUID()
        let requestID = mapStopsRequestID

        guard viewport.isValid, viewport.zoom >= 13 else {
            mapStops = []
            return
        }

        mapStopsTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.mapStopsRequestID == requestID else { return }
            let stops = await self.repository.mapStops(in: viewport)
            guard !Task.isCancelled, self.mapStopsRequestID == requestID else { return }
            self.mapStops = stops
            self.mapStopsTask = nil
        }
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

    func tripDetails(tripID: String, fromStopID: String?) async -> TransitTripDetails? {
        await repository.tripDetails(tripID: tripID, fromStopID: fromStopID)
    }

    func tripDetails(tripID: String, serviceDate: String, fromStopSequence: Int,
                     scheduleShiftSeconds: Int, frequencyStartSeconds: Int?,
                     frequencyHeadwaySeconds: Int?, isFrequencyEstimate: Bool) async -> TransitTripDetails? {
        return await repository.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                            fromStopSequence: fromStopSequence,
                                            scheduleShiftSeconds: scheduleShiftSeconds,
                                            frequencyStartSeconds: frequencyStartSeconds,
                                            frequencyHeadwaySeconds: frequencyHeadwaySeconds,
                                            isFrequencyEstimate: isFrequencyEstimate)
    }

    func departures(at stopIDs: [String]) async -> [TransitDeparture] {
        await repository.departures(at: stopIDs)
    }

    func alerts(for stopIDs: [String]) async -> [String] {
        await repository.alerts(for: stopIDs)
    }

    func railwayScheduleAttribution() async -> String? {
        await repository.railwayScheduleAttribution()
    }

    func railwayScheduleAttribution(for stopID: String?) async -> String? {
        guard stopID?.hasPrefix(TransitousTransitDataProvider.stopIDPrefix) != true else { return nil }
        return await repository.railwayScheduleAttribution()
    }

    private func apply(line: TransitLineDetails?, trip: TransitTripDetails?) {
        selectedLine = line
        selectedTripStopIDs = Set(((trip?.pastStops ?? []) + (trip?.nextStops ?? [])).map(\.stopID)
            + (trip?.currentStopID.map { [$0] } ?? []))
        selectedTripCoordinates = trip?.coordinates ?? []
    }
}
