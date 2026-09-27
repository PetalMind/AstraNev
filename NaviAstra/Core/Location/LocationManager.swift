import CoreLocation
import Foundation

@MainActor
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?
    var onHeading: ((CLHeading) -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    var onFailure: ((Error) -> Void)?
    private var appliedPolicy: LocationPolicy?
    private var headingUpdatesEnabled = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func prepareAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func apply(_ policy: LocationPolicy) {
        let changed = appliedPolicy != policy
        appliedPolicy = policy

        guard changed else {
            applyBackgroundLocationSettings(manager.authorizationStatus)
            setHeadingUpdatesEnabled(policy.updatesHeading)
            return
        }

        manager.stopUpdatingLocation()
        switch policy.demand {
        case .stopped:
            applyBackgroundLocationSettings(manager.authorizationStatus)
        case .oneShot:
            configure(policy)
            applyBackgroundLocationSettings(manager.authorizationStatus)
            if canUseLocationServices {
                manager.requestLocation()
            }
        case .continuous:
            configure(policy)
            applyBackgroundLocationSettings(manager.authorizationStatus)
            if canUseLocationServices {
                manager.startUpdatingLocation()
            }
        }
        setHeadingUpdatesEnabled(policy.updatesHeading)
    }

    func stop() {
        manager.stopUpdatingLocation()
#if os(iOS)
        manager.stopUpdatingHeading()
#endif
    }

    func setHeadingUpdatesEnabled(_ enabled: Bool) {
#if os(iOS)
        guard enabled, CLLocationManager.headingAvailable() else {
            manager.stopUpdatingHeading()
            headingUpdatesEnabled = false
            return
        }
        guard !headingUpdatesEnabled else { return }
        headingUpdatesEnabled = true
        manager.startUpdatingHeading()
#else
        headingUpdatesEnabled = false
#endif
    }

    private var canUseLocationServices: Bool {
#if os(macOS)
        manager.authorizationStatus == .authorizedAlways
#else
        manager.authorizationStatus == .authorizedWhenInUse ||
            manager.authorizationStatus == .authorizedAlways
#endif
    }

    private func configure(_ policy: LocationPolicy) {
        switch policy.accuracy {
        case .hundredMeters:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        case .nearestTenMeters:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        case .bestForNavigation:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        }
        manager.distanceFilter = policy.distanceFilter
        switch policy.activity {
        case .other: manager.activityType = .other
        case .automotiveNavigation: manager.activityType = .automotiveNavigation
        case .otherNavigation: manager.activityType = .otherNavigation
        case .fitness: manager.activityType = .fitness
        }
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
        let wantsBackgroundUpdates = appliedPolicy?.allowsBackgroundUpdates == true
        let isAuthorized = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        let enabled = wantsBackgroundUpdates && isAuthorized && backgroundLocationModeEnabled
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
            self?.reapplyCurrentPolicy()
        }
    }

    private func reapplyCurrentPolicy() {
        guard let appliedPolicy else { return }
        self.appliedPolicy = nil
        apply(appliedPolicy)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.onFailure?(error) }
    }
}
