import Foundation

/// Shared presentation for both map providers; never changes position or route tracking.
enum NavigationPositionIcon: CaseIterable {
    case car, pedestrian, bicycle, bus, tram, train, ferry

    var symbolName: String {
        switch self {
        case .car: "car.fill"
        case .pedestrian: "figure.walk"
        case .bicycle: "bicycle"
        case .bus: "bus.fill"
        case .tram: "tram.fill"
        case .train: "train.side.front.car"
        case .ferry: "ferry.fill"
        }
    }

    var title: String {
        switch self {
        case .car: "Samochód"
        case .pedestrian: "Pieszy"
        case .bicycle: "Rower"
        case .bus: "Autobus"
        case .tram: "Tramwaj lub metro"
        case .train: "Pociąg"
        case .ferry: "Prom"
        }
    }

    @MainActor
    static func current(in state: NavigationState, enabled: Bool) -> Self? {
        guard enabled, state.status == .navigating || state.status == .rerouting else { return nil }
        switch state.transportMode {
        case .car: return .car
        case .walking: return .pedestrian
        case .bicycle: return .bicycle
        case .transit, .parkRide:
            guard let legs = state.route?.journey?.legs,
                  let progress = state.transitProgress,
                  legs.indices.contains(progress.legIndex) else {
                // Until tracking identifies a leg, do not imply the user has boarded.
                return nil
            }
            switch legs[progress.legIndex].mode.uppercased() {
            case "CAR": return .car
            case "WALK", "FOOT": return .pedestrian
            case "BICYCLE", "BIKE": return .bicycle
            default: break
            }
            guard progress.isOnVehicle else { return .pedestrian }
            switch legs[progress.legIndex].mode.uppercased() {
            case "BUS", "COACH": return .bus
            case "TRAM", "SUBWAY", "METRO": return .tram
            case "RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "SUBURBAN_RAIL",
                 "LONG_DISTANCE", "NIGHT_RAIL", "HIGHSPEED_RAIL": return .train
            case "FERRY": return .ferry
            default: return nil
            }
        }
    }
}
