import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) var scenePhase
    @Namespace var transportSelectionNamespace
#if os(iOS)
    @State var tripCoordinator = IOSPlannedTripCoordinator()
    let voiceAssistant: VoiceAssistant
#endif
    @State var plannedTripDraft: PlannedTrip?
    @State var pendingPlannedTripID: UUID?
    @State var pendingPlannedTripOccurrence: Date?
    let tripPlanning: TripPlanningService
    let navigationStore: NavigationStore
    let appRouter: AppRouter
    let searchStore: SearchStore
    let routePlanningStore: RoutePlanningStore
    @Bindable var transitStore: TransitStore
    @Bindable var mapStore: MapStore
    @Bindable var placeStore: PlaceStore
    let energyStore: EnergyStore
    @State var fuelStopStore = FuelStopStore()
    @State var showsFuelStopEntry = false
    @State var openFuelEntryAfterPlaceDismiss = false
    @State var fuelStopEntryCandidates: [FuelStopStation] = []
    @State var weatherStore = WeatherStore()
    @State var showsWeatherDetails = false
#if os(iOS)
    @State var showsRoadReportEditor = false
    @State var quickRoadReportFeedback: QuickRoadReportFeedback?
#endif
    @AppStorage("weatherEnabled") var weatherEnabled = true
    @AppStorage("weatherIntensity") var weatherIntensity = WeatherEffectIntensity.subtle.rawValue
    @AppStorage("weatherAnimations") var weatherAnimations = true
    @AppStorage("weatherMapColors") var weatherMapColors = true
    @AppStorage("weatherDuringNavigation") var weatherDuringNavigation = true
    @AppStorage("weatherRouteForecast") var weatherRouteForecast = true
    @State var panelHeight: CGFloat = 320
    @State var mapPanelInset: CGFloat = 340
    @State var mapHeaderInset: CGFloat = 100
    @State var openOriginSearchAfterPickerDismiss = false
    @State var openDestinationSearchAfterPlaceDismiss = false
    @State var selectingRouteOriginInSearch = false
    @State var selectingRouteOriginOnMap = false
    @State var pickedRouteOriginCoordinate: Coordinate?
    @State var pickedRouteOriginAddress: String?
    @State var routeOriginGeocodingTask: Task<Void, Never>?
    @State var savedPlaceMapSelectionKind: PlaceKind?
    @State var savedPlaceMapCoordinate: Coordinate?
    @State var savedPlaceMapAddress: String?
    @State var savedPlaceMapGeocodingTask: Task<Void, Never>?
    @State var mapPlaceEstimateTask: Task<Void, Never>?
    @State var serverAddress = UserDefaults.standard.string(forKey: "routingServer") ?? "https://valhalla1.openstreetmap.de"
    @AppStorage("transitousContact") var transitousContact = "dominikjaros99@icloud.com"
    @State var editingSavedPlace: SavedPlace?
    @State var placePendingRemoval: SavedPlace?
    @State var showPlaceRemovalConfirmation = false
    @State var favoriteFeedback: FavoriteFeedback?
    @State var openSearchAfterFavoritesDismiss = false
    @State var addingWaypoint = false
    @State var favoriteName = ""
    @State var isSavingPlace = false
    @State var destinationExpanded = false
    @State var routePreviewDetent: NavigationBottomSheetDetent = .medium
    @State var selectedMapPlaceDetent: NavigationBottomSheetDetent = .medium
    @State var isJourneyTimePickerPresented = false
    @State var favoritePulseScale: CGFloat = 1
    @State var showFavoriteRemovalConfirmation = false
    @State var selectedParkedCar: ParkedCar?
    @State var parkedCarStartsInEditMode = false
    @State var showParkedCarReplacementConfirmation = false
    @State var pendingParkedCarCoordinate: Coordinate?
    @State var pendingParkedCarAccuracy: Double?
    @State var pendingParkedCarDate: Date?
    @State var mapActionCoordinate: Coordinate?
    @State var showMapLocationActions = false
    @State var parkedCarToast: ParkedCarToast?
    @State var parkedCarToastDismissTask: Task<Void, Never>?
    @State var arrivalCarPromptDismissed = false
    @State var parkedCarPromptExpiresAt: Date?
    @State var discoveryDrawerCollapseRequest = 0
    @State var discoverySheetDetent: NavigationBottomSheetDetent = .medium
    @State var navigationPanelDetent: NavigationBottomSheetDetent = .medium
    @State var isMapBottomSheetDragging = false
    @State var isARNavigationPresented = false
    @State var arLaunchReadiness: ARLaunchReadiness = .checking
    @State var routeStopDropTargetID: String?
    @State var routeStopReorderFeedbackToken = 0
    @State var journeyGuidanceExpanded = false
    @State var currentStepExpandedOverride: Bool? = nil
#if os(iOS)
    @State var currentStepGuidancePresentation: CurrentStepGuidancePresentation?
    @State var isNavigationPanelTrackingFinger = false
    @State var drivingRoadAlertsHeight: CGFloat = 0
    @State var drivingMapDockHeight: CGFloat = 0
#endif
    @State var routePlanningDetailsExpanded = false
    @State var expandedTransitStopsLegID: UUID?
    @State var expandedTransitTimelineLegID: UUID?
    @State var showsFullTransitItinerary = false
    @State var quickETAEstimates: [String: PlaceRouteEstimate] = [:]
    @State var quickETAOrigin: Coordinate?
    @State var quickETADestinationKey = ""
    @State var quickETAUpdatedAt = Date.distantPast
    @State var quickETAInFlight = false
    @AppStorage("speedWarningsEnabled") var speedWarningsEnabled = true
    @AppStorage("defaultTransportMode") var defaultTransportMode = TransportMode.car.rawValue

    var routePreviewExpanded: Bool {
        get { routePreviewDetent == .expanded }
        nonmutating set { routePreviewDetent = newValue ? .expanded : .medium }
    }

    var navigationPanelExpanded: Bool {
        get { navigationPanelDetent == .expanded }
        nonmutating set { navigationPanelDetent = newValue ? .expanded : .medium }
    }

    init(dependencies: AppDependencies) {
        self.tripPlanning = dependencies.tripPlanning
        self.energyStore = dependencies.energyStore
        self.navigationStore = dependencies.navigationStore
        self.appRouter = dependencies.router
        self.searchStore = dependencies.searchStore
        self.routePlanningStore = dependencies.routePlanningStore
        self.transitStore = dependencies.transitStore
        self.mapStore = dependencies.mapStore
        self.placeStore = dependencies.placeStore
        #if os(iOS)
        self.voiceAssistant = dependencies.voiceAssistant ?? VoiceAssistant(
            navigationStore: dependencies.navigationStore, placeStore: dependencies.placeStore)
        #endif
        #if DEBUG && os(iOS)
        if IOSDebugDrivingScenario.isEnabled {
            _navigationPanelDetent = State(initialValue: IOSDebugDrivingScenario.panelDetent)
        }
        #endif
    }


}

func mapTransitColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xff) / 255,
          green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255)
}

struct PlaceShortcut: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var destination: Destination
    var isRecent: Bool
    var estimatedMinutes: Int? = nil
    var estimatedDistanceMeters: Double? = nil
}

struct RecentPlaceShortcut: Identifiable {
    var id: String
    var destination: Destination
    var usedAt: Date
}
