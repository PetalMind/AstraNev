import Foundation
import CryptoKit

nonisolated struct GTFSStop: Codable, Sendable {
    let id: String
    let name: String
    let address: String?
    let parentStation: String?
    let locationType: Int
    let coordinate: Coordinate
}

nonisolated struct GTFSRoute: Codable, Sendable {
    let id: String
    let shortName: String
    let longName: String
    let agencyName: String
    let type: Int
    let colorHex: UInt32
    var displayName: String { shortName.isEmpty ? (longName.isEmpty ? "MPK" : longName) : shortName }
    var mode: String { type == 0 ? "TRAM" : type == 2 ? "RAIL" : "BUS" }

    var carrierLabel: String {
        let normalized = TransitSearchText.normalize(agencyName)
        if normalized.contains("lodzka kolej aglomeracyjna") { return "ŁKA" }
        if normalized.contains("pkp intercity") { return "IC" }
        if normalized.contains("polregio") { return "POLREGIO" }
        if normalized.contains("koleje mazowieckie") { return "KM" }
        if normalized.contains("koleje dolnoslaskie") { return "KD" }
        if normalized.contains("koleje slaskie") { return "KŚ" }
        if normalized.contains("koleje wielkopolskie") { return "KW" }
        if normalized.contains("koleje malopolskie") { return "KMŁ" }
        if normalized.contains("skm") { return "SKM" }
        return agencyName.isEmpty ? displayName : agencyName
    }
}

nonisolated struct GTFSTrip: Codable, Sendable {
    let id: String
    let routeID: String
    let serviceID: String
    let directionID: String
    let headsign: String
    let trainNumber: String
    let shapeID: String
    let stopTimes: [GTFSTripStop]
    var patternKey: String { routeID + ":" + directionID + ":" + stopTimes.map(\.stopID).joined(separator: ",") }

    func displayLine(for route: GTFSRoute) -> String {
        guard route.mode == "RAIL" else { return route.displayName }
        let number = trainNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return route.carrierLabel }
        return number.lowercased().hasPrefix(route.carrierLabel.lowercased())
            ? number : "\(route.carrierLabel) \(number)"
    }
}

nonisolated struct GTFSTripStop: Codable, Sendable {
    let stopID: String
    let sequence: Int
    let arrivalSeconds: Int
    let departureSeconds: Int
    let shapeDistance: Double?
}

nonisolated struct GTFSCalendar: Codable, Sendable {
    let startDate: String
    let endDate: String
    let weekdayFlags: [String: Bool]
}

