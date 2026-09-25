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
}

nonisolated struct NavigationLocation {
    var coordinate: Coordinate
    var speed: CLLocationSpeed
    var course: CLLocationDirection
    var accuracy: CLLocationAccuracy
    var timestamp: Date
}

enum ManeuverKind: Int, Sendable {
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

struct Maneuver: Identifiable, Sendable {
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

struct TurnLaneGuidance: Identifiable, Sendable {
    var id: Int
    var indications: [String]
    var valid: Bool
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

enum TransportMode: String, CaseIterable, Identifiable {
    case car, walking, bicycle, transit, parkRide
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

enum TransitRealtimeFreshness: String, Equatable, Sendable {
    case live, degraded, stale, unavailable
}

struct Journey: Sendable {
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
    var railwayScheduleAttribution: String? = nil
}

struct JourneyLeg: Identifiable, Sendable {
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
    var hasResolvedWalkingGeometry = false
    var walkingTimeIsApproximate = false
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

nonisolated enum TransitStopMode: String, CaseIterable, Hashable, Sendable {
    case rail
    case tram
    case bus

    var symbolName: String {
        switch self {
        case .rail: "train.side.front.car"
        case .tram: "tram.fill"
        case .bus: "bus.fill"
        }
    }

    var title: String {
        switch self {
        case .rail: "Kolej"
        case .tram: "Tramwaj"
        case .bus: "Autobus"
        }
    }

    var accentHex: UInt32 {
        switch self {
        case .rail: 0x263B70
        case .tram: 0xD83B43
        case .bus: 0x2878D0
        }
    }
}

nonisolated enum TransitStopImportance: Int, Comparable, Sendable {
    case bus
    case tram
    case busMajor
    case tramMajor
    case railStation
    case interchange
    case regionalHub
    case nationalHub

    static func < (lhs: TransitStopImportance, rhs: TransitStopImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TransitStop: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String?
    let coordinate: Coordinate
    let isMajor: Bool
    let lineIDs: [String]
    let lines: [String]
    var modes: Set<TransitStopMode> = []
    var stationID: String? = nil
    var stationName: String? = nil
    var stationCoordinate: Coordinate? = nil
    var memberStopIDs: [String] = []

    var mapGroupID: String {
        guard let stationID else { return id }
        if let stationCoordinate, coordinate.distance(to: stationCoordinate) > 350 { return id }
        return stationID
    }

    var mapStationNameKey: String {
        (stationName ?? name)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var detailStopIDs: [String] { memberStopIDs.isEmpty ? [id] : memberStopIDs }

    var mapModes: [TransitStopMode] {
        if !modes.isEmpty { return TransitStopMode.allCases.filter(modes.contains) }
        return id.hasPrefix("rail/") ? [.rail] : [.bus]
    }

    var isRailway: Bool { mapModes.contains(.rail) }
    var isMultimodal: Bool { mapModes.count > 1 }

    // Loaded GTFS feeds expose station type, served modes and route count, but no national hub rank.
    var mapImportance: TransitStopImportance {
        if isMultimodal { return isMajor ? .regionalHub : .interchange }
        if isRailway { return isMajor ? .regionalHub : .railStation }
        if mapModes.contains(.tram) { return isMajor ? .tramMajor : .tram }
        return isMajor ? .busMajor : .bus
    }

    var isMajorRailStation: Bool { isRailway && isMajor }
    var isTransitHub: Bool {
        mapImportance == .nationalHub || mapImportance == .regionalHub || mapImportance == .interchange
    }
    var isLargeTransitNode: Bool {
        isTransitHub || isMajorRailStation || mapImportance == .tramMajor || mapImportance == .busMajor
    }
    var isImportantNearbyAlternative: Bool {
        isLargeTransitNode || isRailway
    }

    static func mapGroups(from candidates: [TransitStop]) -> [[TransitStop]] {
        var buckets: [String: [[TransitStop]]] = [:]
        for stop in candidates {
            let bucketID = stop.isMajor && !stop.mapStationNameKey.isEmpty
                ? "named:\(stop.mapStationNameKey)" : "group:\(stop.mapGroupID)"
            var groups = buckets[bucketID, default: []]
            let stopModes = Set(stop.mapModes)
            let coordinate = stop.stationCoordinate ?? stop.coordinate
            let groupIndex = groups.indices.first { index in
                let members = groups[index]
                let existingModes = members.reduce(into: Set<TransitStopMode>()) {
                    $0.formUnion($1.mapModes)
                }
                let sameStation = members.first { $0.mapGroupID == stop.mapGroupID }
                if let sameStation {
                    let distance = (sameStation.stationCoordinate ?? sameStation.coordinate).distance(to: coordinate)
                    if distance <= 8 { return true }
                    let combinedModes = existingModes.union(stopModes)
                    let addsMode = combinedModes.count > max(existingModes.count, stopModes.count)
                    if addsMode && distance <= 120 { return true }
                }
                let addsMode = !existingModes.isSuperset(of: stopModes)
                    && !stopModes.isSuperset(of: existingModes)
                guard addsMode else { return false }
                return members.contains {
                    $0.mapStationNameKey == stop.mapStationNameKey
                        && ($0.stationCoordinate ?? $0.coordinate).distance(to: coordinate) <= 120
                }
            }
            if let groupIndex {
                groups[groupIndex].append(stop)
            } else {
                groups.append([stop])
            }
            buckets[bucketID] = groups
        }
        return buckets.values.flatMap { $0 }
    }

    func shouldShowOnMap(zoom: Double) -> Bool {
        if zoom < 11 { return isMajorRailStation || mapImportance == .nationalHub }
        if zoom < 13 {
            return isMajorRailStation || isTransitHub || mapImportance == .busMajor
        }
        if zoom < 14.5 {
            return isRailway || isTransitHub || mapImportance == .tramMajor || mapImportance == .busMajor
        }
        if zoom < 16 { return isRailway || isTransitHub || mapModes.contains(.tram) || mapImportance == .busMajor }
        return true
    }

    var mapMarkerSize: CGFloat {
        if isRailway { return isMajor ? 36 : 32 }
        if mapModes.count > 1 { return 34 }
        if mapModes.contains(.tram) { return isMajor ? 30 : 27 }
        return isMajor ? 26 : 22
    }

    func mapGroup(members: [TransitStop]) -> TransitStop {
        let isStationGroup = stationID != nil && mapGroupID == stationID
        return TransitStop(id: id,
                           name: isStationGroup ? stationName ?? name : name,
                           address: address,
                           coordinate: isStationGroup ? stationCoordinate ?? coordinate : coordinate,
                           isMajor: members.contains(where: \.isMajor),
                           lineIDs: Array(Set(members.flatMap(\.lineIDs))).sorted(),
                           lines: Array(Set(members.flatMap(\.lines))).sorted(),
                           modes: members.reduce(into: Set<TransitStopMode>()) { $0.formUnion($1.mapModes) },
                           stationID: stationID,
                           stationName: isStationGroup ? stationName : nil,
                           stationCoordinate: isStationGroup ? stationCoordinate : nil,
                           memberStopIDs: Array(Set(members.flatMap(\.detailStopIDs))).sorted())
    }

    func mapPresentation(zoom: Double, selected: Bool, active: Bool, alighting: Bool,
                         onRoute: Bool = false, opacity: Double = 1) -> TransitStopMapPresentation {
        TransitStopMapPresentation(modes: mapModes,
                                   name: zoom > 17 || selected || active || alighting ? name : nil,
                                   markerSize: Double(mapMarkerSize),
                                   isSelected: selected, isActive: active, isAlighting: alighting,
                                   isOnRoute: onRoute, opacity: opacity,
                                   showsAlightingBadge: alighting)
    }
}

struct TransitStopMapVisibilityDecision: Equatable {
    let isOnRoute: Bool
    let opacity: Double
}

struct TransitStopMapVisibilityPolicy {
    let zoom: Double
    let transportMode: TransportMode
    let isNavigating: Bool
    let isTransitRoutePreview: Bool
    let visibleStopCount: Int
    let visibleRadius: Double
    let mapCenter: Coordinate
    let userCoordinate: Coordinate?
    let routeEndpointCoordinates: [Coordinate]
    let routeStopIDs: Set<String>

    func decision(for stop: TransitStop, selectedStopID: String?, activeStopID: String?,
                  alightingStopID: String?) -> TransitStopMapVisibilityDecision? {
        let memberIDs = Set(stop.detailStopIDs)
        let isSelected = selectedStopID.map(memberIDs.contains) ?? false
        let isActive = activeStopID.map(memberIDs.contains) ?? false
        let isAlighting = alightingStopID.map(memberIDs.contains) ?? false
        let isOnRoute = !memberIDs.isDisjoint(with: routeStopIDs)
        if isSelected || isActive || isAlighting {
            return TransitStopMapVisibilityDecision(isOnRoute: isOnRoute, opacity: 1)
        }

        let centerDistance = mapCenter.distance(to: stop.coordinate)
        let nearbyDistance = (userCoordinate ?? mapCenter).distance(to: stop.coordinate)
        let nearTransitEndpoint = routeEndpointCoordinates.contains { $0.distance(to: stop.coordinate) <= 600 }
        let hasContextualReach = isNavigating && (transportMode == .walking || transportMode == .transit)
            && nearbyDistance <= 600
        guard centerDistance <= visibleRadius || hasContextualReach
                || (isTransitRoutePreview && nearTransitEndpoint) else { return nil }

        if isNavigating {
            switch transportMode {
            case .car, .parkRide:
                guard stop.isLargeTransitNode else { return nil }
                return TransitStopMapVisibilityDecision(isOnRoute: false, opacity: 1)
            case .walking:
                guard nearbyDistance <= 600 else { return nil }
                return densityAllows(stop)
                    ? TransitStopMapVisibilityDecision(isOnRoute: false, opacity: 1) : nil
            case .transit:
                if isOnRoute { return TransitStopMapVisibilityDecision(isOnRoute: true, opacity: 1) }
                guard nearbyDistance <= 600, stop.isImportantNearbyAlternative else { return nil }
                return TransitStopMapVisibilityDecision(isOnRoute: false, opacity: 0.35)
            case .bicycle:
                return browseDecision(for: stop)
                    ? TransitStopMapVisibilityDecision(isOnRoute: false, opacity: 1) : nil
            }
        }

        if isTransitRoutePreview {
            if isOnRoute { return TransitStopMapVisibilityDecision(isOnRoute: true, opacity: 1) }
            if nearTransitEndpoint {
                guard visibleStopCount <= 80 || stop.isImportantNearbyAlternative else { return nil }
                return TransitStopMapVisibilityDecision(isOnRoute: false, opacity: 1)
            }
        }

        guard browseDecision(for: stop) else { return nil }
        return TransitStopMapVisibilityDecision(isOnRoute: isOnRoute, opacity: 1)
    }

    private func browseDecision(for stop: TransitStop) -> Bool {
        guard stop.shouldShowOnMap(zoom: zoom) else { return false }
        return densityAllows(stop)
    }

    private func densityAllows(_ stop: TransitStop) -> Bool {
        if visibleStopCount >= 120 { return stop.isTransitHub || stop.isMajorRailStation }
        if visibleStopCount >= 80 {
            return stop.isTransitHub || stop.isMajorRailStation || stop.mapImportance == .tramMajor
        }
        if visibleStopCount >= 50 {
            return stop.isTransitHub || stop.isRailway || stop.mapImportance == .tramMajor
                || stop.mapImportance == .busMajor
        }
        return true
    }
}

struct TransitStopMapPresentation: Equatable, Sendable {
    let modes: [TransitStopMode]
    let name: String?
    let markerSize: Double
    let isSelected: Bool
    let isActive: Bool
    let isAlighting: Bool
    let isOnRoute: Bool
    let opacity: Double
    let showsAlightingBadge: Bool

    var isMultimodal: Bool { modes.count > 1 }
    var accessibilityLabel: String {
        let modeNames = modes.map(\.title).joined(separator: ", ")
        let status = isAlighting ? ", przystanek wysiadania"
            : isActive ? ", następny przystanek"
            : isSelected ? ", wybrany przystanek"
            : isOnRoute ? ", na bieżącej trasie" : ""
        return "\(modeNames), \(name ?? "przystanek")\(status)"
    }
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
