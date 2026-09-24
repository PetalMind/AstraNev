import Foundation
import zlib

nonisolated enum TransitRoutingError: LocalizedError {
    case invalidResponse
    case noJourney
    case noParkRide
    case feedUnavailable
    case outsideCoverage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Miasto Łódź zwróciło nieprawidłowe dane komunikacji."
        case .noJourney:
            "Nie znaleziono połączenia MPK dla tej trasy i aktualnej godziny."
        case .noParkRide:
            "Nie udało się znaleźć działającego połączenia z parkingu P+R."
        case .feedUnavailable:
            "Nie udało się pobrać rozkładu jazdy MPK Łódź."
        case .outsideCoverage:
            "Planowanie komunikacji MPK obejmuje Łódź i okolice. Wybierz początek oraz cel bliżej przystanków."
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
                         departingAt: Date = Date()) async throws -> [NavigationRoute] {
        guard !parkRide else { throw TransitRoutingError.noParkRide }
        return try await LodzTransitRepository.shared.calculateRoutes(from: from, to: to,
                                                                      departingAt: departingAt,
                                                                      walkingRoutingEndpoint: walkingRoutingEndpoint)
    }

    func vehiclePositions(near coordinate: Coordinate) async -> TransitVehicleFeed {
        await LodzTransitRepository.shared.vehiclePositions(near: coordinate)
    }

    func departures(at stopID: String, limit: Int = 10) async -> [TransitDeparture] {
        await LodzTransitRepository.shared.departures(at: stopID, limit: limit)
    }

    func alerts(for stopID: String) async -> [String] {
        await LodzTransitRepository.shared.alerts(for: stopID)
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

private actor LodzTransitRepository {
    static let shared = LodzTransitRepository()
    private static let maximumSearchWindow: TimeInterval = 18 * 60 * 60
    private static let maximumAccessWalkTime: TimeInterval = 15 * 60

    private let staticFeedURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/GTFS.zip")!
    private let tripUpdatesURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/trip_updates.bin")!
    private let alertsURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/alerts.bin")!
    private let vehiclePositionsURL = URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/vehicle_positions.bin")!
    private let cacheDirectory: URL = {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("LodzTransit", isDirectory: true)
    }()
    private var database: GTFSDatabase?
    private var databaseWasCached = false
    private var databaseLoadedAt: Date?
    private var databaseLoadTask: Task<LoadedTransitDatabase, Error>?
    private var realtimeSnapshot: GTFSRealtimeSnapshot?
    private var realtimeLoadedAt: Date?
    private var realtimeLoadTask: Task<GTFSRealtimeSnapshot, Never>?
    private var vehiclesSnapshot: [GTFSRealtimeVehicle] = []
    private var vehiclesUpdatedAt: Date?
    private var vehiclesLoadedAt: Date?

    func calculateRoutes(from: Coordinate, to: Coordinate, departingAt: Date,
                         walkingRoutingEndpoint: URL) async throws -> [NavigationRoute] {
        let database = try await loadDatabase()
        let realtime = await loadRealtime()
        guard walkingRoutingEndpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        let boardingStops = database.stops.filter { database.servedStopIDs.contains($0.id) }
        let originWalks = await walkingOptions(from: from, stops: boardingStops,
                                               endpoint: walkingRoutingEndpoint)
        let destinationWalks = await walkingOptions(from: to, stops: boardingStops,
                                                    endpoint: walkingRoutingEndpoint)
        let planned = try Self.plan(database: database, realtime: realtime, from: from, to: to,
                                    departingAt: departingAt, originWalks: originWalks,
                                    destinationWalks: destinationWalks,
                                    usingCachedSchedule: databaseWasCached)
        return await resolveTransferWalks(in: planned, endpoint: walkingRoutingEndpoint)
    }

    private func walkingOptions(from coordinate: Coordinate, stops: [GTFSStop],
                                endpoint: URL) async -> [TransitWalkOption] {
        let candidates = Self.nearestStops(to: coordinate, in: stops, maximumDistance: 3_000, limit: 16)
        return await withTaskGroup(of: TransitWalkOption?.self, returning: [TransitWalkOption].self) { group in
            for (stop, distance) in candidates {
                group.addTask {
                    if distance <= 15 {
                        return TransitWalkOption(stop: stop, distance: distance, duration: 0,
                                                 coordinates: [coordinate, stop.coordinate])
                    }
                    let provider = ValhallaRouteProvider(endpoint: endpoint)
                    guard let route = try? await provider.calculateRoutes(from: coordinate, to: stop.coordinate,
                                                                          mode: .walking).first,
                          route.expectedTravelTime <= Self.maximumAccessWalkTime else { return nil }
                    return TransitWalkOption(stop: stop, distance: route.distance,
                                             duration: route.expectedTravelTime,
                                             coordinates: route.coordinates)
                }
            }
            var results: [TransitWalkOption] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results.sorted { $0.duration < $1.duration }
        }
    }

    private func resolveTransferWalks(in routes: [NavigationRoute], endpoint: URL) async -> [NavigationRoute] {
        await withTaskGroup(of: NavigationRoute?.self, returning: [NavigationRoute].self) { group in
            for route in routes {
                group.addTask {
                    guard var journey = route.journey else { return nil }
                    var resolved = route
                    var changed = false
                    let provider = ValhallaRouteProvider(endpoint: endpoint)
                    for index in journey.legs.indices where journey.legs[index].isTransfer {
                        let leg = journey.legs[index]
                        let transferDeparture = index > 0 && journey.legs[index - 1].isTransfer
                            ? journey.legs[index - 1].arrival : leg.departure
                        guard let from = leg.coordinates.first, let to = leg.coordinates.last,
                              let walkingRoute = try? await provider.calculateRoutes(from: from, to: to,
                                                                                     mode: .walking).first else {
                            return nil
                        }
                        let nextRide = journey.legs.suffix(from: index + 1).first(where: { $0.mode != "WALK" })
                        journey.legs[index].coordinates = walkingRoute.coordinates
                        journey.legs[index].departure = transferDeparture
                        journey.legs[index].arrival = transferDeparture
                            .addingTimeInterval(walkingRoute.expectedTravelTime + leg.minimumTransferTime)
                        if nextRide == nil,
                           journey.legs.indices.contains(index + 1),
                           journey.legs[index + 1].mode == "WALK" {
                            let egressDuration = journey.legs[index + 1].arrival.timeIntervalSince(
                                journey.legs[index + 1].departure)
                            journey.legs[index + 1].departure = journey.legs[index].arrival
                            journey.legs[index + 1].arrival = journey.legs[index].arrival
                                .addingTimeInterval(egressDuration)
                            journey.arrival = journey.legs[index + 1].arrival
                        } else if nextRide == nil {
                            journey.arrival = journey.legs[index].arrival
                        }
                        changed = true
                    }
                    guard changed else { return resolved }
                    for nextRideIndex in journey.legs.indices where journey.legs[nextRideIndex].mode != "WALK" {
                        let previousRideIndex = journey.legs[..<nextRideIndex].lastIndex(where: { $0.mode != "WALK" })
                        let transferStartIndex = (previousRideIndex.map { $0 + 1 } ?? 0)..<nextRideIndex
                        let transfers = transferStartIndex.map { journey.legs[$0] }.filter(\.isTransfer)
                        guard !transfers.isEmpty else { continue }
                        let startTime = previousRideIndex.map { journey.legs[$0].arrival }
                            ?? transfers[0].departure
                        let required = transfers.reduce(0.0) {
                            $0 + $1.arrival.timeIntervalSince($1.departure)
                        }
                        guard required <= journey.legs[nextRideIndex].departure.timeIntervalSince(startTime) else {
                            return nil
                        }
                    }
                    resolved.journey = journey
                    resolved.expectedTravelTime = journey.arrival.timeIntervalSince(journey.departure)
                    resolved.coordinates = journey.legs.flatMap { leg in
                        leg.coordinates.isEmpty ? [] : Array(leg.coordinates.dropFirst(leg.coordinates.isEmpty ? 0 : 1))
                    }
                    if let first = journey.legs.first?.coordinates.first {
                        resolved.coordinates.insert(first, at: 0)
                    }
                    resolved.distance = zip(resolved.coordinates, resolved.coordinates.dropFirst())
                        .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
                    return resolved
                }
            }
            var resolved: [NavigationRoute] = []
            for await route in group {
                if let route { resolved.append(route) }
            }
            let ranked = resolved.sorted { Self.generalizedCost($0) < Self.generalizedCost($1) }
            let fastest = ranked.min { $0.expectedTravelTime < $1.expectedTravelTime }
            let fewestTransfers = ranked.min {
                ($0.journey?.transferCount ?? Int.max, $0.expectedTravelTime)
                    < ($1.journey?.transferCount ?? Int.max, $1.expectedTravelTime)
            }
            let leastWalking = ranked.min {
                ($0.journey?.walkingDuration ?? .infinity, $0.expectedTravelTime)
                    < ($1.journey?.walkingDuration ?? .infinity, $1.expectedTravelTime)
            }
            var selected: [NavigationRoute] = []
            for candidate in [ranked.first, fastest, fewestTransfers, leastWalking].compactMap({ $0 }) {
                guard !selected.contains(where: { Self.transitSignature($0) == Self.transitSignature(candidate) }) else { continue }
                selected.append(candidate)
                if selected.count == 3 { break }
            }
            return selected.sorted { Self.generalizedCost($0) < Self.generalizedCost($1) }
        }
    }

    func departures(at stopID: String, limit: Int) async -> [TransitDeparture] {
        guard let database = try? await loadDatabase() else { return [] }
        let realtime = await loadRealtime()
        return Self.departures(database: database, realtime: realtime, stopID: stopID,
                               after: Date(), limit: limit)
    }

    func alerts(for stopID: String) async -> [String] {
        guard let database = try? await loadDatabase() else { return [] }
        let realtime = await loadRealtime()
        let routeIDs = database.routeIDsByStop[stopID] ?? []
        return Array(realtime.alerts.filter {
            $0.isActive(at: Date()) && (($0.routeIDs.isEmpty && $0.stopIDs.isEmpty)
                || $0.stopIDs.contains(stopID) || !$0.routeIDs.isDisjoint(with: routeIDs))
        }.map(\.message).filter { !$0.isEmpty }.prefix(3))
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
        let vehicle = vehiclesSnapshot.first {
            $0.tripID == departure.tripID && ($0.serviceDate == nil || $0.serviceDate == departure.serviceDate)
        }
        return makeTripDetails(database: database, realtime: realtime, trip: trip, route: route,
                               serviceDate: departure.serviceDate, startSequence: departure.stopSequence,
                               rawVehicle: vehicle)
    }

    func tripDetails(tripID: String, serviceDate: String,
                     fromStopSequence: Int) async -> TransitTripDetails? {
        guard let database = try? await loadDatabase(),
              let trip = database.tripsByID[tripID],
              let route = database.routes[trip.routeID] else { return nil }
        let realtime = await loadRealtime()
        let vehicle = vehiclesSnapshot.first {
            $0.tripID == tripID && ($0.serviceDate == nil || $0.serviceDate == serviceDate)
        }
        return makeTripDetails(database: database, realtime: realtime, trip: trip, route: route,
                               serviceDate: serviceDate, startSequence: fromStopSequence,
                               rawVehicle: vehicle)
    }

    private func makeTripDetails(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
                                 trip: GTFSTrip, route: GTFSRoute, serviceDate: String,
                                 startSequence: Int?, rawVehicle: GTFSRealtimeVehicle?) -> TransitTripDetails? {
        guard let start = GTFSDate.date(from: serviceDate) else { return nil }
        var previousDelay: Int?
        let predicted = trip.stopTimes.compactMap { stop -> TransitJourneyStop? in
            guard let definition = database.stopByID[stop.stopID] else { return nil }
            let scheduledArrival = start.addingTimeInterval(TimeInterval(stop.arrivalSeconds))
            let scheduledDeparture = start.addingTimeInterval(TimeInterval(stop.departureSeconds))
            let update = realtime.update(tripID: trip.id, serviceDate: serviceDate,
                                         stopID: stop.stopID, stopSequence: stop.sequence)
            let arrivalDelay = update?.arrivalDelay
                ?? update?.arrivalTime.map { Int($0.timeIntervalSince(scheduledArrival).rounded()) }
            let departureDelay = update?.departureDelay
                ?? update?.departureTime.map { Int($0.timeIntervalSince(scheduledDeparture).rounded()) }
            if let delay = departureDelay ?? arrivalDelay { previousDelay = delay }
            return TransitJourneyStop(id: "\(trip.id)-\(stop.sequence)",
                                      stopID: stop.stopID, name: definition.name,
                                      coordinate: definition.coordinate,
                                      arrival: update?.arrivalTime ?? scheduledArrival.addingTimeInterval(TimeInterval(arrivalDelay ?? previousDelay ?? 0)),
                                      departure: update?.departureTime ?? scheduledDeparture.addingTimeInterval(TimeInterval(departureDelay ?? previousDelay ?? 0)),
                                      delaySeconds: departureDelay ?? arrivalDelay ?? previousDelay,
                                      hasRealtime: update != nil || previousDelay != nil,
                                      sequence: stop.sequence)
        }
        let vehicleSequence = rawVehicle?.currentStopSequence
            ?? rawVehicle?.currentStopID.flatMap { stopID in
                trip.stopTimes.first(where: { $0.stopID == stopID })?.sequence
            }
        let currentStopIdentifier = (vehicleSequence ?? startSequence).map { sequence in
            "\(trip.id)-\(sequence)"
        }
        let currentIndex = currentStopIdentifier.flatMap { identifier in
            predicted.firstIndex(where: { stop in stop.id == identifier })
        } ?? 0
        let current = predicted.indices.contains(currentIndex) ? predicted[currentIndex].name : nil
        let currentStopID = predicted.indices.contains(currentIndex) ? predicted[currentIndex].stopID : nil
        let pastStops = Array(predicted.prefix(currentIndex).suffix(8))
        let nextStops = Array(predicted.dropFirst(min(currentIndex + 1, predicted.count)))
        let stopIDs = Set(trip.stopTimes.dropFirst(min(currentIndex, trip.stopTimes.count)).map(\.stopID))
        let alert = realtime.alerts.first {
            $0.isActive(at: Date()) && (($0.routeIDs.isEmpty && $0.stopIDs.isEmpty)
                || $0.routeIDs.contains(route.id) || !$0.stopIDs.isDisjoint(with: stopIDs))
        }?.message
        let vehicle: TransitVehicle? = rawVehicle.map { raw in
            TransitVehicle(id: raw.id, line: route.displayName, mode: route.mode,
                           routeID: route.id, tripID: trip.id, destination: trip.headsign,
                           coordinate: raw.coordinate, bearing: raw.bearing,
                           updatedAt: raw.updatedAt ?? Date(), delaySeconds: startSequence.flatMap { sequence in
                               realtime.update(tripID: trip.id, serviceDate: serviceDate,
                                               stopID: raw.currentStopID ?? "", stopSequence: sequence)?.departureDelay
                           }, colorHex: route.colorHex)
        }
        let coordinates = database.shapes[trip.shapeID].flatMap { $0.count > 1 ? $0 : nil }
            ?? trip.stopTimes.compactMap { database.stopByID[$0.stopID]?.coordinate }
        return TransitTripDetails(tripID: trip.id, line: route.displayName, mode: route.mode,
                                  destination: trip.headsign, currentStopName: current, currentStopID: currentStopID,
                                  pastStops: pastStops, nextStops: nextStops, vehicle: vehicle,
                                  activeAlert: alert, colorHex: route.colorHex, coordinates: coordinates)
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

    private func makeVehicleFeed(near coordinate: Coordinate) -> TransitVehicleFeed {
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

    private func loadDatabase() async throws -> GTFSDatabase {
        if let database, let databaseLoadedAt,
           Date().timeIntervalSince(databaseLoadedAt) < 86_400 {
            return database
        }
        database = nil
        let loadTask: Task<LoadedTransitDatabase, Error>
        if let databaseLoadTask {
            loadTask = databaseLoadTask
        } else {
            let directory = cacheDirectory
            let feedURL = staticFeedURL
            loadTask = Task.detached(priority: .utility) {
                try await TransitGTFSLoader.load(cacheDirectory: directory, feedURL: feedURL)
            }
            databaseLoadTask = loadTask
        }
        do {
            let loaded = try await loadTask.value
            database = loaded.database
            databaseWasCached = loaded.wasCached
            databaseLoadedAt = Date()
            databaseLoadTask = nil
            return loaded.database
        } catch {
            databaseLoadTask = nil
            throw error
        }
    }

    private func loadRealtime() async -> GTFSRealtimeSnapshot {
        if let realtimeSnapshot, let realtimeLoadedAt,
           Date().timeIntervalSince(realtimeLoadedAt) < 15 {
            return realtimeSnapshot
        }
        let loadTask: Task<GTFSRealtimeSnapshot, Never>
        if let realtimeLoadTask {
            loadTask = realtimeLoadTask
        } else {
            let updatesURL = tripUpdatesURL
            let alertsURL = alertsURL
            loadTask = Task {
                async let updates = try? Self.download(updatesURL)
                async let alerts = try? Self.download(alertsURL)
                let (updatesData, alertsData) = await (updates, alerts)
                let receivedAt = Date()
                let parsedUpdates = updatesData.flatMap { try? GTFSRealtimeSnapshot.tripUpdates(from: $0) }
                let parsedAlerts = alertsData.flatMap { try? GTFSRealtimeSnapshot.alerts(from: $0) }
                let freshness = self.realtimeFreshness(parsedUpdates?.updatedAt, relativeTo: receivedAt)
                let updatesAreFresh = freshness == .live || freshness == .degraded
                let alertsAreFresh = self.isFresh(parsedAlerts?.updatedAt, relativeTo: receivedAt)
                return GTFSRealtimeSnapshot(
                    updates: updatesAreFresh ? (parsedUpdates?.updates ?? [:]) : [:],
                    canceledTrips: updatesAreFresh ? (parsedUpdates?.canceledTrips ?? []) : [],
                    updatedAt: parsedUpdates?.updatedAt,
                    isAvailable: updatesAreFresh,
                    alertsAvailable: alertsAreFresh,
                    alerts: alertsAreFresh ? (parsedAlerts?.alerts ?? []) : [],
                    freshness: freshness
                )
            }
            realtimeLoadTask = loadTask
        }
        let snapshot = await loadTask.value
        realtimeSnapshot = snapshot
        realtimeLoadedAt = Date()
        realtimeLoadTask = nil
        return snapshot
    }

    private func isFresh(_ updatedAt: Date?, relativeTo now: Date) -> Bool {
        guard let updatedAt else { return false }
        return (-60...180).contains(now.timeIntervalSince(updatedAt))
    }

    private func realtimeFreshness(_ updatedAt: Date?, relativeTo now: Date) -> TransitRealtimeFreshness {
        guard let updatedAt else { return .unavailable }
        let age = now.timeIntervalSince(updatedAt)
        guard (-60...180).contains(age) else { return .stale }
        return age <= 90 ? .live : .degraded
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode), !data.isEmpty else {
            throw TransitRoutingError.invalidResponse
        }
        return data
    }

    private static func plan(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
                             from origin: Coordinate, to destination: Coordinate,
                             departingAt: Date, originWalks: [TransitWalkOption],
                             destinationWalks: [TransitWalkOption],
                             usingCachedSchedule: Bool) throws -> [NavigationRoute] {
        guard !originWalks.isEmpty, !destinationWalks.isEmpty else {
            throw TransitRoutingError.outsideCoverage
        }

        let instances = activeTripInstances(database: database, realtime: realtime, after: departingAt)
        guard !instances.isEmpty else { throw TransitRoutingError.noJourney }
        var departuresByStop: [String: [TransitBoardingDeparture]] = [:]
        for (instanceIndex, instance) in instances.enumerated() {
            for stopIndex in instance.times.indices {
                departuresByStop[instance.times[stopIndex].stopID, default: []]
                    .append(TransitBoardingDeparture(instanceIndex: instanceIndex, stopIndex: stopIndex,
                                                     time: instance.times[stopIndex].departure))
            }
        }
        for stopID in Array(departuresByStop.keys) {
            departuresByStop[stopID]?.sort { $0.time < $1.time }
        }

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
        for ridesUsed in 1...4 {
            guard let previous = layers.last else { break }
            let boardingLabels = transferClosure(previous, database: database)
            var current: [String: [TransitPathLabel]] = [:]
            for (stopID, labels) in boardingLabels {
                guard let departures = departuresByStop[stopID] else { continue }
                for label in labels {
                    let transferBuffer = label.rideCount > 0 && !label.lastLegWasTransfer ? 60.0 : 0
                    let minimumDeparture = label.arrival.addingTimeInterval(transferBuffer)
                    let startIndex = lowerBound(in: departures, for: minimumDeparture)
                    for departure in departures[startIndex...] {
                        if departure.time > departingAt.addingTimeInterval(maximumSearchWindow) { break }
                        let instance = instances[departure.instanceIndex]
                        for downstreamIndex in (departure.stopIndex + 1)..<instance.times.count {
                            let downstream = instance.times[downstreamIndex]
                            let ride = TransitRide(instanceIndex: departure.instanceIndex,
                                                   boardIndex: departure.stopIndex,
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
            layers.append(current)
            let alightingLabels = transferClosure(current, database: database)
            for (stopID, labels) in alightingLabels where stopByID[stopID] != nil {
                for label in labels {
                    for access in destinationWalks where access.stop.id == stopID {
                        candidates.append(TransitPlanCandidate(
                            label: label, destinationWalk: access,
                            arrival: label.arrival.addingTimeInterval(access.duration)))
                    }
                }
            }
            if current.isEmpty { break }
        }

        let rankedCandidates = candidates.sorted {
            candidateCost($0, departingAt: departingAt) < candidateCost($1, departingAt: departingAt)
        }
        var routes: [NavigationRoute] = []
        for candidate in rankedCandidates {
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
        guard !unique.isEmpty else { throw TransitRoutingError.noJourney }

        let fastest = unique.min { $0.expectedTravelTime < $1.expectedTravelTime }
        let fewestTransfers = unique.min {
            ($0.journey?.transferCount ?? Int.max, $0.expectedTravelTime)
                < ($1.journey?.transferCount ?? Int.max, $1.expectedTravelTime)
        }
        let leastWalking = unique.min {
            ($0.journey?.walkingDuration ?? .infinity, $0.expectedTravelTime)
                < ($1.journey?.walkingDuration ?? .infinity, $1.expectedTravelTime)
        }
        var selected: [NavigationRoute] = []
        for candidate in [unique.first, fastest, fewestTransfers, leastWalking].compactMap({ $0 }) + unique {
            guard !selected.contains(where: { transitSignature($0) == transitSignature(candidate) }) else { continue }
            selected.append(candidate)
            if selected.count == 8 { break }
        }
        return selected
    }

    @discardableResult
    private static func insertPareto(_ candidate: TransitPathLabel, at stopID: String,
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

    private static func transferClosure(_ labels: [String: [TransitPathLabel]],
                                        database: GTFSDatabase) -> [String: [TransitPathLabel]] {
        var reachable = labels
        var queue = labels.values.flatMap { $0 }
        var cursor = 0
        while cursor < queue.count {
            let label = queue[cursor]
            cursor += 1
            guard label.transferDepth < 3, label.walkingSeconds < 1_800 else { continue }
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

    private static func candidateCost(_ candidate: TransitPlanCandidate, departingAt: Date) -> Double {
        let rideSeconds = pathRideSeconds(candidate.label)
        let walking = candidate.label.walkingSeconds + candidate.destinationWalk.duration
        let total = candidate.arrival.timeIntervalSince(departingAt)
        let waiting = max(0, total - rideSeconds - walking)
        return rideSeconds + walking * 1.6 + waiting * 1.25
            + Double(candidate.label.transferCount) * 240
    }

    private static func generalizedCost(_ route: NavigationRoute) -> Double {
        guard let journey = route.journey else { return route.expectedTravelTime }
        let rideSeconds = journey.legs.filter { $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        return rideSeconds + journey.walkingDuration * 1.6 + journey.waitingDuration * 1.25
            + Double(journey.transferCount) * 240
    }

    private static func pathRideSeconds(_ label: TransitPathLabel) -> Double {
        var total = 0.0
        var current: TransitPathLabel? = label
        while let node = current {
            if node.ride != nil, let parent = node.parent {
                total += node.arrival.timeIntervalSince(parent.arrival)
            }
            current = node.parent
        }
        return max(0, total)
    }

    private static func transitSignature(_ route: NavigationRoute) -> String {
        route.journey?.legs.filter { $0.mode != "WALK" }
            .map { "\($0.tripID ?? $0.line ?? ""):\($0.from):\($0.to):\($0.departure.timeIntervalSince1970.rounded())" }
            .joined(separator: "|") ?? ""
    }

    private static func nearestStops(to coordinate: Coordinate, in stops: [GTFSStop],
                                     maximumDistance: Double, limit: Int) -> [(GTFSStop, Double)] {
        stops.compactMap { stop -> (GTFSStop, Double)? in
            let distance = coordinate.distance(to: stop.coordinate)
            return distance <= maximumDistance ? (stop, distance) : nil
        }.sorted { $0.1 < $1.1 }.prefix(limit).map { $0 }
    }

    private static func publicStop(_ stop: GTFSStop, database: GTFSDatabase) -> TransitStop {
        let routes = database.routeIDsByStop[stop.id] ?? []
        let lineNames = routes.compactMap { database.routes[$0]?.displayName }
        return TransitStop(id: stop.id, name: stop.name, address: stop.address,
                           coordinate: stop.coordinate,
                           isMajor: stop.parentStation?.isEmpty == false || stop.locationType == 1
                               || Set(lineNames).count >= 4,
                           lineIDs: Array(routes).sorted(), lines: Array(Set(lineNames)).sorted())
    }

    private static func departures(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
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
                                           line: instance.route.displayName, mode: instance.route.mode,
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

    private static func lowerBound(in departures: [TransitBoardingDeparture], for time: Date) -> Int {
        var lower = 0
        var upper = departures.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if departures[middle].time < time { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private static func activeTripInstances(database: GTFSDatabase, realtime: GTFSRealtimeSnapshot,
                                            after departure: Date,
                                            onlyStopIDs: Set<String>? = nil) -> [GTFSTripInstance] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let today = calendar.startOfDay(for: departure)
        let finalServiceDay = calendar.startOfDay(for: departure.addingTimeInterval(maximumSearchWindow))
        var serviceDates: [Date] = []
        for offset in -1...(finalServiceDay > today ? 1 : 0) {
            if let date = calendar.date(byAdding: .day, value: offset, to: today) { serviceDates.append(date) }
        }

        let trips: [GTFSTrip]
        if let onlyStopIDs {
            let tripIDs = Set(onlyStopIDs.flatMap { database.tripIDsByStop[$0] ?? [] })
            trips = tripIDs.compactMap { database.tripsByID[$0] }
        } else {
            trips = database.trips
        }
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
                        < departure.addingTimeInterval(maximumSearchWindow),
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
                      first.departure < departure.addingTimeInterval(maximumSearchWindow) else { continue }
                instances.append(GTFSTripInstance(trip: trip, route: route, serviceDate: dateString,
                                                  times: times, patternKey: trip.patternKey))
            }
        }
        return instances
    }

    private static func serviceIsActive(_ serviceID: String, on date: String, weekday: String,
                                        database: GTFSDatabase) -> Bool {
        if let exception = database.exceptions[serviceID]?[date] { return exception == 1 }
        guard let calendar = database.calendars[serviceID] else { return false }
        return date >= calendar.startDate && date <= calendar.endDate && calendar.weekdayFlags[weekday] == true
    }

    private static func makeRoute(
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
        if origin.distance(to: firstStop.coordinate) > 15 {
            legs.append(JourneyLeg(mode: "WALK", from: "Punkt początkowy", to: firstStop.name,
                                    departure: departingAt, arrival: departingAt.addingTimeInterval(originWalk.duration),
                                    realTime: false, coordinates: originWalk.coordinates))
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
                                       minimumTransferTime: transfer.minimumTransferTime))
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
            legs.append(JourneyLeg(mode: instance.route.mode, line: instance.route.displayName,
                                   from: board.name, to: alight.name,
                                   departure: boardTime.departure, arrival: alightTime.arrival,
                                   realTime: boardTime.hasRealtime || alightTime.hasRealtime,
                                   delaySeconds: boardTime.delaySeconds ?? alightTime.delaySeconds,
                                   coordinates: coordinates, routeID: instance.route.id,
                                   tripID: instance.trip.id, serviceDate: instance.serviceDate,
                                   lineColorHex: instance.route.colorHex,
                                   transitStops: transitStops))
        }
        if candidate.destinationWalk.stop.coordinate.distance(to: destination) > 15 {
            legs.append(JourneyLeg(mode: "WALK", from: candidate.destinationWalk.stop.name, to: "Cel",
                                   departure: candidate.label.arrival,
                                   arrival: candidate.arrival, realTime: false,
                                   coordinates: candidate.destinationWalk.coordinates))
        }

        var coordinates: [Coordinate] = []
        for leg in legs {
            if coordinates.isEmpty { coordinates.append(contentsOf: leg.coordinates) }
            else { coordinates.append(contentsOf: leg.coordinates.dropFirst()) }
        }
        guard coordinates.count > 1 else { return nil }
        let alerts = realtime.alerts.filter { alert in
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
        let journey = Journey(departure: departingAt, arrival: candidate.arrival, legs: legs,
                              scheduleIsCached: usingCachedSchedule,
                              realtimeFeedAvailable: realtime.isAvailable,
                              realtimeFeedUpdatedAt: realtime.updatedAt,
                              alertsFeedAvailable: realtime.alertsAvailable,
                              alerts: Array(alerts), walkingDuration: walkingDuration,
                              waitingDuration: waitingDuration,
                              transferCount: candidate.label.transferCount,
                              realtimeFreshness: realtime.freshness)
        let distance = zip(coordinates, coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        return NavigationRoute(coordinates: coordinates, distance: distance,
                               expectedTravelTime: candidate.arrival.timeIntervalSince(departingAt),
                               maneuvers: [], journey: journey)
    }

    private static func shapeCoordinates(for trip: GTFSTrip, from start: Int, to end: Int,
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

private nonisolated struct GTFSStopPrediction {
    let stopID: String
    let arrival: Date
    let departure: Date
    let delaySeconds: Int?
    let hasRealtime: Bool
}

private nonisolated struct GTFSTripInstance {
    let trip: GTFSTrip
    let route: GTFSRoute
    let serviceDate: String
    let times: [GTFSStopPrediction]
    let patternKey: String
}

private nonisolated struct TransitBoardingDeparture {
    let instanceIndex: Int
    let stopIndex: Int
    let time: Date
}

private nonisolated struct TransitWalkOption: Sendable {
    let stop: GTFSStop
    let distance: Double
    let duration: TimeInterval
    let coordinates: [Coordinate]
}

private nonisolated struct TransitFootpath: Sendable {
    let fromStopID: String
    let toStopID: String
    let walkingDistance: Double
    let walkingDuration: TimeInterval
    let minimumTransferTime: TimeInterval
    let coordinates: [Coordinate]
}

private nonisolated struct TransitPlanCandidate {
    let label: TransitPathLabel
    let destinationWalk: TransitWalkOption
    let arrival: Date
}

private nonisolated struct TransitRide {
    let instanceIndex: Int
    let boardIndex: Int
    let alightIndex: Int
}

private nonisolated final class TransitPathLabel {
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

private nonisolated struct GTFSStop: Sendable {
    let id: String
    let name: String
    let address: String?
    let parentStation: String?
    let locationType: Int
    let coordinate: Coordinate
}

private nonisolated struct GTFSRoute: Sendable {
    let id: String
    let shortName: String
    let longName: String
    let type: Int
    let colorHex: UInt32
    var displayName: String { shortName.isEmpty ? (longName.isEmpty ? "MPK" : longName) : shortName }
    var mode: String { type == 0 ? "TRAM" : type == 2 ? "RAIL" : "BUS" }
}

private nonisolated struct GTFSTrip: Sendable {
    let id: String
    let routeID: String
    let serviceID: String
    let directionID: String
    let headsign: String
    let shapeID: String
    let stopTimes: [GTFSTripStop]
    var patternKey: String { routeID + ":" + directionID + ":" + stopTimes.map(\.stopID).joined(separator: ",") }
}

private nonisolated struct GTFSTripStop: Sendable {
    let stopID: String
    let sequence: Int
    let arrivalSeconds: Int
    let departureSeconds: Int
    let shapeDistance: Double?
}

private nonisolated struct GTFSCalendar: Sendable {
    let startDate: String
    let endDate: String
    let weekdayFlags: [String: Bool]
}

private nonisolated struct GTFSDatabase: Sendable {
    let stops: [GTFSStop]
    let routes: [String: GTFSRoute]
    let trips: [GTFSTrip]
    let calendars: [String: GTFSCalendar]
    let exceptions: [String: [String: Int]]
    let shapes: [String: [Coordinate]]
    let servedStopIDs: Set<String>
    let stopsForSearch: [GTFSStop]
    let normalizedStopNames: [String: String]
    let normalizedRouteNames: [String: String]
    let lineDirections: [String: String]
    let stopByID: [String: GTFSStop]
    let tripsByID: [String: GTFSTrip]
    let tripIDsByStop: [String: [String]]
    let routeIDsByStop: [String: Set<String>]
    let footpathsByStopID: [String: [TransitFootpath]]

    init(data: Data) throws {
        let files = try GTFSZipArchive.extract(data)
        let stopRows = try GTFSCSV.rows(named: "stops.txt", in: files)
        var parsedStops: [GTFSStop] = []
        for row in stopRows {
            guard let id = row["stop_id"], let name = row["stop_name"],
                  let latitudeText = row["stop_lat"], let latitude = Double(latitudeText),
                  let longitudeText = row["stop_lon"], let longitude = Double(longitudeText),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { continue }
            parsedStops.append(GTFSStop(id: id, name: name, address: row["stop_desc"],
                                        parentStation: row["parent_station"],
                                        locationType: Int(row["location_type"] ?? "0") ?? 0,
                                        coordinate: Coordinate(latitude: latitude, longitude: longitude)))
        }
        stops = parsedStops
        let routeRows = try GTFSCSV.rows(named: "routes.txt", in: files)
        routes = Dictionary(routeRows.compactMap { row -> (String, GTFSRoute)? in
            guard let id = row["route_id"] else { return nil }
            return (id, GTFSRoute(id: id, shortName: row["route_short_name"] ?? "",
                                  longName: row["route_long_name"] ?? "",
                                  type: Int(row["route_type"] ?? "") ?? 3,
                                  colorHex: Self.parseColor(row["route_color"]) ?? Self.color(for: row["route_short_name"] ?? id)))
        }, uniquingKeysWith: { first, _ in first })
        normalizedRouteNames = Dictionary(routes.values.map { ($0.id, TransitSearchText.normalize($0.displayName)) },
                                          uniquingKeysWith: { first, _ in first })

        var groupedStops: [String: [GTFSTripStop]] = [:]
        for row in try GTFSCSV.rows(named: "stop_times.txt", in: files) {
            guard let tripID = row["trip_id"], let stopID = row["stop_id"],
                  let sequence = Int(row["stop_sequence"] ?? "") else { continue }
            let arrivalText = row["arrival_time"] ?? ""
            let departureText = row["departure_time"] ?? ""
            guard let arrival = GTFSCSV.serviceSeconds(arrivalText) ?? GTFSCSV.serviceSeconds(departureText),
                  let departure = GTFSCSV.serviceSeconds(departureText) ?? GTFSCSV.serviceSeconds(arrivalText) else { continue }
            groupedStops[tripID, default: []].append(GTFSTripStop(
                stopID: stopID, sequence: sequence, arrivalSeconds: arrival, departureSeconds: departure,
                shapeDistance: row["shape_dist_traveled"].flatMap(Double.init)))
        }
        let tripServedStopIDs = Set(groupedStops.values.flatMap { $0.map(\.stopID) })
        servedStopIDs = tripServedStopIDs
        stopsForSearch = parsedStops.filter { tripServedStopIDs.contains($0.id) }

        var footpaths: [String: [TransitFootpath]] = [:]
        func addFootpath(from: GTFSStop, to: GTFSStop, distance: Double,
                         walkingDuration: TimeInterval, minimumTransferTime: TimeInterval) {
            guard from.id != to.id else { return }
            let candidate = TransitFootpath(fromStopID: from.id, toStopID: to.id,
                                            walkingDistance: distance,
                                            walkingDuration: walkingDuration,
                                            minimumTransferTime: minimumTransferTime,
                                            coordinates: [from.coordinate, to.coordinate])
            if let existing = footpaths[from.id]?.firstIndex(where: { $0.toStopID == to.id }) {
                let old = footpaths[from.id]![existing]
                if old.walkingDuration + old.minimumTransferTime
                    <= walkingDuration + minimumTransferTime { return }
                footpaths[from.id]![existing] = candidate
            } else {
                footpaths[from.id, default: []].append(candidate)
            }
        }

        for row in try GTFSCSV.rows(named: "transfers.txt", in: files) {
            guard let fromID = row["from_stop_id"], let toID = row["to_stop_id"],
                  let from = parsedStops.first(where: { $0.id == fromID }),
                  let to = parsedStops.first(where: { $0.id == toID }) else { continue }
            let type = Int(row["transfer_type"] ?? "0") ?? 0
            guard type == 0 || type == 1 || type == 2 else { continue }
            let distance = from.coordinate.distance(to: to.coordinate)
            let minimum = type == 2 ? max(0, Double(row["min_transfer_time"] ?? "0") ?? 0) : 0
            let estimatedWalk = max(0, distance / 1.0)
            addFootpath(from: from, to: to, distance: distance,
                        walkingDuration: estimatedWalk, minimumTransferTime: minimum)
        }
        for row in try GTFSCSV.rows(named: "pathways.txt", in: files) {
            guard let fromID = row["from_stop_id"], let toID = row["to_stop_id"],
                  let from = parsedStops.first(where: { $0.id == fromID }),
                  let to = parsedStops.first(where: { $0.id == toID }) else { continue }
            let distance = max(0, Double(row["length"] ?? "0") ?? 0)
            let duration = max(0, Double(row["traversal_time"] ?? "0") ?? 0)
            guard duration > 0 || distance > 0 else { continue }
            let effectiveDuration = duration > 0 ? duration : distance / 0.8
            addFootpath(from: from, to: to, distance: distance,
                        walkingDuration: effectiveDuration, minimumTransferTime: 0)
            if row["is_bidirectional"] == "1" {
                addFootpath(from: to, to: from, distance: distance,
                            walkingDuration: effectiveDuration, minimumTransferTime: 0)
            }
        }

        let servedStops = parsedStops.filter { tripServedStopIDs.contains($0.id) }
        let stationGroups = Dictionary(grouping: servedStops.compactMap { stop -> (String, GTFSStop)? in
            guard let parent = stop.parentStation, !parent.isEmpty else { return nil }
            return (parent, stop)
        }, by: { $0.0 })
        for members in stationGroups.values {
            let stopsInStation = members.map(\.1)
            for firstIndex in stopsInStation.indices {
                for secondIndex in stopsInStation.indices where secondIndex != firstIndex {
                    let first = stopsInStation[firstIndex]
                    let second = stopsInStation[secondIndex]
                    let distance = first.coordinate.distance(to: second.coordinate)
                    guard distance <= 500 else { continue }
                    addFootpath(from: first, to: second, distance: distance,
                                walkingDuration: max(45, distance / 0.9),
                                minimumTransferTime: 30)
                }
            }
        }

        let latitudeSorted = servedStops.sorted { $0.coordinate.latitude < $1.coordinate.latitude }
        for firstIndex in latitudeSorted.indices {
            let first = latitudeSorted[firstIndex]
            for secondIndex in latitudeSorted.indices.dropFirst(firstIndex + 1) {
                let second = latitudeSorted[secondIndex]
                if (second.coordinate.latitude - first.coordinate.latitude) * 110_574 > 400 { break }
                let distance = first.coordinate.distance(to: second.coordinate)
                guard distance > 0, distance <= 350 else { continue }
                let sameStation = first.parentStation?.isEmpty == false
                    && first.parentStation == second.parentStation
                guard !sameStation else { continue }
                let detourAdjustedDistance = distance * 1.5
                addFootpath(from: first, to: second, distance: detourAdjustedDistance,
                            walkingDuration: detourAdjustedDistance / 1.0,
                            minimumTransferTime: 60)
                addFootpath(from: second, to: first, distance: detourAdjustedDistance,
                            walkingDuration: detourAdjustedDistance / 1.0,
                            minimumTransferTime: 60)
            }
        }
        footpathsByStopID = footpaths
        normalizedStopNames = Dictionary(parsedStops.map { ($0.id, TransitSearchText.normalize($0.name)) },
                                         uniquingKeysWith: { first, _ in first })
        for id in groupedStops.keys {
            groupedStops[id]?.sort { $0.sequence < $1.sequence }
        }
        trips = try GTFSCSV.rows(named: "trips.txt", in: files).compactMap { row in
            guard let id = row["trip_id"], let routeID = row["route_id"], let serviceID = row["service_id"],
                  let stops = groupedStops[id], stops.count > 1 else { return nil }
            return GTFSTrip(id: id, routeID: routeID, serviceID: serviceID,
                            directionID: row["direction_id"] ?? "",
                            headsign: row["trip_headsign"] ?? "", shapeID: row["shape_id"] ?? "",
                            stopTimes: stops)
        }
        var headsignsByRoute: [String: Set<String>] = [:]
        for trip in trips where !trip.headsign.isEmpty {
            headsignsByRoute[trip.routeID, default: []].insert(trip.headsign)
        }
        lineDirections = headsignsByRoute.mapValues { values in
            values.sorted().prefix(2).joined(separator: " ↔ ")
        }
        stopByID = Dictionary(parsedStops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tripsByID = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tripIDsByStop = groupedStops.reduce(into: [String: [String]]()) { result, entry in
            for stop in entry.value { result[stop.stopID, default: []].append(entry.key) }
        }
        var routesByStop: [String: Set<String>] = [:]
        for trip in trips {
            for stop in trip.stopTimes { routesByStop[stop.stopID, default: []].insert(trip.routeID) }
        }
        routeIDsByStop = routesByStop

        calendars = Dictionary(try GTFSCSV.rows(named: "calendar.txt", in: files).compactMap { row in
            guard let id = row["service_id"], let start = row["start_date"], let end = row["end_date"] else { return nil }
            let flags = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
                .reduce(into: [String: Bool]()) { $0[$1] = row[$1] == "1" }
            return (id, GTFSCalendar(startDate: start, endDate: end, weekdayFlags: flags))
        }, uniquingKeysWith: { first, _ in first })

        var serviceExceptions: [String: [String: Int]] = [:]
        for row in try GTFSCSV.rows(named: "calendar_dates.txt", in: files) {
            guard let id = row["service_id"], let date = row["date"],
                  let type = Int(row["exception_type"] ?? "") else { continue }
            serviceExceptions[id, default: [:]][date] = type
        }
        exceptions = serviceExceptions

        var shapeRows: [String: [(Int, Coordinate)]] = [:]
        for row in try GTFSCSV.rows(named: "shapes.txt", in: files) {
            guard let id = row["shape_id"], let sequence = Int(row["shape_pt_sequence"] ?? ""),
                  let latitude = row["shape_pt_lat"].flatMap(Double.init),
                  let longitude = row["shape_pt_lon"].flatMap(Double.init) else { continue }
            shapeRows[id, default: []].append((sequence, Coordinate(latitude: latitude, longitude: longitude)))
        }
        shapes = shapeRows.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
        guard !stops.isEmpty, !trips.isEmpty else { throw TransitRoutingError.invalidResponse }
    }

    private static func parseColor(_ value: String?) -> UInt32? {
        guard let value, value.count == 6, let color = UInt32(value, radix: 16) else { return nil }
        return color
    }

    private static func color(for value: String) -> UInt32 {
        TransitLinePalette.color(for: value)
    }
}

private nonisolated enum TransitSearchText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private nonisolated struct LoadedTransitDatabase: Sendable {
    let database: GTFSDatabase
    let wasCached: Bool
}

private nonisolated enum TransitGTFSLoader {
    static func load(cacheDirectory: URL, feedURL: URL) async throws -> LoadedTransitDatabase {
        let archiveURL = cacheDirectory.appendingPathComponent("lodz-gtfs.zip")
        let cachedData = try? Data(contentsOf: archiveURL)
        let isFresh = (try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate).map { Date().timeIntervalSince($0) < 86_400 } ?? false

        if let cachedData, isFresh, let database = try? GTFSDatabase(data: cachedData) {
            return LoadedTransitDatabase(database: database, wasCached: true)
        }

        do {
            let data = try await download(feedURL)
            let database = try GTFSDatabase(data: data)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: archiveURL, options: .atomic)
            return LoadedTransitDatabase(database: database, wasCached: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cachedData, let database = try? GTFSDatabase(data: cachedData) {
                return LoadedTransitDatabase(database: database, wasCached: true)
            }
            throw TransitRoutingError.feedUnavailable
        }
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode), !data.isEmpty else {
            throw TransitRoutingError.invalidResponse
        }
        return data
    }
}

private nonisolated enum TransitLinePalette {
    static func color(for value: String) -> UInt32 {
        let colors: [UInt32] = [0xD8343C, 0x2867B2, 0x189477, 0x8A58A8, 0xE18927, 0x357A9F]
        let hash = value.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

private nonisolated enum GTFSZipArchive {
    static func extract(_ archive: Data) throws -> [String: Data] {
        guard archive.count >= 22 else { throw TransitRoutingError.invalidResponse }
        let searchStart = max(0, archive.count - 65_557)
        var endRecord: Int?
        if archive.count >= 22 {
            for offset in stride(from: archive.count - 22, through: searchStart, by: -1) {
                if littleUInt32(archive, offset) == 0x06054b50 {
                    endRecord = offset
                    break
                }
            }
        }
        guard let endRecord else { throw TransitRoutingError.invalidResponse }
        let entryCount = Int(littleUInt16(archive, endRecord + 10))
        var cursor = Int(littleUInt32(archive, endRecord + 16))
        guard cursor >= 0, cursor < archive.count else { throw TransitRoutingError.invalidResponse }
        var files: [String: Data] = [:]
        for _ in 0..<entryCount {
            guard cursor + 46 <= archive.count, littleUInt32(archive, cursor) == 0x02014b50 else {
                throw TransitRoutingError.invalidResponse
            }
            let method = littleUInt16(archive, cursor + 10)
            let compressedSize = Int(littleUInt32(archive, cursor + 20))
            let uncompressedSize = Int(littleUInt32(archive, cursor + 24))
            let nameLength = Int(littleUInt16(archive, cursor + 28))
            let extraLength = Int(littleUInt16(archive, cursor + 30))
            let commentLength = Int(littleUInt16(archive, cursor + 32))
            let localOffset = Int(littleUInt32(archive, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= archive.count, localOffset + 30 <= archive.count,
                  littleUInt32(archive, localOffset) == 0x04034b50 else {
                throw TransitRoutingError.invalidResponse
            }
            let name = String(decoding: archive[nameStart..<nameEnd], as: UTF8.self)
            let dataStart = localOffset + 30
                + Int(littleUInt16(archive, localOffset + 26))
                + Int(littleUInt16(archive, localOffset + 28))
            let dataEnd = dataStart + compressedSize
            guard dataStart >= 0, dataEnd <= archive.count else { throw TransitRoutingError.invalidResponse }
            if !name.hasSuffix("/") {
                let compressed = Data(archive[dataStart..<dataEnd])
                let payload: Data
                switch method {
                case 0:
                    payload = compressed
                case 8:
                    payload = try inflateRaw(compressed, expectedSize: uncompressedSize)
                default:
                    cursor = nameEnd + extraLength + commentLength
                    continue
                }
                files[name] = payload
            }
            cursor = nameEnd + extraLength + commentLength
        }
        return files
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0, expectedSize <= 150_000_000 else { throw TransitRoutingError.invalidResponse }
        var output = Data(count: max(1, expectedSize))
        let outputCapacity = output.count
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw TransitRoutingError.invalidResponse }
        defer { inflateEnd(&stream) }

        let status = compressed.withUnsafeBytes { sourceBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                stream.next_in = UnsafeMutablePointer(mutating: sourceBuffer.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else {
            throw TransitRoutingError.invalidResponse
        }
        return Data(output.prefix(expectedSize))
    }

    private static func littleUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private nonisolated enum GTFSCSV {
    static func rows(named filename: String, in files: [String: Data]) throws -> [[String: String]] {
        guard let data = files[filename] else {
            if ["calendar.txt", "calendar_dates.txt", "shapes.txt", "transfers.txt", "pathways.txt"].contains(filename) { return [] }
            throw TransitRoutingError.invalidResponse
        }
        var rawRows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var index = 0
        while index < data.count {
            let byte = data[index]
            if byte == 34 {
                if quoted, index + 1 < data.count, data[index + 1] == 34 {
                    field.append(34)
                    index += 2
                    continue
                }
                quoted.toggle()
            } else if byte == 44, !quoted {
                row.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
            } else if (byte == 10 || byte == 13), !quoted {
                if byte == 13, index + 1 < data.count, data[index + 1] == 10 { index += 1 }
                row.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
                if !row.allSatisfy(\.isEmpty) { rawRows.append(row) }
                row.removeAll(keepingCapacity: true)
            } else {
                field.append(byte)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(decoding: field, as: UTF8.self))
            if !row.allSatisfy(\.isEmpty) { rawRows.append(row) }
        }
        guard var header = rawRows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !header.isEmpty else { throw TransitRoutingError.invalidResponse }
        header[0] = header[0].replacingOccurrences(of: "\u{feff}", with: "")
        return rawRows.dropFirst().map { values in
            Dictionary(uniqueKeysWithValues: header.enumerated().map { index, key in
                (key, values.indices.contains(index) ? values[index] : "")
            })
        }
    }

    static func serviceSeconds(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 3, let hours = Int(parts[0]),
              let minutes = Int(parts[1]), let seconds = Int(parts[2]),
              hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}

private nonisolated enum GTFSDate {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Warsaw")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Warsaw")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: value)
    }

    static func weekdayKey(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.weekday, from: date) {
        case 2: "monday"
        case 3: "tuesday"
        case 4: "wednesday"
        case 5: "thursday"
        case 6: "friday"
        case 7: "saturday"
        default: "sunday"
        }
    }
}

private extension Collection {
    nonisolated subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private nonisolated struct GTFSRealtimeSnapshot {
    let updates: [String: [String: [String: GTFSStopTimeUpdate]]]
    let canceledTrips: Set<String>
    let updatedAt: Date?
    let isAvailable: Bool
    let alertsAvailable: Bool
    let alerts: [GTFSAlert]
    let freshness: TransitRealtimeFreshness

    static let empty = GTFSRealtimeSnapshot(updates: [:], canceledTrips: [], updatedAt: nil,
                                             isAvailable: false, alertsAvailable: false, alerts: [],
                                             freshness: .unavailable)

    func update(tripID: String, serviceDate: String, stopID: String,
                stopSequence: Int? = nil) -> GTFSStopTimeUpdate? {
        let datedUpdates = updates[tripID]?[serviceDate]
        if let update = datedUpdates?[stopID] { return update }
        if let stopSequence, let update = datedUpdates?["sequence:\(stopSequence)"] { return update }
        let undatedUpdates = updates[tripID]?[""]
        return undatedUpdates?[stopID]
            ?? stopSequence.flatMap { undatedUpdates?["sequence:\($0)"] }
    }

    func isCanceled(tripID: String, serviceDate: String) -> Bool {
        canceledTrips.contains("\(tripID)|\(serviceDate)") || canceledTrips.contains("\(tripID)|")
    }

    static func tripUpdates(from data: Data) throws -> GTFSRealtimeSnapshot {
        var reader = ProtoReader(data: data)
        var updates: [String: [String: [String: GTFSStopTimeUpdate]]] = [:]
        var canceled: Set<String> = []
        var timestamp: Date?
        while let field = try reader.next() {
            switch (field.number, field.bytes, field.varint) {
            case (1, let bytes?, _):
                timestamp = try parseHeader(bytes)
            case (2, let bytes?, _):
                guard let entity = try parseTripUpdateEntity(bytes) else { continue }
                let dateKey = entity.serviceDate ?? ""
                if entity.canceled {
                    canceled.insert("\(entity.tripID)|\(dateKey)")
                } else {
                    for (stopID, update) in entity.stopUpdates {
                        updates[entity.tripID, default: [:]][dateKey, default: [:]][stopID] = update
                    }
                }
            default:
                continue
            }
        }
        return GTFSRealtimeSnapshot(updates: updates, canceledTrips: canceled,
                                    updatedAt: timestamp, isAvailable: true,
                                    alertsAvailable: false, alerts: [], freshness: .unavailable)
    }

    static func alerts(from data: Data) throws -> (alerts: [GTFSAlert], updatedAt: Date?) {
        var reader = ProtoReader(data: data)
        var result: [GTFSAlert] = []
        var timestamp: Date?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                timestamp = try parseHeader(bytes)
            } else if field.number == 2, let bytes = field.bytes,
                      let alert = try parseAlertEntity(bytes), alert.isActive(at: Date()) {
                result.append(alert)
            }
        }
        return (result, timestamp)
    }

    static func vehiclePositions(from data: Data)
        throws -> (vehicles: [GTFSRealtimeVehicle], updatedAt: Date?) {
        var reader = ProtoReader(data: data)
        var vehicles: [GTFSRealtimeVehicle] = []
        var timestamp: Date?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                timestamp = try parseHeader(bytes)
            } else if field.number == 2, let bytes = field.bytes,
                      let vehicle = try parseVehicleEntity(bytes) {
                vehicles.append(vehicle)
            }
        }
        return (vehicles, timestamp)
    }

    private static func parseHeader(_ data: Data) throws -> Date? {
        var reader = ProtoReader(data: data)
        while let field = try reader.next() {
            if field.number == 3, let timestamp = field.varint {
                return Date(timeIntervalSince1970: Double(timestamp))
            }
        }
        return nil
    }

    private static func parseTripUpdateEntity(_ data: Data) throws
        -> (tripID: String, serviceDate: String?, canceled: Bool, stopUpdates: [(String, GTFSStopTimeUpdate)])? {
        var entityReader = ProtoReader(data: data)
        var tripUpdateData: Data?
        while let field = try entityReader.next() {
            if field.number == 3, let bytes = field.bytes {
                tripUpdateData = bytes
                break
            }
        }
        guard let tripUpdateData else { return nil }

        var reader = ProtoReader(data: tripUpdateData)
        var tripID: String?
        var serviceDate: String?
        var relationship: UInt64 = 0
        var stopUpdates: [(String, GTFSStopTimeUpdate)] = []
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                let descriptor = try parseTripDescriptor(bytes)
                tripID = descriptor.tripID
                serviceDate = descriptor.serviceDate
                relationship = descriptor.relationship
            } else if field.number == 2, let bytes = field.bytes,
                      let update = try parseStopTimeUpdate(bytes) {
                stopUpdates.append(update)
            }
        }
        guard let tripID, !tripID.isEmpty else { return nil }
        return (tripID, serviceDate, relationship == 3, stopUpdates)
    }

    private static func parseTripDescriptor(_ data: Data) throws
        -> (tripID: String?, serviceDate: String?, relationship: UInt64, routeID: String?) {
        var reader = ProtoReader(data: data)
        var tripID: String?
        var serviceDate: String?
        var relationship: UInt64 = 0
        var routeID: String?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes { tripID = String(data: bytes, encoding: .utf8) }
            if field.number == 3, let bytes = field.bytes { serviceDate = String(data: bytes, encoding: .utf8) }
            if field.number == 4, let value = field.varint { relationship = value }
            if field.number == 5, let bytes = field.bytes { routeID = String(data: bytes, encoding: .utf8) }
        }
        return (tripID, serviceDate, relationship, routeID)
    }

    private static func parseStopTimeUpdate(_ data: Data) throws -> (String, GTFSStopTimeUpdate)? {
        var reader = ProtoReader(data: data)
        var stopID: String?
        var stopSequence: Int?
        var arrival: GTFSStopTimeEvent?
        var departure: GTFSStopTimeEvent?
        while let field = try reader.next() {
            if field.number == 1, let value = field.varint, value <= UInt64(Int.max) {
                stopSequence = Int(value)
            }
            if field.number == 2, let bytes = field.bytes { arrival = try parseEvent(bytes) }
            if field.number == 3, let bytes = field.bytes { departure = try parseEvent(bytes) }
            if field.number == 4, let bytes = field.bytes { stopID = String(data: bytes, encoding: .utf8) }
        }
        let key = stopID.flatMap { $0.isEmpty ? nil : $0 } ?? stopSequence.map { "sequence:\($0)" }
        guard let key else { return nil }
        return (key, GTFSStopTimeUpdate(arrivalTime: arrival?.time, departureTime: departure?.time,
                                           arrivalDelay: arrival?.delay, departureDelay: departure?.delay))
    }

    private static func parseEvent(_ data: Data) throws -> GTFSStopTimeEvent {
        var reader = ProtoReader(data: data)
        var delay: Int?
        var time: Date?
        while let field = try reader.next() {
            if field.number == 1, let value = field.varint {
                delay = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
            }
            if field.number == 2, let value = field.varint {
                time = Date(timeIntervalSince1970: Double(value))
            }
        }
        return GTFSStopTimeEvent(time: time, delay: delay)
    }

    private static func parseAlertEntity(_ data: Data) throws -> GTFSAlert? {
        var reader = ProtoReader(data: data)
        while let field = try reader.next() {
            guard field.number == 5, let bytes = field.bytes else { continue }
            let alert = try parseAlert(bytes)
            guard !alert.message.isEmpty else { continue }
            return GTFSAlert(message: alert.message, routeIDs: alert.routeIDs,
                             stopIDs: alert.stopIDs, activePeriods: alert.activePeriods)
        }
        return nil
    }

    private static func parseVehicleEntity(_ data: Data) throws -> GTFSRealtimeVehicle? {
        var reader = ProtoReader(data: data)
        var entityID: String?
        var vehicleData: Data?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                entityID = String(data: bytes, encoding: .utf8)
            } else if field.number == 4, let bytes = field.bytes {
                vehicleData = bytes
            }
        }
        guard let vehicleData else { return nil }
        return try parseVehiclePosition(vehicleData, entityID: entityID)
    }

    private static func parseVehiclePosition(_ data: Data, entityID: String?) throws -> GTFSRealtimeVehicle? {
        var reader = ProtoReader(data: data)
        var tripID: String?
        var routeID: String?
        var serviceDate: String?
        var currentStopID: String?
        var currentStopSequence: Int?
        var coordinate: Coordinate?
        var bearing: Double?
        var timestamp: Date?
        var vehicleID: String?
        var label: String?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                let descriptor = try parseTripDescriptor(bytes)
                tripID = descriptor.tripID
                routeID = descriptor.routeID
                serviceDate = descriptor.serviceDate
            } else if field.number == 2, let bytes = field.bytes {
                (coordinate, bearing) = try parsePosition(bytes)
            } else if field.number == 3, let value = field.varint, value <= UInt64(Int.max) {
                currentStopSequence = Int(value)
            } else if field.number == 4, let bytes = field.bytes {
                currentStopID = String(data: bytes, encoding: .utf8)
            } else if field.number == 6, let value = field.varint {
                timestamp = Date(timeIntervalSince1970: Double(value))
            } else if field.number == 8, let bytes = field.bytes {
                (vehicleID, label) = try parseVehicleDescriptor(bytes)
            }
        }
        guard let coordinate else { return nil }
        let id = vehicleID ?? entityID ?? tripID ?? routeID
        guard let id, !id.isEmpty else { return nil }
        return GTFSRealtimeVehicle(id: id, tripID: tripID, routeID: routeID,
                                   serviceDate: serviceDate, currentStopID: currentStopID,
                                   currentStopSequence: currentStopSequence,
                                   coordinate: coordinate, bearing: bearing,
                                   updatedAt: timestamp, label: label)
    }

    private static func parsePosition(_ data: Data) throws -> (Coordinate?, Double?) {
        var reader = ProtoReader(data: data)
        var latitude: Double?
        var longitude: Double?
        var bearing: Double?
        while let field = try reader.next() {
            guard let raw = field.fixed32 else { continue }
            let value = Double(Float(bitPattern: raw))
            if field.number == 1 { latitude = value }
            if field.number == 2 { longitude = value }
            if field.number == 3 { bearing = value }
        }
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return (nil, nil)
        }
        return (Coordinate(latitude: latitude, longitude: longitude), bearing)
    }

    private static func parseVehicleDescriptor(_ data: Data) throws -> (String?, String?) {
        var reader = ProtoReader(data: data)
        var id: String?
        var label: String?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes { id = String(data: bytes, encoding: .utf8) }
            if field.number == 2, let bytes = field.bytes { label = String(data: bytes, encoding: .utf8) }
        }
        return (id, label)
    }

    private static func parseAlert(_ data: Data) throws
        -> (message: String, routeIDs: Set<String>, stopIDs: Set<String>, activePeriods: [GTFSAlertPeriod]) {
        var reader = ProtoReader(data: data)
        var header = ""
        var description = ""
        var routeIDs: Set<String> = []
        var stopIDs: Set<String> = []
        var activePeriods: [GTFSAlertPeriod] = []
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                activePeriods.append(try parseAlertPeriod(bytes))
            }
            if field.number == 10, let bytes = field.bytes { header = try parseTranslatedString(bytes) }
            if field.number == 11, let bytes = field.bytes { description = try parseTranslatedString(bytes) }
            if field.number == 5, let bytes = field.bytes {
                let selector = try parseEntitySelector(bytes)
                if let routeID = selector.routeID { routeIDs.insert(routeID) }
                if let stopID = selector.stopID { stopIDs.insert(stopID) }
            }
        }
        let message = [header, description].filter { !$0.isEmpty }.joined(separator: ": ")
        return (message, routeIDs, stopIDs, activePeriods)
    }

    private static func parseAlertPeriod(_ data: Data) throws -> GTFSAlertPeriod {
        var reader = ProtoReader(data: data)
        var start: Date?
        var end: Date?
        while let field = try reader.next() {
            if field.number == 1, let value = field.varint { start = Date(timeIntervalSince1970: Double(value)) }
            if field.number == 2, let value = field.varint { end = Date(timeIntervalSince1970: Double(value)) }
        }
        return GTFSAlertPeriod(start: start, end: end)
    }

    private static func parseEntitySelector(_ data: Data) throws -> (routeID: String?, stopID: String?) {
        var reader = ProtoReader(data: data)
        var routeID: String?
        var stopID: String?
        while let field = try reader.next() {
            if field.number == 2, let bytes = field.bytes { routeID = String(data: bytes, encoding: .utf8) }
            if field.number == 5, let bytes = field.bytes { stopID = String(data: bytes, encoding: .utf8) }
        }
        return (routeID, stopID)
    }

    private static func parseTranslatedString(_ data: Data) throws -> String {
        var reader = ProtoReader(data: data)
        var firstTranslation: String?
        var polishTranslation: String?
        while let field = try reader.next() {
            guard field.number == 1, let bytes = field.bytes else { continue }
            var translation = ProtoReader(data: bytes)
            var text: String?
            var language = ""
            while let value = try translation.next() {
                if value.number == 1, let bytes = value.bytes { text = String(data: bytes, encoding: .utf8) }
                if value.number == 2, let bytes = value.bytes { language = String(data: bytes, encoding: .utf8) ?? "" }
            }
            guard let text, !text.isEmpty else { continue }
            if firstTranslation == nil { firstTranslation = text }
            if language.lowercased().hasPrefix("pl") { polishTranslation = text }
        }
        return polishTranslation ?? firstTranslation ?? ""
    }
}

private nonisolated struct GTFSRealtimeVehicle {
    let id: String
    let tripID: String?
    let routeID: String?
    let serviceDate: String?
    let currentStopID: String?
    let currentStopSequence: Int?
    let coordinate: Coordinate
    let bearing: Double?
    let updatedAt: Date?
    let label: String?
}

private nonisolated struct GTFSStopTimeUpdate {
    let arrivalTime: Date?
    let departureTime: Date?
    let arrivalDelay: Int?
    let departureDelay: Int?
}

private nonisolated struct GTFSStopTimeEvent {
    let time: Date?
    let delay: Int?
}

private nonisolated struct GTFSAlert {
    let message: String
    let routeIDs: Set<String>
    let stopIDs: Set<String>
    let activePeriods: [GTFSAlertPeriod]

    func isActive(at date: Date) -> Bool {
        activePeriods.isEmpty || activePeriods.contains { $0.contains(date) }
    }
}

private nonisolated struct GTFSAlertPeriod {
    let start: Date?
    let end: Date?

    func contains(_ date: Date) -> Bool {
        date >= (start ?? .distantPast) && date <= (end ?? .distantFuture)
    }
}

private nonisolated struct ProtoField {
    let number: Int
    let wireType: Int
    let varint: UInt64?
    let bytes: Data?
    let fixed32: UInt32?
}

private nonisolated struct ProtoReader {
    private let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }

    mutating func next() throws -> ProtoField? {
        guard offset < data.count else { return nil }
        let tag = try readVarint()
        let number = Int(tag >> 3)
        let wireType = Int(tag & 7)
        guard number > 0 else { throw TransitRoutingError.invalidResponse }
        switch wireType {
        case 0:
            return ProtoField(number: number, wireType: wireType, varint: try readVarint(), bytes: nil, fixed32: nil)
        case 1:
            guard offset + 8 <= data.count else { throw TransitRoutingError.invalidResponse }
            offset += 8
        case 2:
            let rawLength = try readVarint()
            guard rawLength <= UInt64(data.count - offset) else { throw TransitRoutingError.invalidResponse }
            let length = Int(rawLength)
            let value = Data(data[offset..<(offset + length)])
            offset += length
            return ProtoField(number: number, wireType: wireType, varint: nil, bytes: value, fixed32: nil)
        case 5:
            guard offset + 4 <= data.count else { throw TransitRoutingError.invalidResponse }
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            offset += 4
            return ProtoField(number: number, wireType: wireType, varint: nil, bytes: nil, fixed32: value)
        default:
            throw TransitRoutingError.invalidResponse
        }
        return ProtoField(number: number, wireType: wireType, varint: nil, bytes: nil, fixed32: nil)
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw TransitRoutingError.invalidResponse }
            let byte = data[offset]
            offset += 1
            if shift == 63, byte > 1 { throw TransitRoutingError.invalidResponse }
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw TransitRoutingError.invalidResponse
    }
}
