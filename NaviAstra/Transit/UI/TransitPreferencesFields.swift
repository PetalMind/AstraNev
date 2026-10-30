#if os(iOS)
import SwiftUI

struct TransitPreferencesFields: View {
    @Binding var preferences: TransitRoutePreferences

    var body: some View {
        Picker("Wybór połączenia", selection: $preferences.profile) {
            ForEach(TransitRouteProfile.allCases) { Text($0.title).tag($0) }
        }
        Stepper("Dodatkowy czas na przesiadkę: \(preferences.additionalTransferBufferMinutes) min",
                value: $preferences.additionalTransferBufferMinutes, in: 0...30)
        Toggle("Dojścia dostępne dla wózka", isOn: Binding(
            get: { preferences.pedestrianProfile == .wheelchair },
            set: { preferences.pedestrianProfile = $0 ? .wheelchair : .foot }))
        Text("Profil wózka dotyczy dojść i przejść między przystankami. Dostępność pojazdu i przystanku zależy od danych przewoźnika.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
#endif
