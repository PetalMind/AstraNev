import Observation

@MainActor
@Observable
final class RoutePlanningStore {
    var draftPreferences = RoutingPreferences()

    func loadPreferences(from engine: NavigationEngine) {
        draftPreferences = engine.state.routingPreferences
    }

    func applyPreferences(to engine: NavigationEngine) async {
        await engine.updateRoutingPreferences(draftPreferences)
    }
}
