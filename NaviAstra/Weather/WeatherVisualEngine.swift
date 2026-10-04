import Foundation

nonisolated enum WeatherCondition: String, Sendable {
    case clear, cloudy, rain, heavyRain, snow, heavySnow, fog, storm, unknown

    init(code: Int) {
        switch code {
        case 0, 1: self = .clear
        case 2, 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55, 56, 57, 61, 63, 66, 80, 81: self = .rain
        case 65, 67, 82: self = .heavyRain
        case 71, 73, 77, 85: self = .snow
        case 75, 86: self = .heavySnow
        case 95, 96, 99: self = .storm
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .clear: "Bezchmurnie"
        case .cloudy: "Pochmurno"
        case .rain: "Deszcz"
        case .heavyRain: "Intensywny deszcz"
        case .snow: "Śnieg"
        case .heavySnow: "Intensywny śnieg"
        case .fog: "Mgła"
        case .storm: "Burza"
        case .unknown: "Nieznane warunki"
        }
    }
    var symbol: String {
        switch self {
        case .clear: "sun.max"
        case .cloudy, .unknown: "cloud"
        case .rain, .heavyRain: "cloud.rain"
        case .snow, .heavySnow: "cloud.snow"
        case .fog: "cloud.fog"
        case .storm: "cloud.bolt.rain"
        }
    }
    var isHazard: Bool { ![.clear, .cloudy, .unknown].contains(self) }
    var colorHex: UInt32 {
        switch self {
        case .snow, .heavySnow: 0x94BEDF
        case .fog: 0xA5ACB4
        case .storm: 0x9884BA
        default: 0x568FC0
        }
    }
}

nonisolated struct WeatherVisualState: Equatable, Sendable {
    let condition: WeatherCondition
    let visibility: Double?
    let precipitation: Double
    let windSpeed: Double
    let windDirection: Double
    let isDaylight: Bool
    let date: Date
}

nonisolated enum WeatherEffectIntensity: String, CaseIterable, Identifiable {
    case subtle, normal, off
    var id: String { rawValue }
    var title: String {
        switch self { case .subtle: "Subtelna"; case .normal: "Normalna"; case .off: "Wyłączona" }
    }
}

nonisolated struct WeatherVisualConfiguration: Equatable {
    var rainIntensity = 0.0
    var snowIntensity = 0.0
    var fogDensity = 0.0
    var tintHex: UInt32 = 0
    var tintOpacity = 0.0
    var wind = 0.0
    var flashes = false
}

nonisolated enum WeatherVisualEngine {
    static func configuration(state: WeatherVisualState?, intensity: String,
                              animations: Bool, colors: Bool, duringNavigation: Bool,
                              navigating: Bool, reduceMotion: Bool) -> WeatherVisualConfiguration {
        guard let state, Date().timeIntervalSince(state.date) < 1800,
              intensity != WeatherEffectIntensity.off.rawValue,
              !navigating || duringNavigation else { return .init() }
        let scale = intensity == WeatherEffectIntensity.normal.rawValue ? 1.0 : 0.55
        var result = WeatherVisualConfiguration()
        switch state.condition {
        case .clear: result.tintHex = 0xFFD896; result.tintOpacity = 0.025
        case .cloudy: result.tintHex = 0x647889; result.tintOpacity = 0.045
        case .rain, .heavyRain, .storm:
            result.rainIntensity = state.condition == .rain ? 0.4 : 0.8
            result.tintHex = 0x26394C; result.tintOpacity = 0.085
            result.fogDensity = state.condition == .heavyRain ? 0.055 : 0
            result.flashes = state.condition == .storm && !navigating
        case .snow, .heavySnow:
            result.snowIntensity = state.condition == .snow ? 0.35 : 0.75
            result.tintHex = 0xC6D8E1; result.tintOpacity = 0.04
            result.fogDensity = state.condition == .heavySnow ? 0.09 : 0
        case .fog: result.fogDensity = 0.18; result.tintHex = 0xCFD7DC; result.tintOpacity = 0.07
        case .unknown: return .init()
        }
        if let visibility = state.visibility, visibility < 2000 {
            result.fogDensity = max(result.fogDensity, 0.18 * (1 - max(0, visibility) / 2000))
        }
        if !state.isDaylight { result.tintHex = 0x132538; result.tintOpacity = max(result.tintOpacity, 0.07) }
        result.wind = min(25, state.windSpeed) * sin(state.windDirection * .pi / 180)
        result.rainIntensity *= scale * (navigating ? 0.5 : 1)
        result.snowIntensity *= scale * (navigating ? 0.4 : 1)
        result.fogDensity *= scale * (navigating ? 0.3 : 1)
        result.tintOpacity *= scale * (navigating ? 0.7 : 1)
        if !animations || reduceMotion { result.rainIntensity = 0; result.snowIntensity = 0; result.flashes = false }
        if !colors { result.tintOpacity = 0 }
        return result
    }
}
