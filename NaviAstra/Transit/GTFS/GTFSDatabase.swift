import Foundation

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
    var routePatterns: [GTFSRoutePattern]
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
         feedFingerprint: String? = nil,
         trace: TransitPlanningTrace? = nil) throws {
        let archiveIndexStartedAt = ProcessInfo.processInfo.systemUptime
        let feedArchives = try feeds.map { try GTFSZipArchive.open($0.data) }
        trace?.recordDuration("GTFSArchiveIndex", startedAt: archiveIndexStartedAt)

        func rows(named filename: String, namespacedColumns: [String] = []) throws -> [[String: String]] {
            let startedAt = ProcessInfo.processInfo.systemUptime
            var result: [[String: String]] = []
            for index in feeds.indices {
                let prefix = feeds[index].prefix
                let parsed = try GTFSCSV.rows(named: filename, in: feedArchives[index],
                                               prefix: prefix, namespacedColumns: namespacedColumns)
                result.reserveCapacity(result.count + parsed.count)
                result.append(contentsOf: parsed)
            }
            trace?.recordDuration("GTFSCSV_\(filename)", startedAt: startedAt)
            return result
        }
        func forEachRow(named filename: String, namespacedColumns: [String] = [],
                        body: ([String: String]) throws -> Void) throws {
            let startedAt = ProcessInfo.processInfo.systemUptime
            for index in feeds.indices {
                try GTFSCSV.forEachRow(named: filename, in: feedArchives[index],
                                       prefix: feeds[index].prefix,
                                       namespacedColumns: namespacedColumns, body: body)
            }
            trace?.recordDuration("GTFSCSV_\(filename)", startedAt: startedAt)
        }
        let railwayIndex = feeds.firstIndex { $0.prefix == "rail/" }
        railwayFeedAvailable = railwayIndex != nil
        railwayFeedRetrievedAt = railwayIndex.flatMap { feeds[$0].retrievedAt }
        railwayFeedVersion = try railwayIndex.flatMap { index in
            try GTFSCSV.rows(named: "feed_info.txt", in: feedArchives[index]).first?["feed_version"]
        }
        railwayAttributions = try railwayIndex.map { index in
            try GTFSCSV.rows(named: "attributions.txt", in: feedArchives[index]).compactMap { row in
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
        let parsedStopsByID = Dictionary(parsedStops.map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
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
        try forEachRow(named: "stop_times.txt", namespacedColumns: ["trip_id", "stop_id"]) { row in
            guard let tripID = row["trip_id"], let stopID = row["stop_id"],
                  let sequence = Int(row["stop_sequence"] ?? "") else { return }
            let arrivalText = row["arrival_time"] ?? ""
            let departureText = row["departure_time"] ?? ""
            guard let arrival = GTFSCSV.serviceSeconds(arrivalText) ?? GTFSCSV.serviceSeconds(departureText),
                  let departure = GTFSCSV.serviceSeconds(departureText) ?? GTFSCSV.serviceSeconds(arrivalText) else { return }
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
        var footpathIndicesByStopID: [String: [String: Int]] = [:]
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
            if let existing = footpathIndicesByStopID[from.id]?[to.id],
               let old = footpaths[from.id]?[existing] {
                if old.walkingDuration + old.minimumTransferTime
                    <= walkingDuration + minimumTransferTime { return }
                footpaths[from.id]![existing] = candidate
            } else {
                let nextIndex = footpaths[from.id]?.count ?? 0
                footpaths[from.id, default: []].append(candidate)
                footpathIndicesByStopID[from.id, default: [:]][to.id] = nextIndex
            }
        }

        for row in try rows(named: "transfers.txt", namespacedColumns: ["from_stop_id", "to_stop_id"]) {
            guard let fromID = row["from_stop_id"], let toID = row["to_stop_id"],
                  let from = parsedStopsByID[fromID],
                  let to = parsedStopsByID[toID] else { continue }
            let type = Int(row["transfer_type"] ?? "0") ?? 0
            if type == 3 {
                prohibitedTransferPairs.insert(transferPairKey(from: fromID, to: toID))
                footpaths[fromID]?.removeAll { $0.toStopID == toID }
                if let remaining = footpaths[fromID] {
                    footpathIndicesByStopID[fromID] = Dictionary(
                        remaining.enumerated().map { ($0.element.toStopID, $0.offset) },
                        uniquingKeysWith: { first, _ in first })
                } else {
                    footpathIndicesByStopID.removeValue(forKey: fromID)
                }
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
                  let from = parsedStopsByID[fromID],
                  let to = parsedStopsByID[toID] else { continue }
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

        let latitudeSortedIndices = servedStops.indices.sorted {
            servedStops[$0].coordinate.latitude < servedStops[$1].coordinate.latitude
        }
        var latitudeOrderByServedStopIndex = Array(repeating: 0, count: servedStops.count)
        for (order, stopIndex) in latitudeSortedIndices.enumerated() {
            latitudeOrderByServedStopIndex[stopIndex] = order
        }
        // A local grid prunes the candidate pairs; the geodesic 350 m check remains authoritative.
        let transferGridCellSize = 0.002
        func transferGridCell(for coordinate: Coordinate) -> TransitTransferGridCell {
            TransitTransferGridCell(
                latitude: Int(floor(coordinate.latitude / transferGridCellSize)),
                longitude: Int(floor(coordinate.longitude / transferGridCellSize)))
        }
        let servedStopIndicesByCell = Dictionary(grouping: servedStops.indices, by: {
            transferGridCell(for: servedStops[$0].coordinate)
        })
        let latitudeCellRadius = Int(ceil(400 / 110_574 / transferGridCellSize)) + 1
        for (firstOrder, firstIndex) in latitudeSortedIndices.enumerated() {
            let first = servedStops[firstIndex]
            let maxLatitude = min(89.999, abs(first.coordinate.latitude) + 400 / 110_574)
            let metersPerLongitudeDegree = max(
                1_000, 111_320 * cos(maxLatitude * .pi / 180))
            let longitudeCellRadius = Int(ceil(400 / metersPerLongitudeDegree / transferGridCellSize)) + 1
            let firstCell = transferGridCell(for: first.coordinate)
            var nearbySecondIndices: [Int] = []
            for latitudeCell in (firstCell.latitude - latitudeCellRadius)...(firstCell.latitude + latitudeCellRadius) {
                for longitudeCell in (firstCell.longitude - longitudeCellRadius)...(firstCell.longitude + longitudeCellRadius) {
                    let cell = TransitTransferGridCell(latitude: latitudeCell, longitude: longitudeCell)
                    for secondIndex in servedStopIndicesByCell[cell] ?? []
                        where latitudeOrderByServedStopIndex[secondIndex] > firstOrder {
                        nearbySecondIndices.append(secondIndex)
                    }
                }
            }
            nearbySecondIndices.sort {
                latitudeOrderByServedStopIndex[$0] < latitudeOrderByServedStopIndex[$1]
            }
            for secondIndex in nearbySecondIndices {
                let second = servedStops[secondIndex]
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
        let tripRows = try rows(named: "trips.txt", namespacedColumns: ["trip_id", "route_id", "service_id", "shape_id"])
        let parsedTrips: [GTFSTrip] = tripRows.compactMap { row -> GTFSTrip? in
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
        let parsedServiceIDs = Array(Set(parsedTrips.map { $0.serviceID })).sorted()
        serviceIDs = parsedServiceIDs
        let serviceIndexByID = Dictionary(uniqueKeysWithValues: parsedServiceIDs.enumerated()
            .map { ($1, $0) })
        var headsignsByRoute: [String: Set<String>] = [:]
        for trip in parsedTrips where !trip.headsign.isEmpty {
            headsignsByRoute[trip.routeID, default: []].insert(trip.headsign)
        }
        lineDirections = headsignsByRoute.mapValues { values in
            values.sorted().prefix(2).joined(separator: " ↔ ")
        }
        stopByID = parsedStopsByID
        stopsByStationID = Dictionary(grouping: parsedStops.compactMap { stop -> (String, GTFSStop)? in
            if let parent = stop.parentStation, !parent.isEmpty { return (parent, stop) }
            return stop.locationType == 1 ? (stop.id, stop) : nil
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        tripsByID = Dictionary(parsedTrips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tripIDsByStop = groupedStops.reduce(into: [String: [String]]()) { result, entry in
            for stop in entry.value { result[stop.stopID, default: []].append(entry.key) }
        }
        let tripPatterns = Dictionary(grouping: parsedTrips.indices, by: {
            GTFSTripPatternKey(trip: parsedTrips[$0])
        })
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
            let tripIndicesByService = Dictionary(grouping: sortedTripIndices, by: {
                serviceIndexByID[parsedTrips[$0].serviceID] ?? -1
            })
            let tripsByService = tripIndicesByService.keys.sorted().map { serviceIndex in
                let serviceTripIndices = tripIndicesByService[serviceIndex] ?? []
                let maximumDuration = serviceTripIndices.reduce(into: 0) { maximum, tripIndex in
                    guard let first = parsedTrips[tripIndex].stopTimes.first,
                          let last = parsedTrips[tripIndex].stopTimes.last else { return }
                    maximum = max(maximum, last.arrivalSeconds - first.departureSeconds)
                }
                return GTFSServiceTripGroup(serviceIndex: serviceIndex,
                                            tripIndices: serviceTripIndices,
                                            maximumScheduledDurationSeconds: maximumDuration)
            }
            let pattern = GTFSRoutePattern(id: patternID, key: nil,
                                           routeID: firstTrip.routeID,
                                           stopIDs: firstTrip.stopTimes.map { $0.stopID },
                                           tripIndices: nil,
                                           tripsByService: tripsByService)
            builtPatterns.append(pattern)
            for stopID in pattern.stopIDs { patternIDsByStop[stopID, default: []].append(patternID) }
        }
        routePatterns = builtPatterns
        routePatternIDsByStop = patternIDsByStop
        stopSpatialIndex = TransitStopSpatialIndex(stops: parsedStops.filter {
            tripServedStopIDs.contains($0.id)
        })
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
        try forEachRow(named: "shapes.txt", namespacedColumns: ["shape_id"]) { row in
            guard let id = row["shape_id"], let sequence = Int(row["shape_pt_sequence"] ?? ""),
                  let latitude = row["shape_pt_lat"].flatMap(Double.init),
                  let longitude = row["shape_pt_lon"].flatMap(Double.init) else { return }
            shapeRows[id, default: []].append((sequence, Coordinate(latitude: latitude, longitude: longitude)))
        }
        shapes = shapeRows.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
        guard !stops.isEmpty, !parsedTrips.isEmpty else { throw TransitRoutingError.invalidResponse }
    }

    var requiresPatternServiceIndexUpgrade: Bool {
        routePatterns.contains { $0.tripsByService == nil }
    }

    func upgradingPatternServiceIndexes() -> GTFSDatabase {
        guard requiresPatternServiceIndexUpgrade else { return self }
        let serviceIndexByID = Dictionary(uniqueKeysWithValues: serviceIDs.enumerated()
            .map { ($1, $0) })
        var upgraded = self
        upgraded.routePatterns = routePatterns.map { pattern in
            guard pattern.tripsByService == nil else { return pattern }
            guard let legacyTripIndices = pattern.tripIndices else { return pattern }
            let tripIndicesByService = Dictionary(grouping: legacyTripIndices, by: { tripIndex in
                guard trips.indices.contains(tripIndex) else { return -1 }
                return serviceIndexByID[trips[tripIndex].serviceID] ?? -1
            })
            let groups = tripIndicesByService.keys.sorted().map { serviceIndex in
                let tripIndices = tripIndicesByService[serviceIndex] ?? []
                let maximumDuration = tripIndices.reduce(into: 0) { maximum, tripIndex in
                    guard trips.indices.contains(tripIndex),
                          let first = trips[tripIndex].stopTimes.first,
                          let last = trips[tripIndex].stopTimes.last else { return }
                    maximum = max(maximum, last.arrivalSeconds - first.departureSeconds)
                }
                return GTFSServiceTripGroup(
                    serviceIndex: serviceIndex,
                    tripIndices: tripIndices,
                    maximumScheduledDurationSeconds: maximumDuration)
            }
            return GTFSRoutePattern(id: pattern.id, key: nil, routeID: pattern.routeID,
                                    stopIDs: pattern.stopIDs, tripIndices: nil,
                                    tripsByService: groups)
        }
        return upgraded
    }

    private static func parseColor(_ value: String?) -> UInt32? {
        guard let value, value.count == 6, let color = UInt32(value, radix: 16) else { return nil }
        return color
    }

    private static func color(for value: String) -> UInt32 {
        TransitLinePalette.color(for: value)
    }
}

nonisolated enum TransitLinePalette {
    static func color(for value: String) -> UInt32 {
        let colors: [UInt32] = [0xD8343C, 0x2867B2, 0x189477, 0x8A58A8, 0xE18927, 0x357A9F]
        let hash = value.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return colors[Int(hash % UInt32(colors.count))]
    }
}
