import Foundation
import os
import CryptoKit

nonisolated enum TransitPlanningPhase: Equatable, Sendable {
    case loadingSchedule
    case searchingConnections
    case enrichingGeometry
}

typealias TransitPlanningProgressHandler = @MainActor @Sendable (TransitPlanningPhase?) async -> Void
typealias TransitProvisionalRoutesHandler = @MainActor @Sendable ([NavigationRoute]) async -> Void

nonisolated enum TransitSignposting {
    static let log = OSLog(subsystem: "STDMSolution.NaviAstra", category: "TransitPlanning")

    static func begin(_ name: StaticString, planningID: UInt64? = nil) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        if let planningID {
            os_signpost(.begin, log: log, name: name, signpostID: identifier,
                        "planningID=%{public}llu", planningID)
        } else {
            os_signpost(.begin, log: log, name: name, signpostID: identifier)
        }
        return identifier
    }

    static func end(_ name: StaticString, identifier: OSSignpostID, planningID: UInt64? = nil) {
        if let planningID {
            os_signpost(.end, log: log, name: name, signpostID: identifier,
                        "planningID=%{public}llu", planningID)
        } else {
            os_signpost(.end, log: log, name: name, signpostID: identifier)
        }
    }

    static func event(_ name: StaticString, value: Int, planningID: UInt64? = nil) {
        if let planningID {
            os_signpost(.event, log: log, name: name,
                        "planningID=%{public}llu value=%{public}d", planningID, value)
        } else {
            os_signpost(.event, log: log, name: name, "value=%{public}d", value)
        }
    }

    static func summary(_ value: String, planningID: UInt64) {
        os_signpost(.event, log: log, name: "PlanningSummary",
                    "planningID=%{public}llu %{public}@", planningID, value as NSString)
    }
}

nonisolated final class TransitPlanningTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var durations: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    private var values: [String: String] = [:]

    func recordDuration(_ name: String, startedAt: TimeInterval) {
        let milliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        lock.lock()
        durations[name] = max(durations[name] ?? 0, milliseconds)
        lock.unlock()
    }

    func setCount(_ name: String, value: Int) {
        lock.lock()
        counts[name] = value
        lock.unlock()
    }

    func setValue(_ name: String, value: String) {
        lock.lock()
        values[name] = value
        lock.unlock()
    }

    func recordElapsedDuration(_ name: String) {
        recordDuration(name, startedAt: startedAt)
    }

    func addCount(_ name: String, value: Int) {
        lock.lock()
        counts[name, default: 0] += value
        lock.unlock()
    }

    func emitSummary(planningID: UInt64) {
        lock.lock()
        let durations = self.durations
        let counts = self.counts
        let values = self.values
        lock.unlock()

        func duration(_ name: String) -> String {
            guard let value = durations[name] else { return "n/a" }
            return "\(Int(value.rounded()))ms"
        }
        func count(_ name: String) -> String {
            counts[name].map(String.init) ?? "n/a"
        }
        func value(_ name: String) -> String {
            values[name] ?? "n/a"
        }
        let shapeHitRate: String
        if let reachable = counts["matrixReachableTargets"], reachable > 0,
           let shapes = counts["matrixShapesReturned"] {
            shapeHitRate = "\(Int((Double(shapes) / Double(reachable) * 100).rounded()))%"
        } else {
            shapeHitRate = "n/a"
        }
        let total = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
        var summary = "total=\(total)ms gtfsLoad=\(duration("GTFSLoad")) indexBuild=\(duration("ScheduleIndexBuild")) "
            + "realtimeWait=\(duration("RealtimeWait")) realtimeFetch=\(duration("RealtimeBackgroundFetch")) "
            + "nearbyStopsMax=\(duration("NearbyStops")) "
            + "walkingMatrixMax=\(duration("WalkingMatrix")) transitSearch=\(duration("TransitSearch")) "
            + "candidateRanking=\(duration("CandidateRanking")) geometryFetch=\(duration("GeometryFetch")) "
            + "snapshotBuild=\(duration("TransitSnapshotBuild")) "
            + "timeToStaticCandidates=\(duration("TimeToStaticCandidates")) "
            + "timeToFirstRoute=\(duration("TimeToFirstRoute")) "
            + "timeToRouteReady=\(duration("TimeToRouteReady")) "
            + "counts[nearbyStops=\(count("nearbyStops")), tripDaysExamined=\(count("tripDaysExamined")), "
            + "activeTrips=\(count("activeTrips")), activeRoutes=\(count("activeRoutes")), "
            + "routesTouched=\(count("routesTouched")), activePatterns=\(count("activePatterns")), "
            + "markedStops=\(count("markedStops")), departureScans=\(count("departureTripsScanned")), "
            + "departureDominated=\(count("departureTripsDominated")), "
            + "stopsWithDepartures=\(count("stopsWithDepartures")), candidates=\(count("candidates")), "
            + "uniqueRoutes=\(count("uniqueRoutes")), walkingSegments=\(count("walkingSegments")), "
            + "rounds=\(count("roundsExecuted")), matrixCalls=\(count("matrixCalls")), "
            + "matrixTargets=\(count("matrixTargetsSent")), matrixHTTPErrorCount=\(count("matrixHTTPErrorCount")), "
            + "matrixErrorCount=\(count("matrixErrorCount")), "
            + "matrixHTTPErrorStatus=\(count("matrixHTTPErrorStatus")), "
            + "matrixFallbackCount=\(count("matrixFallbackCount")), fallbackRequestCount=\(count("fallbackRequestCount")), "
            + "approximateFallbackStops=\(count("approximateFallbackStops")), "
            + "matrixReachable=\(count("matrixReachableTargets")), matrixUnreachable=\(count("matrixUnreachableTargets")), "
            + "matrixOverWalkLimit=\(count("matrixOverWalkLimit")), matrixShapesReturned=\(count("matrixShapesReturned")), "
            + "matrixShapeHitRate=\(shapeHitRate), "
            + "geometryCacheHits=\(count("geometryCacheHits")), geometryRequests=\(count("geometryRequests")), "
            + "accessCacheHits=\(count("persistentAccessCacheHits")), "
            + "searchWindowStage=\(count("searchWindowStage")), "
            + "realtimeAgeSeconds=\(count("realtimeAgeSeconds")), realtimeFreshness=\(value("realtimeFreshness")), "
            + "realtimeUsed=\(value("realtimeUsed")), realtimeRefreshDeferred=\(count("realtimeRefreshDeferred"))]"
        summary += "compiledIndexLoad=\(duration("CompiledIndexLoad")) compiledIndexHit=\(count("compiledIndexHit")) "
            + "transferGraphCacheHit=\(count("transferGraphCacheHit")) "
            + "flatTripServiceIndexHit=\(count("flatTripServiceIndexHit")) "
        TransitSignposting.summary(summary, planningID: planningID)
    }
}

