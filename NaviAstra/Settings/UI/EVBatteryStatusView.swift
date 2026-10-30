import SwiftUI

/// Shared by both iOS settings entry points so battery corrections behave alike.
struct EVBatteryStatusView: View {
    let navigation: NavigationStore
    let enteredPercent: Int
    @State private var confirming = false

    var body: some View {
        if let percent = navigation.state.evEstimatedBatteryPercent,
           let range = navigation.state.evEstimatedRangeKilometers {
            LabeledContent("Szacowany poziom teraz",
                value: percent.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "pl_PL"))) + "%")
            LabeledContent("Szacowany zasięg teraz",
                value: range.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "pl_PL"))) + " km")
            Button("Potwierdź wskazanie auta: \(enteredPercent)%") {
                confirming = true
                Task {
                    await navigation.confirmEVBatteryPercent(enteredPercent)
                    confirming = false
                }
            }
            .disabled(confirming)
            Text("Szacunek maleje wraz z przebytą drogą. Po ładowaniu wpisz i potwierdź poziom z samochodu; aplikacja nie odczytuje baterii automatycznie.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
