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
    @State var navigationStore: NavigationStore
    @State var appRouter: AppRouter
    @State var searchStore: SearchStore
    @State var routePlanningStore: RoutePlanningStore
    @State var transitStore: TransitStore
    @State var mapStore: MapStore
    @State var placeStore: PlaceStore
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
    @State var trafficKey = ""
    @State var trafficConfigured = TrafficCredential.read() != nil
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
        _navigationStore = State(initialValue: dependencies.navigationStore)
        _appRouter = State(initialValue: dependencies.router)
        _searchStore = State(initialValue: dependencies.searchStore)
        _routePlanningStore = State(initialValue: dependencies.routePlanningStore)
        _transitStore = State(initialValue: dependencies.transitStore)
        _mapStore = State(initialValue: dependencies.mapStore)
        _placeStore = State(initialValue: dependencies.placeStore)
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