nonisolated enum TransitRoutingError: LocalizedError {
    case invalidResponse
    case noJourney
    case noJourneyBeforeArrivalDeadline
    case noParkRide
    case walkingUnavailable
    case walkingServerError(Int)
    case walkingRateLimited
    case feedUnavailable
    case railwayFeedUnavailable
    case outsideCoverage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Źródło rozkładów zwróciło nieprawidłowe dane."
        case .noJourney:
            "Nie znaleziono połączenia kolejowego ani komunikacji publicznej dla wybranej godziny."
        case .noJourneyBeforeArrivalDeadline:
            "Nie znaleziono połączenia, które dotrze przed wybraną godziną."
        case .noParkRide:
            "Nie udało się znaleźć działającego połączenia z parkingu P+R."
        case .walkingUnavailable:
            "Nie udało się wyznaczyć dojścia pieszo do przystanków przez serwer Valhalla."
        case .walkingServerError(let statusCode):
            "Serwer tras odrzucił wyznaczenie dojścia (HTTP \(statusCode))."
        case .walkingRateLimited:
            "Serwer tras ograniczył liczbę żądań. Poczekaj chwilę i spróbuj ponownie."
        case .feedUnavailable:
            "Nie udało się pobrać rozkładu jazdy komunikacji publicznej."
        case .railwayFeedUnavailable:
            "Krajowy rozkład kolejowy jest chwilowo niedostępny. Spróbuj ponownie za chwilę."
        case .outsideCoverage:
            "Wybierz początek i cel, z których można dojść do stacji lub przystanku w 30 minut pieszo."
        }
    }
}

struct LodzTransitRouteProvider {
    let walkingRoutingEndpoint: URL

