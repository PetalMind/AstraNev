import CoreLocation
import Foundation

nonisolated struct Coordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var cl: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    func distance(to other: Coordinate) -> CLLocationDistance {
        let earthRadius = 6_371_000.0
        let latitude1 = latitude * .pi / 180
        let latitude2 = other.latitude * .pi / 180
        let latitudeDelta = latitude2 - latitude1
        let longitudeDegrees = (other.longitude - longitude + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        let longitudeDelta = longitudeDegrees * .pi / 180
        let meanLatitude = (latitude1 + latitude2) / 2
        let localX = longitudeDelta * cos(meanLatitude)
        let localDistance = hypot(localX, latitudeDelta)
        if localDistance < 0.1 { return earthRadius * localDistance }

        let latitudeTerm = sin(latitudeDelta / 2)
        let longitudeTerm = sin(longitudeDelta / 2)
        let haversine = latitudeTerm * latitudeTerm +
            cos(latitude1) * cos(latitude2) * longitudeTerm * longitudeTerm
        return 2 * earthRadius * asin(min(1, sqrt(haversine)))
    }
}

struct Destination: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var coordinate: Coordinate
    var address: String? = nil
}

struct NavigationLocation {
    var coordinate: Coordinate
    var speed: CLLocationSpeed
    var course: CLLocationDirection
    var accuracy: CLLocationAccuracy
    var timestamp: Date
}

enum ManeuverKind: Int {
    case none = 0
    case start = 1
    case startRight = 2
    case startLeft = 3
    case destination = 4
    case destinationRight = 5
    case destinationLeft = 6
    case becomes = 7
    case straight = 8
    case slightRight = 9
    case right = 10
    case sharpRight = 11
    case uTurnRight = 12
    case uTurnLeft = 13
    case sharpLeft = 14
    case left = 15
    case slightLeft = 16
    case rampStraight = 17
    case rampRight = 18
    case rampLeft = 19
    case exitRight = 20
    case exitLeft = 21
    case stayStraight = 22
    case stayRight = 23
    case stayLeft = 24
    case merge = 25
    case roundaboutEnter = 26
    case roundaboutExit = 27
    case ferryEnter = 28
    case ferryExit = 29
    case transit = 30
    case transitTransfer = 31
    case transitRemainOn = 32
    case transitConnectionStart = 33
    case transitConnectionTransfer = 34
    case transitConnectionDestination = 35
    case postTransitConnectionDestination = 36

    var symbolName: String {
        switch self {
        case .startLeft, .destinationLeft, .slightLeft, .sharpLeft, .left, .rampLeft, .exitLeft, .stayLeft:
            "arrow.turn.up.left"
        case .startRight, .destinationRight, .slightRight, .sharpRight, .right, .rampRight, .exitRight, .stayRight:
            "arrow.turn.up.right"
        case .uTurnLeft:
            "arrow.uturn.left"
        case .uTurnRight:
            "arrow.uturn.right"
        case .roundaboutEnter, .roundaboutExit:
            "arrow.clockwise"
        case .merge:
            "arrow.merge"
        case .straight, .stayStraight, .rampStraight:
            "arrow.up"
        case .none, .start, .destination, .becomes, .ferryEnter, .ferryExit, .transit,
             .transitTransfer, .transitRemainOn, .transitConnectionStart,
             .transitConnectionTransfer, .transitConnectionDestination,
             .postTransitConnectionDestination:
            "arrow.up.right"
        }
    }

    var instructionTitle: String? {
        switch self {
        case .straight, .stayStraight: "Jedź prosto"
        case .slightRight: "Lekko skręć w prawo"
        case .right, .startRight, .destinationRight, .stayRight: "Skręć w prawo"
        case .sharpRight: "Skręć ostro w prawo"
        case .uTurnRight: "Zawróć w prawo"
        case .uTurnLeft: "Zawróć w lewo"
        case .sharpLeft: "Skręć ostro w lewo"
        case .left, .startLeft, .destinationLeft, .stayLeft: "Skręć w lewo"
        case .slightLeft: "Lekko skręć w lewo"
        case .exitRight: "Zjedź w prawo"
        case .exitLeft: "Zjedź w lewo"
        case .rampLeft: "Wjedź na zjazd w lewo"
        case .rampRight: "Wjedź na zjazd w prawo"
        case .merge: "Włącz się do ruchu"
        case .roundaboutEnter: "Wjedź na rondo"
        case .roundaboutExit: "Zjedź z ronda"
        default: nil
        }
    }

