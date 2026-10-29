import SwiftUI

struct FuelStopQuickSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: EnergyStore
    let stations: [FuelStopStation]
    let trips: [TripRecord]
    let onSaved: () -> Void
    @State private var selected: FuelStopStation?
    @State private var addingVehicle = false

    private var vehicle: EnergyVehicle? {
        if let selected = store.selectedVehicle, selected.powertrain != .electric { return selected }
        return store.vehicles.first { $0.powertrain != .electric }
    }

    var body: some View {
        Group {
            if let vehicle, let station = selected ?? (stations.count == 1 ? stations.first : nil) {
                EnergyEntryEditor(store: store, vehicle: vehicle, original: nil,
                                  coordinate: station.identity.coordinate, trips: trips, suggestedStation: station,
                                  onSaved: onSaved)
            } else if vehicle == nil {
                NavigationStack {
                    ContentUnavailableView {
                        Label("Dodaj pojazd do tankowania", systemImage: "car.side")
                    } description: {
                        Text("Tankowanie wymaga pojazdu spalinowego lub hybrydowego. Wybrana stacja zostanie zachowana.")
                    } actions: {
                        Button("Dodaj pojazd", systemImage: "plus") { addingVehicle = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } } }
                }
            } else {
                NavigationStack {
                    List(stations.sorted {
                        let order = $0.identity.name.localizedStandardCompare($1.identity.name)
                        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                    }) { station in
                        Button { selected = station } label: {
                            Label(station.identity.name, systemImage: "fuelpump.fill")
                                .foregroundStyle(Color.naviTextPrimary)
                        }
                    }
                    .navigationTitle("Na której stacji tankujesz?")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } } }
                }
            }
        }
        .sheet(isPresented: $addingVehicle) { EnergyVehicleEditor(store: store, original: nil) }
    }
}