    init(walkingRoutingEndpoint: URL = URL(string: UserDefaults.standard.string(forKey: "routingServer")
        ?? "https://valhalla1.openstreetmap.de")!) {
        self.walkingRoutingEndpoint = walkingRoutingEndpoint
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, parkRide: Bool = false,
                         departingAt: Date = Date(),
                         onProgress: TransitPlanningProgressHandler? = nil,
                         onProvisionalRoutes: TransitProvisionalRoutesHandler? = nil) async throws -> [NavigationRoute] {
        guard !parkRide else { throw TransitRoutingError.noParkRide }
        return try await LodzTransitRepository.shared.calculateRoutes(from: from, to: to,
                                                                      departingAt: departingAt,
                                                                      walkingRoutingEndpoint: walkingRoutingEndpoint,
                                                                      onProgress: onProgress,
                                                                      onProvisionalRoutes: onProvisionalRoutes)
    }

    func vehiclePositions(near coordinate: Coordinate) async -> TransitVehicleFeed {
        await LodzTransitRepository.shared.vehiclePositions(near: coordinate)
    }

    func departures(at stopID: String, limit: Int = 10) async -> [TransitDeparture] {
        await LodzTransitRepository.shared.departures(at: stopID, limit: limit)
    }

    func departures(at stopIDs: [String], limit: Int = 10) async -> [TransitDeparture] {
        await LodzTransitRepository.shared.departures(at: stopIDs, limit: limit)
    }

    func alerts(for stopID: String) async -> [String] {
        await LodzTransitRepository.shared.alerts(for: stopID)
    }

    func alerts(for stopIDs: [String]) async -> [String] {
        await LodzTransitRepository.shared.alerts(for: stopIDs)
    }

    func railwayScheduleAttribution() async -> String? {
        await LodzTransitRepository.shared.railwayScheduleAttribution()
    }

    func search(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults {
        await LodzTransitRepository.shared.search(query, near: coordinate)
    }

    func lineDetails(for routeID: String) async -> TransitLineDetails? {
        await LodzTransitRepository.shared.lineDetails(for: routeID)
    }

    func vehicleDetails(id: String) async -> TransitTripDetails? {
        await LodzTransitRepository.shared.vehicleDetails(id: id)
    }

    func tripDetails(for departure: TransitDeparture) async -> TransitTripDetails? {
        await LodzTransitRepository.shared.tripDetails(for: departure)
    }

    func tripDetails(tripID: String, serviceDate: String, fromStopSequence: Int) async -> TransitTripDetails? {
        await LodzTransitRepository.shared.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                                       fromStopSequence: fromStopSequence)
    }
}

actor LodzTransitRepository {
    static let shared = LodzTransitRepository()
    static let maximumDepartureSearchWindow: TimeInterval = 18 * 60 * 60
    static let maximumJourneyDuration: TimeInterval = 18 * 60 * 60
    static let stagedDepartureWindows: [TimeInterval] = [2, 6, 18].map { $0 * 60 * 60 }
    static let maximumAccessWalkTime: TimeInterval = 30 * 60
    // Conservative client batch size; the server's Valhalla max_locations is configuration-specific.
    static let walkingMatrixBatchSize = 20
    static let maximumLocalWalkingCandidates = walkingMatrixBatchSize * 4
    static let maximumRailWalkingCandidates = walkingMatrixBatchSize * 2
    static let maximumAccessWalkDistance: Double = 10_000
    static let maximumApproximateLocalWalkingCandidates = 12
    static let maximumApproximateRailWalkingCandidates = 8
    static let maximumWalkingGeometryCandidates = 6
    static let maximumCachedWalkingGeometries = 5_000
    static let maximumCachedAccessEstimates = 10_000

    let staticFeedURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/GTFS.zip")!
    let tripUpdatesURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/trip_updates.bin")!
    let alertsURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/alerts.bin")!
    let vehiclePositionsURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/vehicle_positions.bin")!
    let railwayFeedURL = URL(string: "https://mkuran.pl/gtfs/polish_trains.zip")!
    let railwayTripUpdatesURL = URL(string: "https://mkuran.pl/gtfs/polish_trains/updates.pb")!
    let cacheDirectory: URL = {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("LodzTransit", isDirectory: true)
    }()
    var compiledDatabaseURL: URL {
        cacheDirectory.appendingPathComponent("compiled-transit-index-v3.plist")
    }
    var database: GTFSDatabase?
    var databaseWasCached = false
    var databaseLoadedAt: Date?
    var databaseLoadTask: Task<LoadedTransitDatabase, Error>?
    var realtimeSnapshot: GTFSRealtimeSnapshot?
    var realtimeLoadedAt: Date?
    var realtimeLoadTask: Task<GTFSRealtimeSnapshot, Never>?
    var vehiclesSnapshot: [GTFSRealtimeVehicle] = []
    var vehiclesUpdatedAt: Date?
    var vehiclesLoadedAt: Date?
    var nextPlanningID: UInt64 = 0
    var walkingGeometryCache: [String: [TransitWalkingGeometryKey: TransitWalkingGeometry]] = [:]
    var walkingGeometryCacheOrder: [String: [TransitWalkingGeometryKey]] = [:]
    var walkingGeometryStoredAt: [String: [TransitWalkingGeometryKey: Date]] = [:]
    var persistentAccessEstimates: [String: TransitAccessEstimate] = [:]
    var pedestrianCacheLoaded = false
    var pedestrianCacheWriteTask: Task<Void, Never>?
    var loadedDatabaseFingerprint: String?
    var flatTripServiceIndex: TransitFlatTripServiceIndex?
    var flatTripServiceFingerprint: String?
    var flatTripServiceBuildTask: Task<Void, Never>?

}