nonisolated struct TransitStopSpatialIndex: Codable, Sendable {
    private static let cellsPerDegree = 10.0
    let stopIDsByCell: [String: [String]]

    init(stops: [GTFSStop]) {
        stopIDsByCell = Dictionary(grouping: stops, by: {
            Self.cellKey(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }).mapValues { $0.map(\.id) }
    }

    func nearbyStopIDs(to coordinate: Coordinate, within distance: Double) -> [String] {
        let latitudeRadius = Int(ceil(distance / 110_574 * Self.cellsPerDegree)) + 1
        let metersPerLongitudeDegree = max(1_000, 111_320 * abs(cos(coordinate.latitude * .pi / 180)))
        let longitudeRadius = min(1_800,
                                  Int(ceil(distance / metersPerLongitudeDegree * Self.cellsPerDegree)) + 1)
        let centerLatitude = Int(floor(coordinate.latitude * Self.cellsPerDegree))
        let centerLongitude = Int(floor(coordinate.longitude * Self.cellsPerDegree))
        var ids: [String] = []
        for latitude in (centerLatitude - latitudeRadius)...(centerLatitude + latitudeRadius) {
            for longitude in (centerLongitude - longitudeRadius)...(centerLongitude + longitudeRadius) {
                ids.append(contentsOf: stopIDsByCell["\(latitude):\(longitude)"] ?? [])
            }
        }
        return ids
    }

    private static func cellKey(latitude: Double, longitude: Double) -> String {
        "\(Int(floor(latitude * cellsPerDegree))):\(Int(floor(longitude * cellsPerDegree)))"
    }
}

nonisolated struct GTFSRoutePattern: Codable, Sendable {
    let id: Int
    let key: String
    let routeID: String
    let stopIDs: [String]
    let tripIndices: [Int]
}

nonisolated struct GTFSInputFeed: Sendable {
    let data: Data
    let prefix: String
    let retrievedAt: Date?
}

nonisolated enum TransitFeedFingerprint {
    static func make(_ feeds: [GTFSInputFeed]) -> String {
        var hasher = SHA256()
        for feed in feeds.sorted(by: { $0.prefix < $1.prefix }) {
            hasher.update(data: Data(feed.prefix.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: feed.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct GTFSDatabase: Codable, Sendable {
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
    let stopsByStationID: [String: [GTFSStop]]
    let tripsByID: [String: GTFSTrip]
    let tripIDsByStop: [String: [String]]
    let routeIDsByStop: [String: Set<String>]
    let routePatterns: [GTFSRoutePattern]
    let routePatternIDsByStop: [String: [Int]]
    let stopSpatialIndex: TransitStopSpatialIndex
    let serviceIDs: [String]
    let footpathsByStopID: [String: [TransitFootpath]]
    let feedFingerprint: String
    let railwayFeedAvailable: Bool
    let railwayFeedVersion: String?
    let railwayFeedRetrievedAt: Date?
    let railwayAttributions: [String]

    init(feeds: [GTFSInputFeed],
         cachedFootpathsByStopID: [String: [TransitFootpath]]? = nil,
         feedFingerprint: String? = nil) throws {
        let feedFiles = try feeds.map { try GTFSZipArchive.extract($0.data) }
        func rows(named filename: String, namespacedColumns: [String] = []) throws -> [[String: String]] {
            var result: [[String: String]] = []
            for index in feeds.indices {
                let prefix = feeds[index].prefix
                let parsed = try GTFSCSV.rows(named: filename, in: feedFiles[index])
                result.reserveCapacity(result.count + parsed.count)
                for sourceRow in parsed {
                    guard !prefix.isEmpty, !namespacedColumns.isEmpty else {
                        result.append(sourceRow)
                        continue
                    }
                    var row = sourceRow
                    for column in namespacedColumns {
                        if let value = row[column], !value.isEmpty { row[column] = prefix + value }
                    }
                    result.append(row)
                }
            }
            return result
        }
        let railwayIndex = feeds.firstIndex { $0.prefix == "rail/" }
        railwayFeedAvailable = railwayIndex != nil
        railwayFeedRetrievedAt = railwayIndex.flatMap { feeds[$0].retrievedAt }
        railwayFeedVersion = try railwayIndex.flatMap { index in
            try GTFSCSV.rows(named: "feed_info.txt", in: feedFiles[index]).first?["feed_version"]
        }
        railwayAttributions = try railwayIndex.map { index in
            try GTFSCSV.rows(named: "attributions.txt", in: feedFiles[index]).compactMap { row in
                guard let name = row["organization_name"], !name.isEmpty else { return nil }
                guard let url = row["attribution_url"], !url.isEmpty else { return name }
                return "\(name) (\(url))"
            }
        } ?? []

        let stopRows = try rows(named: "stops.txt", namespacedColumns: ["stop_id", "parent_station"])
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
        let agencyNames = Dictionary(try rows(named: "agency.txt", namespacedColumns: ["agency_id"])
            .compactMap { row -> (String, String)? in
                guard let id = row["agency_id"], let name = row["agency_name"], !name.isEmpty else { return nil }
                return (id, name)
            }, uniquingKeysWith: { first, _ in first })
        let routeRows = try rows(named: "routes.txt", namespacedColumns: ["route_id", "agency_id"])
        routes = Dictionary(routeRows.compactMap { row -> (String, GTFSRoute)? in
            guard let id = row["route_id"] else { return nil }
            let agencyName = row["agency_id"].flatMap { agencyNames[$0] }
                ?? (agencyNames.count == 1 ? agencyNames.values.first : nil) ?? ""
            return (id, GTFSRoute(id: id, shortName: row["route_short_name"] ?? "",
                                  longName: row["route_long_name"] ?? "",
                                  agencyName: agencyName,
                                  type: Int(row["route_type"] ?? "") ?? 3,
                                  colorHex: Self.parseColor(row["route_color"]) ?? Self.color(for: row["route_short_name"] ?? id)))
        }, uniquingKeysWith: { first, _ in first })
        normalizedRouteNames = Dictionary(routes.values.map { ($0.id, TransitSearchText.normalize($0.displayName)) },
                                          uniquingKeysWith: { first, _ in first })

        var groupedStops: [String: [GTFSTripStop]] = [:]
        for row in try rows(named: "stop_times.txt", namespacedColumns: ["trip_id", "stop_id"]) {
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

        if let cachedFootpathsByStopID {
            footpathsByStopID = cachedFootpathsByStopID
        } else {
        var footpaths: [String: [TransitFootpath]] = [:]
        var prohibitedTransferPairs: Set<String> = []
        func transferPairKey(from: String, to: String) -> String {
            from + "\u{0}" + to
        }
        func addFootpath(from: GTFSStop, to: GTFSStop, distance: Double,
                         walkingDuration: TimeInterval, minimumTransferTime: TimeInterval) {
            guard from.id != to.id,
                  !prohibitedTransferPairs.contains(transferPairKey(from: from.id, to: to.id)) else { return }
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

        for row in try rows(named: "transfers.txt", namespacedColumns: ["from_stop_id", "to_stop_id"]) {
            guard let fromID = row["from_stop_id"], let toID = row["to_stop_id"],
                  let from = parsedStops.first(where: { $0.id == fromID }),
                  let to = parsedStops.first(where: { $0.id == toID }) else { continue }
            let type = Int(row["transfer_type"] ?? "0") ?? 0
            if type == 3 {
                prohibitedTransferPairs.insert(transferPairKey(from: fromID, to: toID))
                footpaths[fromID]?.removeAll { $0.toStopID == toID }
                continue
            }
            guard type == 0 || type == 1 || type == 2 else { continue }
            let distance = from.coordinate.distance(to: to.coordinate)
            let minimum = type == 2 ? max(0, Double(row["min_transfer_time"] ?? "0") ?? 0) : 0
            let estimatedWalk = max(0, distance / 1.0)
            addFootpath(from: from, to: to, distance: distance,
                        walkingDuration: estimatedWalk, minimumTransferTime: minimum)
        }
        for row in try rows(named: "pathways.txt", namespacedColumns: ["from_stop_id", "to_stop_id"]) {
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
        }
        normalizedStopNames = Dictionary(parsedStops.map { ($0.id, TransitSearchText.normalize($0.name)) },
                                         uniquingKeysWith: { first, _ in first })
        for id in groupedStops.keys {
            groupedStops[id]?.sort { $0.sequence < $1.sequence }
        }
        let parsedTrips: [GTFSTrip] = try rows(named: "trips.txt", namespacedColumns: ["trip_id", "route_id", "service_id", "shape_id"]).compactMap { row -> GTFSTrip? in
            guard let id = row["trip_id"], let routeID = row["route_id"], let serviceID = row["service_id"],
                  let stops = groupedStops[id], stops.count > 1 else { return nil }
            return GTFSTrip(id: id, routeID: routeID, serviceID: serviceID,
                            directionID: row["direction_id"] ?? "",
                            headsign: row["trip_headsign"] ?? "",
                            trainNumber: row["plk_train_number"] ?? row["trip_short_name"] ?? "",
                            shapeID: row["shape_id"] ?? "",
                            stopTimes: stops)
        }
        trips = parsedTrips
        var headsignsByRoute: [String: Set<String>] = [:]
        for trip in parsedTrips where !trip.headsign.isEmpty {
            headsignsByRoute[trip.routeID, default: []].insert(trip.headsign)
        }
        lineDirections = headsignsByRoute.mapValues { values in
            values.sorted().prefix(2).joined(separator: " ↔ ")
        }
        stopByID = Dictionary(parsedStops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stopsByStationID = Dictionary(grouping: parsedStops.compactMap { stop -> (String, GTFSStop)? in
            if let parent = stop.parentStation, !parent.isEmpty { return (parent, stop) }
            return stop.locationType == 1 ? (stop.id, stop) : nil
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        tripsByID = Dictionary(parsedTrips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tripIDsByStop = groupedStops.reduce(into: [String: [String]]()) { result, entry in
            for stop in entry.value { result[stop.stopID, default: []].append(entry.key) }
        }
        let tripPatterns = Dictionary(grouping: parsedTrips.indices, by: { parsedTrips[$0].patternKey })
        var builtPatterns: [GTFSRoutePattern] = []
        var patternIDsByStop: [String: [Int]] = [:]
        for (patternID, key) in tripPatterns.keys.sorted().enumerated() {
            guard let tripIndices = tripPatterns[key], let firstTripIndex = tripIndices.first else { continue }
            let firstTrip = parsedTrips[firstTripIndex]
            let sortedTripIndices = tripIndices.sorted {
                let left = parsedTrips[$0].stopTimes.first?.departureSeconds ?? 0
                let right = parsedTrips[$1].stopTimes.first?.departureSeconds ?? 0
                if left == right { return parsedTrips[$0].id < parsedTrips[$1].id }
                return left < right
            }
            let pattern = GTFSRoutePattern(id: patternID, key: key, routeID: firstTrip.routeID,
                                           stopIDs: firstTrip.stopTimes.map { $0.stopID },
                                           tripIndices: sortedTripIndices)
            builtPatterns.append(pattern)
            for stopID in pattern.stopIDs { patternIDsByStop[stopID, default: []].append(patternID) }
        }
        routePatterns = builtPatterns
        routePatternIDsByStop = patternIDsByStop
        stopSpatialIndex = TransitStopSpatialIndex(stops: parsedStops.filter {
            tripServedStopIDs.contains($0.id)
        })
        serviceIDs = Array(Set(parsedTrips.map { $0.serviceID })).sorted()
        self.feedFingerprint = feedFingerprint ?? TransitFeedFingerprint.make(feeds)
        var routesByStop: [String: Set<String>] = [:]
        for trip in parsedTrips {
            for stop in trip.stopTimes { routesByStop[stop.stopID, default: []].insert(trip.routeID) }
        }
        routeIDsByStop = routesByStop

        calendars = Dictionary(try rows(named: "calendar.txt", namespacedColumns: ["service_id"]).compactMap { row in
            guard let id = row["service_id"], let start = row["start_date"], let end = row["end_date"] else { return nil }
            let flags = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
                .reduce(into: [String: Bool]()) { $0[$1] = row[$1] == "1" }
            return (id, GTFSCalendar(startDate: start, endDate: end, weekdayFlags: flags))
        }, uniquingKeysWith: { first, _ in first })

        var serviceExceptions: [String: [String: Int]] = [:]
        for row in try rows(named: "calendar_dates.txt", namespacedColumns: ["service_id"]) {
            guard let id = row["service_id"], let date = row["date"],
                  let type = Int(row["exception_type"] ?? "") else { continue }
            serviceExceptions[id, default: [:]][date] = type
        }
        exceptions = serviceExceptions

        var shapeRows: [String: [(Int, Coordinate)]] = [:]
        for row in try rows(named: "shapes.txt", namespacedColumns: ["shape_id"]) {
            guard let id = row["shape_id"], let sequence = Int(row["shape_pt_sequence"] ?? ""),
                  let latitude = row["shape_pt_lat"].flatMap(Double.init),
                  let longitude = row["shape_pt_lon"].flatMap(Double.init) else { continue }
            shapeRows[id, default: []].append((sequence, Coordinate(latitude: latitude, longitude: longitude)))
        }
        shapes = shapeRows.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
        guard !stops.isEmpty, !parsedTrips.isEmpty else { throw TransitRoutingError.invalidResponse }
    }

    private static func parseColor(_ value: String?) -> UInt32? {
        guard let value, value.count == 6, let color = UInt32(value, radix: 16) else { return nil }
        return color
    }

    private static func color(for value: String) -> UInt32 {
        TransitLinePalette.color(for: value)
    }
}

nonisolated enum TransitSearchText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct LoadedTransitDatabase: Sendable {
    let database: GTFSDatabase
    let wasCached: Bool
}

nonisolated struct PersistedTransitDatabase: Codable, Sendable {
    static let currentSchemaVersion = 3
    let schemaVersion: Int
    let database: GTFSDatabase
}

nonisolated struct PersistedTransferGraph: Codable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let fingerprint: String
    let storedAt: Date
    let footpathsByStopID: [String: [TransitFootpath]]
}

nonisolated struct LoadedGTFSArchive: Sendable {
    let data: Data
    let wasCached: Bool
    let retrievedAt: Date?
}

nonisolated enum TransitGTFSLoader {
    static func load(cacheDirectory: URL, feedURL: URL,
                     railwayFeedURL: URL, planningID: UInt64?,
                     trace: TransitPlanningTrace?) async throws -> LoadedTransitDatabase {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        async let cityArchiveRequest = loadArchive(cacheDirectory: cacheDirectory,
                                                   filename: "lodz-gtfs.zip", feedURL: feedURL)
        async let railwayArchiveRequest = try? loadArchive(cacheDirectory: cacheDirectory,
                                                           filename: "polish-trains-gtfs.zip",
                                                           feedURL: railwayFeedURL)
        let cityArchive = try await cityArchiveRequest
        let railwayArchive = await railwayArchiveRequest
        if Task.isCancelled { throw CancellationError() }
        var feeds = [GTFSInputFeed(data: cityArchive.data, prefix: "", retrievedAt: cityArchive.retrievedAt)]
        if let railwayArchive {
            feeds.append(GTFSInputFeed(data: railwayArchive.data, prefix: "rail/",
                                       retrievedAt: railwayArchive.retrievedAt))
        }
        let transferCacheURL = cacheDirectory.appendingPathComponent("transit-transfer-graph-v1.plist")
        func makeDatabase(_ inputFeeds: [GTFSInputFeed]) throws -> GTFSDatabase {
            let fingerprint = TransitFeedFingerprint.make(inputFeeds)
            let cachedFootpaths = readTransferGraph(at: transferCacheURL, fingerprint: fingerprint)
            trace?.setCount("transferGraphCacheHit", value: cachedFootpaths.map { _ in 1 } ?? 0)
            let database = try GTFSDatabase(feeds: inputFeeds,
                                            cachedFootpathsByStopID: cachedFootpaths?.footpathsByStopID,
                                            feedFingerprint: fingerprint)
            if cachedFootpaths == nil {
                persistTransferGraph(database.footpathsByStopID, fingerprint: fingerprint,
                                     to: transferCacheURL)
            }
            return database
        }
        let database: GTFSDatabase
        do {
            let indexStartedAt = ProcessInfo.processInfo.systemUptime
            let indexInterval = TransitSignposting.begin("ScheduleIndexBuild", planningID: planningID)
            defer {
                TransitSignposting.end("ScheduleIndexBuild", identifier: indexInterval,
                                       planningID: planningID)
                trace?.recordDuration("ScheduleIndexBuild", startedAt: indexStartedAt)
            }
            do {
                database = try makeDatabase(feeds)
            } catch {
                guard railwayArchive != nil else { throw error }
                database = try makeDatabase([feeds[0]])
            }
        }
        return LoadedTransitDatabase(database: database,
                                     wasCached: cityArchive.wasCached && (railwayArchive?.wasCached ?? true))
    }

    private static func readTransferGraph(at url: URL, fingerprint: String) -> PersistedTransferGraph? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let cache = try PropertyListDecoder().decode(PersistedTransferGraph.self, from: data)
            guard cache.schemaVersion == PersistedTransferGraph.currentSchemaVersion,
                  cache.fingerprint == fingerprint,
                  (0...30 * 24 * 60 * 60).contains(Date().timeIntervalSince(cache.storedAt)) else {
                return nil
            }
            return cache
        } catch {
            return nil
        }
    }

    private static func persistTransferGraph(_ footpaths: [String: [TransitFootpath]],
                                             fingerprint: String, to url: URL) {
        do {
            let cache = PersistedTransferGraph(
                schemaVersion: PersistedTransferGraph.currentSchemaVersion,
                fingerprint: fingerprint,
                storedAt: Date(),
                footpathsByStopID: footpaths
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(cache).write(to: url, options: .atomic)
        } catch {
            // A failed derived cache write must never prevent GTFS use.
        }
    }

    private static func loadArchive(cacheDirectory: URL, filename: String,
                                    feedURL: URL) async throws -> LoadedGTFSArchive {
        let archiveURL = cacheDirectory.appendingPathComponent(filename)
        let cachedData = try? Data(contentsOf: archiveURL)
        let isFresh = (try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate).map { Date().timeIntervalSince($0) < 86_400 } ?? false

        if let cachedData, isFresh, cachedData.count > 22 {
            let retrievedAt = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return LoadedGTFSArchive(data: cachedData, wasCached: true, retrievedAt: retrievedAt ?? nil)
        }

        do {
            let data = try await download(feedURL)
            guard data.count > 22 else { throw TransitRoutingError.invalidResponse }
            try data.write(to: archiveURL, options: .atomic)
            return LoadedGTFSArchive(data: data, wasCached: false, retrievedAt: Date())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cachedData, cachedData.count > 22 {
                let retrievedAt = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return LoadedGTFSArchive(data: cachedData, wasCached: true, retrievedAt: retrievedAt ?? nil)
            }
            throw TransitRoutingError.feedUnavailable
        }
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
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

nonisolated enum TransitLinePalette {
    static func color(for value: String) -> UInt32 {
        let colors: [UInt32] = [0xD8343C, 0x2867B2, 0x189477, 0x8A58A8, 0xE18927, 0x357A9F]
        let hash = value.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return colors[Int(hash % UInt32(colors.count))]
    }
}
