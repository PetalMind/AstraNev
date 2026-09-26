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

struct WalkingRouteCost: Sendable {
    let duration: TimeInterval
    let distance: Double
    let coordinates: [Coordinate]?
}

struct Destination: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var coordinate: Coordinate
    var address: String? = nil
    var poi: POIMetadata? = nil
}

enum RoutePointSource: String, Codable, Equatable, Sendable {
    case currentLocation, search, mapSelection, poi, favorite, savedPlace, history
}

struct RoutePoint: Equatable, Sendable {
    var coordinate: Coordinate
    var name: String
    var address: String?
    var source: RoutePointSource
    var poi: POIMetadata?

    init(_ destination: Destination, source: RoutePointSource) {
        coordinate = destination.coordinate
        name = destination.name
        address = destination.address
        self.source = source
        poi = destination.poi
    }

    var destination: Destination {
        Destination(name: name, coordinate: coordinate, address: address, poi: poi)
    }

    var isCurrentLocation: Bool { source == .currentLocation }
}

struct RoutePlan: Equatable, Sendable {
    var origin: RoutePoint
    var destination: RoutePoint
}

struct POIMetadata: Codable, Equatable, Sendable {
    var provider: PlaceProvider
    var osmID: String?
    var category: String?
    var brand: String?
    var operatorName: String?
}

nonisolated struct NavigationLocation {
    var coordinate: Coordinate
    var speed: CLLocationSpeed
    var course: CLLocationDirection
    var accuracy: CLLocationAccuracy
    var timestamp: Date
    var speedAccuracy: CLLocationAccuracy = -1
    var courseAccuracy: CLLocationAccuracy = -1
}

struct NavigationRoute: Identifiable, Sendable {
    var id = UUID()
    var coordinates: [Coordinate]
    var distance: Double
    var expectedTravelTime: TimeInterval
    var maneuvers: [Maneuver]
    var journey: Journey?
    var chargingDuration: TimeInterval = 0
    var chargingStops: [EVChargingStop] = []
}

struct EVChargingStop: Identifiable, Sendable {
    let id: String
    let destination: Destination
    let connectorTypes: [String]
    let maximumPowerKW: Double
    let estimatedChargingTime: TimeInterval
    let availabilityKnown: Bool
    let publicAccess: Bool?
}

enum TransportMode: String, CaseIterable, Identifiable, Sendable {
    case car, walking, bicycle, transit, parkRide

    static var configuredDefault: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: "defaultTransportMode") else {
            return .car
        }
        return Self(rawValue: rawValue) ?? .car
    }

    var id: Self { self }
    var title: String {
        switch self {
        case .car: "Auto"
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

enum JourneyTimeMode: String, CaseIterable, Identifiable {
    case now
    case departAt
    case arriveBy

    var id: Self { self }

    var title: String {
        switch self {
        case .now: "Teraz"
        case .departAt: "Wyjazd o…"
        case .arriveBy: "Przyjazd na…"
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

nonisolated enum RouteColorPalette {
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
