import SwiftUI

struct ValhallaPreferencesView: View {
    let navigation: NavigationStore
    @State private var draft = RoutingPreferences()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Pojazdy silnikowe") {
                Picker("Profil pojazdu", selection: $draft.advanced.vehicle) {
                    ForEach(ValhallaVehicle.allCases) { Text($0.title).tag($0) }
                }
                if draft.advanced.vehicle == .truck {
                    number("Wysokość (m)", value: $draft.advanced.truckHeight)
                    number("Szerokość (m)", value: $draft.advanced.truckWidth)
                    number("Długość (m)", value: $draft.advanced.truckLength)
                    number("Masa całkowita (t)", value: $draft.advanced.truckWeight)
                    number("Nacisk osi (t)", value: $draft.advanced.truckAxleLoad)
                    Toggle("Ładunek niebezpieczny", isOn: $draft.advanced.truckHazmat)
                }
                if draft.advanced.vehicle == .motorScooter {
                    Stepper("Maksymalna prędkość: \(Int(draft.advanced.scooterTopSpeed)) km/h",
                            value: $draft.advanced.scooterTopSpeed, in: 20...120, step: 5)
                }
                Text("Profil pojazdu jest używany w trybie Auto. Ograniczenia pojazdu zależą od kompletności danych OpenStreetMap.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.evPlanningEnabled && draft.advanced.vehicle != .auto {
                    Text("Wyłącz planowanie ładowania EV lub wybierz samochód, aby wyznaczyć trasę.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Pieszo i dostępność") {
                Picker("Profil pieszy", selection: $draft.advanced.walkingProfile) {
                    ForEach(ValhallaWalkingProfile.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Tempo marszu: \(draft.advanced.walkingSpeed.formatted(.number.precision(.fractionLength(1)).locale(PolishRegionalFormat.locale))) km/h",
                        value: $draft.advanced.walkingSpeed, in: 0.5...15, step: 0.1)
                Stepper("Tempo na wózku: \(draft.advanced.wheelchairSpeed.formatted(.number.precision(.fractionLength(1)).locale(PolishRegionalFormat.locale))) km/h",
                        value: $draft.advanced.wheelchairSpeed, in: 0.5...15, step: 0.1)
                Toggle("Preferuj oświetlone ulice", isOn: $draft.advanced.preferLit)
                Stepper("Maksymalna trudność szlaku: \(draft.advanced.hikingDifficulty)",
                        value: $draft.advanced.hikingDifficulty, in: 0...6)
                Text("Skala 0–6: od łatwych ścieżek do trudnych szlaków alpejskich. Profil wózka dostosowuje koszty schodów i tempo; dane mapowe nie gwarantują dostępności całej trasy. Preferowanie oświetlenia nie gwarantuje oświetlonej drogi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rower") {
                Picker("Typ roweru", selection: $draft.advanced.bicycle) {
                    ForEach(ValhallaBicycle.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Tempo na płaskiej drodze: \(Int(draft.advanced.cyclingSpeed)) km/h",
                        value: $draft.advanced.cyclingSpeed, in: 5...60)
                VStack(alignment: .leading) {
                    Text("Jezdnie: \(Int(draft.advanced.useRoads * 100))%")
                    Slider(value: $draft.advanced.useRoads, in: 0...1)
                        .accessibilityLabel("Akceptacja jazdy po jezdniach")
                        .accessibilityValue(draft.advanced.useRoads.formatted(.percent.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale)))
                    Text("Niższa wartość preferuje drogi rowerowe i spokojniejsze ulice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            Section("Komunikacja publiczna") {
                TransitPreferencesFields(preferences: $draft.transit)
            }
            #endif
            Section("Trasy piesze i rowerowe") {
                VStack(alignment: .leading) {
                    Text("Akceptacja podejść pieszo: \(Int(draft.advanced.walkingUseHills * 100))%")
                    Slider(value: $draft.advanced.walkingUseHills, in: 0...1)
                        .accessibilityLabel("Akceptacja podejść pieszo")
                        .accessibilityValue(draft.advanced.walkingUseHills.formatted(.percent.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale)))
                }
                VStack(alignment: .leading) {
                    Text("Akceptacja podjazdów rowerem: \(Int(draft.advanced.useHills * 100))%")
                    Slider(value: $draft.advanced.useHills, in: 0...1)
                        .accessibilityLabel("Akceptacja podjazdów rowerem")
                        .accessibilityValue(draft.advanced.useHills.formatted(.percent.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale)))
                    Text("Niższa wartość preferuje łagodniejsze trasy, jeśli istnieje alternatywa.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Dojazd i wybór trasy") {
                Picker("Wybór trasy drogowej", selection: Binding(
                    get: { draft.advanced.effectiveRoutePreference },
                    set: { draft.advanced.routePreference = $0; draft.advanced.shortest = $0 == .shortest })) {
                    ForEach(RoutePreference.allCases) { Text($0.title).tag($0) }
                }
                Text("Najszybsza wybiera najkrótszy szacowany czas. Polecana dla mnie uwzględnia zapamiętane wybory, jeśli uczenie tras jest włączone. Historia nie zmienia wyboru w pozostałych profilach ani wyświetlanego czasu jazdy.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Zrównoważona i polecana: do 15% i najwyżej 5 min dłużej, do 20% i najwyżej 5 km dalej od najszybszej trasy. Wygodna: do 25% i najwyżej 10 min dłużej, do 30% i najwyżej 10 km dalej. Mniej manewrów i lepsza znana nawierzchnia pomagają wybrać wariant w tych granicach.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Najkrótsza odległość wpływa także na profil tras pieszych i rowerowych.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.advanced.effectiveRoutePreference == .shortest {
                    Text("Przy wyborze najkrótszej odległości serwer pomija miękkie preferencje dróg, opłat i podjazdów. Ograniczenia dostępu i wykluczone obszary nadal obowiązują.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Strona dojazdu do celu", selection: $draft.advanced.arrivalSide) {
                    ForEach(ValhallaArrivalSide.allCases) { Text($0.title).tag($0) }
                }
                Text("Strona ruchu oznacza prawą w Polsce i lewą w krajach z ruchem lewostronnym. Ustawienie może nie mieć zastosowania przy skrzyżowaniu lub celu na osi drogi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Ustawienia zapisują się automatycznie. W podglądzie przeliczają trasę. Podczas jazdy zostaną użyte przy następnym przeliczeniu. Godzinę wyjazdu lub przyjazdu wybierzesz w planowaniu trasy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, PolishRegionalFormat.locale)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Profile i preferencje")
        .onAppear { draft = navigation.state.routingPreferences; loaded = true }
        .onChange(of: draft) { _, value in
            guard loaded, value != navigation.state.routingPreferences else { return }
            saveTask?.cancel()
            saveTask = Task {
                do { try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation() }
                catch { return }
                await navigation.updateRoutingPreferences(value)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            let value = draft
            if value != navigation.state.routingPreferences {
                Task { await navigation.updateRoutingPreferences(value) }
            }
        }
    }

    private func number(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(1...2)).locale(PolishRegionalFormat.locale))
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }
}
