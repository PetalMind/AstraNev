import Observation

@MainActor
@Observable
final class RoutePlanningStore {
    var draftPreferences = RoutingPreferences()

    func loadPreferences(from navigation: NavigationStore) {
        draftPreferences = navigation.state.routingPreferences
    }

    func updatePreference<Value>(
        _ keyPath: WritableKeyPath<RoutingPreferences, Value>,
        value: Value,
        to navigation: NavigationStore
    ) {
        var preferences = draftPreferences
        preferences[keyPath: keyPath] = value
        updatePreferences(preferences, to: navigation)
    }

    func updatePreferences(
        _ update: (inout RoutingPreferences) -> Void,
        to navigation: NavigationStore
    ) {
        var preferences = draftPreferences
        update(&preferences)
        updatePreferences(preferences, to: navigation)
    }

    private func updatePreferences(
        _ preferences: RoutingPreferences,
        to navigation: NavigationStore
    ) {
        draftPreferences = preferences
        Task { await navigation.updateRoutingPreferences(preferences) }
    }
}
