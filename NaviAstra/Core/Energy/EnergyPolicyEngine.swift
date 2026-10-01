import Foundation
import Observation

enum NavigationEnergyMode: Equatable {
    case idle
    case mapBrowsing
    case routePreview
    case driving
    case walking
    case backgroundNavigation
    case arrived
}

struct LocationPolicy: Equatable {
    enum Demand: Equatable { case stopped, oneShot, continuous }
    enum Accuracy: Equatable { case hundredMeters, nearestTenMeters, bestForNavigation }
    enum Activity: Equatable { case other, automotiveNavigation, otherNavigation, fitness }

    let demand: Demand
    let accuracy: Accuracy
    let distanceFilter: Double
    let activity: Activity
    let allowsBackgroundUpdates: Bool
    let updatesHeading: Bool

    static let stopped = LocationPolicy(demand: .stopped, accuracy: .hundredMeters,
                                        distanceFilter: 0, activity: .other,
                                        allowsBackgroundUpdates: false, updatesHeading: false)
}

struct EnergyPolicy: Equatable {
    let mode: NavigationEnergyMode
    let location: LocationPolicy
    /// Zero means the map renderer should remain dormant.
    let mapFramesPerSecond: Int
    let trafficRefreshInterval: TimeInterval?
    let transitRefreshInterval: TimeInterval?
    let enables3DBuildings: Bool
    let enablesMapPrefetch: Bool

    var mapRenderingEnabled: Bool { mapFramesPerSecond > 0 }
}

@MainActor @Observable
final class EnergyPolicyEngine {
    private(set) var currentPolicy = EnergyPolicy(
        mode: .idle, location: .stopped, mapFramesPerSecond: 0,
        trafficRefreshInterval: nil, transitRefreshInterval: nil,
        enables3DBuildings: false, enablesMapPrefetch: false)

    @discardableResult
    func update(navigationStatus: NavigationStatus,
                transportMode: TransportMode,
                appIsForeground: Bool,
                lowPowerMode: Bool,
                thermalState: ProcessInfo.ThermalState,
                speedMetersPerSecond: Double?) -> EnergyPolicy {
        let isNavigating = navigationStatus == .navigating || navigationStatus == .rerouting
        let mode: NavigationEnergyMode
        if !appIsForeground {
            mode = isNavigating ? .backgroundNavigation : .idle
        } else {
            switch navigationStatus {
            case .navigating, .rerouting:
                mode = transportMode == .walking ? .walking : .driving
            case .arrived:
                mode = .arrived
            case .destinationPreview, .routeCalculating, .routePreview:
                mode = .routePreview
            case .idle, .error:
                mode = .mapBrowsing
            }
        }

        let thermallyLimited = thermalState == .serious || thermalState == .critical
        let performanceLimited = lowPowerMode || thermallyLimited
        let routeActivity = transportMode == .car || transportMode == .parkRide
        let drivingTrafficInterval: TimeInterval = performanceLimited ? 120 : 90

        let location: LocationPolicy
        let frameRate: Int
        let trafficInterval: TimeInterval?
        let transitInterval: TimeInterval?
        switch mode {
        case .idle:
            location = .stopped
            frameRate = 0
            trafficInterval = nil
            transitInterval = nil
        case .mapBrowsing:
            location = LocationPolicy(demand: .oneShot, accuracy: .hundredMeters,
                                      distanceFilter: lowPowerMode ? 100 : 50, activity: .other,
                                      allowsBackgroundUpdates: false, updatesHeading: false)
            frameRate = 30
            trafficInterval = nil
            transitInterval = 60
        case .routePreview:
            location = LocationPolicy(demand: .oneShot, accuracy: .bestForNavigation,
                                      distanceFilter: 0, activity: .other,
                                      allowsBackgroundUpdates: false, updatesHeading: false)
            frameRate = 30
            trafficInterval = routeActivity ? (performanceLimited ? 120 : 90) : nil
            transitInterval = nil
        case .driving:
            location = LocationPolicy(demand: .continuous, accuracy: .bestForNavigation,
                                      distanceFilter: 0,
                                      activity: transportMode == .car ? .automotiveNavigation : .otherNavigation,
                                      allowsBackgroundUpdates: true, updatesHeading: false)
            frameRate = performanceLimited ? 30 : 60
            trafficInterval = routeActivity ? drivingTrafficInterval : nil
            transitInterval = transportMode == .transit || transportMode == .parkRide
                ? (performanceLimited ? 60 : 30) : nil
        case .walking:
            location = LocationPolicy(demand: .continuous, accuracy: .nearestTenMeters,
                                      distanceFilter: 0, activity: .otherNavigation,
                                      allowsBackgroundUpdates: true, updatesHeading: true)
            frameRate = performanceLimited ? 30 : 60
            trafficInterval = nil
            transitInterval = nil
        case .backgroundNavigation:
            location = LocationPolicy(demand: .continuous, accuracy: .bestForNavigation,
                                      distanceFilter: 0,
                                      activity: transportMode == .car || transportMode == .parkRide
                                        ? .automotiveNavigation : .otherNavigation,
                                      allowsBackgroundUpdates: true, updatesHeading: false)
            frameRate = 0
            trafficInterval = routeActivity ? drivingTrafficInterval : nil
            transitInterval = transportMode == .transit || transportMode == .parkRide ? 60 : nil
        case .arrived:
            location = .stopped
            frameRate = 30
            trafficInterval = nil
            transitInterval = nil
        }

        let policy = EnergyPolicy(
            mode: mode,
            location: location,
            mapFramesPerSecond: frameRate,
            trafficRefreshInterval: trafficInterval,
            transitRefreshInterval: transitInterval,
            enables3DBuildings: !performanceLimited && mode != .backgroundNavigation && mode != .idle,
            enablesMapPrefetch: !performanceLimited && mode != .backgroundNavigation && mode != .idle)
        if currentPolicy != policy { currentPolicy = policy }
        return policy
    }
}
