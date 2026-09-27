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
    var mode: String {
        switch type {
        case 0, 900..<1_000:
            return "TRAM"
        // Extended GTFS types 100–199 are rail services; 400–499 cover
        // metro and other urban rail services.
        case 1, 2, 100..<200, 400..<500:
            return "RAIL"
        default:
            return "BUS"
        }
    }

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
    let pickupType: Int
    let dropOffType: Int

    init(stopID: String, sequence: Int, arrivalSeconds: Int, departureSeconds: Int,
         shapeDistance: Double?, pickupType: Int = 0, dropOffType: Int = 0) {
        self.stopID = stopID
        self.sequence = sequence
        self.arrivalSeconds = arrivalSeconds
        self.departureSeconds = departureSeconds
        self.shapeDistance = shapeDistance
        self.pickupType = pickupType
        self.dropOffType = dropOffType
    }

    var allowsPickup: Bool { pickupType != 1 }
    var allowsDropOff: Bool { dropOffType != 1 }
}

nonisolated struct GTFSTripFrequency: Codable, Sendable {
    let startSeconds: Int
    let endSeconds: Int
    let headwaySeconds: Int
    let exactTimes: Bool
}

nonisolated struct GTFSCalendar: Codable, Sendable {
    let startDate: String
    let endDate: String
    let weekdayFlags: [String: Bool]
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
