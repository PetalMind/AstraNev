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
