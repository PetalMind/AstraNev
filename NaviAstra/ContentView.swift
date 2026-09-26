import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Namespace var transportSelectionNamespace
    @State var engine: NavigationEngine
    @State var appRouter: AppRouter
    @State var searchStore: SearchStore
    @State var routePlanningStore: RoutePlanningStore
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
    @State var selectedMapPlaces: [SearchResult] = []
    @State var selectedTransitSheet: TransitSheetSelection?
    @State var selectedTransitStopID: String?
    @State var selectedTransitRouteID: String?
    @State var selectedTransitTripID: String?
    @State var selectedTransitTripStopIDs: Set<String> = []
    @State var selectedTransitLine: TransitLineDetails?
    @State var selectedTransitTripCoordinates: [Coordinate] = []
    @State var liveTransitTripDetails: TransitTripDetails?
    @State var mapPlaceEstimateTask: Task<Void, Never>?
    @State var serverAddress = UserDefaults.standard.string(forKey: "routingServer") ?? "https://valhalla1.openstreetmap.de"
    @State var editingSavedPlace: SavedPlace?
    @State var placePendingRemoval: SavedPlace?
    @State var showPlaceRemovalConfirmation = false
    @State var addingWaypoint = false
    @State var nearbyRequest: NearbySearchRequest?
    @State var localData: LocalDataStore
    @State var favoriteName = ""
    @State var isSavingPlace = false
    @State var destinationExpanded = false
    @State var routePreviewExpanded = false
    @State var favoritePulseScale: CGFloat = 1
    @State var showFavoriteRemovalConfirmation = false
    @State var trafficKey = ""
    @State var trafficConfigured = TrafficCredential.read() != nil
    @State var isMapReady = false
    @State var discoveryDrawerCollapseRequest = 0
    @State var navigationPanelExpanded = false
    @State var quickETAEstimates: [String: PlaceRouteEstimate] = [:]
    @State var quickETAOrigin: Coordinate?
    @State var quickETADestinationKey = ""
    @State var quickETAUpdatedAt = Date.distantPast
    @State var quickETAInFlight = false
    @AppStorage("mapBase") var mapBase = BaseMap.standard.rawValue
    @AppStorage("mapAppearance") var mapAppearance = MapAppearance.auto.rawValue
    @AppStorage("mapDimension") var mapDimension = MapDimension.flat.rawValue
    @AppStorage("mapTrafficVisible") var mapTrafficVisible = true
    @AppStorage("mapPOICategories") var mapPOICategories = MapPOICategory.allMask
    @AppStorage("mapPOIVisible") var mapPOIVisible = true
    @AppStorage("mapBuildingsVisible") var mapBuildingsVisible = true
    @AppStorage("mapTransitVisible") var mapTransitVisible = false
    @AppStorage("mapCyclingVisible") var mapCyclingVisible = false
    @AppStorage("speedWarningsEnabled") var speedWarningsEnabled = true
    @AppStorage("defaultTransportMode") var defaultTransportMode = TransportMode.car.rawValue

    init(dependencies: AppDependencies) {
        _engine = State(initialValue: dependencies.navigationEngine)
        _appRouter = State(initialValue: dependencies.router)
        _localData = State(initialValue: dependencies.localData)
        _searchStore = State(initialValue: dependencies.searchStore)
        _routePlanningStore = State(initialValue: dependencies.routePlanningStore)
    }


}

struct NearbySearchRequest: Identifiable {
    let id = UUID()
    let category: NearbyPlaceCategory
    let nearDestination: Bool
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