nonisolated struct GTFSStopPrediction {
    let stopID: String
    let arrival: Date
    let departure: Date
    let delaySeconds: Int?
    let hasRealtime: Bool
}

nonisolated struct GTFSTripInstance {
    let trip: GTFSTrip
    let route: GTFSRoute
    let serviceDate: String
    let times: [GTFSStopPrediction]
    let patternKey: String
}

nonisolated struct TransitBoardingDeparture {
    let instanceIndex: Int
    let stopIndex: Int
    let time: Date
}

nonisolated struct TransitWalkOption: Sendable {
    let stop: GTFSStop
    let distance: Double
    let duration: TimeInterval
    let coordinates: [Coordinate]
    let hasResolvedGeometry: Bool
    var isApproximate = false
}

nonisolated struct TransitFootpath: Codable, Sendable {
    let fromStopID: String
    let toStopID: String
    let walkingDistance: Double
    let walkingDuration: TimeInterval
    let minimumTransferTime: TimeInterval
    let coordinates: [Coordinate]
}

nonisolated struct TransitPlanCandidate {
    let label: TransitPathLabel
    let destinationWalk: TransitWalkOption
    let arrival: Date
}

nonisolated struct TransitWalkingGeometryKey: Hashable, Codable, Sendable {
    let fromLatitude: UInt64
    let fromLongitude: UInt64
    let toLatitude: UInt64
    let toLongitude: UInt64

    init(from: Coordinate, to: Coordinate) {
        fromLatitude = from.latitude.bitPattern
        fromLongitude = from.longitude.bitPattern
        toLatitude = to.latitude.bitPattern
        toLongitude = to.longitude.bitPattern
    }
}

nonisolated struct TransitWalkingGeometryRequest: Sendable {
    let from: Coordinate
    let to: Coordinate
    var key: TransitWalkingGeometryKey { TransitWalkingGeometryKey(from: from, to: to) }
}

nonisolated struct TransitWalkingGeometry: Codable, Sendable {
    let coordinates: [Coordinate]
    let duration: TimeInterval
}

nonisolated struct TransitAccessEstimate: Codable, Sendable {
    let key: String
    let origin: Coordinate
    let stopID: String
    let distance: Double
    let duration: TimeInterval
    let storedAt: Date
}

nonisolated struct PersistedWalkingGeometry: Codable, Sendable {
    let endpoint: String
    let key: TransitWalkingGeometryKey
    let geometry: TransitWalkingGeometry
    let storedAt: Date
}

nonisolated struct PersistedPedestrianCache: Codable, Sendable {
    static let currentSchemaVersion = 2
    let schemaVersion: Int
    let geometries: [PersistedWalkingGeometry]
    let accessEstimates: [TransitAccessEstimate]
}

func fetchTransitWalkingGeometry(
    _ request: TransitWalkingGeometryRequest,
    endpoint: URL
) async -> (TransitWalkingGeometryKey, TransitWalkingGeometry?) {
    do {
        guard let route = try await ValhallaRouteProvider(endpoint: endpoint)
            .calculateRoutes(from: request.from, to: request.to, mode: .walking).first else {
            return (request.key, nil)
        }
        return (request.key, TransitWalkingGeometry(coordinates: route.coordinates,
                                                    duration: route.expectedTravelTime))
    } catch {
        return (request.key, nil)
    }
}

