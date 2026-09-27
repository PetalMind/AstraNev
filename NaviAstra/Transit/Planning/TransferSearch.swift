import Foundation

extension TransitRepository {
    static func plan(snapshot: TransitSnapshot,
                             from origin: Coordinate, to destination: Coordinate,
                             departingAt: Date, departureSearchWindow: TimeInterval,
                             arrivalDeadline: Date? = nil,
                             activeScheduleCache: TransitActiveScheduleCache? = nil,
                             originWalks: [TransitWalkOption],
                             destinationWalksByStopID: [String: [TransitWalkOption]]?,
                             usingCachedSchedule: Bool, resultLimit: Int,
                             planningID: UInt64, trace: TransitPlanningTrace,
                             regionID: String,
                             cancellationToken: TransitPlanningCancellationToken? = nil)
        throws -> [NavigationRoute] {
        try cancellationToken?.checkCancellation()
        let database = snapshot.database
        let realtime = snapshot.realtime
        guard !originWalks.isEmpty, !database.servedStopIDs.isEmpty else {
            if !database.railwayFeedAvailable { throw TransitRoutingError.railwayFeedUnavailable }
            throw TransitRoutingError.outsideCoverage
        }

        var instances: [GTFSTripInstance] = []
        var departuresByPatternStop: [Int: [ArraySlice<TransitBoardingDeparture>]] = [:]
        var arrivalEnvelopeByPatternStop: [Int: [Int: [[Int]]]] = [:]
        var patternInstanceBaseByID: [Int: Int] = [:]
        var activeRouteIDs: Set<String> = []
        var touchedPatternIDs: Set<Int> = []

        let stopByID = database.stopByID
        let requestedLatestDeparture = departingAt.addingTimeInterval(departureSearchWindow)
        let latestDeparture = arrivalDeadline.map { min(requestedLatestDeparture, $0) }
            ?? requestedLatestDeparture
        var initial: [String: [TransitPathLabel]] = [:]
        for access in originWalks {
            try cancellationToken?.checkCancellation()
            let accessArrival = departingAt.addingTimeInterval(access.duration)
            // An approach that reaches its stop after the last permitted boarding time
            // cannot seed any route in this search window.
            guard accessArrival <= latestDeparture else { continue }
            let label = TransitPathLabel(arrival: departingAt.addingTimeInterval(access.duration),
                                         currentStopID: access.stop.id,
                                         initialWalkingSeconds: access.duration,
                                         walkingSeconds: access.duration, rideSeconds: 0,
                                         rideCount: 0,
                                         transferCount: 0, transferDepth: 0,
                                         lastLegWasTransfer: false, initialStopID: access.stop.id,
                                         parent: nil, ride: nil)
            insertPareto(label, at: access.stop.id, in: &initial)
        }

        var layers: [[String: [TransitPathLabel]]] = [initial]
        var candidates: [TransitPlanCandidate] = []
        let candidateLimit = max(resultLimit * 4, resultLimit)
        var totalCandidateCount = 0
        var approximateDestinationWalksByStopID: [String: TransitWalkOption] = [:]
        var roundsExecuted = 0
        var departureTripsScanned = 0
        var departureTripsDominated = 0
        var ridesUsed = 1
        while true {
            try cancellationToken?.checkCancellation()
            guard let previous = layers.last else { break }
            roundsExecuted = ridesUsed
            let boardingLabels = transferClosure(previous, database: database, instances: instances,
                                                 latestBoardingTime: latestDeparture,
                                                 cancellationToken: cancellationToken)
            try cancellationToken?.checkCancellation()
            let markedStops = Set(boardingLabels.keys)
            let patternsToScan = Set(markedStops.flatMap { database.routePatternIDsByStop[$0] ?? [] })
                .sorted()
            var current: [String: [TransitPathLabel]] = [:]
            for patternID in patternsToScan {
                try cancellationToken?.checkCancellation()
                guard database.routePatterns.indices.contains(patternID) else { continue }
                let pattern = database.routePatterns[patternID]
                touchedPatternIDs.insert(patternID)
                if departuresByPatternStop[patternID] == nil {
                    var sharedSchedule = activeScheduleCache?.schedule(for: patternID)
                    if sharedSchedule != nil {
                        trace.addCount("activeScheduleCacheHits", value: 1)
                    }
                    if sharedSchedule == nil, let activeScheduleCache {
                        let instancesStartedAt = ProcessInfo.processInfo.systemUptime
                        let patternInstances = snapshot.activeInstances(
                            for: pattern, after: activeScheduleCache.coverageStart,
                            maximumDeparture: activeScheduleCache.coverageEnd, trace: trace,
                            cancellationToken: cancellationToken)
                        try cancellationToken?.checkCancellation()
                        trace.addDuration("ActiveInstanceBuild", startedAt: instancesStartedAt)
                        trace.addCount("activeTripInstancesBuilt", value: patternInstances.count)
                        var indexedDepartures = Array(
                            repeating: [TransitBoardingDeparture](), count: pattern.stopIDs.count)
                        for (instanceIndex, instance) in patternInstances.enumerated() {
                            if instanceIndex.isMultiple(of: 128) {
                                try cancellationToken?.checkCancellation()
                            }
                            for stopIndex in instance.times.indices
                                where stopIndex < indexedDepartures.count
                                    && instance.times[stopIndex].departure <= activeScheduleCache.coverageEnd
                                    && instance.times[stopIndex].isBoardable {
                                indexedDepartures[stopIndex].append(
                                    TransitBoardingDeparture(instanceIndex: instanceIndex,
                                                             time: instance.times[stopIndex].departure))
                            }
                        }
                        for stopIndex in indexedDepartures.indices {
                            try cancellationToken?.checkCancellation()
                            indexedDepartures[stopIndex].sort { $0.time < $1.time }
                        }
                        let builtSchedule = TransitActiveScheduleCache.PatternSchedule(
                            instances: patternInstances, departuresByStopIndex: indexedDepartures)
                        activeScheduleCache.store(builtSchedule, for: patternID)
                        sharedSchedule = builtSchedule
                    }
                    let patternInstances: [GTFSTripInstance]
                    let departuresByStopIndex: [ArraySlice<TransitBoardingDeparture>]
                    if let sharedSchedule {
                        patternInstances = sharedSchedule.instances
                        departuresByStopIndex = sharedSchedule.departuresByStopIndex.map { departures in
                            let endIndex = upperBound(in: departures, for: latestDeparture)
                            return departures[..<endIndex]
                        }
                    } else {
                        let instancesStartedAt = ProcessInfo.processInfo.systemUptime
                        patternInstances = snapshot.activeInstances(
                            for: pattern, after: departingAt,
                            maximumDeparture: latestDeparture, trace: trace,
                            cancellationToken: cancellationToken)
                        try cancellationToken?.checkCancellation()
                        trace.addDuration("ActiveInstanceBuild", startedAt: instancesStartedAt)
                        trace.addCount("activeTripInstancesBuilt", value: patternInstances.count)
                        var indexedDepartures = Array(
                            repeating: [TransitBoardingDeparture](), count: pattern.stopIDs.count)
                        for (instanceIndex, instance) in patternInstances.enumerated() {
                            if instanceIndex.isMultiple(of: 128) {
                                try cancellationToken?.checkCancellation()
                            }
                            for stopIndex in instance.times.indices
                                where stopIndex < indexedDepartures.count
                                    && instance.times[stopIndex].departure <= latestDeparture
                                    && instance.times[stopIndex].isBoardable {
                                indexedDepartures[stopIndex].append(
                                    TransitBoardingDeparture(instanceIndex: instanceIndex,
                                                             time: instance.times[stopIndex].departure))
                            }
                        }
                        for stopIndex in indexedDepartures.indices {
                            try cancellationToken?.checkCancellation()
                            indexedDepartures[stopIndex].sort { $0.time < $1.time }
                        }
                        departuresByStopIndex = indexedDepartures.map { ArraySlice($0) }
                    }
                    let firstInstanceIndex = instances.count
                    patternInstanceBaseByID[patternID] = firstInstanceIndex
                    instances.append(contentsOf: patternInstances)
                    activeRouteIDs.insert(pattern.routeID)
                    departuresByPatternStop[patternID] = departuresByStopIndex
                }

                guard let departuresByStopIndex = departuresByPatternStop[patternID] else { continue }
                guard let instanceBase = patternInstanceBaseByID[patternID] else { continue }
                for stopIndex in pattern.stopIDs.indices {
                    try cancellationToken?.checkCancellation()
                    let stopID = pattern.stopIDs[stopIndex]
                    guard let labels = boardingLabels[stopID],
                          departuresByStopIndex.indices.contains(stopIndex) else { continue }
                    let departures = departuresByStopIndex[stopIndex]
                    guard !departures.isEmpty else { continue }
                    let arrivalEnvelopeByDownstreamStop: [[Int]]
                    if let cached = arrivalEnvelopeByPatternStop[patternID]?[stopIndex]
                        ?? activeScheduleCache?.arrivalEnvelope(for: patternID, stopIndex: stopIndex,
                                                                 departureCount: departures.count) {
                        arrivalEnvelopeByDownstreamStop = cached
                    } else {
                        // For each downstream stop, build a compact suffix minimum over
                        // trips ordered by departure at this boarding stop. A label only
                        // needs the best-arriving trip it can still catch; scanning every
                        // departure again for every label repeats dominated work.
                        var envelopes = Array(repeating: [Int](), count: pattern.stopIDs.count)
                        for downstreamIndex in (stopIndex + 1)..<pattern.stopIDs.count {
                            try cancellationToken?.checkCancellation()
                            var isFIFO = true
                            var previousArrival: Date?
                            for departure in departures {
                                if departureTripsScanned.isMultiple(of: 128) {
                                    try cancellationToken?.checkCancellation()
                                }
                                departureTripsScanned += 1
                                let instance = instances[instanceBase + departure.instanceIndex]
                                guard instance.times.indices.contains(downstreamIndex),
                                      instance.times[downstreamIndex].isAlightable else {
                                    isFIFO = false
                                    break
                                }
                                let arrival = instance.times[downstreamIndex].arrival
                                if let previousArrival, arrival < previousArrival {
                                    isFIFO = false
                                    break
                                }
                                previousArrival = arrival
                            }
                            if isFIFO {
                                // FIFO timetables need no per-trip breakpoint storage:
                                // the first departure that can be caught arrives first.
                                envelopes[downstreamIndex] = [-2]
                                continue
                            }

                            var bestDepartureBreakpoints: [Int] = []
                            var bestDepartureIndex = -1
                            var bestArrival = Date.distantFuture
                            for departureIndex in departures.indices.reversed() {
                                if departureTripsScanned.isMultiple(of: 128) {
                                    try cancellationToken?.checkCancellation()
                                }
                                departureTripsScanned += 1
                                let departure = departures[departureIndex]
                                let instance = instances[instanceBase + departure.instanceIndex]
                                guard instance.times.indices.contains(downstreamIndex),
                                      instance.times[downstreamIndex].isAlightable else {
                                    continue
                                }
                                let arrival = instance.times[downstreamIndex].arrival
                                // Prefer the earlier departure when arrival times tie,
                                // matching the prior forward scan's strict improvement.
                                if bestDepartureIndex == -1 || arrival <= bestArrival {
                                    bestArrival = arrival
                                    bestDepartureIndex = departureIndex
                                    bestDepartureBreakpoints.append(departureIndex)
                                }
                            }
                            envelopes[downstreamIndex] = Array(bestDepartureBreakpoints.reversed())
                        }
                        var patternEnvelopes = arrivalEnvelopeByPatternStop[patternID] ?? [:]
                        patternEnvelopes[stopIndex] = envelopes
                        arrivalEnvelopeByPatternStop[patternID] = patternEnvelopes
                        activeScheduleCache?.storeArrivalEnvelope(
                            envelopes, for: patternID, stopIndex: stopIndex,
                            departureCount: departures.count)
                        arrivalEnvelopeByDownstreamStop = envelopes
                    }
                    for label in labels {
                        try cancellationToken?.checkCancellation()
                        let transferBuffer = label.rideCount > 0 && !label.lastLegWasTransfer ? 60.0 : 0
                        let minimumDeparture = label.arrival.addingTimeInterval(transferBuffer)
                        let transferRuleContext = matchingTransferRules(
                            for: label, toStopID: stopID, instances: instances, database: database)
                        let earliestBoarding = transferRuleContext.map { _ in label.arrival }
                            ?? minimumDeparture
                        let startIndex = lowerBound(
                            in: departures, for: earliestBoarding)
                        guard startIndex < departures.count else { continue }
                        for downstreamIndex in (stopIndex + 1)..<pattern.stopIDs.count {
                            try cancellationToken?.checkCancellation()
                            guard arrivalEnvelopeByDownstreamStop.indices.contains(downstreamIndex) else { continue }
                            let bestDepartureIndex: Int
                            if let transferRuleContext {
                                var best: (index: Int, arrival: Date)?
                                for departureIndex in startIndex..<departures.count {
                                    if departureIndex.isMultiple(of: 128) {
                                        try cancellationToken?.checkCancellation()
                                    }
                                    let departure = departures[departureIndex]
                                    let candidateIndex = instanceBase + departure.instanceIndex
                                    guard instances.indices.contains(candidateIndex) else { continue }
                                    let instance = instances[candidateIndex]
                                    guard instance.times.indices.contains(stopIndex),
                                          instance.times.indices.contains(downstreamIndex),
                                          instance.times[downstreamIndex].isAlightable,
                                          allowsBoarding(label: label,
                                                         departure: instance.times[stopIndex].departure,
                                                         outboundRouteID: instance.route.id,
                                                         outboundTripID: instance.trip.id,
                                                         normalBuffer: transferBuffer,
                                                         context: transferRuleContext) else { continue }
                                    let arrival = instance.times[downstreamIndex].arrival
                                    if let arrivalDeadline, arrival > arrivalDeadline { continue }
                                    if best == nil || arrival < best!.arrival
                                        || (arrival == best!.arrival && departure.time < departures[best!.index].time) {
                                        best = (departureIndex, arrival)
                                    }
                                }
                                guard let best else { continue }
                                bestDepartureIndex = best.index
                            } else {
                                let breakpoints = arrivalEnvelopeByDownstreamStop[downstreamIndex]
                                if breakpoints.count == 1 && breakpoints[0] == -2 {
                                    bestDepartureIndex = startIndex
                                } else {
                                    var lower = 0
                                    var upper = breakpoints.count
                                    while lower < upper {
                                        let middle = lower + (upper - lower) / 2
                                        if breakpoints[middle] < startIndex {
                                            lower = middle + 1
                                        } else {
                                            upper = middle
                                        }
                                    }
                                    guard lower < breakpoints.count else { continue }
                                    bestDepartureIndex = breakpoints[lower]
                                }
                            }
                            if case nil = transferRuleContext {
                                departureTripsDominated += departures.count - startIndex - 1
                            }
                            let departure = departures[bestDepartureIndex]
                            let instance = instances[instanceBase + departure.instanceIndex]
                            guard instance.times.indices.contains(downstreamIndex),
                                  instance.times[downstreamIndex].isAlightable else { continue }
                            let downstream = instance.times[downstreamIndex]
                            if let arrivalDeadline, downstream.arrival > arrivalDeadline { continue }
                            let ride = TransitRide(instanceIndex: instanceBase + departure.instanceIndex,
                                                   boardIndex: stopIndex,
                                                   alightIndex: downstreamIndex)
                            let rideSeconds = max(0, downstream.arrival.timeIntervalSince(
                                instance.times[stopIndex].departure))
                            let next = TransitPathLabel(arrival: downstream.arrival,
                                                        currentStopID: downstream.stopID,
                                                        initialWalkingSeconds: label.initialWalkingSeconds,
                                                        walkingSeconds: label.walkingSeconds,
                                                        rideSeconds: label.rideSeconds + rideSeconds,
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
            layers.append(current)
            let alightingLabels = transferClosure(current, database: database, instances: instances,
                                                  cancellationToken: cancellationToken)
            try cancellationToken?.checkCancellation()
            for (stopID, labels) in alightingLabels
                where database.servedStopIDs.contains(stopID) && stopByID[stopID] != nil {
                try cancellationToken?.checkCancellation()
                let destinationOptions: [TransitWalkOption]
                if let destinationWalksByStopID {
                    destinationOptions = destinationWalksByStopID[stopID] ?? []
                } else if let cachedOption = approximateDestinationWalksByStopID[stopID] {
                    destinationOptions = [cachedOption]
                } else if let stop = stopByID[stopID] {
                    // Coarse egress estimates are cheap and only needed for stops
                    // actually reached by the current transit search. This avoids
                    // building an option for every served stop in the feed.
                    let straightLineDistance = stop.coordinate.distance(to: destination)
                    let estimatedDistance = straightLineDistance * 1.5
                    let option = TransitWalkOption(
                        stop: stop, distance: estimatedDistance,
                        duration: estimatedDistance / 0.9,
                        coordinates: [stop.coordinate, destination],
                        hasResolvedGeometry: false, isApproximate: true)
                    approximateDestinationWalksByStopID[stopID] = option
                    destinationOptions = [option]
                } else {
                    destinationOptions = []
                }
                guard !destinationOptions.isEmpty else { continue }
                for label in labels {
                    try cancellationToken?.checkCancellation()
                    for access in destinationOptions {
                        try cancellationToken?.checkCancellation()
                        let arrival = label.arrival.addingTimeInterval(access.duration)
                        if let arrivalDeadline, arrival > arrivalDeadline { continue }
                        candidates.append(TransitPlanCandidate(
                            label: label, destinationWalk: access, arrival: arrival))
                        totalCandidateCount += 1
                        if candidateLimit > 0, candidates.count >= candidateLimit * 2 {
                            candidates = TransitCandidateRanker.bestCandidates(
                                candidates, departingAt: departingAt, limit: candidateLimit)
                                .map(\.candidate)
                        }
                    }
                }
            }
            if current.isEmpty { break }
            ridesUsed += 1
        }

        trace.setCount("roundsExecuted", value: roundsExecuted)
        TransitSignposting.event("TransitRoundsExecuted", value: roundsExecuted, planningID: planningID)
        trace.setCount("activeTrips", value: instances.count)
        trace.setCount("activeRoutes", value: activeRouteIDs.count)
        trace.setCount("activePatterns", value: touchedPatternIDs.count)
        trace.setCount("markedStops", value: markedStopsCount(in: layers))
        trace.setCount("departureTripsScanned", value: departureTripsScanned)
        trace.setCount("departureTripsDominated", value: departureTripsDominated)
        let stopsWithDepartures = departuresByPatternStop.values.reduce(into: 0) { count, departuresByStop in
            for departures in departuresByStop where !departures.isEmpty { count += 1 }
        }
        trace.setCount("stopsWithDepartures", value: stopsWithDepartures)
        TransitSignposting.event("ActiveTripInstanceCount", value: instances.count, planningID: planningID)
        TransitSignposting.event("ActiveRouteCount", value: activeRouteIDs.count, planningID: planningID)
        TransitSignposting.event("ActiveRoutePatternCount", value: touchedPatternIDs.count, planningID: planningID)
        trace.setCount("routesTouched", value: touchedPatternIDs.count)
        TransitSignposting.event("RoutesTouched", value: touchedPatternIDs.count, planningID: planningID)
        let rankingStartedAt = ProcessInfo.processInfo.systemUptime
        let rankingInterval = TransitSignposting.begin("CandidateRanking", planningID: planningID)
        trace.setCount("candidates", value: totalCandidateCount)
        trace.setCount("candidatesRetained", value: candidates.count)
        TransitSignposting.event("StaticCandidateCount", value: totalCandidateCount, planningID: planningID)
        let rankedCandidates = TransitCandidateRanker.bestCandidates(
            candidates, departingAt: departingAt, limit: candidateLimit)
        TransitSignposting.end("CandidateRanking", identifier: rankingInterval, planningID: planningID)
        trace.recordDuration("CandidateRanking", startedAt: rankingStartedAt)
        var routes: [NavigationRoute] = []
        for rankedCandidate in rankedCandidates {
            try cancellationToken?.checkCancellation()
            let candidate = rankedCandidate.candidate
            if let route = makeRoute(candidate: candidate, database: database, realtime: realtime,
                                     instances: instances, stopByID: stopByID,
                                     origin: origin, destination: destination, departingAt: departingAt,
                                     originWalks: originWalks,
                                     usingCachedSchedule: usingCachedSchedule,
                                     regionID: regionID) {
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
                && (existing.lastLegWasTransfer || !candidate.lastLegWasTransfer)
        }) else { return false }
        labels.removeAll { existing in
            candidate.arrival <= existing.arrival
                && candidate.walkingSeconds <= existing.walkingSeconds
                && candidate.transferCount <= existing.transferCount
                && (candidate.lastLegWasTransfer || !existing.lastLegWasTransfer)
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
                                database: GTFSDatabase,
                                instances: [GTFSTripInstance] = [],
                                latestBoardingTime: Date? = nil,
                                cancellationToken: TransitPlanningCancellationToken? = nil)
        -> [String: [TransitPathLabel]] {
        if Task.isCancelled || cancellationToken?.isCancelled == true { return [:] }
        let boardingSeeds: [String: [TransitPathLabel]]
        if let latestBoardingTime {
            boardingSeeds = labels.compactMapValues { labels in
                let eligible = labels.filter { $0.arrival <= latestBoardingTime }
                return eligible.isEmpty ? nil : eligible
            }
        } else {
            boardingSeeds = labels
        }
        var reachable = boardingSeeds
        var queue = boardingSeeds.values.flatMap { $0 }
        var cursor = 0
        while cursor < queue.count {
            if Task.isCancelled || cancellationToken?.isCancelled == true { return reachable }
            let label = queue[cursor]
            cursor += 1
            if let latestBoardingTime, label.arrival > latestBoardingTime { continue }
            var transfers = database.footpathsByStopID[label.currentStopID] ?? []
            if let incoming = previousRideContext(for: label, instances: instances),
               incoming.stopID == label.currentStopID,
               let from = database.stopByID[incoming.stopID] {
                for rule in database.transferRules where rule.isScoped
                    && (rule.transferType == 0 || rule.transferType == 1 || rule.transferType == 2
                        || rule.transferType == 4 || rule.transferType == 5)
                    && (rule.fromRouteID == nil || rule.fromRouteID == incoming.routeID)
                    && (rule.fromTripID == nil || rule.fromTripID == incoming.tripID) {
                    guard let endpoints = resolvedTransferStops(rule, database: database),
                          endpoints.fromStopID == incoming.stopID,
                          endpoints.toStopID != incoming.stopID,
                          let to = database.stopByID[endpoints.toStopID] else { continue }
                    let distance = from.coordinate.distance(to: to.coordinate)
                    transfers.append(TransitFootpath(
                        fromStopID: from.id, toStopID: to.id,
                        walkingDistance: rule.transferType == 4 ? 0 : distance,
                        walkingDuration: rule.transferType == 4 ? 0 : distance,
                        minimumTransferTime: rule.minimumTransferTime,
                        coordinates: [from.coordinate, to.coordinate],
                        isInSeatConnection: rule.transferType == 4))
                }
            }
            for transfer in transfers {
                if Task.isCancelled || cancellationToken?.isCancelled == true { return reachable }
                let walkingSeconds = label.walkingSeconds + transfer.walkingDuration
                let arrival = label.arrival.addingTimeInterval(transfer.requiredTransferDuration)
                if let latestBoardingTime, arrival > latestBoardingTime { continue }
                let next = TransitPathLabel(
                    arrival: arrival,
                    currentStopID: transfer.toStopID,
                    initialWalkingSeconds: label.initialWalkingSeconds,
                    walkingSeconds: walkingSeconds, rideSeconds: label.rideSeconds,
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

    static func walkingAccessCandidates(from coordinate: Coordinate,
                                        database: GTFSDatabase,
                                        maximumStraightLineDistance: Double? = nil,
                                        includingStopIDs: Set<String> = [],
                                        sortByDistance: Bool = true) -> [(GTFSStop, Double)] {
        let candidates: [(GTFSStop, Double)]
        if let maximumStraightLineDistance {
            let nearbyIDs = Set(database.stopSpatialIndex.nearbyStopIDs(
                to: coordinate, within: maximumStraightLineDistance))
                .union(includingStopIDs)
            candidates = nearbyIDs.compactMap { database.stopByID[$0] }
                .map { ($0, coordinate.distance(to: $0.coordinate)) }
                .filter { $0.1 <= maximumStraightLineDistance || includingStopIDs.contains($0.0.id) }
        } else {
            candidates = database.stopsForSearch
                .map { ($0, coordinate.distance(to: $0.coordinate)) }
        }
        guard sortByDistance else { return candidates }
        return candidates.sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 < $1.1
        }
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
            for index in instance.times.indices where instance.times[index].stopID == stopID
                && instance.times[index].isBoardable
                && instance.times[index].departure >= date.addingTimeInterval(-30) {
            let prediction = instance.times[index]
            let departureID = "\(instance.trip.id)|\(instance.serviceDate)|\(instance.trip.stopTimes[index].sequence)"
                + (instance.frequencyStartSeconds.map { "|freq=\($0)" } ?? "")
            result.append(TransitDeparture(id: departureID,
                                           stopID: stopID, routeID: instance.route.id, tripID: instance.trip.id,
                                           line: instance.trip.displayLine(for: instance.route), mode: instance.route.mode,
                                           destination: instance.trip.headsign.isEmpty
                                               ? instance.trip.stopTimes.last.flatMap { database.stopByID[$0.stopID]?.name } ?? "Kierunek nieznany"
                                               : instance.trip.headsign,
                                           scheduledDeparture: GTFSDate.serviceInstant(
                                               from: instance.serviceDate,
                                               seconds: instance.trip.stopTimes[index].departureSeconds
                                                + instance.scheduleShiftSeconds)
                                               ?? prediction.departure,
                                           estimatedDeparture: prediction.departure,
                                           delaySeconds: prediction.delaySeconds,
                                           hasRealtime: prediction.hasRealtime,
                                           colorHex: instance.route.colorHex,
                                           stopSequence: instance.trip.stopTimes[index].sequence,
                                           serviceDate: instance.serviceDate,
                                           scheduleShiftSeconds: instance.scheduleShiftSeconds,
                                           frequencyStartSeconds: instance.frequencyStartSeconds,
                                           frequencyHeadwaySeconds: instance.frequencyHeadwaySeconds,
                                           isFrequencyEstimate: instance.isFrequencyEstimate))
            }
        }
        return result.sorted { $0.estimatedDeparture < $1.estimatedDeparture }.prefix(limit).map { $0 }
    }

    static func lowerBound(in departures: ArraySlice<TransitBoardingDeparture>, for time: Date) -> Int {
        var lower = 0
        var upper = departures.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if departures[middle].time < time { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    static func upperBound(in departures: [TransitBoardingDeparture], for time: Date) -> Int {
        var lower = 0
        var upper = departures.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if departures[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    static func matchingTransferRules(
        for label: TransitPathLabel,
        toStopID: String,
        instances: [GTFSTripInstance],
        database: GTFSDatabase
    ) -> (previousArrival: Date, rules: [GTFSTransferRule])? {
        guard let incoming = previousRideContext(for: label, instances: instances) else { return nil }
        let rules = database.transferRules.filter { rule in
            guard let endpoints = resolvedTransferStops(rule, database: database) else { return false }
            return endpoints.fromStopID == incoming.stopID && endpoints.toStopID == toStopID
                && (rule.fromRouteID == nil || rule.fromRouteID == incoming.routeID)
                && (rule.fromTripID == nil || rule.fromTripID == incoming.tripID)
        }
        return rules.isEmpty ? nil : (incoming.arrival, rules)
    }

    static func resolvedTransferStops(
        _ rule: GTFSTransferRule,
        database: GTFSDatabase
    ) -> (fromStopID: String, toStopID: String)? {
        let fromStopID = rule.fromStopID
            ?? rule.fromTripID.flatMap { database.tripsByID[$0]?.stopTimes.last?.stopID }
        let toStopID = rule.toStopID
            ?? rule.toTripID.flatMap { database.tripsByID[$0]?.stopTimes.first?.stopID }
        guard let fromStopID, let toStopID else { return nil }
        return (fromStopID, toStopID)
    }

    static func previousRideContext(
        for label: TransitPathLabel,
        instances: [GTFSTripInstance]
    ) -> (stopID: String, routeID: String, tripID: String, arrival: Date)? {
        var ancestor: TransitPathLabel? = label
        while let current = ancestor {
            if let ride = current.ride,
               instances.indices.contains(ride.instanceIndex),
               instances[ride.instanceIndex].times.indices.contains(ride.alightIndex) {
                let incoming = instances[ride.instanceIndex]
                let stop = incoming.times[ride.alightIndex]
                return (stop.stopID, incoming.route.id, incoming.trip.id, stop.arrival)
            }
            ancestor = current.parent
        }
        return nil
    }

    static func allowsBoarding(
        label: TransitPathLabel,
        departure: Date,
        outboundRouteID: String,
        outboundTripID: String,
        normalBuffer: TimeInterval,
        context: (previousArrival: Date, rules: [GTFSTransferRule])
    ) -> Bool {
        var matchingRules = context.rules.filter { rule in
            (rule.toRouteID == nil || rule.toRouteID == outboundRouteID)
                && (rule.toTripID == nil || rule.toTripID == outboundTripID)
        }
        guard !matchingRules.isEmpty else {
            return departure >= label.arrival.addingTimeInterval(normalBuffer)
        }

        let highestSpecificity = matchingRules.map {
            [ $0.fromRouteID, $0.toRouteID, $0.fromTripID, $0.toTripID ].compactMap { $0 }.count
        }.max() ?? 0
        matchingRules = matchingRules.filter {
            [ $0.fromRouteID, $0.toRouteID, $0.fromTripID, $0.toTripID ].compactMap { $0 }.count
                == highestSpecificity
        }
        guard !matchingRules.contains(where: { $0.transferType == 3 }) else { return false }

        let hasProtectedConnection = matchingRules.contains {
            $0.transferType == 1 || $0.transferType == 4
        }
        var requiredDeparture = label.arrival.addingTimeInterval(hasProtectedConnection ? 0 : normalBuffer)
        for rule in matchingRules where rule.transferType == 2 {
            requiredDeparture = max(requiredDeparture,
                                    context.previousArrival.addingTimeInterval(rule.minimumTransferTime))
        }
        return departure >= requiredDeparture
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
            guard let serviceStart = GTFSDate.serviceStart(from: dateString) else { continue }
            for trip in trips {
                guard let route = database.routes[trip.routeID],
                      serviceIsActive(trip.serviceID, on: dateString, weekday: weekday,
                                      database: database) else { continue }
                instances.append(contentsOf: GTFSTripInstanceBuilder.build(
                    trip: trip, route: route, serviceDate: dateString,
                    serviceStart: serviceStart, database: database, realtime: realtime,
                    earliestArrival: departure.addingTimeInterval(-3_600),
                    latestDeparture: departure.addingTimeInterval(maximumDepartureSearchWindow)))
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
        usingCachedSchedule: Bool,
        regionID: String
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
                if transfer.isInSeatConnection { continue }
                legs.append(JourneyLeg(mode: "WALK", from: fromStop.name, to: toStop.name,
                                       departure: parent.arrival, arrival: node.arrival,
                                       realTime: false, coordinates: transfer.coordinates,
                                       isTransfer: true,
                                       minimumTransferTime: transfer.minimumTransferTime,
                                       walkingDuration: transfer.walkingDuration,
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
                      let stop = stopByID[instance.times[index].stopID],
                      !instance.times[index].isSkipped else { return nil }
                let prediction = instance.times[index]
                let stopPrefix = instance.frequencyStartSeconds.map {
                    "\(instance.trip.id)-freq-\($0)"
                } ?? instance.trip.id
                return TransitJourneyStop(id: "\(stopPrefix)-\(instance.trip.stopTimes[index].sequence)",
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
                                   transitStops: transitStops,
                                   scheduleShiftSeconds: instance.scheduleShiftSeconds,
                                   frequencyStartSeconds: instance.frequencyStartSeconds,
                                   frequencyHeadwaySeconds: instance.frequencyHeadwaySeconds,
                                   isFrequencyEstimate: instance.isFrequencyEstimate))
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
                && alert.applies(routeIDs: relevantRoutes, stopIDs: relevantStops,
                                 tripIDs: Set(legs.compactMap(\.tripID)))
        }.map(\.message).filter { !$0.isEmpty }.prefix(3)
        let rideDuration = legs.filter { $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        let walkingDuration = legs.filter { $0.mode == "WALK" }
            .reduce(0.0) { $0 + $1.plannedWalkingDuration }
        let waitingDuration = max(0, candidate.arrival.timeIntervalSince(departingAt) - rideDuration - walkingDuration)
        let journeyHasRail = legs.contains { $0.mode == "RAIL" }
        let journeySources = Set(legs.compactMap { leg -> String? in
            guard leg.mode != "WALK", let tripID = leg.tripID else { return nil }
            return tripID.hasPrefix("rail/") ? "rail" : regionID
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
                              transferCount: Self.transferCount(in: legs, rules: database.transferRules),
                              realtimeFreshness: journeyFreshness,
                              frequencyEstimateHeadwaySeconds: legs.first(where: \.isFrequencyEstimate)?.frequencyHeadwaySeconds,
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

    static func transferCount(in legs: [JourneyLeg], rules: [GTFSTransferRule]) -> Int {
        let rides = legs.filter { $0.mode != "WALK" }
        guard rides.count > 1 else { return 0 }
        let inSeatConnections = zip(rides, rides.dropFirst()).reduce(into: 0) { count, pair in
            let (incoming, outgoing) = pair
            let isLinked = rules.contains { rule in
                rule.transferType == 4
                    && rule.fromTripID == incoming.tripID
                    && rule.toTripID == outgoing.tripID
                    && (rule.fromRouteID == nil || rule.fromRouteID == incoming.routeID)
                    && (rule.toRouteID == nil || rule.toRouteID == outgoing.routeID)
            }
            if isLinked { count += 1 }
        }
        return max(0, rides.count - 1 - inSeatConnections)
    }

    static func shapeCoordinates(for trip: GTFSTrip, from start: Int, to end: Int,
                                         database: GTFSDatabase,
                                         stopByID: [String: GTFSStop]) -> [Coordinate] {
        guard let boardID = trip.stopTimes[safe: start]?.stopID,
              let alightID = trip.stopTimes[safe: end]?.stopID,
              let board = stopByID[boardID], let alight = stopByID[alightID] else { return [] }
        func anchored(_ points: [Coordinate]) -> [Coordinate] {
            var result = [board.coordinate]
            for point in points where (result.last?.distance(to: point) ?? .infinity) > 1 {
                result.append(point)
            }
            if (result.last?.distance(to: alight.coordinate) ?? .infinity) > 1 {
                result.append(alight.coordinate)
            }
            return result
        }
        if let shape = database.shapes[trip.shapeID], shape.count > 1 {
            if let boardDistance = trip.stopTimes[safe: start]?.shapeDistance,
               let alightDistance = trip.stopTimes[safe: end]?.shapeDistance,
               boardDistance != alightDistance,
               let distances = database.shapeDistances[trip.shapeID], distances.count == shape.count {
                let low = min(boardDistance, alightDistance)
                let high = max(boardDistance, alightDistance)
                let matchingIndices = distances.indices.filter { index in
                    guard let distance = distances[index] else { return false }
                    return distance >= low && distance <= high
                }
                if let first = matchingIndices.first, let last = matchingIndices.last {
                    let startIndex = boardDistance <= alightDistance ? first : last
                    let endIndex = boardDistance <= alightDistance ? last : first
                    let range = min(startIndex, endIndex)...max(startIndex, endIndex)
                    let points = Array(shape[range])
                    return anchored(startIndex <= endIndex ? points : Array(points.reversed()))
                }
            }

            var nearestAlightIndexAtOrAfter = Array(repeating: shape.count - 1, count: shape.count)
            if shape.count > 1 {
                for index in stride(from: shape.count - 2, through: 0, by: -1) {
                    let candidate = index + 1
                    let current = nearestAlightIndexAtOrAfter[candidate]
                    let candidateDistance = shape[candidate].distance(to: alight.coordinate)
                    let currentDistance = shape[current].distance(to: alight.coordinate)
                    nearestAlightIndexAtOrAfter[index] = candidateDistance < currentDistance
                        || (candidateDistance == currentDistance && candidate < current)
                        ? candidate : current
                }
            }
            var best: (start: Int, end: Int, error: Double, span: Int)?
            for startIndex in 0..<(shape.count - 1) {
                let endIndex = nearestAlightIndexAtOrAfter[startIndex + 1]
                let error = shape[startIndex].distance(to: board.coordinate)
                    + shape[endIndex].distance(to: alight.coordinate)
                let span = endIndex - startIndex
                if best == nil || error < best!.error || (error == best!.error && span < best!.span) {
                    best = (startIndex, endIndex, error, span)
                }
            }
            if let best {
                return anchored(Array(shape[best.start...best.end]))
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
