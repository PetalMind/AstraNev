import Foundation

/// A distance-based estimate, never a reading from the vehicle. Charging requires
/// an explicit battery correction; passing a planned charger does not add energy.
nonisolated struct EVBatteryEstimate {
    private(set) var fullRangeMeters: Double
    private var confirmedRangeMeters: Double
    private var confirmedTripDistance: Double

    init?(fullRangeMeters: Double, batteryPercent: Double, tripDistance: Double) {
        guard fullRangeMeters.isFinite, fullRangeMeters > 0,
              batteryPercent.isFinite, (0...100).contains(batteryPercent),
              tripDistance.isFinite, tripDistance >= 0 else { return nil }
        self.fullRangeMeters = fullRangeMeters
        confirmedRangeMeters = fullRangeMeters * batteryPercent / 100
        confirmedTripDistance = tripDistance
    }

    func remainingRange(at tripDistance: Double) -> Double {
        guard tripDistance.isFinite else { return 0 }
        return max(0, confirmedRangeMeters - max(0, tripDistance - confirmedTripDistance))
    }

    func batteryPercent(at tripDistance: Double) -> Double {
        100 * remainingRange(at: tripDistance) / fullRangeMeters
    }
}

extension NavigationSession {
    func resetEVBatteryEstimate() {
        let preferences = state.routingPreferences
        evBatteryEstimate = preferences.evPlanningEnabled && state.transportMode == .car
            ? EVBatteryEstimate(fullRangeMeters: preferences.evRangeKilometers * 1_000,
                batteryPercent: Double(preferences.evBatteryPercent), tripDistance: tripSession?.distanceMeters ?? 0)
            : nil
        publishEVBatteryEstimate()
    }

    func publishEVBatteryEstimate() {
        guard state.routingPreferences.evPlanningEnabled,
              let estimate = evBatteryEstimate, let trip = tripSession else {
            state.evEstimatedBatteryPercent = nil
            state.evEstimatedRangeKilometers = nil
            return
        }
        state.evEstimatedBatteryPercent = estimate.batteryPercent(at: trip.distanceMeters)
        state.evEstimatedRangeKilometers = estimate.remainingRange(at: trip.distanceMeters) / 1_000
    }

    func availableEVRangeMeters(for preferences: RoutingPreferences) -> Double {
        guard let estimate = evBatteryEstimate, let trip = tripSession,
              state.status == .navigating || state.status == .rerouting else {
            return preferences.availableEVRangeKilometers * 1_000
        }
        return estimate.remainingRange(at: trip.distanceMeters)
    }

    func confirmEVBatteryPercent(_ percent: Int) async {
        guard (0...100).contains(percent), state.routingPreferences.evPlanningEnabled else { return }
        var preferences = state.routingPreferences
        preferences.evBatteryPercent = percent
        // Even confirming the same entered value after charging is a new observation.
        await updateRoutingPreferences(preferences)
        resetEVBatteryEstimate()
        if state.status == .navigating || state.status == .rerouting,
           let origin = state.location?.coordinate { await reroute(from: origin) }
    }
}