nonisolated struct TransitRide {
    let instanceIndex: Int
    let boardIndex: Int
    let alightIndex: Int
}

nonisolated final class TransitPathLabel {
    let arrival: Date
    let currentStopID: String
    let initialWalkingSeconds: Double
    let walkingSeconds: Double
    let rideCount: Int
    let transferCount: Int
    let transferDepth: Int
    let lastLegWasTransfer: Bool
    let initialStopID: String
    let parent: TransitPathLabel?
    let ride: TransitRide?
    let transfer: TransitFootpath?

    init(arrival: Date, currentStopID: String, initialWalkingSeconds: Double, walkingSeconds: Double,
         rideCount: Int, transferCount: Int, transferDepth: Int, lastLegWasTransfer: Bool, initialStopID: String,
         parent: TransitPathLabel?, ride: TransitRide?, transfer: TransitFootpath? = nil) {
        self.arrival = arrival
        self.currentStopID = currentStopID
        self.initialWalkingSeconds = initialWalkingSeconds
        self.walkingSeconds = walkingSeconds
        self.rideCount = rideCount
        self.transferCount = transferCount
        self.transferDepth = transferDepth
        self.lastLegWasTransfer = lastLegWasTransfer
        self.initialStopID = initialStopID
        self.parent = parent
        self.ride = ride
        self.transfer = transfer
    }
}


nonisolated struct TransitBitSet: Sendable {
    private var words: [UInt64]

    init(count: Int) {
        words = Array(repeating: 0, count: (count + 63) / 64)
    }

    mutating func insert(_ index: Int) {
        guard index >= 0, index / 64 < words.count else { return }
        words[index / 64] |= UInt64(1) << UInt64(index % 64)
    }

    func contains(_ index: Int) -> Bool {
        guard index >= 0, index / 64 < words.count else { return false }
        return words[index / 64] & (UInt64(1) << UInt64(index % 64)) != 0
    }
}

nonisolated struct TransitFlatTripServiceIndex: Sendable {
    static let headerByteCount = 44
    private static let magic = Array("NATIDX01".utf8)
    private let data: Data

    init?(data: Data, fingerprint: String, tripCount: Int) {
        guard tripCount >= 0, tripCount <= (Int.max - Self.headerByteCount) / 4,
              data.count == Self.headerByteCount + tripCount * 4,
              Array(data.prefix(Self.magic.count)) == Self.magic,
              Array(data[8..<40]) == Self.fingerprintBytes(fingerprint),
              Self.readUInt32(data, at: 40) == UInt32(clamping: tripCount) else { return nil }
        self.data = data
    }

    func serviceIndex(at tripIndex: Int) -> Int {
        guard tripIndex >= 0,
              Self.headerByteCount + (tripIndex + 1) * 4 <= data.count else { return -1 }
        let value = Self.readUInt32(data, at: Self.headerByteCount + tripIndex * 4)
        return value == UInt32.max ? -1 : Int(value)
    }

    static func header(fingerprint: String, tripCount: Int) -> Data {
        var data = Data(magic)
        data.append(contentsOf: fingerprintBytes(fingerprint))
        append(UInt32(clamping: tripCount), to: &data)
        return data
    }

    static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func fingerprintBytes(_ fingerprint: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(fingerprint.utf8)))
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