    var isExit: Bool {
        switch self {
        case .rampStraight, .rampRight, .rampLeft, .exitRight, .exitLeft: true
        default: false
        }
    }

    var isRoundabout: Bool { self == .roundaboutEnter || self == .roundaboutExit }
}

struct Maneuver: Identifiable {
    var id: Int { shapeIndex }
    var shapeIndex: Int
    var instruction: String
    var type: Int
    var streetNames: [String] = []
    var lanes: [TurnLaneGuidance] = []
    var exitNumber: String?
    var exitRoad: String?
    var exitToward: String?

    var kind: ManeuverKind { ManeuverKind(rawValue: type) ?? .none }
    var iconName: String { kind.symbolName }
    var displayInstruction: String { kind.instructionTitle ?? instruction }
    var streetName: String? { streetNames.first(where: { !$0.isEmpty }) }
    var streetLine: String? {
        guard kind.instructionTitle != nil, let streetName else { return nil }
        return "w \(streetName)"
    }
    var spokenInstruction: String {
        guard let streetLine else { return displayInstruction }
        return "\(displayInstruction) \(streetLine)"
    }
}

struct TurnLaneGuidance: Identifiable {
    var id: Int
    var indications: [String]
    var valid: Bool
}

struct NavigationRoute: Identifiable {
    var id = UUID()
    var coordinates: [Coordinate]
    var distance: Double
    var expectedTravelTime: TimeInterval
    var maneuvers: [Maneuver]
    var journey: Journey?
    var chargingDuration: TimeInterval = 0
    var chargingStops: [EVChargingStop] = []
}

struct EVChargingStop: Identifiable {
    let id: String
    let destination: Destination
    let connectorTypes: [String]
    let maximumPowerKW: Double
    let estimatedChargingTime: TimeInterval
    let availabilityKnown: Bool
    let publicAccess: Bool?
}

enum TransportMode: String, CaseIterable, Identifiable {
    case car, walking, bicycle, transit, parkRide
    var id: Self { self }
    var title: String {
        switch self {
        case .car: "Samochód"
        case .walking: "Pieszo"
        case .bicycle: "Rower"
        case .transit: "Komunikacja"
        case .parkRide: "P+R"
        }
    }
    var symbol: String {
        switch self {
        case .car: "car.fill"
        case .walking: "figure.walk"
        case .bicycle: "bicycle"
        case .transit: "tram.fill"
        case .parkRide: "parkingsign.circle.fill"
        }
    }
    var valhallaCosting: String {
        switch self {
        case .car: "auto"
        case .walking: "pedestrian"
        case .bicycle: "bicycle"
        case .transit, .parkRide: ""
        }
    }
}

struct RoutingPreferences: Codable, Equatable {
    var avoidTolls = false
    var avoidHighways = false
    var avoidFerries = false
    var avoidUnpaved = false
    var evPlanningEnabled = false
    var evRangeKilometers: Double = 0
    var evBatteryPercent = 100
    var evConsumptionKWhPer100Km: Double = 18
    var evMaximumChargingPowerKW: Double = 150
    var evConnectorTypes: Set<String> = []

    var availableEVRangeKilometers: Double {
        evRangeKilometers * Double(max(0, min(100, evBatteryPercent))) / 100
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case avoidTolls, avoidHighways, avoidFerries, avoidUnpaved
        case evPlanningEnabled, evRangeKilometers, evBatteryPercent
        case evConsumptionKWhPer100Km, evMaximumChargingPowerKW, evConnectorTypes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        avoidTolls = try values.decodeIfPresent(Bool.self, forKey: .avoidTolls) ?? false
        avoidHighways = try values.decodeIfPresent(Bool.self, forKey: .avoidHighways) ?? false
        avoidFerries = try values.decodeIfPresent(Bool.self, forKey: .avoidFerries) ?? false
        avoidUnpaved = try values.decodeIfPresent(Bool.self, forKey: .avoidUnpaved) ?? false
        evPlanningEnabled = try values.decodeIfPresent(Bool.self, forKey: .evPlanningEnabled) ?? false
        evRangeKilometers = try values.decodeIfPresent(Double.self, forKey: .evRangeKilometers) ?? 0
        evBatteryPercent = try values.decodeIfPresent(Int.self, forKey: .evBatteryPercent) ?? 100
        evConsumptionKWhPer100Km = try values.decodeIfPresent(Double.self, forKey: .evConsumptionKWhPer100Km) ?? 18
        evMaximumChargingPowerKW = try values.decodeIfPresent(Double.self, forKey: .evMaximumChargingPowerKW) ?? 150
        evConnectorTypes = try values.decodeIfPresent(Set<String>.self, forKey: .evConnectorTypes) ?? []
    }
}

