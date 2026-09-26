import CoreLocation
import Foundation

@MainActor
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?
    var onHeading: ((CLHeading) -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    var onFailure: ((Error) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func setHeadingUpdatesEnabled(_ enabled: Bool) {
        guard enabled, CLLocationManager.headingAvailable() else {
            manager.stopUpdatingHeading()
            return
        }
        manager.startUpdatingHeading()
    }

    var backgroundLocationModeEnabled: Bool {
#if os(iOS)
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
#else
        return false
#endif
    }

    func requestTransitBackgroundAuthorization() -> Bool {
#if os(iOS)
        guard backgroundLocationModeEnabled else { return false }
        if manager.authorizationStatus == .authorizedAlways {
            applyBackgroundLocationSettings(.authorizedAlways)
            return true
        }
        manager.requestAlwaysAuthorization()
#endif
        return false
    }

    func stopBackgroundNavigationUpdates() {
#if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
#endif
    }

    private func applyBackgroundLocationSettings(_ authorization: CLAuthorizationStatus) {
#if os(iOS)
        let enabled = authorization == .authorizedAlways && backgroundLocationModeEnabled
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = !enabled
#endif
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in self?.onLocation?(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor [weak self] in self?.onHeading?(newHeading) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.applyBackgroundLocationSettings(status)
            self?.onAuthorization?(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.onFailure?(error) }
    }
}
