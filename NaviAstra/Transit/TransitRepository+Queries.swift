import Foundation

extension TransitRepository {
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
            return switch route.mode {
            case "RAIL": .rail
            case "TRAM": .tram
            default: .bus
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
        let instances = activeTripInstances(database: database, realtime: realtime,
                                            after: date, onlyStopIDs: [stopID])
        var result: [TransitDeparture] = []
        for instance in instances {
            for index in instance.times.indices where instance.times[index].stopID == stopID
                && instance.times[index].isBoardable
                && instance.times[index].departure >= date.addingTimeInterval(-30) {
                let prediction = instance.times[index]
                let departureID = "\(instance.trip.id)|\(instance.serviceDate)|\(instance.trip.stopTimes[index].sequence)"
                    + (instance.frequencyStartSeconds.map { "|freq=\($0)" } ?? "")
                result.append(TransitDeparture(
                    id: departureID,
                    stopID: stopID,
                    routeID: instance.route.id,
                    tripID: instance.trip.id,
                    line: instance.trip.displayLine(for: instance.route),
                    mode: instance.route.mode,
                    destination: instance.trip.headsign.isEmpty
                        ? instance.trip.stopTimes.last.flatMap { database.stopByID[$0.stopID]?.name } ?? "Kierunek nieznany"
                        : instance.trip.headsign,
                    scheduledDeparture: GTFSDate.serviceInstant(
                        from: instance.serviceDate,
                        seconds: instance.trip.stopTimes[index].departureSeconds + instance.scheduleShiftSeconds)
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
        return result.sorted { $0.estimatedDeparture < $1.estimatedDeparture }
            .prefix(limit).map { $0 }
    }

    private static func activeTripInstances(database: GTFSDatabase,
                                            realtime: GTFSRealtimeSnapshot,
                                            after departure: Date,
                                            onlyStopIDs: Set<String>) -> [GTFSTripInstance] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let today = calendar.startOfDay(for: departure)
        let finalDay = calendar.startOfDay(
            for: departure.addingTimeInterval(maximumDepartureSearchWindow))
        let serviceDates = (-1...(finalDay > today ? 1 : 0)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
        let tripIDs = Set(onlyStopIDs.flatMap { database.tripIDsByStop[$0] ?? [] })
        let trips = tripIDs.compactMap { database.tripsByID[$0] }
        var instances: [GTFSTripInstance] = []
        for serviceDate in serviceDates {
            let date = GTFSDate.string(from: serviceDate)
            let weekday = GTFSDate.weekdayKey(for: serviceDate, calendar: calendar)
            guard let serviceStart = GTFSDate.serviceStart(from: date) else { continue }
            for trip in trips {
                guard let route = database.routes[trip.routeID],
                      serviceIsActive(trip.serviceID, on: date, weekday: weekday,
                                      database: database) else { continue }
                instances.append(contentsOf: GTFSTripInstanceBuilder.build(
                    trip: trip, route: route, serviceDate: date,
                    serviceStart: serviceStart, database: database, realtime: realtime,
                    earliestArrival: departure.addingTimeInterval(-3_600),
                    latestDeparture: departure.addingTimeInterval(maximumDepartureSearchWindow)))
            }
        }
        return instances
    }

    private static func serviceIsActive(_ serviceID: String, on date: String, weekday: String,
                                        database: GTFSDatabase) -> Bool {
        if let exception = database.exceptions[serviceID]?[date] { return exception == 1 }
        guard let calendar = database.calendars[serviceID] else { return false }
        return date >= calendar.startDate && date <= calendar.endDate
            && calendar.weekdayFlags[weekday] == true
    }

    func departures(at stopID: String, limit: Int) async -> [TransitDeparture] {
        guard let database = try? await loadDatabase() else { return [] }
        let realtime = await loadRealtime()
        return Self.departures(database: database, realtime: realtime, stopID: stopID,
                               after: Date(), limit: limit)
    }

    func departures(at stopIDs: [String], limit: Int) async -> [TransitDeparture] {
        guard let database = try? await loadDatabase() else { return [] }
        let realtime = await loadRealtime()
        let uniqueStopIDs = Array(Set(stopIDs)).sorted().prefix(20)
        let departures = uniqueStopIDs.flatMap { stopID in
            Self.departures(database: database, realtime: realtime, stopID: stopID,
                            after: Date(), limit: limit)
        }.sorted { $0.estimatedDeparture < $1.estimatedDeparture }
        return Array(departures.prefix(limit))
    }

    func alerts(for stopID: String) async -> [String] {
        await alerts(for: [stopID])
    }

    func alerts(for stopIDs: [String]) async -> [String] {
        let cityStopIDs = Set(stopIDs.filter { !$0.hasPrefix("rail/") })
        guard !cityStopIDs.isEmpty else { return [] }
        guard let database = try? await loadDatabase() else { return [] }
        let realtime = await loadRealtime()
        let routeIDs = Set(cityStopIDs.flatMap { database.routeIDsByStop[$0] ?? [] })
        return Array(realtime.alerts.filter {
            $0.isActive(at: Date())
                && $0.applies(routeIDs: routeIDs, stopIDs: cityStopIDs, tripIDs: [])
        }.map(\.message).filter { !$0.isEmpty }.prefix(3))
    }

    func railwayScheduleAttribution() async -> String? {
        guard let database = try? await loadDatabase(), database.railwayFeedAvailable else { return nil }
        return Self.railwayAttribution(for: database)
    }

    func search(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults {
        guard query.count >= 2, let database = try? await loadDatabase(), !Task.isCancelled else {
            return TransitSearchResults(stops: [], lines: [])
        }
        let normalized = TransitSearchText.normalize(query)
        let matchingStops = database.stopsForSearch.compactMap { stop -> (stop: GTFSStop, distance: Double)? in
            guard database.normalizedStopNames[stop.id]?.contains(normalized) == true else { return nil }
            return (stop, coordinate.map { stop.coordinate.distance(to: $0) } ?? .infinity)
        }.sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.stop.name.localizedStandardCompare(rhs.stop.name) == .orderedAscending
        }.prefix(12).map { Self.publicStop($0.stop, database: database) }

        let matchingLines = database.routes.values.filter {
            database.normalizedRouteNames[$0.id]?.contains(normalized) == true
        }.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
            .prefix(8).map { route in
                return TransitLineSearchResult(id: route.id, name: route.displayName, mode: route.mode,
                                               directions: database.lineDirections[route.id] ?? "",
                                               colorHex: route.colorHex)
            }
        return TransitSearchResults(stops: Array(matchingStops), lines: Array(matchingLines))
    }

    func lineDetails(for routeID: String) async -> TransitLineDetails? {
        guard let database = try? await loadDatabase(), let route = database.routes[routeID] else { return nil }
        let matchingTrips = database.trips.filter { $0.routeID == routeID }
        guard let trip = matchingTrips.max(by: { $0.stopTimes.count < $1.stopTimes.count }) else { return nil }
        let stops = trip.stopTimes.compactMap { database.stopByID[$0.stopID] }
        let directions = Array(Set(matchingTrips.map(\.headsign).filter { !$0.isEmpty })).sorted()
        let coordinates = database.shapes[trip.shapeID].flatMap { $0.count > 1 ? $0 : nil }
            ?? stops.map(\.coordinate)
        return TransitLineDetails(id: route.id, name: route.displayName, mode: route.mode,
                                  directions: directions.prefix(2).joined(separator: " ↔ "),
                                  colorHex: route.colorHex,
                                  stops: stops.map { Self.publicStop($0, database: database) },
                                  coordinates: coordinates)
    }

    func vehicleDetails(id: String) async -> TransitTripDetails? {
        let now = Date()
        if vehiclesLoadedAt.map({ now.timeIntervalSince($0) >= 20 }) ?? true,
           let coordinate = vehiclesSnapshot.first(where: { $0.id == id })?.coordinate {
            _ = await vehiclePositions(near: coordinate)
        }
        guard let database = try? await loadDatabase(),
              let vehicle = vehiclesSnapshot.first(where: { $0.id == id }),
              let tripID = vehicle.tripID, let trip = database.tripsByID[tripID],
              let route = database.routes[vehicle.routeID ?? trip.routeID] else { return nil }
        let realtime = await loadRealtime()
        let serviceDate = vehicle.serviceDate ?? GTFSDate.string(from: now)
        let currentSequence = vehicle.currentStopSequence
            ?? vehicle.currentStopID.flatMap { stopID in trip.stopTimes.first(where: { $0.stopID == stopID })?.sequence }
        return makeTripDetails(database: database, realtime: realtime, trip: trip, route: route,
                               serviceDate: serviceDate, startSequence: currentSequence,
                               rawVehicle: vehicle)
    }

    func tripDetails(for departure: TransitDeparture) async -> TransitTripDetails? {
        guard let database = try? await loadDatabase(),
              let trip = database.tripsByID[departure.tripID],
              let route = database.routes[departure.routeID] else { return nil }
        let realtime = await loadRealtime()
        let vehicle = departure.frequencyStartSeconds == nil ? vehiclesSnapshot.first {
            $0.tripID == departure.tripID && ($0.serviceDate == nil || $0.serviceDate == departure.serviceDate)
        } : nil
        return makeTripDetails(database: database, realtime: realtime, trip: trip, route: route,
                               serviceDate: departure.serviceDate, startSequence: departure.stopSequence,
                               rawVehicle: vehicle,
                               scheduleShiftSeconds: departure.scheduleShiftSeconds,
                               frequencyStartSeconds: departure.frequencyStartSeconds,
                               frequencyHeadwaySeconds: departure.frequencyHeadwaySeconds,
                               isFrequencyEstimate: departure.isFrequencyEstimate)
    }

    func tripDetails(tripID: String, serviceDate: String,
                     fromStopSequence: Int) async -> TransitTripDetails? {
        await tripDetails(tripID: tripID, serviceDate: serviceDate,
                          fromStopSequence: fromStopSequence, scheduleShiftSeconds: 0,
                          frequencyStartSeconds: nil, frequencyHeadwaySeconds: nil)
    }

    func tripDetails(tripID: String, serviceDate: String, fromStopSequence: Int,
                     scheduleShiftSeconds: Int, frequencyStartSeconds: Int?,
                     frequencyHeadwaySeconds: Int?) async -> TransitTripDetails? {
        guard let database = try? await loadDatabase(),
              let trip = database.tripsByID[tripID],
              let route = database.routes[trip.routeID] else { return nil }
        let realtime = await loadRealtime()
        let vehicle = frequencyStartSeconds == nil ? vehiclesSnapshot.first {
            $0.tripID == tripID && ($0.serviceDate == nil || $0.serviceDate == serviceDate)
        } : nil
        return makeTripDetails(database: database, realtime: realtime, trip: trip, route: route,
                               serviceDate: serviceDate, startSequence: fromStopSequence,
                               rawVehicle: vehicle, scheduleShiftSeconds: scheduleShiftSeconds,
                               frequencyStartSeconds: frequencyStartSeconds,
                               frequencyHeadwaySeconds: frequencyHeadwaySeconds)
    }

    func makeTripDetails(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
                                 trip: GTFSTrip, route: GTFSRoute, serviceDate: String,
                                 startSequence: Int?, rawVehicle: GTFSRealtimeVehicle?,
                                 scheduleShiftSeconds: Int = 0, frequencyStartSeconds: Int? = nil,
                                 frequencyHeadwaySeconds: Int? = nil,
                                 isFrequencyEstimate: Bool = false) -> TransitTripDetails? {
        guard let start = GTFSDate.serviceStart(from: serviceDate) else { return nil }
        var previousDelay: Int?
        var hasNoRealtimeDataFromHere = false
        let predicted = trip.stopTimes.compactMap { stop -> TransitJourneyStop? in
            guard let definition = database.stopByID[stop.stopID] else { return nil }
            let scheduledArrival = start.addingTimeInterval(TimeInterval(stop.arrivalSeconds
                                                                          + scheduleShiftSeconds))
            let scheduledDeparture = start.addingTimeInterval(TimeInterval(stop.departureSeconds
                                                                           + scheduleShiftSeconds))
            let update = realtime.update(tripID: trip.id, serviceDate: serviceDate,
                                         stopID: stop.stopID, stopSequence: stop.sequence,
                                         frequencyStartSeconds: frequencyStartSeconds)
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
            let stopPrefix = frequencyStartSeconds.map { "\(trip.id)-freq-\($0)" } ?? trip.id
            return TransitJourneyStop(id: "\(stopPrefix)-\(stop.sequence)",
                                      stopID: stop.stopID, name: definition.name,
                                      coordinate: definition.coordinate,
                                      arrival: timingUpdate?.arrivalTime ?? scheduledArrival.addingTimeInterval(TimeInterval(arrivalDelay ?? previousDelay ?? 0)),
                                      departure: timingUpdate?.departureTime ?? scheduledDeparture.addingTimeInterval(TimeInterval(departureDelay ?? previousDelay ?? 0)),
                                      delaySeconds: departureDelay ?? arrivalDelay ?? previousDelay,
                                      hasRealtime: update?.isSkipped == true
                                        || (timingUpdate != nil && !hasNoRealtimeDataFromHere)
                                        || previousDelay != nil,
                                      sequence: stop.sequence,
                                      isSkipped: update?.isSkipped == true)
        }
        let vehicleSequence = rawVehicle?.currentStopSequence
            ?? rawVehicle?.currentStopID.flatMap { stopID in
                trip.stopTimes.first(where: { $0.stopID == stopID })?.sequence
            }
        let currentStopIdentifier = (vehicleSequence ?? startSequence).map { sequence in
            let stopPrefix = frequencyStartSeconds.map { "\(trip.id)-freq-\($0)" } ?? trip.id
            return "\(stopPrefix)-\(sequence)"
        }
        let currentIndex = currentStopIdentifier.flatMap { identifier in
            predicted.firstIndex(where: { stop in stop.id == identifier })
        } ?? 0
        let current = predicted.indices.contains(currentIndex) ? predicted[currentIndex].name : nil
        let currentStopID = predicted.indices.contains(currentIndex) ? predicted[currentIndex].stopID : nil
        let pastStops = Array(predicted.prefix(currentIndex).suffix(8))
        let nextStops = Array(predicted.dropFirst(min(currentIndex + 1, predicted.count)))
        let stopIDs = Set(trip.stopTimes.dropFirst(min(currentIndex, trip.stopTimes.count)).map(\.stopID))
        let alert = route.mode == "RAIL" ? nil : realtime.alerts.first {
            $0.isActive(at: Date())
                && $0.applies(routeIDs: [route.id], stopIDs: stopIDs, tripIDs: [trip.id])
        }?.message
        let vehicle: TransitVehicle? = rawVehicle.map { raw in
            TransitVehicle(id: raw.id, line: trip.displayLine(for: route), mode: route.mode,
                           routeID: route.id, tripID: trip.id, destination: trip.headsign,
                           coordinate: raw.coordinate, bearing: raw.bearing,
                           updatedAt: raw.updatedAt ?? Date(), delaySeconds: startSequence.flatMap { sequence in
                               realtime.update(tripID: trip.id, serviceDate: serviceDate,
                                               stopID: raw.currentStopID ?? "", stopSequence: sequence)?.departureDelay
                           }, colorHex: route.colorHex)
        }
        let coordinates = database.shapes[trip.shapeID].flatMap { $0.count > 1 ? $0 : nil }
            ?? trip.stopTimes.compactMap { database.stopByID[$0.stopID]?.coordinate }
        return TransitTripDetails(tripID: trip.id, line: trip.displayLine(for: route), mode: route.mode,
                                  destination: trip.headsign, currentStopName: current, currentStopID: currentStopID,
                                  pastStops: pastStops, nextStops: nextStops, vehicle: vehicle,
                                  activeAlert: alert, colorHex: route.colorHex, coordinates: coordinates,
                                  frequencyHeadwaySeconds: frequencyHeadwaySeconds,
                                  isFrequencyEstimate: isFrequencyEstimate)
    }

    func vehiclePositions(near coordinate: Coordinate) async -> TransitVehicleFeed {
        let receivedAt = Date()
        if let vehiclesLoadedAt, receivedAt.timeIntervalSince(vehiclesLoadedAt) < 20 {
            return makeVehicleFeed(near: coordinate)
        }
        do {
            _ = try await loadDatabase()
            async let vehicleData = Self.download(vehiclePositionsURL)
            async let realtime = loadRealtime()
            let (data, realtimeSnapshot) = try await (vehicleData, realtime)
            let parsed = try GTFSRealtimeSnapshot.vehiclePositions(from: data)
            guard isFresh(parsed.updatedAt, relativeTo: Date()) else {
                vehiclesSnapshot = []
                vehiclesUpdatedAt = nil
                vehiclesLoadedAt = Date()
                return makeVehicleFeed(near: coordinate)
            }
            vehiclesSnapshot = parsed.vehicles.filter { isFresh($0.updatedAt ?? parsed.updatedAt, relativeTo: Date()) }
            vehiclesUpdatedAt = parsed.updatedAt
            vehiclesLoadedAt = Date()
            _ = realtimeSnapshot
            return makeVehicleFeed(near: coordinate)
        } catch {
            vehiclesSnapshot = []
            vehiclesUpdatedAt = nil
            vehiclesLoadedAt = Date()
            return makeVehicleFeed(near: coordinate)
        }
    }

    func makeVehicleFeed(near coordinate: Coordinate) -> TransitVehicleFeed {
        guard let database else {
            return TransitVehicleFeed(vehicles: [], updatedAt: nil)
        }
        let vehicles = vehiclesSnapshot.compactMap { vehicle -> TransitVehicle? in
            guard coordinate.distance(to: vehicle.coordinate) <= 12_000 else { return nil }
            let trip = vehicle.tripID.flatMap { database.tripsByID[$0] }
            let routeID = vehicle.routeID ?? trip?.routeID
            let route = routeID.flatMap { database.routes[$0] }
            let fallback = vehicle.label ?? routeID ?? "MPK"
            let line = route?.displayName ?? fallback
            let mode = route?.mode ?? "BUS"
            let delay = vehicle.tripID.flatMap {
                realtimeSnapshot?.update(tripID: $0, serviceDate: vehicle.serviceDate ?? "",
                                         stopID: vehicle.currentStopID ?? "",
                                         stopSequence: vehicle.currentStopSequence)?.departureDelay
                    ?? realtimeSnapshot?.update(tripID: $0, serviceDate: vehicle.serviceDate ?? "",
                                                stopID: vehicle.currentStopID ?? "",
                                                stopSequence: vehicle.currentStopSequence)?.arrivalDelay
            }
            guard let routeID else { return nil }
            return TransitVehicle(id: vehicle.id, line: line, mode: mode, routeID: routeID,
                                  tripID: vehicle.tripID, destination: trip?.headsign,
                                  coordinate: vehicle.coordinate, bearing: vehicle.bearing,
                                  updatedAt: vehicle.updatedAt ?? vehiclesUpdatedAt ?? Date(),
                                  delaySeconds: delay, colorHex: route?.colorHex ?? TransitLinePalette.color(for: line))
        }.sorted { coordinate.distance(to: $0.coordinate) < coordinate.distance(to: $1.coordinate) }
        let stops = database.stops.filter {
            database.servedStopIDs.contains($0.id) && coordinate.distance(to: $0.coordinate) <= 30_000
        }.map { Self.publicStop($0, database: database) }
        let closestStop = stops.min { coordinate.distance(to: $0.coordinate) < coordinate.distance(to: $1.coordinate) }
        let nearbyDepartures: [TransitDeparture]
        if let closestStop, coordinate.distance(to: closestStop.coordinate) <= 1_000 {
            nearbyDepartures = Self.departures(database: database, realtime: realtimeSnapshot ?? .empty,
                                               stopID: closestStop.id, after: Date(), limit: 4)
        } else {
            nearbyDepartures = []
        }
        return TransitVehicleFeed(vehicles: Array(vehicles.prefix(200)), updatedAt: vehiclesUpdatedAt,
                                  stops: stops, nearbyStop: closestStop, nearbyDepartures: nearbyDepartures)
    }
}
