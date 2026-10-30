import Foundation

@MainActor
struct AppDependencies {
    let tripPlanning: TripPlanningService
    let energyStore: EnergyStore
    let router: AppRouter
    let navigationStore: NavigationStore
    let placeStore: PlaceStore
    let searchStore: SearchStore
    let routePlanningStore: RoutePlanningStore
    let transitStore: TransitStore
    let mapStore: MapStore
    #if os(iOS)
    var voiceAssistant: VoiceAssistant?
    #endif

    static func live() -> AppDependencies {
        let configuredAddress = UserDefaults.standard.string(forKey: "routingServer") ?? ""
        let endpoint = URL(string: configuredAddress)
            ?? URL(string: "https://valhalla1.openstreetmap.de")!
        let transitProvider = TransitousRouteProvider()
        let transitDataProvider = TransitousTransitDataProvider()
        let navigationDependencies = NavigationSessionDependencies.live(
            routeEndpoint: endpoint,
            trafficAPIKey: TrafficCredential.read(),
            transitProvider: transitProvider,
            transitDataProvider: transitDataProvider)
        let placeStore = PlaceStore()
        let energyStore = EnergyStore()
        energyStore.historyRevisionProvider = { [weak placeStore] in placeStore?.historyRevision ?? 0 }
        let session = NavigationSession(dependencies: navigationDependencies)
        session.selectedVehicleID = { [weak energyStore] in energyStore?.selectedVehicle?.id }
        session.onTripFinished = { [weak placeStore] trip in _ = placeStore?.addTrip(trip) }
        session.onTripCheckpoint = { [weak placeStore] trip in
            placeStore?.retryPendingHistoryWrites()
            _ = placeStore?.saveActiveTrip(trip)
        }
        session.onHistoryMaintenance = { [weak placeStore] in placeStore?.retryPendingHistoryWrites() }
        let navigationStore = NavigationStore(session: session)
        var dependencies = AppDependencies(
            tripPlanning: .shared,
            energyStore: energyStore,
            router: AppRouter(),
            navigationStore: navigationStore,
            placeStore: placeStore,
            searchStore: SearchStore(transitRepository: transitDataProvider),
            routePlanningStore: RoutePlanningStore(),
            transitStore: TransitStore(repository: transitDataProvider),
            mapStore: MapStore())
        #if os(iOS)
        dependencies.voiceAssistant = VoiceAssistant(navigationStore: navigationStore, placeStore: placeStore)
        if let voiceAssistant = dependencies.voiceAssistant {
            VoiceIntentBridge.shared.attach(assistant: voiceAssistant)
        }
        #endif
        #if DEBUG && os(iOS)
        if IOSDebugDrivingScenario.isEnabled {
            IOSDebugDrivingScenario.prepare(dependencies.navigationStore)
        } else {
            IOSDebugRoutePlanningScenario.prepare(dependencies.navigationStore)
        }
        #if targetEnvironment(simulator)
        dependencies.voiceAssistant?.prepareVisualAudit()
        #endif
        #endif
        return dependencies
    }

    #if os(iOS)
    func recoverDrivingHistoryAfterLaunch() async {
        await DrivingLearningEngine.shared.recoverHistoricalTripsAfterLaunch(
            records: { placeStore.trips }, historyRevision: { placeStore.historyRevision })
    }
    #endif
}
