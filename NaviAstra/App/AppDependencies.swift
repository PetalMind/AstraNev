import Foundation

@MainActor
struct AppDependencies {
    let router: AppRouter
    let navigationStore: NavigationStore
    let placeStore: PlaceStore
    let searchStore: SearchStore
    let routePlanningStore: RoutePlanningStore
    let transitStore: TransitStore
    let mapStore: MapStore

    static func live() -> AppDependencies {
        let configuredAddress = UserDefaults.standard.string(forKey: "routingServer") ?? ""
        let endpoint = URL(string: configuredAddress)
            ?? URL(string: "https://valhalla1.openstreetmap.de")!
        let transitProvider = TransitousRouteProvider()
        let transitDataProvider = LocalTransitDataProvider()
        let navigationDependencies = NavigationSessionDependencies.live(
            routeEndpoint: endpoint,
            trafficAPIKey: TrafficCredential.read(),
            transitProvider: transitProvider,
            transitDataProvider: transitDataProvider)
        let placeStore = PlaceStore()
        let navigationStore = NavigationStore(
            session: NavigationSession(dependencies: navigationDependencies))
        return AppDependencies(
            router: AppRouter(),
            navigationStore: navigationStore,
            placeStore: placeStore,
            searchStore: SearchStore(transitRepository: transitDataProvider),
            routePlanningStore: RoutePlanningStore(),
            transitStore: TransitStore(repository: transitDataProvider),
            mapStore: MapStore())
    }
}
