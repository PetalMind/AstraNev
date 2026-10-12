import SwiftUI

extension ContentView {
    func openFuelEntry(for identity: PlaceIdentity) {
        let stationID: String
        if identity.provider == .openStreetMap, let type = identity.osmType, let id = identity.externalID {
            stationID = "\(type)/\(id)"
        } else {
            stationID = identity.cacheKey
        }
        fuelStopEntryCandidates = [FuelStopStation(id: stationID, identity: identity)]
#if os(iOS)
        placeStore.selectedMapPlaces = []
        showsFuelStopEntry = true
#else
        openFuelEntryAfterPlaceDismiss = true
        placeStore.selectedMapPlaces = []
#endif
    }

    var fuelStopMonitoringKey: String {
        let active = scenePhase == .active && appRouter.sheet == nil && !showsFuelStopEntry &&
            navigationStore.state.transportMode == .car && energyStore.selectedVehicle?.powertrain != .electric
        return "\(active)/\(energyStore.selectedVehicle?.id.uuidString ?? "none")"
    }

    func monitorFuelStops() async {
        fuelStopStore.reset()
        guard fuelStopMonitoringKey.hasPrefix("true/"), energyStore.selectedVehicle != nil else { return }
        while !Task.isCancelled {
            let fix: NavigationLocation?
            if isNavigating, let current = navigationStore.state.location,
               (0...10).contains(Date().timeIntervalSince(current.timestamp)), current.accuracy <= 30 {
                fix = current
            } else {
                fix = await navigationStore.freshFuelLocation()
            }
            guard !Task.isCancelled else { return }
            let nearby = await fuelStopStore.refresh(location: fix)
            do { try await Task.sleep(for: .seconds(nearby ? 20 : 60)) } catch { return }
        }
    }

    @ViewBuilder var fuelStopMapControl: some View {
        if !fuelStopStore.candidates.isEmpty {
            Button {
                fuelStopEntryCandidates = fuelStopStore.candidates
                showsFuelStopEntry = true
            } label: {
                circleSurface {
                    Image(systemName: "fuelpump.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor, Color(naviHex: NaviAstraColorPalette.surfaceDay))
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dodaj tankowanie")
            .accessibilityHint(fuelStopStore.candidates.count == 1
                ? "Rozpoznana stacja: \(fuelStopStore.candidates[0].identity.name)"
                : "Wybierz stację, na której tankujesz")
            .help("Dodaj tankowanie na stacji")
        }
    }

    @ViewBuilder func routeEnergyCostCaption(_ route: NavigationRoute) -> some View {
        if navigationStore.state.transportMode == .car,
           let estimate = energyStore.estimate(vehicleID: energyStore.selectedVehicle?.id,
               kilometers: route.distance / 1000, trips: placeStore.trips) {
            let quantity = estimate.components.map { "~\(EnergyNumber.text($0.quantity)) \($0.kind.unit)" }.joined(separator: " + ")
            Label("\(quantity) · ~\(EnergyNumber.money(estimate.cost))", systemImage: "fuelpump")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder func routeEnergyPreview(_ route: NavigationRoute) -> some View {
        if let vehicle = energyStore.selectedVehicle {
            VStack(alignment: .leading, spacing: 6) {
                Text(vehicle.name).font(.caption).foregroundStyle(.secondary)
                if let estimate = energyStore.estimate(vehicleID: vehicle.id,
                    kilometers: route.distance / 1000, trips: placeStore.trips) {
                    EnergyCostLabel(estimate: estimate)
                    Text("Szacunek ze średniego zużycia i ostatnich cen. Nie uwzględnia warunków na tej trasie.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Brak danych paliwa do oszacowania kosztu").font(.caption).foregroundStyle(.secondary)
                }
                Button("Paliwo i pojazdy") { appRouter.present(.energy) }.font(.caption)
            }
        } else {
            Button("Dodaj pojazd i oblicz koszt jazdy", systemImage: "fuelpump") { appRouter.present(.energy) }
                .font(.subheadline)
        }
    }
}
