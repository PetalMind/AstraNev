import Foundation

/// Visual preferences only. A model never selects a routing profile.
enum NavigationMarkerModel: String, CaseIterable, Codable, Identifiable {
    case compact, sedan, suv, estate, cityBike, roadBike, pedestrian, bus, tram, train, ferry
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Kompakt"
        case .sedan: "Sedan"
        case .suv: "SUV"
        case .estate: "Kombi"
        case .cityBike: "Rower"
        case .roadBike: "Rower sportowy"
        case .pedestrian: "Pieszy"
        case .bus: "Autobus"
        case .tram: "Tramwaj"
        case .train: "Pociąg"
        case .ferry: "Prom"
        }
    }
    var transportIcon: NavigationPositionIcon {
        switch self {
        case .compact, .sedan, .suv, .estate: .car
        case .cityBike, .roadBike: .bicycle
        case .pedestrian: .pedestrian
        case .bus: .bus
        case .tram: .tram
        case .train: .train
        case .ferry: .ferry
        }
    }
    static let cars: [Self] = [.compact, .sedan, .suv]
    static let bicycles: [Self] = [.cityBike]
}

enum NavigationMarkerPaint: String, CaseIterable, Codable, Identifiable {
    case pearl, graphite, silver, blue, violet, coral
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pearl: "Biały"
        case .graphite: "Czarny"
        case .silver: "Srebrny"
        case .blue: "Niebieski"
        case .violet: "Fioletowy"
        case .coral: "Czerwony"
        }
    }
    var hex: UInt32 {
        switch self {
        case .pearl: 0xE5E9EF
        case .graphite: 0x242B35
        case .silver: 0xACBACB
        case .blue: 0x387CEB
        case .violet: 0x9854DE
        case .coral: 0xC64242
        }
    }
}

enum NavigationMarkerSize: String, CaseIterable, Codable, Identifiable {
    case standard, large
    var id: String { rawValue }
    var title: String { self == .standard ? "Standardowa" : "Większa" }
    var scale: Double { self == .standard ? 1 : 1.22 }
}

struct NavigationMarkerAppearance: Codable, Equatable {
    var car: NavigationMarkerModel = .compact
    var bicycle: NavigationMarkerModel = .cityBike
    var carPaint: NavigationMarkerPaint = .blue
    var bicyclePaint: NavigationMarkerPaint = .violet
    var pedestrianPaint: NavigationMarkerPaint = .blue
    var arrowPaint: NavigationMarkerPaint = .blue
    var size: NavigationMarkerSize = .standard

    init() {}

    private enum CodingKeys: String, CodingKey {
        case car, bicycle, carPaint, bicyclePaint, pedestrianPaint, arrowPaint, size
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        car = try values.decodeIfPresent(NavigationMarkerModel.self, forKey: .car) ?? .compact
        bicycle = try values.decodeIfPresent(NavigationMarkerModel.self, forKey: .bicycle) ?? .cityBike
        carPaint = try values.decodeIfPresent(NavigationMarkerPaint.self, forKey: .carPaint) ?? .blue
        bicyclePaint = try values.decodeIfPresent(NavigationMarkerPaint.self, forKey: .bicyclePaint) ?? .violet
        pedestrianPaint = try values.decodeIfPresent(NavigationMarkerPaint.self, forKey: .pedestrianPaint) ?? .blue
        // Older saved preferences have no arrow color; preserve their other selections.
        arrowPaint = try values.decodeIfPresent(NavigationMarkerPaint.self, forKey: .arrowPaint) ?? .blue
        size = try values.decodeIfPresent(NavigationMarkerSize.self, forKey: .size) ?? .standard
    }

    func model(for icon: NavigationPositionIcon) -> NavigationMarkerModel {
        switch icon {
        // Retain all other preferences from the first catalog when replacing its older models.
        case .car: Self.validated(car == .estate ? .sedan : car,
                                 allowed: NavigationMarkerModel.cars, fallback: .compact)
        case .bicycle: .cityBike
        case .pedestrian: .pedestrian
        case .bus: .bus
        case .tram: .tram
        case .train: .train
        case .ferry: .ferry
        }
    }

    func paint(for icon: NavigationPositionIcon) -> NavigationMarkerPaint {
        switch icon {
        case .car: carPaint
        case .bicycle: bicyclePaint
        case .pedestrian: pedestrianPaint
        case .bus, .tram, .train, .ferry: .blue
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "navigationMarkerAppearance"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    private static func validated(_ value: NavigationMarkerModel,
                                  allowed: [NavigationMarkerModel], fallback: NavigationMarkerModel) -> NavigationMarkerModel {
        allowed.contains(value) ? value : fallback
    }
}

/// A renderer snapshot, independent of routing, progress, arrival and camera planning.
struct NavigationMarkerPresentation {
    var model: NavigationMarkerModel?
    var paint: NavigationMarkerPaint = .blue
    var scale: Double = 1
    var bearing: Double?
    var direction: Double?
    var deviceHeading: Double?
    var pitch: Double = 0
    var night = false
    var increasedContrast = false
    var compact = false
    var detailZoom: Double?
    var quality: GPSQuality = .excellent

    @MainActor
    static func resolve(state: NavigationState, settings: MapSettings, bearing: Double?,
                        cameraHeading: Double, pitch: Double, zoom: Double,
                        night: Bool, increasedContrast: Bool) -> Self {
        let active = state.status == .navigating || state.status == .rerouting
        let icon = NavigationPositionIcon.current(in: state, enabled: settings.transportPositionIconsEnabled)
        let age = state.location.map { max(0, Date().timeIntervalSince($0.timestamp)) } ?? .infinity
        // Do not present an old course as a current direction. Offline connectivity is unrelated.
        let reliableDirection = active && age < 5 && state.gpsQuality != .noSignal
        let appearance = settings.markerAppearance
        var result = Self()
        result.model = icon.map { appearance.model(for: $0) }
        result.paint = icon.map { appearance.paint(for: $0) } ?? appearance.arrowPaint
        result.scale = appearance.size.scale
        result.bearing = active ? bearing.map { $0 - cameraHeading } : nil
        result.direction = reliableDirection ? result.bearing : nil
        if icon == .pedestrian, reliableDirection, let heading = state.deviceHeading {
            result.deviceHeading = heading - cameraHeading
        }
        result.pitch = max(0, min(60, pitch))
        result.night = night
        result.increasedContrast = increasedContrast
        result.compact = !active
        result.detailZoom = active ? zoom : nil
        result.quality = age > 30 ? .noSignal : (age > 5 ? .predicted : state.gpsQuality)
        return result
    }

    var accessibilityLabel: String {
        let name = model.map { " · \($0.transportIcon.title)" } ?? ""
        let signal = quality == .good || quality == .excellent ? "" : " · \(quality.title)"
        return "Twoja pozycja\(name)\(signal)"
    }
}
