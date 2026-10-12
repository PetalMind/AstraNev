import Foundation
import CoreLocation
import MapKit

nonisolated enum ValhallaVehicle: String, Codable, CaseIterable, Identifiable {
    case auto, motorcycle, motorScooter = "motor_scooter", truck, bus, taxi
    var id: Self { self }
    var title: String {
        switch self {
        case .auto: "Samochód"
        case .motorcycle: "Motocykl"
        case .motorScooter: "Skuter / motorower"
        case .truck: "Ciężarówka"
        case .bus: "Autobus"
        case .taxi: "Taksówka"
        }
    }
}

nonisolated enum ValhallaWalkingProfile: String, Codable, CaseIterable, Identifiable {
    case foot, wheelchair, blind
    var id: Self { self }
    var title: String {
        switch self {
        case .foot: "Pieszo"
        case .wheelchair: "Wózek"
        case .blind: "Osoba niewidoma"
        }
    }
}

nonisolated enum ValhallaBicycle: String, Codable, CaseIterable, Identifiable {
    case road, hybrid, cross, mountain
    var id: Self { self }
    var title: String {
        switch self {
        case .road: "Szosowy"
        case .hybrid: "Miejski / trekkingowy"
        case .cross: "Gravel / przełajowy"
        case .mountain: "Górski"
        }
    }
}

nonisolated enum ValhallaArrivalSide: String, Codable, CaseIterable, Identifiable {
    case either, same, opposite
    var id: Self { self }
    var title: String {
        switch self {
        case .either: "Dowolna strona"
        case .same: "Po stronie ruchu"
        case .opposite: "Po przeciwnej stronie"
        }
    }
}

nonisolated struct ValhallaAvoidArea: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var vertices: [Coordinate]

    var isValid: Bool {
        guard (3...32).contains(vertices.count), Set(vertices.map { "\($0.latitude):\($0.longitude)" }).count == vertices.count,
              vertices.allSatisfy(\.isValidValhallaCoordinate) else { return false }
        // Reject crossing rings and degenerate polygons instead of sending ambiguous exclusions.
        let points = vertices + [vertices[0]]
        let area = zip(points, points.dropFirst()).reduce(0.0) {
            $0 + $1.0.longitude * $1.1.latitude - $1.1.longitude * $1.0.latitude
        }
        guard abs(area) > 1e-10 else { return false }
        func orientation(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate) -> Double {
            (b.longitude - a.longitude) * (c.latitude - a.latitude)
                - (b.latitude - a.latitude) * (c.longitude - a.longitude)
        }
        for i in vertices.indices {
            for j in vertices.indices where j > i + 1 && !(i == 0 && j == vertices.count - 1) {
                let a = points[i], b = points[i + 1], c = points[j], d = points[j + 1]
                let abC = orientation(a, b, c), abD = orientation(a, b, d)
                let cdA = orientation(c, d, a), cdB = orientation(c, d, b)
                if abC * abD <= 0 && cdA * cdB <= 0 { return false }
            }
        }
        return true
    }

    var closedRing: [[Double]] {
        guard let first = vertices.first else { return [] }
        return (vertices + [first]).map { [$0.longitude, $0.latitude] }
    }
}

