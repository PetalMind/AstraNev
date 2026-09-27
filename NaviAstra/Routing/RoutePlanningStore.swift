import Observation

@MainActor
@Observable
final class RoutePlanningStore {
    var draftPreferences = RoutingPreferences()

    func loadPreferences(from navigation: NavigationStore) {
        draftPreferences = navigation.state.routingPreferences
    }

    func applyPreferences(to navigation: NavigationStore) async {
        await navigation.updateRoutingPreferences(draftPreferences)
    }
}
