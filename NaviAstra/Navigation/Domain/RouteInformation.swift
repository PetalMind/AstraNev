import Foundation

nonisolated struct RouteInformation: Sendable {
    var toll: Bool?
    var highway: Bool?
    var ferry: Bool?
    var timeRestrictions: Bool?
    var warnings: [String] = []
    var countries: [String] = []
    var destinationSide: String?
    var scopeDescription: String?
    var source: RouteInformationSource?
}

nonisolated struct RouteInformationSource: Sendable {
    var endpoint: URL
    var shapes: [String]
    var costing: String
}

nonisolated struct ManeuverInformation: Sendable {
    var distanceMeters: Double?
    var duration: Double?
    var beginStreetNames: [String] = []
    var exitNumbers: [String] = []
    var exitRoads: [String] = []
    var exitDirections: [String] = []
    var exitNames: [String] = []
    var toll: Bool?
    var highway: Bool?
    var rough: Bool?
    var gate: Bool?
    var ferry: Bool?
    var timeRestrictions: Bool?
    var verbalAlert: String?
    var verbalBefore: String?
    var verbalAfter: String?
    var verbalSuccinct: String?

    var notices: [String] {
        [(toll, "Odcinek płatny"), (highway, "Autostrada"), (rough, "Nawierzchnia nieutwardzona lub nierówna"),
         (gate, "Brama na trasie"), (ferry, "Przeprawa promowa"),
         (timeRestrictions, "Ograniczenia zależne od czasu")].compactMap { $0.0 == true ? $0.1 : nil }
    }
}

nonisolated struct RouteRoadSection: Identifiable, Sendable {
    var id: Int
    var startMeters: Double
    var lengthMeters: Double
    var names: [String]
    var attributes: [RouteInformationItem]
}

nonisolated struct RouteInformationItem: Identifiable, Sendable {
    var id: String { title }
    var title: String
    var value: String
}

nonisolated struct RouteElevationSample: Identifiable, Sendable {
    var id: Double { distanceMeters }
    var distanceMeters: Double
    var heightMeters: Double?
}

nonisolated struct DetailedRouteInformation: Sendable {
    var sections: [RouteRoadSection] = []
    var elevations: [RouteElevationSample] = []
    var countries: [String] = []
    var regions: [String] = []
    var notices: [String] = []
    var completedLegs: Int = 0
    var totalLegs: Int = 0

    var ascent: Double? { elevationChange(up: true) }
    var descent: Double? { elevationChange(up: false) }
    private func elevationChange(up: Bool) -> Double? {
        guard elevations.count > 1, elevations.allSatisfy({ $0.heightMeters != nil }) else { return nil }
        return zip(elevations, elevations.dropFirst()).reduce(0) { sum, pair in
            let delta = pair.1.heightMeters! - pair.0.heightMeters!
            return sum + max(0, up ? delta : -delta)
        }
    }
}
