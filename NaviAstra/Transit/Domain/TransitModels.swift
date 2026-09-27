import CoreGraphics
import Foundation

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
    var frequencyEstimateHeadwaySeconds: Int? = nil
    var railwayScheduleAttribution: String? = nil
    var originAccessStopID: String? = nil
    var destinationAccessStopID: String? = nil
    var sourceID: String? = nil
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
    var walkingDuration: TimeInterval? = nil
    var scheduleShiftSeconds: Int = 0
    var frequencyStartSeconds: Int? = nil
    var frequencyHeadwaySeconds: Int? = nil
    var isFrequencyEstimate = false
    var hasResolvedWalkingGeometry = false
    var walkingTimeIsApproximate = false
    var scheduledDeparture: Date? = nil
    var scheduledArrival: Date? = nil
    var direction: String? = nil
    var operatorName: String? = nil
    var distance: Double? = nil
    var isInterlined = false

    var plannedWalkingDuration: TimeInterval {
        walkingDuration ?? max(0, arrival.timeIntervalSince(departure) - minimumTransferTime)
    }
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
    var isSkipped = false
    var scheduledArrival: Date? = nil
    var scheduledDeparture: Date? = nil
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
    var routeProjection: RouteProjection? = nil
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
    let isPlanningCarRoute: Bool
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
        guard !isPlanningCarRoute else { return nil }

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
    var scheduleShiftSeconds: Int = 0
    var frequencyStartSeconds: Int? = nil
    var frequencyHeadwaySeconds: Int? = nil
    var isFrequencyEstimate: Bool = false
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
    var frequencyHeadwaySeconds: Int? = nil
    var isFrequencyEstimate = false
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
