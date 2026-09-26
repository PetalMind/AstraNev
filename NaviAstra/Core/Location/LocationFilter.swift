import CoreLocation
import Foundation

struct LocationFilter {
    private var previous: CLLocation?
    private var mode: TransportMode?

    mutating func accept(_ location: CLLocation, mode newMode: TransportMode) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 70,
              abs(location.timestamp.timeIntervalSinceNow) < 15 else { return false }
        if mode != newMode {
            previous = nil
            mode = newMode
        }
        if let previous {
            let interval = location.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0 else { return false }
            if location.distance(from: previous) / interval > newMode.maximumPlausibleSpeed { return false }
        }
        previous = location
        return true
    }
}

extension TransportMode {
    var maximumPlausibleSpeed: Double {
        switch self {
        case .walking: 10
        case .bicycle: 40
        case .car: 75
        case .transit: 90
        case .parkRide: 75
        }
    }
}
