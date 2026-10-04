import Foundation

enum TransitLegMode: String, Codable, Hashable, Sendable {
    case walk
    case bus
    case tram
    case train
    case suburbanRail
    case metro
    case ferry
    case bicycle
    case car
    case unknown

    var isTransit: Bool {
        switch self {
        case .walk, .bicycle, .car: false
        case .bus, .tram, .train, .suburbanRail, .metro, .ferry, .unknown: true
        }
    }
}

struct TransitLeg: Identifiable, Sendable {
    let id: String
    let mode: TransitLegMode
    let sourceMode: String
    let line: String?
    let direction: String?
    let operatorName: String?
    let fromStop: String
    let toStop: String
    let fromCoordinate: Coordinate
    let toCoordinate: Coordinate
    let scheduledDeparture: Date
    let estimatedDeparture: Date
    let scheduledArrival: Date
    let estimatedArrival: Date
    let delaySeconds: Int?
    let intermediateStops: [TransitJourneyStop]
    let geometry: [Coordinate]
    let distance: Double
    let realtimeAvailable: Bool
    let routeID: String?
    let tripID: String?
    let lineColorHex: UInt32?
    let alerts: [String]
    let isInterlined: Bool

    var duration: TimeInterval { max(0, estimatedArrival.timeIntervalSince(estimatedDeparture)) }
    var isTransit: Bool { mode.isTransit }
}

struct TransitJourney: Identifiable, Sendable {
    let id: String
    let departure: Date
    let arrival: Date
    let duration: TimeInterval
    let transfers: Int
    let walkingDuration: TimeInterval
    let walkingDistance: Double
    let waitingDuration: TimeInterval
    let legs: [TransitLeg]
    let realtimeAvailable: Bool
    let alerts: [String]
}

enum TransitRouteProfile: String, Codable, Hashable, Sendable {
    case balanced
    case fastest
    case leastWalking
    case fewestTransfers
}

nonisolated struct TransitRoutePreferences: Hashable, Sendable {
    var profile: TransitRouteProfile = .balanced
    var additionalTransferBufferMinutes: Int = 1
    var pedestrianProfile: PedestrianProfile = .foot

    init(profile: TransitRouteProfile = .balanced,
         additionalTransferBufferMinutes: Int = 1,
         pedestrianProfile: PedestrianProfile = .foot) {
        self.profile = profile
        self.additionalTransferBufferMinutes = max(0, additionalTransferBufferMinutes)
        self.pedestrianProfile = pedestrianProfile
    }
}

enum PedestrianProfile: String, Hashable, Sendable {
    case foot = "FOOT"
    case wheelchair = "WHEELCHAIR"
}