nonisolated struct ValhallaRoutingOptions: Codable, Equatable {
    var vehicle: ValhallaVehicle = .auto
    var walkingProfile: ValhallaWalkingProfile = .foot
    var bicycle: ValhallaBicycle = .hybrid
    var walkingSpeed = 5.1
    var wheelchairSpeed = 4.0
    var cyclingSpeed = 18.0
    var useHills = 0.25
    var walkingUseHills = 0.5
    var useRoads = 0.5
    var preferLit = false
    var hikingDifficulty = 1
    var truckHeight = 4.11
    var truckWidth = 2.6
    var truckLength = 21.64
    var truckWeight = 21.77
    var truckAxleLoad = 9.07
    var truckHazmat = false
    var scooterTopSpeed = 45.0
    var shortest = false
    var routePreference: RoutePreference = .fastest

    var effectiveRoutePreference: RoutePreference { shortest ? .shortest : routePreference }
    var arrivalSide: ValhallaArrivalSide = .either
    var avoidAreas: [ValhallaAvoidArea] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case vehicle, walkingProfile, bicycle, walkingSpeed, wheelchairSpeed, cyclingSpeed, useHills, walkingUseHills, useRoads, preferLit, hikingDifficulty, truckHeight, truckWidth, truckLength, truckWeight, truckAxleLoad, truckHazmat, scooterTopSpeed, shortest, routePreference, arrivalSide, avoidAreas
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vehicle = try values.decodeIfPresent(ValhallaVehicle.self, forKey: .vehicle) ?? vehicle
        walkingProfile = try values.decodeIfPresent(ValhallaWalkingProfile.self, forKey: .walkingProfile) ?? walkingProfile
        bicycle = try values.decodeIfPresent(ValhallaBicycle.self, forKey: .bicycle) ?? bicycle
        walkingSpeed = try values.decodeIfPresent(Double.self, forKey: .walkingSpeed) ?? walkingSpeed
        wheelchairSpeed = try values.decodeIfPresent(Double.self, forKey: .wheelchairSpeed) ?? wheelchairSpeed
        cyclingSpeed = try values.decodeIfPresent(Double.self, forKey: .cyclingSpeed) ?? cyclingSpeed
        useHills = try values.decodeIfPresent(Double.self, forKey: .useHills) ?? useHills
        walkingUseHills = try values.decodeIfPresent(Double.self, forKey: .walkingUseHills) ?? walkingUseHills
        useRoads = try values.decodeIfPresent(Double.self, forKey: .useRoads) ?? useRoads
        preferLit = try values.decodeIfPresent(Bool.self, forKey: .preferLit) ?? preferLit
        hikingDifficulty = try values.decodeIfPresent(Int.self, forKey: .hikingDifficulty) ?? hikingDifficulty
        truckHeight = try values.decodeIfPresent(Double.self, forKey: .truckHeight) ?? truckHeight
        truckWidth = try values.decodeIfPresent(Double.self, forKey: .truckWidth) ?? truckWidth
        truckLength = try values.decodeIfPresent(Double.self, forKey: .truckLength) ?? truckLength
        truckWeight = try values.decodeIfPresent(Double.self, forKey: .truckWeight) ?? truckWeight
        truckAxleLoad = try values.decodeIfPresent(Double.self, forKey: .truckAxleLoad) ?? truckAxleLoad
        truckHazmat = try values.decodeIfPresent(Bool.self, forKey: .truckHazmat) ?? truckHazmat
        scooterTopSpeed = try values.decodeIfPresent(Double.self, forKey: .scooterTopSpeed) ?? scooterTopSpeed
        shortest = try values.decodeIfPresent(Bool.self, forKey: .shortest) ?? shortest
        routePreference = try values.decodeIfPresent(RoutePreference.self, forKey: .routePreference) ?? routePreference
        arrivalSide = try values.decodeIfPresent(ValhallaArrivalSide.self, forKey: .arrivalSide) ?? arrivalSide
        avoidAreas = try values.decodeIfPresent([ValhallaAvoidArea].self, forKey: .avoidAreas) ?? avoidAreas
    }

    func costing(for mode: TransportMode) -> String {
        switch mode {
        case .car: vehicle.rawValue
        case .walking: "pedestrian"
        case .bicycle: "bicycle"
        case .parkRide: "auto"
        case .transit: "multimodal"
        }
    }
}