enum GPSQuality: Equatable {
    case noSignal, weak, predicted, good, excellent
    var title: String {
        switch self {
        case .noSignal: "Brak GPS"
        case .weak: "Słaby GPS"
        case .predicted: "Pozycja przewidywana"
        case .good: "GPS dobry"
        case .excellent: "GPS bardzo dobry"
        }
    }
    var symbol: String {
        switch self {
        case .noSignal: "location.slash"
        case .weak: "location.circle"
        case .predicted: "location.north.circle"
        case .good: "location.circle.fill"
        case .excellent: "location.circle.fill"
        }
    }
}

enum TransitRealtimeFreshness: String, Sendable {
    case live, degraded, stale, unavailable
}

struct Journey {
    var departure: Date
    var arrival: Date
    var legs: [JourneyLeg]
    var scheduleIsCached = false
    var realtimeFeedAvailable = false
    var realtimeFeedUpdatedAt: Date?
    var alertsFeedAvailable = false
    var alerts: [String] = []
    var walkingDuration: TimeInterval = 0
    var waitingDuration: TimeInterval = 0
    var transferCount: Int = 0
    var realtimeFreshness: TransitRealtimeFreshness = .unavailable
}

struct JourneyLeg: Identifiable {
    var id = UUID()
    var mode: String
    var line: String?
    var from: String
    var to: String
    var departure: Date
    var arrival: Date
    var realTime: Bool
    var delaySeconds: Int? = nil
    var coordinates: [Coordinate]
    var routeID: String? = nil
    var tripID: String? = nil
    var serviceDate: String? = nil
    var lineColorHex: UInt32? = nil
    var transitStops: [TransitJourneyStop] = []
    var isTransfer = false
    var minimumTransferTime: TimeInterval = 0
}

struct TransitJourneyStop: Identifiable, Equatable, Sendable {
    let id: String
    let stopID: String
    let name: String
    let coordinate: Coordinate
    let arrival: Date
    let departure: Date
    let delaySeconds: Int?
    let hasRealtime: Bool
    let sequence: Int
}

struct TransitNavigationProgress: Equatable, Sendable {
    var legIndex: Int
    var legFraction: Double
    var routeFraction: Double
    var legDistance: Double
    var distanceToLegEnd: Double
    var distanceFromRoute: Double
    var nextStop: TransitJourneyStop?
    var distanceToNextStop: Double?
    var stopsUntilAlighting: Int?
    var isOnVehicle = false
}

struct TransitStop: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String?
    let coordinate: Coordinate
    let isMajor: Bool
    let lineIDs: [String]
    let lines: [String]
}

struct TransitDeparture: Identifiable, Equatable, Sendable {
    let id: String
    let stopID: String
    let routeID: String
    let tripID: String
    let line: String
    let mode: String
    let destination: String
    let scheduledDeparture: Date
    let estimatedDeparture: Date
    let delaySeconds: Int?
    let hasRealtime: Bool
    let colorHex: UInt32
    let stopSequence: Int
    let serviceDate: String
}

struct TransitLineSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mode: String
    let directions: String
    let colorHex: UInt32
}

struct TransitSearchResults: Sendable {
    let stops: [TransitStop]
    let lines: [TransitLineSearchResult]
}

struct TransitLineDetails: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mode: String
    let directions: String
    let colorHex: UInt32
    let stops: [TransitStop]
    let coordinates: [Coordinate]
}

struct TransitTripDetails: Equatable, Sendable {
    let tripID: String
    let line: String
    let mode: String
    let destination: String
    let currentStopName: String?
    let currentStopID: String?
    let pastStops: [TransitJourneyStop]
    let nextStops: [TransitJourneyStop]
    let vehicle: TransitVehicle?
    let activeAlert: String?
    let colorHex: UInt32
    let coordinates: [Coordinate]
}

struct TransitVehicle: Identifiable, Equatable, Sendable {
    let id: String
    let line: String
    let mode: String
    let routeID: String
    let tripID: String?
    let destination: String?
    let coordinate: Coordinate
    let bearing: Double?
    let updatedAt: Date
    let delaySeconds: Int?
    let colorHex: UInt32
}

struct TransitVehicleFeed: Sendable {
    let vehicles: [TransitVehicle]
    let updatedAt: Date?
    var stops: [TransitStop] = []
    var nearbyStop: TransitStop? = nil
    var nearbyDepartures: [TransitDeparture] = []
}

