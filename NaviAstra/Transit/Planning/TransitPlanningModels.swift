import Foundation
import CryptoKit

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
