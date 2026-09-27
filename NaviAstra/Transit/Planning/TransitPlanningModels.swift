import Foundation

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
}

nonisolated struct TransitBoardingDeparture {
    let instanceIndex: Int
    let time: Date
}

nonisolated final class TransitActiveScheduleCache: @unchecked Sendable {
    private struct EnvelopeKey: Hashable {
        let patternID: Int
        let stopIndex: Int
        let departureCount: Int
    }

    struct PatternSchedule {
        let instances: [GTFSTripInstance]
        let departuresByStopIndex: [[TransitBoardingDeparture]]
    }

    let coverageStart: Date
    let coverageEnd: Date
    private let lock = NSLock()
    private var schedulesByPatternID: [Int: PatternSchedule] = [:]
    private var arrivalEnvelopes: [EnvelopeKey: [[Int]]] = [:]

    init(coverageStart: Date, coverageEnd: Date) {
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
    }

    func schedule(for patternID: Int) -> PatternSchedule? {
        lock.lock()
        defer { lock.unlock() }
        return schedulesByPatternID[patternID]
    }

    func store(_ schedule: PatternSchedule, for patternID: Int) {
        lock.lock()
        schedulesByPatternID[patternID] = schedule
        lock.unlock()
    }

    func arrivalEnvelope(for patternID: Int, stopIndex: Int,
                         departureCount: Int) -> [[Int]]? {
        lock.lock()
        defer { lock.unlock() }
        return arrivalEnvelopes[EnvelopeKey(patternID: patternID, stopIndex: stopIndex,
                                            departureCount: departureCount)]
    }

    func storeArrivalEnvelope(_ envelope: [[Int]], for patternID: Int, stopIndex: Int,
                              departureCount: Int) {
        lock.lock()
        arrivalEnvelopes[EnvelopeKey(patternID: patternID, stopIndex: stopIndex,
                                     departureCount: departureCount)] = envelope
        lock.unlock()
    }
}

nonisolated struct TransitPlanningContext: Sendable {
    let snapshot: TransitSnapshot
    let usingCachedSchedule: Bool
    let activeScheduleCache: TransitActiveScheduleCache?
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
    let rideSeconds: Double
    let rideCount: Int
    let transferCount: Int
    let transferDepth: Int
    let lastLegWasTransfer: Bool
    let initialStopID: String
    let parent: TransitPathLabel?
    let ride: TransitRide?
    let transfer: TransitFootpath?

    init(arrival: Date, currentStopID: String, initialWalkingSeconds: Double, walkingSeconds: Double,
         rideSeconds: Double,
         rideCount: Int, transferCount: Int, transferDepth: Int, lastLegWasTransfer: Bool, initialStopID: String,
         parent: TransitPathLabel?, ride: TransitRide?, transfer: TransitFootpath? = nil) {
        self.arrival = arrival
        self.currentStopID = currentStopID
        self.initialWalkingSeconds = initialWalkingSeconds
        self.walkingSeconds = walkingSeconds
        self.rideSeconds = rideSeconds
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

nonisolated struct TransitSnapshot: Sendable {
    let database: GTFSDatabase
    let realtime: GTFSRealtimeSnapshot
    let activeServiceBitsByServiceDate: [String: TransitBitSet]
    let serviceDates: [String]

    init(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
         departure: Date, maximumDepartureWindow: TimeInterval) {
        self.database = database
        self.realtime = realtime
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let today = calendar.startOfDay(for: departure)
        let finalDay = calendar.startOfDay(for: departure.addingTimeInterval(maximumDepartureWindow))
        let offsets = -1...(finalDay > today ? 1 : 0)
        var serviceDates: [String] = []
        var serviceBitsByDate: [String: TransitBitSet] = [:]

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
            serviceDates.append(date)
            serviceBitsByDate[date] = activeServices
        }
        self.serviceDates = serviceDates
        activeServiceBitsByServiceDate = serviceBitsByDate
    }

    func activeInstances(for pattern: GTFSRoutePattern,
                         after departure: Date,
                         maximumDeparture: Date,
        trace: TransitPlanningTrace? = nil) -> [GTFSTripInstance] {
        guard let route = database.routes[pattern.routeID] else { return [] }
        guard let tripsByService = pattern.tripsByService else { return [] }
        var instances: [GTFSTripInstance] = []
        var tripRowsVisited = 0
        for serviceDate in serviceDates {
            guard let serviceDay = GTFSDate.date(from: serviceDate),
                  let activeServices = activeServiceBitsByServiceDate[serviceDate] else { continue }
            for group in tripsByService where activeServices.contains(group.serviceIndex) {
                let departureSeconds = departure.timeIntervalSince(serviceDay)
                let maximumDepartureSeconds = maximumDeparture.timeIntervalSince(serviceDay)
                let earliestPossibleFirstDeparture = Int(floor(departureSeconds - 3_600))
                    - group.maximumScheduledDurationSeconds
                let firstDepartureAtOrAfter = Int(ceil(maximumDepartureSeconds))
                let lowerIndex = Self.tripIndexBoundary(
                    in: group.tripIndices, for: earliestPossibleFirstDeparture,
                    upperBound: true, trips: database.trips)
                let upperIndex = Self.tripIndexBoundary(
                    in: group.tripIndices, for: firstDepartureAtOrAfter,
                    upperBound: false, trips: database.trips)
                guard lowerIndex < upperIndex else { continue }
                tripRowsVisited += upperIndex - lowerIndex
                for tripIndex in group.tripIndices[lowerIndex..<upperIndex] {
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
                                                      serviceDate: serviceDate, times: times))
                }
            }
        }
        trace?.addCount("scheduleTripRowsVisited", value: tripRowsVisited)
        return instances
    }

    private static func tripIndexBoundary(in tripIndices: [Int], for departureSeconds: Int,
                                          upperBound: Bool, trips: [GTFSTrip]) -> Int {
        var lower = 0
        var upper = tripIndices.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let firstDeparture = trips[tripIndices[middle]].stopTimes.first?.departureSeconds ?? Int.min
            let advances = firstDeparture < departureSeconds
                || (upperBound && firstDeparture == departureSeconds)
            if advances {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
