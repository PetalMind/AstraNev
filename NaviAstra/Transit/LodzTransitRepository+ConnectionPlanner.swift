import Foundation

extension LodzTransitRepository {
    static func plan(snapshot: TransitSnapshot,
                             from origin: Coordinate, to destination: Coordinate,
                             departingAt: Date, departureSearchWindow: TimeInterval,
                             maximumJourneyDuration: TimeInterval,
                             originWalks: [TransitWalkOption],
                             destinationWalks: [TransitWalkOption],
                             usingCachedSchedule: Bool, resultLimit: Int,
                             planningID: UInt64, trace: TransitPlanningTrace) throws -> [NavigationRoute] {
        let database = snapshot.database
        let realtime = snapshot.realtime
        guard !originWalks.isEmpty, !destinationWalks.isEmpty else {
            if !database.railwayFeedAvailable { throw TransitRoutingError.railwayFeedUnavailable }
            throw TransitRoutingError.outsideCoverage
        }

        var instances: [GTFSTripInstance] = []
        var departuresByPatternStop: [Int: [[TransitBoardingDeparture]]] = [:]
        var activeRouteIDs: Set<String> = []
        var touchedPatternIDs: Set<Int> = []

        let stopByID = Dictionary(uniqueKeysWithValues: database.stops.map { ($0.id, $0) })
        var initial: [String: [TransitPathLabel]] = [:]
        for access in originWalks {
            let label = TransitPathLabel(arrival: departingAt.addingTimeInterval(access.duration),
                                         currentStopID: access.stop.id,
                                         initialWalkingSeconds: access.duration,
                                         walkingSeconds: access.duration, rideCount: 0,
                                         transferCount: 0, transferDepth: 0,
                                         lastLegWasTransfer: false, initialStopID: access.stop.id,
                                         parent: nil, ride: nil)
            insertPareto(label, at: access.stop.id, in: &initial)
        }

        var layers: [[String: [TransitPathLabel]]] = [initial]
        var candidates: [TransitPlanCandidate] = []
        var roundsExecuted = 0
        var departureTripsScanned = 0
        var departureTripsDominated = 0
        let latestDeparture = departingAt.addingTimeInterval(departureSearchWindow)
        let latestArrival = departingAt.addingTimeInterval(maximumJourneyDuration)
        for ridesUsed in 1...4 {
            guard let previous = layers.last else { break }
            roundsExecuted = ridesUsed
            let boardingLabels = transferClosure(previous, database: database)
            let markedStops = Set(boardingLabels.keys)
            let patternsToScan = Set(markedStops.flatMap { database.routePatternIDsByStop[$0] ?? [] })
                .sorted()
            var current: [String: [TransitPathLabel]] = [:]
            for patternID in patternsToScan {
                guard database.routePatterns.indices.contains(patternID) else { continue }
                let pattern = database.routePatterns[patternID]
                touchedPatternIDs.insert(patternID)
                if departuresByPatternStop[patternID] == nil {
                    let patternInstances = snapshot.activeInstances(
                        for: pattern, after: departingAt,
                        maximumDeparture: departingAt.addingTimeInterval(Self.maximumDepartureSearchWindow))
                    let firstInstanceIndex = instances.count
                    instances.append(contentsOf: patternInstances)
                    activeRouteIDs.insert(pattern.routeID)
                    var departuresByStopIndex = Array(
                        repeating: [TransitBoardingDeparture](), count: pattern.stopIDs.count)
                    for (offset, instance) in patternInstances.enumerated() {
                        let instanceIndex = firstInstanceIndex + offset
                        for stopIndex in instance.times.indices where stopIndex < departuresByStopIndex.count {
                            departuresByStopIndex[stopIndex].append(
                                TransitBoardingDeparture(instanceIndex: instanceIndex,
                                                         stopIndex: stopIndex,
                                                         time: instance.times[stopIndex].departure))
                        }
                    }
                    for stopIndex in departuresByStopIndex.indices {
                        departuresByStopIndex[stopIndex].sort { $0.time < $1.time }
                    }
                    departuresByPatternStop[patternID] = departuresByStopIndex
                }

                guard let departuresByStopIndex = departuresByPatternStop[patternID] else { continue }
                for stopIndex in pattern.stopIDs.indices {
                    let stopID = pattern.stopIDs[stopIndex]
                    guard let labels = boardingLabels[stopID],
                          departuresByStopIndex.indices.contains(stopIndex) else { continue }
                    let departures = departuresByStopIndex[stopIndex]
                    guard !departures.isEmpty else { continue }
                    for label in labels {
                        let transferBuffer = label.rideCount > 0 && !label.lastLegWasTransfer ? 60.0 : 0
                        let minimumDeparture = label.arrival.addingTimeInterval(transferBuffer)
                        let startIndex = lowerBound(in: departures, for: minimumDeparture)
                        guard startIndex < departures.count else { continue }
                        var bestArrivalByDownstreamIndex: [Int: Date] = [:]
                        for departureIndex in startIndex..<departures.count {
                            let departure = departures[departureIndex]
                            if departure.time > latestDeparture { break }
                            departureTripsScanned += 1
                            let instance = instances[departure.instanceIndex]
                            var improvesAnAlightingStop = false
                            for downstreamIndex in (stopIndex + 1)..<instance.times.count {
                                let arrival = instance.times[downstreamIndex].arrival
                                if arrival > latestArrival { break }
                                if arrival < (bestArrivalByDownstreamIndex[downstreamIndex] ?? .distantFuture) {
                                    improvesAnAlightingStop = true
                                }
                            }
                            guard improvesAnAlightingStop else {
                                departureTripsDominated += 1
                                continue
                            }
                            for downstreamIndex in (stopIndex + 1)..<instance.times.count {
                                let downstream = instance.times[downstreamIndex]
                                if downstream.arrival > latestArrival { break }
                                bestArrivalByDownstreamIndex[downstreamIndex] = min(
                                    bestArrivalByDownstreamIndex[downstreamIndex] ?? .distantFuture,
                                    downstream.arrival)
                                let ride = TransitRide(instanceIndex: departure.instanceIndex,
                                                       boardIndex: stopIndex,
                                                       alightIndex: downstreamIndex)
                                let next = TransitPathLabel(arrival: downstream.arrival,
                                                            currentStopID: downstream.stopID,
                                                            initialWalkingSeconds: label.initialWalkingSeconds,
                                                            walkingSeconds: label.walkingSeconds,
                                                            rideCount: ridesUsed,
                                                            transferCount: max(0, ridesUsed - 1),
                                                            transferDepth: 0, lastLegWasTransfer: false,
                                                            initialStopID: label.initialStopID,
                                                            parent: label, ride: ride)
                                insertPareto(next, at: downstream.stopID, in: &current)
                            }
                        }
                    }
                }
            }
            layers.append(current)
            let alightingLabels = transferClosure(current, database: database)
            for (stopID, labels) in alightingLabels where stopByID[stopID] != nil {
                for label in labels {
                    for access in destinationWalks where access.stop.id == stopID {
                        let arrival = label.arrival.addingTimeInterval(access.duration)
                        guard arrival <= latestArrival else { continue }
                        candidates.append(TransitPlanCandidate(
                            label: label, destinationWalk: access, arrival: arrival))
                    }
                }
            }
            if current.isEmpty { break }
        }

        trace.setCount("roundsExecuted", value: roundsExecuted)
        TransitSignposting.event("TransitRoundsExecuted", value: roundsExecuted, planningID: planningID)
        trace.setCount("activeTrips", value: instances.count)
        trace.setCount("activeRoutes", value: activeRouteIDs.count)
        trace.setCount("activePatterns", value: touchedPatternIDs.count)
        trace.setCount("markedStops", value: markedStopsCount(in: layers))
        trace.setCount("departureTripsScanned", value: departureTripsScanned)
        trace.setCount("departureTripsDominated", value: departureTripsDominated)
        trace.setCount("stopsWithDepartures", value: departuresByPatternStop.values
            .flatMap { $0 }.filter { !$0.isEmpty }.count)
        TransitSignposting.event("ActiveTripInstanceCount", value: instances.count, planningID: planningID)
        TransitSignposting.event("ActiveRouteCount", value: activeRouteIDs.count, planningID: planningID)
        TransitSignposting.event("ActiveRoutePatternCount", value: touchedPatternIDs.count, planningID: planningID)
        trace.setCount("routesTouched", value: touchedPatternIDs.count)
        TransitSignposting.event("RoutesTouched", value: touchedPatternIDs.count, planningID: planningID)
        let rankingStartedAt = ProcessInfo.processInfo.systemUptime
        let rankingInterval = TransitSignposting.begin("CandidateRanking", planningID: planningID)
        trace.setCount("candidates", value: candidates.count)
        TransitSignposting.event("StaticCandidateCount", value: candidates.count, planningID: planningID)
        let rankedCandidates = candidates.sorted {
            candidateCost($0, departingAt: departingAt, instances: instances)
                < candidateCost($1, departingAt: departingAt, instances: instances)
        }
        TransitSignposting.end("CandidateRanking", identifier: rankingInterval, planningID: planningID)
        trace.recordDuration("CandidateRanking", startedAt: rankingStartedAt)
        var routes: [NavigationRoute] = []
        for candidate in rankedCandidates.prefix(max(resultLimit * 4, resultLimit)) {
            if let route = makeRoute(candidate: candidate, database: database, realtime: realtime,
                                     instances: instances, stopByID: stopByID,
                                     origin: origin, destination: destination, departingAt: departingAt,
                                     originWalks: originWalks,
                                     usingCachedSchedule: usingCachedSchedule) {
                routes.append(route)
            }
        }
        var unique: [NavigationRoute] = []
        var seen = Set<String>()
        for route in routes {
            let signature = route.journey?.legs
                .filter { $0.mode != "WALK" }
                .map { "\($0.tripID ?? $0.line ?? ""):\($0.from):\($0.to):\($0.departure.timeIntervalSince1970.rounded())" }
                .joined(separator: "|") ?? ""
            guard !signature.isEmpty, seen.insert(signature).inserted else { continue }
            unique.append(route)
        }
        trace.setCount("uniqueRoutes", value: unique.count)
        TransitSignposting.event("UniqueTransitRouteCount", value: unique.count, planningID: planningID)
        guard !unique.isEmpty else {
            throw TransitRoutingError.noJourney
        }
        if resultLimit > 3 { return Array(unique.prefix(resultLimit)) }
        return selectRouteVariants(unique, limit: resultLimit)
    }

