import Foundation

nonisolated struct GTFSStopPrediction {
    let stopID: String
    let arrival: Date
    let departure: Date
    let delaySeconds: Int?
    let hasRealtime: Bool
    var isSkipped = false
    var isBoardable = true
    var isAlightable = true
}

nonisolated struct GTFSTripInstance {
    let trip: GTFSTrip
    let route: GTFSRoute
    let serviceDate: String
    let times: [GTFSStopPrediction]
    let scheduleShiftSeconds: Int
    let frequencyStartSeconds: Int?
    let frequencyHeadwaySeconds: Int?
    let isFrequencyEstimate: Bool

    init(trip: GTFSTrip, route: GTFSRoute, serviceDate: String, times: [GTFSStopPrediction],
         scheduleShiftSeconds: Int = 0, frequencyStartSeconds: Int? = nil,
         frequencyHeadwaySeconds: Int? = nil, isFrequencyEstimate: Bool = false) {
        self.trip = trip
        self.route = route
        self.serviceDate = serviceDate
        self.times = times
        self.scheduleShiftSeconds = scheduleShiftSeconds
        self.frequencyStartSeconds = frequencyStartSeconds
        self.frequencyHeadwaySeconds = frequencyHeadwaySeconds
        self.isFrequencyEstimate = isFrequencyEstimate
    }
}