nonisolated extension Coordinate {
    var isValidValhallaCoordinate: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

nonisolated enum ValhallaFeatureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

nonisolated struct ValhallaPlanningTime: Sendable {
    var type: Int
    var value: String?

    @MainActor static func resolved(mode: JourneyTimeMode, date: Date, coordinate: Coordinate) async throws -> Self {
        guard mode != .now else { return Self(type: 0) }
        #if os(iOS)
        if OfflineRoutingStore.shared.preferOffline || OfflineRoutingStore.shared.networkUnavailable {
            throw ValhallaFeatureError.message("Planowanie na wskazaną godzinę wymaga ustalenia strefy czasowej przez internet. Dla trasy offline wybierz wyjazd teraz.")
        }
        #endif
        guard let request = MKReverseGeocodingRequest(location:
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) else {
            throw ValhallaFeatureError.message("Nie udało się ustalić strefy czasowej podróży.")
        }
        let places = try await request.mapItems
        try RoadRoutingContext.checkCancellation()
        guard let zone = places.first?.timeZone else {
            throw ValhallaFeatureError.message("Nie udało się ustalić strefy czasowej planowanej podróży. Spróbuj ponownie lub wybierz wyjazd teraz.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return Self(type: mode == .arriveBy ? 2 : 1, value: formatter.string(from: date))
    }

    var payload: [String: Any] {
        var result: [String: Any] = ["type": type]
        if let value { result["value"] = value }
        return result
    }
}

extension RoutingPreferences {
    /// Shared by normal, alternative, optimized, EV and reroute requests.
    func applyValhallaOptions(to payload: inout [String: Any], mode: TransportMode) throws {
        let profile = advanced
        let costing = profile.costing(for: mode)
        payload["costing"] = costing
        var options: [String: Any] = [:]
        func validated(_ value: Double, _ range: ClosedRange<Double>, _ title: String) throws -> Double {
            guard value.isFinite, range.contains(value) else {
                throw ValhallaFeatureError.message("\(title): podaj wartość od \(range.lowerBound) do \(range.upperBound).")
            }
            return value
        }
        if mode == .car || mode == .parkRide {
            if mode == .car, evPlanningEnabled, profile.vehicle != .auto {
                throw ValhallaFeatureError.message("Planowanie ładowania EV jest dostępne dla profilu samochodu. Wyłącz EV albo wybierz samochód.")
            }
            options = ["maneuver_penalty": 12.0, "use_highways": avoidHighways ? 0.0 : 1.0,
                       "use_living_streets": 0.0, "service_penalty": 30.0]
            if avoidTolls { options["use_tolls"] = 0.0 }
            if avoidHighways { options["use_highways"] = 0.0 }
            if avoidFerries { options["use_ferry"] = 0.0 }
            if avoidUnpaved { options["exclude_unpaved"] = true }
            if costing == "truck" {
                options["height"] = try validated(profile.truckHeight, 0.1...10, "Wysokość (m)")
                options["width"] = try validated(profile.truckWidth, 0.1...10, "Szerokość (m)")
                options["length"] = try validated(profile.truckLength, 0.1...50, "Długość (m)")
                options["weight"] = try validated(profile.truckWeight, 0.1...100, "Masa (t)")
                options["axle_load"] = try validated(profile.truckAxleLoad, 0.1...40, "Nacisk osi (t)")
                options["hazmat"] = profile.truckHazmat
            }
            if costing == "motor_scooter" {
                // Scooter supports its own road preference; don't send inherited highway bias.
                options.removeValue(forKey: "use_highways")
                options["top_speed"] = try validated(profile.scooterTopSpeed, 20...120, "Prędkość skutera")
            }
        } else if mode == .walking {
            options["type"] = profile.walkingProfile.rawValue
            options["walking_speed"] = try validated(profile.walkingProfile == .wheelchair
                ? profile.wheelchairSpeed : profile.walkingSpeed, 0.5...25, "Tempo (km/h)")
            options["use_hills"] = try validated(profile.walkingUseHills, 0...1, "Preferencja podjazdów")
            options["use_lit"] = profile.preferLit ? 1.0 : 0.0
            options["max_hiking_difficulty"] = profile.hikingDifficulty
            guard (0...6).contains(profile.hikingDifficulty) else { throw RoutingError.invalidResponse }
        } else if mode == .bicycle {
            options["bicycle_type"] = profile.bicycle.rawValue
            options["cycling_speed"] = try validated(profile.cyclingSpeed, 5...60, "Tempo roweru (km/h)")
            options["use_hills"] = try validated(profile.useHills, 0...1, "Preferencja podjazdów")
            options["use_roads"] = try validated(profile.useRoads, 0...1, "Preferencja jezdni")
        }
        options["shortest"] = profile.effectiveRoutePreference == .shortest
        payload["costing_options"] = [costing: options]
        if payload["locations"] != nil {
            var locations = payload["locations"] as? [[String: Any]] ?? []
            if !locations.isEmpty {
                locations[locations.count - 1]["preferred_side"] = profile.arrivalSide.rawValue
                payload["locations"] = locations
            }
        }
        guard profile.avoidAreas.count <= 8, profile.avoidAreas.allSatisfy(\.isValid) else {
            throw ValhallaFeatureError.message("Obszary omijane muszą mieć 3–32 wierzchołki bez przecięć. Maksymalnie 8 obszarów.")
        }
        let polygons = profile.avoidAreas.map(\.closedRing) + RoadRoutingContext.closurePolygons
        if !polygons.isEmpty { payload["exclude_polygons"] = polygons }
        payload["date_time"] = (RoadRoutingContext.planningTime ?? ValhallaPlanningTime(type: 0)).payload
    }
}
