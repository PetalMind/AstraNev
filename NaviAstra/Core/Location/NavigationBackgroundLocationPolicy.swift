import CoreLocation
import Foundation

nonisolated enum NavigationBackgroundLocationPolicy {
    static func allowsDelivery(demandIsContinuous: Bool, navigationAllowsBackground: Bool,
                               authorization: CLAuthorizationStatus, backgroundModeEnabled: Bool) -> Bool {
        demandIsContinuous && navigationAllowsBackground && backgroundModeEnabled
            && (authorization == .authorizedWhenInUse || authorization == .authorizedAlways)
    }

    @MainActor static func preservesContinuousSession(previous: LocationPolicy?, next: LocationPolicy) -> Bool {
        previous?.demand == .continuous && next.demand == .continuous
    }
}