nonisolated enum GTFSTripInstanceBuilder {
    static func build(trip: GTFSTrip, route: GTFSRoute, serviceDate: String,
                      serviceStart: Date, database: GTFSDatabase,
                      realtime: GTFSRealtimeSnapshot, earliestArrival: Date,
                      latestDeparture: Date,
                      cancellationToken: TransitPlanningCancellationToken? = nil)
        -> [GTFSTripInstance] {
        guard let firstStop = trip.stopTimes.first, let lastStop = trip.stopTimes.last,
              !realtime.isCanceled(tripID: trip.id, serviceDate: serviceDate) else { return [] }
        let frequencyWindows = database.frequenciesByTripID[trip.id] ?? []
        var departures: [(shift: Int, start: Int?, headway: Int?, isEstimate: Bool)] = []
        if frequencyWindows.isEmpty {
            let scheduledDeparture = serviceStart.addingTimeInterval(TimeInterval(firstStop.departureSeconds))
            let scheduledArrival = serviceStart.addingTimeInterval(TimeInterval(lastStop.arrivalSeconds))
            guard scheduledArrival > earliestArrival, scheduledDeparture < latestDeparture else { return [] }
            departures.append((0, nil, nil, false))
        } else {
            guard let earliestSeconds = GTFSDate.serviceSeconds(at: earliestArrival, for: serviceDate),
                  let latestSeconds = GTFSDate.serviceSeconds(at: latestDeparture, for: serviceDate) else { return [] }
            let scheduledDuration = lastStop.arrivalSeconds - firstStop.departureSeconds
            var seenFrequencyStarts = Set<Int>()
            for window in frequencyWindows {
                if Task.isCancelled || cancellationToken?.isCancelled == true { return [] }
                let interval = Double(window.headwaySeconds)
                let firstIndex = max(0, Int(floor((earliestSeconds - Double(window.startSeconds)
                                                   - Double(scheduledDuration)) / interval)) + 1)
                let endIndex = max(0, Int(ceil((latestSeconds - Double(window.startSeconds)) / interval)))
                guard firstIndex < endIndex else { continue }
                for index in firstIndex..<endIndex {
                    if Task.isCancelled || cancellationToken?.isCancelled == true { return [] }
                    let (offset, overflow) = index.multipliedReportingOverflow(by: window.headwaySeconds)
                    guard !overflow else { break }
                    let (startSeconds, additionOverflow) = window.startSeconds.addingReportingOverflow(offset)
                    guard !additionOverflow, startSeconds < window.endSeconds else { break }
                    guard seenFrequencyStarts.insert(startSeconds).inserted else { continue }
                    if realtime.isCanceled(tripID: trip.id, serviceDate: serviceDate,
                                           frequencyStartSeconds: startSeconds) { continue }
                    departures.append((startSeconds - firstStop.departureSeconds,
                                       startSeconds, window.headwaySeconds, !window.exactTimes))
                }
            }
        }

        var instances: [GTFSTripInstance] = []
        instances.reserveCapacity(departures.count)
        for departure in departures {
            if Task.isCancelled || cancellationToken?.isCancelled == true { return [] }
            var previousDelay: Int?
            var hasNoRealtimeDataFromHere = false
            var times: [GTFSStopPrediction] = []
            times.reserveCapacity(trip.stopTimes.count)
            for stop in trip.stopTimes {
                if Task.isCancelled || cancellationToken?.isCancelled == true { return [] }
                let scheduledArrival = serviceStart.addingTimeInterval(
                    TimeInterval(stop.arrivalSeconds + departure.shift))
                let scheduledDeparture = serviceStart.addingTimeInterval(
                    TimeInterval(stop.departureSeconds + departure.shift))
                let update = realtime.update(tripID: trip.id, serviceDate: serviceDate,
                                             stopID: stop.stopID, stopSequence: stop.sequence,
                                             frequencyStartSeconds: departure.start)
                if update?.hasNoData == true {
                    hasNoRealtimeDataFromHere = true
                    previousDelay = nil
                }
                let timingUpdate = hasNoRealtimeDataFromHere || update?.hasUsableTiming == false
                    ? nil : update
                let arrivalDelay = timingUpdate?.arrivalDelay
                    ?? timingUpdate?.arrivalTime.map { Int($0.timeIntervalSince(scheduledArrival).rounded()) }
                let departureDelay = timingUpdate?.departureDelay
                    ?? timingUpdate?.departureTime.map { Int($0.timeIntervalSince(scheduledDeparture).rounded()) }
                if let delay = departureDelay ?? arrivalDelay { previousDelay = delay }
                let arrival = timingUpdate?.arrivalTime
                    ?? scheduledArrival.addingTimeInterval(TimeInterval(arrivalDelay ?? previousDelay ?? 0))
                let leave = timingUpdate?.departureTime
                    ?? scheduledDeparture.addingTimeInterval(TimeInterval(departureDelay ?? previousDelay ?? 0))
                times.append(GTFSStopPrediction(
                    stopID: stop.stopID, arrival: arrival, departure: leave,
                    delaySeconds: departureDelay ?? arrivalDelay ?? previousDelay,
                    hasRealtime: update?.isSkipped == true
                        || (timingUpdate != nil && !hasNoRealtimeDataFromHere) || previousDelay != nil,
                    isSkipped: update?.isSkipped == true,
                    isBoardable: stop.allowsPickup && update?.isSkipped != true,
                    isAlightable: stop.allowsDropOff && update?.isSkipped != true))
            }
            instances.append(GTFSTripInstance(
                trip: trip, route: route, serviceDate: serviceDate, times: times,
                scheduleShiftSeconds: departure.shift,
                frequencyStartSeconds: departure.start,
                frequencyHeadwaySeconds: departure.headway,
                isFrequencyEstimate: departure.isEstimate))
        }
        return instances
    }
}

nonisolated struct TransitBoardingDeparture {
    let instanceIndex: Int
    let time: Date
}

