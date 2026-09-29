import Foundation

struct TransitousTransitDataProvider: TransitDataProviding {
    static let stopIDPrefix = "transitous/"
    static let routeIDPrefix = "transitous/"
    static let tripIDPrefix = "transitous/"

    let region: TransitRegion
    private let local: LocalTransitDataProvider
    private let client: TransitousClient

    init(region: TransitRegion = .lodz,
         configuration: TransitousClientConfiguration = .init(),
         transport: TransitousTransport = URLSessionTransitousTransport(),
         local: LocalTransitDataProvider? = nil) {
        self.region = region
        self.local = local ?? LocalTransitDataProvider(region: region)
        self.client = TransitousClient(configuration: configuration, transport: transport)
    }

    func vehiclePositions(near coordinate: Coordinate) async -> TransitVehicleFeed {
        await local.vehiclePositions(near: coordinate)
    }

    func mapStops(in viewport: TransitMapViewport) async -> [TransitStop] {
        guard viewport.zoom >= 13 else { return [] }
        guard let places = try? await client.stops(in: viewport), !Task.isCancelled else { return [] }
        return places.compactMap(Self.mapStop).sorted {
            if $0.isMajor != $1.isMajor { return $0.isMajor }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func departures(at stopID: String, limit: Int) async -> [TransitDeparture] {
        guard Self.isTransitousID(stopID, prefix: Self.stopIDPrefix) else {
            return await local.departures(at: stopID, limit: limit)
        }
        return await transitousDepartures(at: stopID, limit: limit)
    }

    func departures(at stopIDs: [String], limit: Int) async -> [TransitDeparture] {
        let localIDs = stopIDs.filter { !Self.isTransitousID($0, prefix: Self.stopIDPrefix) }
        let transitousIDs = stopIDs.filter { Self.isTransitousID($0, prefix: Self.stopIDPrefix) }
        let localDepartures = await localDepartureResults(at: localIDs, limit: limit)
        let globalDepartures = await withTaskGroup(of: [TransitDeparture].self) { group in
            for stopID in transitousIDs.prefix(8) {
                group.addTask { await transitousDepartures(at: stopID, limit: limit) }
            }
            var result: [TransitDeparture] = []
            for await departures in group { result.append(contentsOf: departures) }
            return result
        }
        return (localDepartures + globalDepartures)
            .sorted { $0.estimatedDeparture < $1.estimatedDeparture }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func alerts(for stopID: String) async -> [String] {
        guard Self.isTransitousID(stopID, prefix: Self.stopIDPrefix) else {
            return await local.alerts(for: stopID)
        }
        guard let response = try? await client.departures(at: Self.rawID(stopID), limit: 10) else { return [] }
        let alerts = (response.place.alerts ?? []).map(\.headerText)
            + response.stopTimes.flatMap { ($0.place.alerts ?? []).map(\.headerText) }
        return Array(Set(alerts.filter { !$0.isEmpty })).prefix(3).map { $0 }
    }

    func alerts(for stopIDs: [String]) async -> [String] {
        let localIDs = stopIDs.filter { !Self.isTransitousID($0, prefix: Self.stopIDPrefix) }
        let transitousIDs = stopIDs.filter { Self.isTransitousID($0, prefix: Self.stopIDPrefix) }
        async let regionalAlertsTask = regionalAlertMessages(for: localIDs)
        let globalAlerts = await withTaskGroup(of: [String].self) { group in
            for stopID in transitousIDs.prefix(6) {
                group.addTask { await alerts(for: stopID) }
            }
            var result: [String] = []
            for await alerts in group { result.append(contentsOf: alerts) }
            return result
        }
        let regionalAlerts = await regionalAlertsTask
        return Array(Set(regionalAlerts + globalAlerts).filter { !$0.isEmpty }).prefix(6).map { $0 }
    }

    func railwayScheduleAttribution() async -> String? {
        await local.railwayScheduleAttribution()
    }

    func search(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults {
        let isNearLocalRegion = coordinate.map {
            $0.distance(to: region.coverageCenter) <= region.coverageRadiusMeters
        } ?? true
        async let regionalResults = regionalSearch(query, near: coordinate,
                                                   includeLocalResults: isNearLocalRegion)
        let globalStops: [TransitStop]
        if let matches = try? await client.searchStops(query, near: coordinate) {
            globalStops = matches.compactMap(Self.mapStop)
        } else {
            globalStops = []
        }
        let regional = await regionalResults
        let uniqueGlobalStops = globalStops.filter { candidate in
            !regional.stops.contains { existing in
                TransitSearchText.normalize(existing.name) == TransitSearchText.normalize(candidate.name)
                    && existing.coordinate.distance(to: candidate.coordinate) <= 100
            }
        }
        return TransitSearchResults(stops: Array((regional.stops + uniqueGlobalStops).prefix(12)),
                                    lines: regional.lines)
    }

    func lineDetails(for routeID: String) async -> TransitLineDetails? {
        guard !Self.isTransitousID(routeID, prefix: Self.routeIDPrefix) else { return nil }
        return await local.lineDetails(for: routeID)
    }

    func vehicleDetails(id: String) async -> TransitTripDetails? {
        await local.vehicleDetails(id: id)
    }

    func tripDetails(for departure: TransitDeparture) async -> TransitTripDetails? {
        guard Self.isTransitousID(departure.tripID, prefix: Self.tripIDPrefix) else {
            return await local.tripDetails(for: departure)
        }
        guard let trip = try? await client.trip(Self.rawID(departure.tripID)) else { return nil }
        return TransitousMapper.tripDetails(from: trip, currentStopID: Self.rawID(departure.stopID))
    }

    func tripDetails(tripID: String, serviceDate: String,
                     fromStopSequence: Int) async -> TransitTripDetails? {
        guard Self.isTransitousID(tripID, prefix: Self.tripIDPrefix) else {
            return await local.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                           fromStopSequence: fromStopSequence)
        }
        guard let trip = try? await client.trip(Self.rawID(tripID)) else { return nil }
        return TransitousMapper.tripDetails(from: trip, currentStopSequence: fromStopSequence)
    }

    func tripDetails(tripID: String, serviceDate: String, fromStopSequence: Int,
                     scheduleShiftSeconds: Int, frequencyStartSeconds: Int?,
                     frequencyHeadwaySeconds: Int?, isFrequencyEstimate: Bool) async -> TransitTripDetails? {
        guard Self.isTransitousID(tripID, prefix: Self.tripIDPrefix) else {
            return await local.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                           fromStopSequence: fromStopSequence,
                                           scheduleShiftSeconds: scheduleShiftSeconds,
                                           frequencyStartSeconds: frequencyStartSeconds,
                                           frequencyHeadwaySeconds: frequencyHeadwaySeconds,
                                           isFrequencyEstimate: isFrequencyEstimate)
            .map { details in
                var details = details
                details.isFrequencyEstimate = isFrequencyEstimate
                return details
            }
        }
        guard let trip = try? await client.trip(Self.rawID(tripID)) else { return nil }
        var details = TransitousMapper.tripDetails(from: trip, currentStopSequence: fromStopSequence)
        details?.frequencyHeadwaySeconds = frequencyHeadwaySeconds
        details?.isFrequencyEstimate = isFrequencyEstimate
        return details
    }

    func tripDetails(tripID: String, fromStopID: String?) async -> TransitTripDetails? {
        guard Self.isTransitousID(tripID, prefix: Self.tripIDPrefix) else {
            return await local.tripDetails(tripID: tripID, serviceDate: "", fromStopSequence: 0)
        }
        guard let trip = try? await client.trip(Self.rawID(tripID)) else { return nil }
        return TransitousMapper.tripDetails(from: trip,
                                            currentStopID: fromStopID.map(Self.rawID))
    }

    private func transitousDepartures(at stopID: String, limit: Int) async -> [TransitDeparture] {
        guard let response = try? await client.departures(at: Self.rawID(stopID), limit: limit),
              !Task.isCancelled else { return [] }
        return response.stopTimes.enumerated().compactMap { index, stopTime -> TransitDeparture? in
            guard stopTime.cancelled != true, stopTime.tripCancelled != true,
                  let tripID = stopTime.tripId, let routeID = stopTime.routeId,
                  let departure = TransitousMapper.date(stopTime.place.departure) else { return nil }
            let scheduled = TransitousMapper.date(stopTime.place.scheduledDeparture) ?? departure
            let isRealtime = stopTime.realTime == true
            let delay = isRealtime ? Int(departure.timeIntervalSince(scheduled).rounded()) : nil
            let line = stopTime.displayName?.transitousNilIfBlank
                ?? stopTime.routeShortName?.transitousNilIfBlank
                ?? stopTime.routeLongName?.transitousNilIfBlank
                ?? stopTime.tripId
                ?? "Linia"
            let destination = stopTime.headsign?.transitousNilIfBlank
                ?? stopTime.tripTo?.name.transitousNilIfBlank
                ?? stopTime.routeLongName?.transitousNilIfBlank
                ?? "Kierunek nieznany"
            return TransitDeparture(
                id: "\(Self.stopIDPrefix)\(Self.rawID(stopID))|\(tripID)|\(departure.timeIntervalSince1970)",
                stopID: "\(Self.stopIDPrefix)\(Self.rawID(stopID))",
                routeID: "\(Self.routeIDPrefix)\(routeID)",
                tripID: "\(Self.tripIDPrefix)\(tripID)",
                line: line,
                mode: stopTime.mode?.uppercased() ?? "BUS",
                destination: destination,
                scheduledDeparture: scheduled,
                estimatedDeparture: departure,
                delaySeconds: delay,
                hasRealtime: isRealtime,
                colorHex: TransitousMapper.colorValue(stopTime.routeColor) ?? 0x2867B2,
                stopSequence: index,
                serviceDate: Self.serviceDate(for: departure, timeZoneID: stopTime.place.tz),
                isFrequencyEstimate: false)
        }
    }

    private func regionalSearch(_ query: String, near coordinate: Coordinate?,
                                includeLocalResults: Bool) async -> TransitSearchResults {
        guard includeLocalResults else { return TransitSearchResults(stops: [], lines: []) }
        return await local.search(query, near: coordinate)
    }

    private func localDepartureResults(at stopIDs: [String], limit: Int) async -> [TransitDeparture] {
        guard !stopIDs.isEmpty else { return [] }
        return await local.departures(at: stopIDs, limit: limit)
    }

    private func regionalAlertMessages(for stopIDs: [String]) async -> [String] {
        guard !stopIDs.isEmpty else { return [] }
        return await local.alerts(for: stopIDs)
    }

    private static func mapStop(_ match: TransitousGeocodeMatchDTO) -> TransitStop? {
        mapStop(id: match.id, name: match.name, latitude: match.lat, longitude: match.lon,
                parentID: nil, importance: match.importance, rawModes: match.modes)
    }

    private static func mapStop(_ place: TransitousPlaceDTO) -> TransitStop? {
        let fallbackID = "\(place.lat),\(place.lon),\(place.name)"
        return mapStop(id: place.stopId ?? fallbackID, name: place.name, latitude: place.lat,
                       longitude: place.lon, parentID: place.parentId, importance: place.importance,
                       rawModes: place.modes)
    }

    private static func mapStop(id: String, name: String, latitude: Double, longitude: Double,
                                parentID: String?, importance: Double?, rawModes: [String]?) -> TransitStop? {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let modes = Set((rawModes ?? []).compactMap { rawMode -> TransitStopMode? in
            switch rawMode.uppercased() {
            case "BUS", "COACH": .bus
            case "TRAM": .tram
            case "SUBWAY", "METRO": .metro
            case "FERRY": .ferry
            case "RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "SUBURBAN_RAIL",
                 "HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL": .rail
            default: nil
            }
        })
        let id = id.hasPrefix(stopIDPrefix) ? id : stopIDPrefix + id
        let stationID = parentID.map { $0.hasPrefix(stopIDPrefix) ? $0 : stopIDPrefix + $0 }
        return TransitStop(id: id, name: name, address: nil,
                           coordinate: Coordinate(latitude: latitude, longitude: longitude),
                           isMajor: (importance ?? 0) >= 0.62,
                           lineIDs: [], lines: [], modes: modes,
                           stationID: stationID)
    }

    private static func isTransitousID(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix)
    }

    private static func rawID(_ value: String) -> String {
        guard value.hasPrefix(stopIDPrefix) || value.hasPrefix(routeIDPrefix) || value.hasPrefix(tripIDPrefix) else {
            return value
        }
        return String(value.dropFirst(stopIDPrefix.count))
    }

    private static func serviceDate(for date: Date, timeZoneID: String?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneID.flatMap { TimeZone(identifier: $0) } ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0,
                      components.day ?? 0)
    }
}