    static func markedStopsCount(in layers: [[String: [TransitPathLabel]]]) -> Int {
        Set(layers.flatMap(\.keys)).count
    }

    @discardableResult
    static func insertPareto(_ candidate: TransitPathLabel, at stopID: String,
                                     in labelsByStop: inout [String: [TransitPathLabel]]) -> Bool {
        var labels = labelsByStop[stopID] ?? []
        guard !labels.contains(where: { existing in
            existing.arrival <= candidate.arrival
                && existing.walkingSeconds <= candidate.walkingSeconds
                && existing.transferCount <= candidate.transferCount
        }) else { return false }
        labels.removeAll { existing in
            candidate.arrival <= existing.arrival
                && candidate.walkingSeconds <= existing.walkingSeconds
                && candidate.transferCount <= existing.transferCount
        }
        labels.append(candidate)
        labelsByStop[stopID] = labels
        return true
    }

    static func pathDistance(_ coordinates: [Coordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst())
            .reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func transferClosure(_ labels: [String: [TransitPathLabel]],
                                        database: GTFSDatabase) -> [String: [TransitPathLabel]] {
        var reachable = labels
        var queue = labels.values.flatMap { $0 }
        var cursor = 0
        while cursor < queue.count {
            let label = queue[cursor]
            cursor += 1
            guard label.transferDepth < 12, label.walkingSeconds < 1_800 else { continue }
            for transfer in database.footpathsByStopID[label.currentStopID] ?? [] {
                let walkingSeconds = label.walkingSeconds + transfer.walkingDuration
                guard walkingSeconds <= 1_800 else { continue }
                let next = TransitPathLabel(
                    arrival: label.arrival.addingTimeInterval(transfer.walkingDuration + transfer.minimumTransferTime),
                    currentStopID: transfer.toStopID,
                    initialWalkingSeconds: label.initialWalkingSeconds,
                    walkingSeconds: walkingSeconds,
                    rideCount: label.rideCount, transferCount: label.transferCount,
                    transferDepth: label.transferDepth + 1, lastLegWasTransfer: true,
                    initialStopID: label.initialStopID, parent: label, ride: nil, transfer: transfer)
                if insertPareto(next, at: transfer.toStopID, in: &reachable) {
                    queue.append(next)
                }
            }
        }
        return reachable
    }

    static func candidateCost(_ candidate: TransitPlanCandidate, departingAt: Date,
                                      instances: [GTFSTripInstance]) -> Double {
        let rideSeconds = pathRideSeconds(candidate.label, instances: instances)
        let walking = candidate.label.walkingSeconds + candidate.destinationWalk.duration
        let total = candidate.arrival.timeIntervalSince(departingAt)
        let waiting = max(0, total - rideSeconds - walking)
        return rideSeconds + walking * 1.6 + waiting * 1.25
            + Double(candidate.label.transferCount) * 240
    }

    static func generalizedCost(_ route: NavigationRoute) -> Double {
        guard let journey = route.journey else { return route.expectedTravelTime }
        let rideSeconds = journey.legs.filter { $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        return rideSeconds + journey.walkingDuration * 1.6 + journey.waitingDuration * 1.25
            + Double(journey.transferCount) * 240 + transferRiskPenalty(for: journey.legs)
    }

    static func transferRiskPenalty(for legs: [JourneyLeg]) -> Double {
        var penalty = 0.0
        for nextRideIndex in legs.indices where legs[nextRideIndex].mode != "WALK" {
            guard let previousRideIndex = legs[..<nextRideIndex].lastIndex(where: { $0.mode != "WALK" }) else {
                continue
            }
            let transferWalks = legs[(previousRideIndex + 1)..<nextRideIndex]
                .filter { $0.mode == "WALK" }
            let requiredTransfer = transferWalks.isEmpty
                ? 60.0
                : transferWalks.reduce(0.0) { $0 + max(0, $1.arrival.timeIntervalSince($1.departure)) }
            let available = legs[nextRideIndex].departure
                .timeIntervalSince(legs[previousRideIndex].arrival)
            let margin = max(0, available - requiredTransfer)
            let risk = max(0, (120 - margin) / 120)
            penalty += risk * risk * 240
            if transferWalks.contains(where: { $0.isTransfer && !$0.hasResolvedWalkingGeometry }) {
                penalty += 120
            }
        }
        return penalty
    }

    static func pathRideSeconds(_ label: TransitPathLabel,
                                        instances: [GTFSTripInstance]) -> Double {
        var total = 0.0
        var current: TransitPathLabel? = label
        while let node = current {
            if let ride = node.ride,
               instances.indices.contains(ride.instanceIndex) {
                let times = instances[ride.instanceIndex].times
                if times.indices.contains(ride.boardIndex), times.indices.contains(ride.alightIndex) {
                    total += max(0, times[ride.alightIndex].arrival
                        .timeIntervalSince(times[ride.boardIndex].departure))
                }
            }
            current = node.parent
        }
        return max(0, total)
    }

    static func transitSignature(_ route: NavigationRoute) -> String {
        route.journey?.legs.filter { $0.mode != "WALK" }
            .map { "\($0.tripID ?? $0.line ?? ""):\($0.from):\($0.to):\($0.departure.timeIntervalSince1970.rounded())" }
            .joined(separator: "|") ?? ""
    }

    static func nearestStops(to coordinate: Coordinate,
                                     stopByID: [String: GTFSStop],
                                     spatialIndex: TransitStopSpatialIndex,
                                     maximumDistance: Double, localLimit: Int,
                                     railwayLimit: Int) -> [(GTFSStop, Double)] {
        let nearby = spatialIndex.nearbyStopIDs(to: coordinate, within: maximumDistance)
            .compactMap { stopByID[$0] }
            .compactMap { stop -> (GTFSStop, Double)? in
            let distance = coordinate.distance(to: stop.coordinate)
            return distance <= maximumDistance ? (stop, distance) : nil
        }.sorted { $0.1 < $1.1 }
        let local = Array(nearby.filter { !$0.0.id.hasPrefix("rail/") }.prefix(localLimit))
        let railway = Array(nearby.filter { $0.0.id.hasPrefix("rail/") }.prefix(railwayLimit))
        let prioritizedLocalCount = min(12, local.count)
        let prioritizedRailwayCount = min(8, railway.count)
        let prioritized = (Array(local.prefix(prioritizedLocalCount))
            + Array(railway.prefix(prioritizedRailwayCount))).sorted { $0.1 < $1.1 }
        let remaining = (Array(local.dropFirst(prioritizedLocalCount))
            + Array(railway.dropFirst(prioritizedRailwayCount))).sorted { $0.1 < $1.1 }
        return prioritized + remaining
    }

    static func publicStop(_ stop: GTFSStop, database: GTFSDatabase) -> TransitStop {
        let routes = database.routeIDsByStop[stop.id] ?? []
        let lineNames = routes.compactMap { database.routes[$0]?.displayName }
        let stationID = stop.parentStation?.isEmpty == false
            ? stop.parentStation
            : stop.locationType == 1 ? stop.id : nil
        let station = stationID.flatMap { database.stopByID[$0] }
        let stationRouteIDs: Set<String> = {
            guard let stationID else { return routes }
            let members = database.stopsByStationID[stationID] ?? [stop]
            return Set(members.flatMap { database.routeIDsByStop[$0.id] ?? [] })
        }()
        let stationLineNames = stationRouteIDs.compactMap { database.routes[$0]?.displayName }
        let modes = Set(stationRouteIDs.compactMap { routeID -> TransitStopMode? in
            guard let route = database.routes[routeID] else { return nil }
            switch route.mode {
            case "RAIL": return .rail
            case "TRAM": return .tram
            default: return .bus
            }
        })
        return TransitStop(id: stop.id, name: stop.name, address: stop.address,
                           coordinate: stop.coordinate,
                           isMajor: stop.locationType == 1 || Set(stationLineNames).count >= 4
                               || modes.contains(.rail) && stop.parentStation?.isEmpty == false,
                           lineIDs: Array(routes).sorted(), lines: Array(Set(lineNames)).sorted(),
                           modes: modes,
                           stationID: stationID,
                           stationName: station?.name,
                           stationCoordinate: station?.coordinate)
    }

    static func railwayAttribution(for database: GTFSDatabase) -> String {
        let parts = database.railwayAttributions.isEmpty
            ? ["PKP Polskie Linie Kolejowe S.A.", "Koleje Mazowieckie – KM sp. z o.o.",
               "GTFS: Mikołaj Kuranowski (mkuran.pl)"]
            : database.railwayAttributions
        var text = parts.joined(separator: ", ")
        if let version = database.railwayFeedVersion, !version.isEmpty {
            text += " · wydanie \(version)"
        }
        if let retrievedAt = database.railwayFeedRetrievedAt {
            text += " · pobrano \(retrievedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return text + " · dane przetworzone przez NaviAstra"
    }

    static func departures(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
                                   stopID: String, after date: Date, limit: Int) -> [TransitDeparture] {
        guard database.servedStopIDs.contains(stopID), limit > 0 else { return [] }
        let instances = activeTripInstances(database: database, realtime: realtime, after: date,
                                            onlyStopIDs: [stopID])
        var result: [TransitDeparture] = []
        for instance in instances {
            guard let index = instance.times.firstIndex(where: { $0.stopID == stopID }),
                  instance.times[index].departure >= date.addingTimeInterval(-30) else { continue }
            let prediction = instance.times[index]
            result.append(TransitDeparture(id: "\(instance.trip.id)|\(instance.serviceDate)|\(instance.trip.stopTimes[index].sequence)",
                                           stopID: stopID, routeID: instance.route.id, tripID: instance.trip.id,
                                           line: instance.trip.displayLine(for: instance.route), mode: instance.route.mode,
                                           destination: instance.trip.headsign.isEmpty
                                               ? instance.trip.stopTimes.last.flatMap { database.stopByID[$0.stopID]?.name } ?? "Kierunek nieznany"
                                               : instance.trip.headsign,
                                           scheduledDeparture: GTFSDate.date(from: instance.serviceDate)?
                                               .addingTimeInterval(TimeInterval(instance.trip.stopTimes[index].departureSeconds))
                                               ?? prediction.departure,
                                           estimatedDeparture: prediction.departure,
                                           delaySeconds: prediction.delaySeconds,
                                           hasRealtime: prediction.hasRealtime,
                                           colorHex: instance.route.colorHex,
                                           stopSequence: instance.trip.stopTimes[index].sequence,
                                           serviceDate: instance.serviceDate))
        }
        return result.sorted { $0.estimatedDeparture < $1.estimatedDeparture }.prefix(limit).map { $0 }
    }

    static func lowerBound(in departures: [TransitBoardingDeparture], for time: Date) -> Int {
        var lower = 0
        var upper = departures.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if departures[middle].time < time { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    static func activeTripInstances(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
                                            after departure: Date,
                                            onlyStopIDs: Set<String>? = nil,
                                            onlyTripIDs: Set<String>? = nil,
                                            planningID: UInt64? = nil,
                                            trace: TransitPlanningTrace? = nil) -> [GTFSTripInstance] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let today = calendar.startOfDay(for: departure)
        let finalServiceDay = calendar.startOfDay(for: departure.addingTimeInterval(maximumDepartureSearchWindow))
        var serviceDates: [Date] = []
        for offset in -1...(finalServiceDay > today ? 1 : 0) {
            if let date = calendar.date(byAdding: .day, value: offset, to: today) { serviceDates.append(date) }
        }

        let trips: [GTFSTrip]
        if let onlyTripIDs {
            trips = onlyTripIDs.compactMap { database.tripsByID[$0] }
        } else if let onlyStopIDs {
            let tripIDs = Set(onlyStopIDs.flatMap { database.tripIDsByStop[$0] ?? [] })
            trips = tripIDs.compactMap { database.tripsByID[$0] }
        } else {
            trips = database.trips
        }
        let tripsExamined = trips.count * serviceDates.count
        trace?.addCount("tripDaysExamined", value: tripsExamined)
        TransitSignposting.event("TripsExamined", value: tripsExamined, planningID: planningID)
        var instances: [GTFSTripInstance] = []
        for serviceDate in serviceDates {
            let dateString = GTFSDate.string(from: serviceDate)
            let weekday = GTFSDate.weekdayKey(for: serviceDate, calendar: calendar)
            for trip in trips {
                guard let route = database.routes[trip.routeID],
                      let firstStop = trip.stopTimes.first, let lastStop = trip.stopTimes.last,
                      serviceDate.addingTimeInterval(TimeInterval(lastStop.arrivalSeconds))
                        > departure.addingTimeInterval(-3_600),
                      serviceDate.addingTimeInterval(TimeInterval(firstStop.departureSeconds))
                        < departure.addingTimeInterval(maximumDepartureSearchWindow),
                      serviceIsActive(trip.serviceID, on: dateString, weekday: weekday, database: database),
                      !realtime.isCanceled(tripID: trip.id, serviceDate: dateString) else { continue }
                var previousDelay: Int?
                let times = trip.stopTimes.map { stop -> GTFSStopPrediction in
                    let scheduledArrival = serviceDate.addingTimeInterval(TimeInterval(stop.arrivalSeconds))
                    let scheduledDeparture = serviceDate.addingTimeInterval(TimeInterval(stop.departureSeconds))
                    let update = realtime.update(tripID: trip.id, serviceDate: dateString,
                                                 stopID: stop.stopID, stopSequence: stop.sequence)
                    let arrivalDelay = update?.arrivalDelay
                        ?? update?.arrivalTime.map { Int($0.timeIntervalSince(scheduledArrival).rounded()) }
                    let departureDelay = update?.departureDelay
                        ?? update?.departureTime.map { Int($0.timeIntervalSince(scheduledDeparture).rounded()) }
                    if let delay = departureDelay ?? arrivalDelay { previousDelay = delay }
                    let arrival = update?.arrivalTime
                        ?? scheduledArrival.addingTimeInterval(TimeInterval(arrivalDelay ?? previousDelay ?? 0))
                    let departure = update?.departureTime
                        ?? scheduledDeparture.addingTimeInterval(TimeInterval(departureDelay ?? previousDelay ?? 0))
                    return GTFSStopPrediction(stopID: stop.stopID, arrival: arrival, departure: departure,
                                              delaySeconds: departureDelay ?? arrivalDelay ?? previousDelay,
                                              hasRealtime: update != nil || previousDelay != nil)
                }
                guard let first = times.first, let last = times.last,
                      last.arrival > departure.addingTimeInterval(-3_600),
                      first.departure < departure.addingTimeInterval(maximumDepartureSearchWindow) else { continue }
                instances.append(GTFSTripInstance(trip: trip, route: route, serviceDate: dateString,
                                                  times: times, patternKey: trip.patternKey))
            }
        }
        return instances
    }

    static func serviceIsActive(_ serviceID: String, on date: String, weekday: String,
                                        database: GTFSDatabase) -> Bool {
        if let exception = database.exceptions[serviceID]?[date] { return exception == 1 }
        guard let calendar = database.calendars[serviceID] else { return false }
        return date >= calendar.startDate && date <= calendar.endDate && calendar.weekdayFlags[weekday] == true
    }

    static func makeRoute(
        candidate: TransitPlanCandidate,
        database: GTFSDatabase,
        realtime: GTFSRealtimeSnapshot,
        instances: [GTFSTripInstance],
        stopByID: [String: GTFSStop],
        origin: Coordinate,
        destination: Coordinate,
        departingAt: Date,
        originWalks: [TransitWalkOption],
        usingCachedSchedule: Bool
    ) -> NavigationRoute? {
        var path: [TransitPathLabel] = []
        var root = candidate.label
        while let parent = root.parent {
            path.append(root)
            root = parent
        }
        guard candidate.label.rideCount > 0,
              let firstStop = stopByID[root.currentStopID],
              let originWalk = originWalks.first(where: { $0.stop.id == root.currentStopID }) else { return nil }
        path.reverse()

        var legs: [JourneyLeg] = []
        if originWalk.duration > 0.1 {
            legs.append(JourneyLeg(mode: "WALK", from: "Punkt początkowy", to: firstStop.name,
                                    departure: departingAt, arrival: departingAt.addingTimeInterval(originWalk.duration),
                                    realTime: false, coordinates: originWalk.coordinates,
                                    hasResolvedWalkingGeometry: originWalk.hasResolvedGeometry,
                                    walkingTimeIsApproximate: originWalk.isApproximate))
        }
        var relevantRoutes = Set<String>()
        var relevantStops = Set<String>([firstStop.id, candidate.destinationWalk.stop.id])
        for node in path {
            if let transfer = node.transfer,
               let parent = node.parent,
               let fromStop = stopByID[transfer.fromStopID],
               let toStop = stopByID[transfer.toStopID] {
                legs.append(JourneyLeg(mode: "WALK", from: fromStop.name, to: toStop.name,
                                       departure: parent.arrival, arrival: node.arrival,
                                       realTime: false, coordinates: transfer.coordinates,
                                       isTransfer: true,
                                       minimumTransferTime: transfer.minimumTransferTime,
                                       walkingTimeIsApproximate: true))
                relevantStops.insert(fromStop.id)
                relevantStops.insert(toStop.id)
                continue
            }
            guard let ride = node.ride else { continue }
            guard instances.indices.contains(ride.instanceIndex) else { return nil }
            let instance = instances[ride.instanceIndex]
            guard instance.times.indices.contains(ride.boardIndex),
                  instance.times.indices.contains(ride.alightIndex),
                  let board = stopByID[instance.times[ride.boardIndex].stopID],
                  let alight = stopByID[instance.times[ride.alightIndex].stopID] else { return nil }
            let boardTime = instance.times[ride.boardIndex]
            let alightTime = instance.times[ride.alightIndex]
            let coordinates = shapeCoordinates(for: instance.trip, from: ride.boardIndex,
                                                to: ride.alightIndex, database: database,
                                                stopByID: stopByID)
            let transitStops = (ride.boardIndex...ride.alightIndex).compactMap { index -> TransitJourneyStop? in
                guard instance.times.indices.contains(index), instance.trip.stopTimes.indices.contains(index),
                      let stop = stopByID[instance.times[index].stopID] else { return nil }
                let prediction = instance.times[index]
                return TransitJourneyStop(id: "\(instance.trip.id)-\(instance.trip.stopTimes[index].sequence)",
                                          stopID: stop.id, name: stop.name, coordinate: stop.coordinate,
                                          arrival: prediction.arrival, departure: prediction.departure,
                                          delaySeconds: prediction.delaySeconds,
                                          hasRealtime: prediction.hasRealtime,
                                          sequence: instance.trip.stopTimes[index].sequence)
            }
            relevantRoutes.insert(instance.route.id)
            relevantStops.insert(board.id)
            relevantStops.insert(alight.id)
            legs.append(JourneyLeg(mode: instance.route.mode,
                                   line: instance.trip.displayLine(for: instance.route),
                                   from: board.name, to: alight.name,
                                   departure: boardTime.departure, arrival: alightTime.arrival,
                                   realTime: boardTime.hasRealtime || alightTime.hasRealtime,
                                   delaySeconds: boardTime.delaySeconds ?? alightTime.delaySeconds,
                                   coordinates: coordinates, routeID: instance.route.id,
                                   tripID: instance.trip.id, serviceDate: instance.serviceDate,
                                   lineColorHex: instance.route.colorHex,
                                   transitStops: transitStops))
        }
        if candidate.destinationWalk.duration > 0.1 {
            legs.append(JourneyLeg(mode: "WALK", from: candidate.destinationWalk.stop.name, to: "Cel",
                                   departure: candidate.label.arrival,
                                   arrival: candidate.arrival, realTime: false,
                                   coordinates: candidate.destinationWalk.coordinates,
                                   hasResolvedWalkingGeometry: candidate.destinationWalk.hasResolvedGeometry,
                                   walkingTimeIsApproximate: candidate.destinationWalk.isApproximate))
        }

        var coordinates: [Coordinate] = []
        for leg in legs {
            if coordinates.isEmpty { coordinates.append(contentsOf: leg.coordinates) }
            else { coordinates.append(contentsOf: leg.coordinates.dropFirst()) }
        }
        guard coordinates.count > 1 else { return nil }
        let journeyHasLocalTransit = legs.contains { leg in
            leg.mode != "WALK" && !(leg.tripID?.hasPrefix("rail/") ?? false)
        }
        let alerts = (journeyHasLocalTransit ? realtime.alerts : []).filter { alert in
            alert.isActive(at: departingAt)
                && ((alert.routeIDs.isEmpty && alert.stopIDs.isEmpty)
                || !alert.routeIDs.isDisjoint(with: relevantRoutes)
                || !alert.stopIDs.isDisjoint(with: relevantStops))
        }.map(\.message).filter { !$0.isEmpty }.prefix(3)
        let rideDuration = legs.filter { $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        let walkingDuration = legs.filter { $0.mode == "WALK" }
            .reduce(0.0) { $0 + max(0, $1.arrival.timeIntervalSince($1.departure) - $1.minimumTransferTime) }
        let waitingDuration = max(0, candidate.arrival.timeIntervalSince(departingAt) - rideDuration - walkingDuration)
        let journeyHasRail = legs.contains { $0.mode == "RAIL" }
        let journeySources = Set(legs.compactMap { leg -> String? in
            guard leg.mode != "WALK", let tripID = leg.tripID else { return nil }
            return tripID.hasPrefix("rail/") ? "rail" : "lodz"
        })
        let journeyFreshness = Self.combinedFreshness(journeySources.compactMap {
            realtime.sourceFreshness[$0]
        })
        let journeyRealtimeUpdatedAt = journeySources.compactMap { realtime.sourceUpdatedAt[$0] }.min()
        let journeyRealtimeAvailable = !journeySources.isEmpty && journeySources.allSatisfy { source in
            let freshness = realtime.sourceFreshness[source]
            return freshness == .live || freshness == .degraded
        }
        let journey = Journey(departure: departingAt, arrival: candidate.arrival, legs: legs,
                              scheduleIsCached: usingCachedSchedule,
                              realtimeFeedAvailable: journeyRealtimeAvailable,
                              realtimeFeedUpdatedAt: journeyRealtimeUpdatedAt,
                              alertsFeedAvailable: journeyHasLocalTransit && realtime.alertsAvailable,
                              alerts: Array(alerts), walkingDuration: walkingDuration,
                              waitingDuration: waitingDuration,
                              transferCount: candidate.label.transferCount,
                              realtimeFreshness: journeyFreshness,
                              railwayScheduleAttribution: journeyHasRail
                                  ? Self.railwayAttribution(for: database) : nil,
                              originAccessStopID: root.currentStopID,
                              destinationAccessStopID: candidate.destinationWalk.stop.id)
        let distance = zip(coordinates, coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        return NavigationRoute(coordinates: coordinates, distance: distance,
                               expectedTravelTime: candidate.arrival.timeIntervalSince(departingAt),
                               maneuvers: [], journey: journey)
    }

    static func shapeCoordinates(for trip: GTFSTrip, from start: Int, to end: Int,
                                         database: GTFSDatabase,
                                         stopByID: [String: GTFSStop]) -> [Coordinate] {
        guard let boardID = trip.stopTimes[safe: start]?.stopID,
              let alightID = trip.stopTimes[safe: end]?.stopID,
              let board = stopByID[boardID], let alight = stopByID[alightID] else { return [] }
        if let shape = database.shapes[trip.shapeID], shape.count > 1 {
            let startIndex = shape.indices.min { shape[$0].distance(to: board.coordinate) < shape[$1].distance(to: board.coordinate) }
            let endIndex = shape.indices.min { shape[$0].distance(to: alight.coordinate) < shape[$1].distance(to: alight.coordinate) }
            if let startIndex, let endIndex {
                let range = min(startIndex, endIndex)...max(startIndex, endIndex)
                let points = Array(shape[range])
                return startIndex <= endIndex ? points : points.reversed()
            }
        }
        return [board.coordinate, alight.coordinate]
    }

}

extension Collection {
    nonisolated subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
