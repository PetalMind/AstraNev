import Foundation
import Observation

@MainActor @Observable
final class NavigationState {
    var searchMapCenter: Coordinate?
    var routeOriginMapSelectionActive = false
    var searchResults: [SearchResult] = []
    var location: NavigationLocation?
    var cameraLocation: NavigationLocation?
    var deviceHeading: Double?
    var route: NavigationRoute?
    var transportMode: TransportMode = .car
    var journeyTimeMode: JourneyTimeMode = .now
    var journeyTargetTime = Date()
    var laterTransitRoutes: [NavigationRoute] = []
    var isLoadingLaterTransitRoutes = false
    var didSearchLaterTransitRoutes = false
    // Keep provider order stable when the selected route changes.
    var routeOptions: [NavigationRoute] = []
    var alternatives: [NavigationRoute] {
        routeOptions.filter { $0.id != route?.id }
    }
    var routeGeometryProgress: Double {
        guard let route, progress?.geometryRouteID == route.id else { return 0 }
        return progress?.geometryProgress ?? 0
    }
    var routeOrigin: RoutePoint?
    var routePlan: RoutePlan? {
        guard let destination,
              let origin = routeOrigin ?? location.map({
                  RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: $0.coordinate),
                             source: .currentLocation)
              }) else { return nil }
        return RoutePlan(origin: origin,
                         destination: RoutePoint(destination, source: destination.poi == nil ? .search : .poi))
    }
    var destination: Destination?
    var navigationTarget: POINavigationTarget?
    var parkRideCarTarget: POINavigationTarget?
    var waypoints: [Destination] = []
    var evChargingStops: [Destination] = []
    var waypointNavigationTargets: [UUID: POINavigationTarget] = [:]
    var routingPreferences = RoutingPreferences()
    var progress: RouteProgress?
    var routeMatch: NavigationRouteMatch?
    var transitProgress: TransitNavigationProgress?
    var transitPlanningPhase: TransitPlanningPhase?
    var status: NavigationStatus = .idle
    var cameraState: NavigationCameraState = .browse
    var cameraIntent: CameraIntent?
    var cameraCommandID = 0
    var routeRevealProgress = 1.0
    var weakGPS = false
    var gpsQuality: GPSQuality = .noSignal
    var estimatedArrival: Date?
    var lastTrip: TripRecord?
    var errorMessage: String?
    var voicePreferences = VoiceGuidancePreferences.load() {
        didSet { voicePreferences.save() }
    }
    var voiceEnabled: Bool {
        get { voicePreferences.isEnabled }
        set {
            var updated = voicePreferences
            updated.isEnabled = newValue
            voicePreferences = updated
        }
    }
    var speedLimitKph: Int?
    var speedLimitSource: SpeedLimitSource?
    var speedLimitMessage: String?
    var roadSafetyAlerts: [RoadSafetyAlert] = []
    var roadSafetyStatus: RoadSafetyStatus = .idle
    var traffic: TrafficSnapshot?
    var trafficStatus: TrafficStatus = .notConfigured
    var trafficLightTileURLTemplate: String?
    var trafficDarkTileURLTemplate: String?
    var trafficLightIncidentTileURLTemplate: String?
    var trafficDarkIncidentTileURLTemplate: String?
    var nearbySuggestions: [RouteStopSuggestion] = []
    var nearbyStatus: NearbySearchStatus = .idle
    var transitVehicles: [TransitVehicle] = []
    var transitVehiclesUpdatedAt: Date?
    var transitStops: [TransitStop] = []
    var nearbyTransitStop: TransitStop?
    var nearbyTransitDepartures: [TransitDeparture] = []
    var transitBackgroundLocationAvailable = false
}

enum TrafficStatus: Equatable {
    case notConfigured, updating, available, unavailable(String)
}

enum NearbySearchStatus: Equatable {
    case idle, searching, available, unavailable(String)
}

enum EVPlanningError: LocalizedError {
    case rangeNotConfigured, consumptionNotConfigured, chargersUnavailable

    var errorDescription: String? {
        switch self {
        case .rangeNotConfigured:
            "Wpisz szacowany zasięg EV w ustawieniach, aby uwzględnić postoje na ładowanie."
        case .consumptionNotConfigured:
            "Wpisz zużycie energii oraz maksymalną moc ładowania auta w ustawieniach EV."
        case .chargersUnavailable:
            "Nie znaleziono wystarczającej liczby publicznych ładowarek ze znanym złączem i mocą w danych OpenStreetMap."
        }
    }
}