nonisolated final class TransitActiveScheduleCache: @unchecked Sendable {
    private static let maximumRetainedPatternSchedules = 64
    private static let maximumRetainedStopPredictions = 300_000
    private static let maximumRetainedArrivalEnvelopeEntries = 500_000

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
    private var recentlyUsedPatternIDs: [Int] = []
    private var retainedStopPredictionCount = 0
    private var retainedArrivalEnvelopeEntryCount = 0

    init(coverageStart: Date, coverageEnd: Date) {
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
    }

    func schedule(for patternID: Int) -> PatternSchedule? {
        lock.lock()
        defer { lock.unlock() }
        guard let schedule = schedulesByPatternID[patternID] else { return nil }
        touch(patternID)
        return schedule
    }

    func store(_ schedule: PatternSchedule, for patternID: Int) {
        let predictionCount = schedule.instances.reduce(into: 0) {
            $0 += $1.times.count
        }
        guard predictionCount <= Self.maximumRetainedStopPredictions else { return }
        lock.lock()
        if let previous = schedulesByPatternID.removeValue(forKey: patternID) {
            retainedStopPredictionCount -= previous.instances.reduce(into: 0) {
                $0 += $1.times.count
            }
            evictEnvelopes(for: patternID)
        }
        schedulesByPatternID[patternID] = schedule
        retainedStopPredictionCount += predictionCount
        touch(patternID)
        while schedulesByPatternID.count > Self.maximumRetainedPatternSchedules
                || retainedStopPredictionCount > Self.maximumRetainedStopPredictions {
            guard let oldestPatternID = recentlyUsedPatternIDs.first,
                  oldestPatternID != patternID else { break }
            evict(oldestPatternID)
        }
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
        let entryCount = envelope.reduce(into: 0) { $0 += $1.count }
        guard entryCount <= Self.maximumRetainedArrivalEnvelopeEntries else { return }
        lock.lock()
        guard schedulesByPatternID[patternID] != nil else {
            lock.unlock()
            return
        }
        let key = EnvelopeKey(patternID: patternID, stopIndex: stopIndex,
                              departureCount: departureCount)
        if let previous = arrivalEnvelopes.removeValue(forKey: key) {
            retainedArrivalEnvelopeEntryCount -= previous.reduce(into: 0) { $0 += $1.count }
        }
        arrivalEnvelopes[key] = envelope
        retainedArrivalEnvelopeEntryCount += entryCount
        while retainedArrivalEnvelopeEntryCount > Self.maximumRetainedArrivalEnvelopeEntries {
            guard let oldestPatternID = recentlyUsedPatternIDs.first(where: { candidatePatternID in
                arrivalEnvelopes.keys.contains { $0.patternID == candidatePatternID }
            }) else { break }
            evictEnvelopes(for: oldestPatternID)
        }
        lock.unlock()
    }

    private func touch(_ patternID: Int) {
        recentlyUsedPatternIDs.removeAll { $0 == patternID }
        recentlyUsedPatternIDs.append(patternID)
    }

    private func evict(_ patternID: Int) {
        if let schedule = schedulesByPatternID.removeValue(forKey: patternID) {
            retainedStopPredictionCount -= schedule.instances.reduce(into: 0) {
                $0 += $1.times.count
            }
        }
        evictEnvelopes(for: patternID)
        recentlyUsedPatternIDs.removeAll { $0 == patternID }
    }

    private func evictEnvelopes(for patternID: Int) {
        let keys = arrivalEnvelopes.keys.filter { $0.patternID == patternID }
        for key in keys {
            if let envelope = arrivalEnvelopes.removeValue(forKey: key) {
                retainedArrivalEnvelopeEntryCount -= envelope.reduce(into: 0) { $0 += $1.count }
            }
        }
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
    var isInSeatConnection = false

    var requiredTransferDuration: TimeInterval {
        max(walkingDuration, minimumTransferTime)
    }

    var extraBufferAfterWalking: TimeInterval {
        max(0, minimumTransferTime - walkingDuration)
    }
}

nonisolated struct GTFSTransferRule: Codable, Sendable {
    let fromStopID: String?
    let toStopID: String?
    let transferType: Int
    let minimumTransferTime: TimeInterval
    let fromRouteID: String?
    let toRouteID: String?
    let fromTripID: String?
    let toTripID: String?

    var isScoped: Bool {
        fromRouteID != nil || toRouteID != nil || fromTripID != nil || toTripID != nil
    }
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
         departure: Date, maximumDepartureWindow: TimeInterval,
         cancellationToken: TransitPlanningCancellationToken? = nil) {
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
            if Task.isCancelled || cancellationToken?.isCancelled == true { break }
            guard let serviceDay = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let date = GTFSDate.string(from: serviceDay)
            let weekday = GTFSDate.weekdayKey(for: serviceDay, calendar: calendar)
            var activeServices = TransitBitSet(count: database.serviceIDs.count)
            for (serviceIndex, serviceID) in database.serviceIDs.enumerated() {
                if Task.isCancelled || cancellationToken?.isCancelled == true { break }
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
                         trace: TransitPlanningTrace? = nil,
                         cancellationToken: TransitPlanningCancellationToken? = nil)
        -> [GTFSTripInstance] {
        guard let route = database.routes[pattern.routeID] else { return [] }
        guard let tripsByService = pattern.tripsByService else { return [] }
        var instances: [GTFSTripInstance] = []
        var tripRowsVisited = 0
        for serviceDate in serviceDates {
            if Task.isCancelled || cancellationToken?.isCancelled == true { break }
            guard let serviceStart = GTFSDate.serviceStart(from: serviceDate),
                  let activeServices = activeServiceBitsByServiceDate[serviceDate] else { continue }
            guard let departureSeconds = GTFSDate.serviceSeconds(at: departure, for: serviceDate),
                  let maximumDepartureSeconds = GTFSDate.serviceSeconds(at: maximumDeparture,
                                                                         for: serviceDate) else { continue }
            for group in tripsByService where activeServices.contains(group.serviceIndex) {
                if Task.isCancelled || cancellationToken?.isCancelled == true { break }
                let earliestPossibleFirstDeparture = Int(floor(departureSeconds - 3_600))
                    - group.maximumScheduledDurationSeconds
                let firstDepartureAtOrAfter = Int(ceil(maximumDepartureSeconds))
                let frequencyTripIndices = group.frequencyTripIndices ?? group.tripIndices.filter { index in
                    database.trips.indices.contains(index)
                        && !(database.frequenciesByTripID[database.trips[index].id] ?? []).isEmpty
                }
                let candidateTripIndices: [Int]
                if !frequencyTripIndices.isEmpty {
                    let scheduledTripIndices = group.scheduledTripIndices ?? group.tripIndices.filter { index in
                        database.trips.indices.contains(index)
                            && (database.frequenciesByTripID[database.trips[index].id] ?? []).isEmpty
                    }
                    let lowerIndex = Self.tripIndexBoundary(
                        in: scheduledTripIndices, for: earliestPossibleFirstDeparture,
                        upperBound: true, trips: database.trips)
                    let upperIndex = Self.tripIndexBoundary(
                        in: scheduledTripIndices, for: firstDepartureAtOrAfter,
                        upperBound: false, trips: database.trips)
                    var candidates = lowerIndex < upperIndex
                        ? Array(scheduledTripIndices[lowerIndex..<upperIndex]) : []
                    candidates.append(contentsOf: frequencyTripIndices)
                    candidateTripIndices = candidates
                } else {
                    let scheduledTripIndices = group.scheduledTripIndices ?? group.tripIndices
                    let lowerIndex = Self.tripIndexBoundary(
                        in: scheduledTripIndices, for: earliestPossibleFirstDeparture,
                        upperBound: true, trips: database.trips)
                    let upperIndex = Self.tripIndexBoundary(
                        in: scheduledTripIndices, for: firstDepartureAtOrAfter,
                        upperBound: false, trips: database.trips)
                    guard lowerIndex < upperIndex else { continue }
                    candidateTripIndices = Array(scheduledTripIndices[lowerIndex..<upperIndex])
                }
                tripRowsVisited += candidateTripIndices.count
                for tripIndex in candidateTripIndices {
                    if Task.isCancelled || cancellationToken?.isCancelled == true { break }
                    guard database.trips.indices.contains(tripIndex) else { continue }
                    let trip = database.trips[tripIndex]
                    instances.append(contentsOf: GTFSTripInstanceBuilder.build(
                        trip: trip, route: route, serviceDate: serviceDate,
                        serviceStart: serviceStart, database: database, realtime: realtime,
                        earliestArrival: departure.addingTimeInterval(-3_600),
                        latestDeparture: maximumDeparture,
                        cancellationToken: cancellationToken))
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
