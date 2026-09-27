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

nonisolated struct GTFSTripPatternKey: Hashable, Comparable {
    let routeID: String
    let directionID: String
    let stopIDs: [String]

    init(trip: GTFSTrip) {
        routeID = trip.routeID
        directionID = trip.directionID
        stopIDs = trip.stopTimes.map(\.stopID)
    }

    static func < (left: GTFSTripPatternKey, right: GTFSTripPatternKey) -> Bool {
        if left.routeID != right.routeID { return left.routeID < right.routeID }
        if left.directionID != right.directionID { return left.directionID < right.directionID }
        return left.stopIDs.lexicographicallyPrecedes(right.stopIDs)
    }
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

nonisolated struct TransitTransferGridCell: Hashable {
    let latitude: Int
    let longitude: Int
}

nonisolated struct GTFSServiceTripGroup: Codable, Sendable {
    let serviceIndex: Int
    let tripIndices: [Int]
    let maximumScheduledDurationSeconds: Int
}

nonisolated struct GTFSRoutePattern: Codable, Sendable {
    let id: Int
    let key: String?
    let routeID: String
    let stopIDs: [String]
    let tripIndices: [Int]?
    let tripsByService: [GTFSServiceTripGroup]?
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

nonisolated enum TransitSearchText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