nonisolated struct TransitSnapshot: Sendable {
    let database: GTFSDatabase
    let realtime: GTFSRealtimeSnapshot
    let activeTripBitsByServiceDate: [String: TransitBitSet]
    let serviceDates: [String]

    init(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
         departure: Date, maximumDepartureWindow: TimeInterval,
         flatTripServiceIndex: TransitFlatTripServiceIndex?) {
        self.database = database
        self.realtime = realtime
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let today = calendar.startOfDay(for: departure)
        let finalDay = calendar.startOfDay(for: departure.addingTimeInterval(maximumDepartureWindow))
        let offsets = -1...(finalDay > today ? 1 : 0)
        var serviceDates: [String] = []
        var tripBitsByDate: [String: TransitBitSet] = [:]
        let serviceIndexByID = Dictionary(uniqueKeysWithValues: database.serviceIDs.enumerated()
            .map { ($1, $0) })

        for offset in offsets {
            guard let serviceDay = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let date = GTFSDate.string(from: serviceDay)
            let weekday = GTFSDate.weekdayKey(for: serviceDay, calendar: calendar)
            var activeServices = TransitBitSet(count: database.serviceIDs.count)
            for (serviceIndex, serviceID) in database.serviceIDs.enumerated() {
                if let exception = database.exceptions[serviceID]?[date] {
                    if exception == 1 { activeServices.insert(serviceIndex) }
                } else if let service = database.calendars[serviceID],
                          date >= service.startDate, date <= service.endDate,
                          service.weekdayFlags[weekday] == true {
                    activeServices.insert(serviceIndex)
                }
            }
            var bits = TransitBitSet(count: database.trips.count)
            for tripIndex in database.trips.indices {
                let serviceIndex = flatTripServiceIndex?.serviceIndex(at: tripIndex)
                    ?? serviceIndexByID[database.trips[tripIndex].serviceID]
                    ?? -1
                if activeServices.contains(serviceIndex) { bits.insert(tripIndex) }
            }
            serviceDates.append(date)
            tripBitsByDate[date] = bits
        }
        self.serviceDates = serviceDates
        activeTripBitsByServiceDate = tripBitsByDate
    }

    func activeInstances(for pattern: GTFSRoutePattern,
                         after departure: Date,
                         maximumDeparture: Date) -> [GTFSTripInstance] {
        guard let route = database.routes[pattern.routeID] else { return [] }
        var instances: [GTFSTripInstance] = []
        for serviceDate in serviceDates {
            guard let serviceDay = GTFSDate.date(from: serviceDate),
                  let tripBits = activeTripBitsByServiceDate[serviceDate] else { continue }
            for tripIndex in pattern.tripIndices where tripBits.contains(tripIndex) {
                guard database.trips.indices.contains(tripIndex) else { continue }
                let trip = database.trips[tripIndex]
                guard let firstStop = trip.stopTimes.first, let lastStop = trip.stopTimes.last,
                      serviceDay.addingTimeInterval(TimeInterval(lastStop.arrivalSeconds))
                        > departure.addingTimeInterval(-3_600),
                      serviceDay.addingTimeInterval(TimeInterval(firstStop.departureSeconds))
                        < maximumDeparture,
                      !realtime.isCanceled(tripID: trip.id, serviceDate: serviceDate) else { continue }

                var previousDelay: Int?
                let times = trip.stopTimes.map { stop -> GTFSStopPrediction in
                    let scheduledArrival = serviceDay.addingTimeInterval(TimeInterval(stop.arrivalSeconds))
                    let scheduledDeparture = serviceDay.addingTimeInterval(TimeInterval(stop.departureSeconds))
                    let update = realtime.update(tripID: trip.id, serviceDate: serviceDate,
                                                 stopID: stop.stopID, stopSequence: stop.sequence)
                    let arrivalDelay = update?.arrivalDelay
                        ?? update?.arrivalTime.map { Int($0.timeIntervalSince(scheduledArrival).rounded()) }
                    let departureDelay = update?.departureDelay
                        ?? update?.departureTime.map { Int($0.timeIntervalSince(scheduledDeparture).rounded()) }
                    if let delay = departureDelay ?? arrivalDelay { previousDelay = delay }
                    let arrival = update?.arrivalTime
                        ?? scheduledArrival.addingTimeInterval(TimeInterval(arrivalDelay ?? previousDelay ?? 0))
                    let leave = update?.departureTime
                        ?? scheduledDeparture.addingTimeInterval(TimeInterval(departureDelay ?? previousDelay ?? 0))
                    return GTFSStopPrediction(stopID: stop.stopID, arrival: arrival, departure: leave,
                                              delaySeconds: departureDelay ?? arrivalDelay ?? previousDelay,
                                              hasRealtime: update != nil || previousDelay != nil)
                }
                guard let first = times.first, let last = times.last,
                      last.arrival > departure.addingTimeInterval(-3_600),
                      first.departure < maximumDeparture else { continue }
                instances.append(GTFSTripInstance(trip: trip, route: route,
                                                  serviceDate: serviceDate, times: times,
                                                  patternKey: trip.patternKey))
            }
        }
        return instances
    }
}
