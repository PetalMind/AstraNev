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
    let frequenciesByTripID: [String: [GTFSTripFrequency]]
    let tripIDsByStop: [String: [String]]
    let routeIDsByStop: [String: Set<String>]
    let feedFingerprint: String
    let railwayFeedAvailable: Bool
    let railwayFeedVersion: String?
    let railwayFeedRetrievedAt: Date?
    let railwayAttributions: [String]

    init(feeds: [GTFSInputFeed],
         feedFingerprint: String? = nil) throws {
        let feedArchives = try feeds.map { try GTFSZipArchive.open($0.data) }

        func rows(named filename: String, namespacedColumns: [String] = []) throws -> [[String: String]] {
            var result: [[String: String]] = []
            for index in feeds.indices {
                let prefix = feeds[index].prefix
                let parsed = try GTFSCSV.rows(named: filename, in: feedArchives[index],
                                               prefix: prefix, namespacedColumns: namespacedColumns)
                result.reserveCapacity(result.count + parsed.count)
                result.append(contentsOf: parsed)
            }
            return result
        }
        func forEachRow(named filename: String, namespacedColumns: [String] = [],
                        body: ([String: String]) throws -> Void) throws {
            for index in feeds.indices {
                try GTFSCSV.forEachRow(named: filename, in: feedArchives[index],
                                       prefix: feeds[index].prefix,
                                       namespacedColumns: namespacedColumns, body: body)
            }
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

        var rawGroupedStops: [String: [(stopID: String, sequence: Int, arrival: Int?, departure: Int?,
                                       shapeDistance: Double?, pickupType: Int, dropOffType: Int)]] = [:]
        try forEachRow(named: "stop_times.txt", namespacedColumns: ["trip_id", "stop_id"]) { row in
            guard let tripID = row["trip_id"], let stopID = row["stop_id"],
                  let sequence = Int(row["stop_sequence"] ?? "") else { return }
            rawGroupedStops[tripID, default: []].append((
                stopID: stopID, sequence: sequence,
                arrival: GTFSCSV.serviceSeconds(row["arrival_time"] ?? ""),
                departure: GTFSCSV.serviceSeconds(row["departure_time"] ?? ""),
                shapeDistance: row["shape_dist_traveled"].flatMap(Double.init),
                pickupType: Int(row["pickup_type"] ?? "0") ?? 0,
                dropOffType: Int(row["drop_off_type"] ?? "0") ?? 0))
        }
        var groupedStops = rawGroupedStops.compactMapValues { rawStops -> [GTFSTripStop]? in
            let ordered = rawStops.sorted { $0.sequence < $1.sequence }
            guard ordered.count > 1,
                  ordered.first.map({ $0.arrival != nil || $0.departure != nil }) == true,
                  ordered.last.map({ $0.arrival != nil || $0.departure != nil }) == true else { return nil }
            var interpolated: [GTFSTripStop] = []
            interpolated.reserveCapacity(ordered.count)
            for index in ordered.indices {
                let row = ordered[index]
                let time = row.arrival ?? row.departure ?? {
                    guard let previous = ordered[..<index].last(where: { $0.arrival != nil || $0.departure != nil }),
                          let next = ordered[(index + 1)...].first(where: { $0.arrival != nil || $0.departure != nil }) else {
                        return nil
                    }
                    let previousIndex = ordered.firstIndex(where: { $0.sequence == previous.sequence }) ?? 0
                    let nextIndex = ordered.firstIndex(where: { $0.sequence == next.sequence }) ?? ordered.count - 1
                    let previousTime = previous.arrival ?? previous.departure ?? 0
                    let nextTime = next.arrival ?? next.departure ?? previousTime
                    let fraction: Double
                    if let startDistance = previous.shapeDistance,
                       let endDistance = next.shapeDistance, endDistance > startDistance,
                       let distance = row.shapeDistance,
                       distance >= startDistance, distance <= endDistance {
                        fraction = (distance - startDistance) / (endDistance - startDistance)
                    } else if nextIndex > previousIndex {
                        fraction = Double(index - previousIndex) / Double(nextIndex - previousIndex)
                    } else {
                        return nil
                    }
                    return Int((Double(previousTime) + Double(nextTime - previousTime) * fraction).rounded())
                }()
                guard let time else { return nil }
                interpolated.append(GTFSTripStop(
                    stopID: row.stopID, sequence: row.sequence,
                    arrivalSeconds: row.arrival ?? time,
                    departureSeconds: row.departure ?? time,
                    shapeDistance: row.shapeDistance,
                    pickupType: row.pickupType, dropOffType: row.dropOffType))
            }
            return interpolated
        }
        let tripServedStopIDs = Set(groupedStops.values.flatMap { $0.map(\.stopID) })
        servedStopIDs = tripServedStopIDs
        stopsForSearch = parsedStops.filter { tripServedStopIDs.contains($0.id) }
        normalizedStopNames = Dictionary(parsedStops.map { ($0.id, TransitSearchText.normalize($0.name)) },
                                         uniquingKeysWith: { first, _ in first })
        for id in groupedStops.keys {
            groupedStops[id]?.sort { $0.sequence < $1.sequence }
        }
        let parsedFrequenciesByTripID = Dictionary(grouping: try rows(
            named: "frequencies.txt", namespacedColumns: ["trip_id"]
        ).compactMap { row -> (String, GTFSTripFrequency)? in
            guard let tripID = row["trip_id"],
                  let start = GTFSCSV.serviceSeconds(row["start_time"] ?? ""),
                  let end = GTFSCSV.serviceSeconds(row["end_time"] ?? ""),
                  let headway = Int(row["headway_secs"] ?? ""),
                  start >= 0, end > start, headway > 0 else { return nil }
            let exactValue = row["exact_times"] ?? ""
            guard exactValue.isEmpty || exactValue == "0" || exactValue == "1" else { return nil }
            let exactTimes = exactValue == "1"
            return (tripID, GTFSTripFrequency(startSeconds: start, endSeconds: end,
                                              headwaySeconds: headway, exactTimes: exactTimes))
        }, by: { $0.0 }).mapValues { $0.map(\.1).sorted { $0.startSeconds < $1.startSeconds } }
        frequenciesByTripID = parsedFrequenciesByTripID
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

        var shapeRows: [String: [(sequence: Int, coordinate: Coordinate)]] = [:]
        try forEachRow(named: "shapes.txt", namespacedColumns: ["shape_id"]) { row in
            guard let id = row["shape_id"], let sequence = Int(row["shape_pt_sequence"] ?? ""),
                  let latitude = row["shape_pt_lat"].flatMap(Double.init),
                  let longitude = row["shape_pt_lon"].flatMap(Double.init) else { return }
            shapeRows[id, default: []].append((sequence,
                                               Coordinate(latitude: latitude, longitude: longitude)))
        }
        let orderedShapeRows = shapeRows.mapValues { $0.sorted { $0.sequence < $1.sequence } }
        shapes = orderedShapeRows.mapValues { $0.map { $0.coordinate } }
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

nonisolated enum TransitLinePalette {
    static func color(for _: String) -> UInt32 { NaviAstraColorPalette.transitFallback }
}