enum RouteColorPalette {
    static let activeLight: UInt32 = 0x248BFF
    static let activeDark: UInt32 = 0x2E95FF
    static let casingLight: UInt32 = 0x0B3158
    static let casingDark: UInt32 = 0x071C31
    static let alternativeLight: UInt32 = 0x8C99A8
    static let alternativeDark: UInt32 = 0x687483
    static let traveled: UInt32 = 0x485563
    static let walking: UInt32 = 0x718EFF
    static let cycling: UInt32 = 0x21B89A
    static let trafficFree: UInt32 = 0x27C46B
    static let trafficModerate: UInt32 = 0xF4C542
    static let trafficSlow: UInt32 = 0xFF8A34
    static let trafficHeavy: UInt32 = 0xF04444
    static let trafficStationary: UInt32 = 0xA92939
    static let closure: UInt32 = 0xE63946
}

struct RouteLegGeometry {
    let targetID: UUID?
    let active: [Coordinate]
    let continuation: [Coordinate]
}

enum RouteMapGeometry {
    static func activeLeg(in route: [Coordinate], from position: Coordinate?, through stops: [Destination]) -> RouteLegGeometry {
        guard route.count > 1 else {
            return RouteLegGeometry(targetID: nil, active: route, continuation: [])
        }
        guard !stops.isEmpty else {
            return RouteLegGeometry(targetID: nil, active: route, continuation: [])
        }

        let currentDistance = position.flatMap { MapMatcher.project($0, onto: route)?.alongRoute } ?? 0
        let nextStop = stops
            .compactMap { stop -> (Destination, RouteProjection)? in
                guard let projection = MapMatcher.project(stop.coordinate, onto: route),
                      projection.distanceFromRoute <= 1_000,
                      projection.alongRoute > currentDistance + 30 else { return nil }
                return (stop, projection)
            }
            .min { $0.1.alongRoute < $1.1.alongRoute }

        guard let (stop, projection) = nextStop else {
            return RouteLegGeometry(targetID: nil, active: route, continuation: [])
        }

        let segment = min(projection.segment, route.count - 2)
        var active = Array(route.prefix(segment + 1))
        if active.last?.distance(to: projection.coordinate) ?? .infinity > 0.5 {
            active.append(projection.coordinate)
        }

        var continuation = [projection.coordinate]
        for coordinate in route.dropFirst(segment + 1) {
            if continuation.last?.distance(to: coordinate) ?? .infinity > 0.5 {
                continuation.append(coordinate)
            }
        }

        return RouteLegGeometry(targetID: stop.id, active: active, continuation: continuation)
    }

    static func dashedSegments(_ coordinates: [Coordinate], dashLength: Double = 18, gapLength: Double = 10) -> [[Coordinate]] {
        guard coordinates.count > 1 else { return [] }
        var segments: [[Coordinate]] = []
        var current: [Coordinate] = []
        var drawing = true
        var remaining = dashLength

        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let length = start.distance(to: end)
            guard length > 0 else { continue }
            var consumed = 0.0

            while consumed < length {
                let step = min(remaining, length - consumed)
                let from = interpolate(start, end, fraction: consumed / length)
                let to = interpolate(start, end, fraction: (consumed + step) / length)
                if drawing {
                    if current.isEmpty {
                        current.append(from)
                    } else if current.last!.distance(to: from) > 0.5 {
                        current.append(from)
                    }
                    current.append(to)
                }

                consumed += step
                remaining -= step
                if remaining <= 0.0001 {
                    if drawing, current.count > 1 { segments.append(current) }
                    if drawing { current = [] }
                    drawing.toggle()
                    remaining = drawing ? dashLength : gapLength
                }
            }
        }

        if drawing, current.count > 1 { segments.append(current) }
        return segments
    }

    private static func interpolate(_ start: Coordinate, _ end: Coordinate, fraction: Double) -> Coordinate {
        Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                   longitude: start.longitude + (end.longitude - start.longitude) * fraction)
    }
}

struct RouteProgress {
    var traveledDistance: Double
    var remainingDistance: Double
    var remainingTime: TimeInterval
    var distanceToNextManeuver: Double
    var nextManeuver: Maneuver?
}

enum NavigationStatus: Equatable { case idle, destinationPreview, routeCalculating, routePreview, navigating, rerouting, arrived, error }

protocol RouteProvider {
    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute]
}

protocol AdvancedRouteProvider: RouteProvider {
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute]
    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int]
}
