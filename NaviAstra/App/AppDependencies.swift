import Foundation

@MainActor
struct AppDependencies {
    let router: AppRouter
    let navigationEngine: NavigationEngine
    let localData: LocalDataStore
    let searchStore: SearchStore
    let routePlanningStore: RoutePlanningStore

    static func live() -> AppDependencies {
        let configuredAddress = UserDefaults.standard.string(forKey: "routingServer") ?? ""
        let endpoint = URL(string: configuredAddress)
            ?? URL(string: "https://valhalla1.openstreetmap.de")!
        let navigationDependencies = NavigationEngineDependencies.live(
            routeEndpoint: endpoint,
            trafficAPIKey: TrafficCredential.read())
        return AppDependencies(
            router: AppRouter(),
            navigationEngine: NavigationEngine(dependencies: navigationDependencies),
            localData: LocalDataStore(),
            searchStore: SearchStore(),
            routePlanningStore: RoutePlanningStore())
    }
}
