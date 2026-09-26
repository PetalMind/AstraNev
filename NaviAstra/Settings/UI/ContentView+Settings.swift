import SwiftUI
import AVFAudio

extension ContentView {
    var trafficDetailsSheet: some View {
        NavigationStack {
            ScrollView { trafficCard.padding() }
                .navigationTitle("Ruch na żywo")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Zamknij") { appRouter.dismiss(.trafficDetails) }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    var settingsSheet: some View {
        NavigationStack {
            settingsForm
                .navigationTitle("Ustawienia")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Zamknij") { appRouter.dismiss(.settings) }
                    }
                }
                .onAppear { routePlanningStore.loadPreferences(from: engine) }
        }
    }

    private var settingsForm: some View {
        Form {
            settingsMapTypeSection
            settingsAppearanceSection
            settingsCameraSection
            settingsMapDetailsSection
            settingsPOISection
            settingsGuidanceSection
            settingsVoiceSection
            settingsDefaultRouteSection
            settingsRoutingSection
            settingsTrafficSection
            settingsValhallaSection
            settingsTransitSection
            settingsDisclaimer
        }
    }

    private var settingsMapTypeSection: some View {
        Section("Rodzaj mapy") {
            Picker("Mapa bazowa", selection: supportedBaseMap) {
                ForEach(BaseMap.allCases) { value in
                    Text(value.title).tag(value.rawValue)
                        .disabled(!mapCapabilities.supports(value))
                }
            }
            if !mapCapabilities.supportsSatellite {
                unavailableReason("Mapa satelitarna", reason: "Obecne źródło mapy nie udostępnia zdjęć satelitarnych.")
            }
            if !mapCapabilities.supportsTerrain {
                unavailableReason("Mapa terenowa", reason: "Obecne źródło mapy nie udostępnia terenu.")
            }
        }
    }

    private var settingsAppearanceSection: some View {
        Section("Wygląd") {
            Picker("Wygląd", selection: $mapAppearance) {
                ForEach(MapAppearance.allCases) { value in Text(value.title).tag(value.rawValue) }
            }
            .disabled(!mapCapabilities.supportsApplicationDarkMode)
            if !mapCapabilities.supportsMapDarkStyle {
                Text("Styl mapy nie obsługuje wariantu nocnego. Wybór zmienia tylko wygląd aplikacji.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var settingsCameraSection: some View {
        Section("Perspektywa i budynki") {
            Picker("Kamera", selection: $mapDimension) {
                ForEach(MapDimension.allCases) { value in Text(value.title).tag(value.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(!mapCapabilities.supports3DCamera)
            if mapCapabilities.supports3DBuildings {
                Toggle("Budynki 3D", isOn: $mapBuildingsVisible)
            } else {
                unavailableToggle("Budynki 3D", reason: "Obecny styl mapy nie udostępnia osobnej warstwy budynków.")
            }
        }
    }

    private var settingsMapDetailsSection: some View {
        Section("Szczegóły mapy") {
            if mapCapabilities.supportsTrafficOverlay {
                Toggle("Ruch drogowy", isOn: $mapTrafficVisible)
            } else {
                unavailableToggle("Ruch drogowy", reason: "Obecny dostawca nie udostępnia warstwy ruchu.")
            }
            if mapCapabilities.supportsPOIToggle {
                Toggle("POI", isOn: $mapPOIVisible)
            } else {
                unavailableToggle("POI", reason: "Obecny styl mapy nie pozwala osobno ukryć punktów zainteresowania.")
            }
            if mapCapabilities.supportsTransitOverlay {
                Toggle("Wyróżnij kolej i tramwaje", isOn: $mapTransitVisible)
            } else {
                unavailableToggle("Transport publiczny", reason: "Brak niezależnej warstwy u obecnego dostawcy mapy.")
            }
            if mapCapabilities.supportsCyclingOverlay {
                Toggle("Trasy rowerowe", isOn: $mapCyclingVisible)
            } else {
                unavailableToggle("Trasy rowerowe", reason: "Brak niezależnej warstwy u obecnego dostawcy mapy.")
            }
        }
    }

    private var settingsPOISection: some View {
        Section("Kategorie miejsc na mapie") {
            ForEach(MapPOICategory.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { mapPOICategories & category.mask != 0 },
                    set: { enabled in
                        if enabled { mapPOICategories |= category.mask }
                        else { mapPOICategories &= ~category.mask }
                    }))
            }
            .disabled(!mapPOIVisible)
            Text("Podczas prowadzenia mapa wybiera z zaznaczonych kategorii miejsca przydatne dla danego sposobu podróży. Przy celu wyróżnia parkingi i przystanki.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var settingsGuidanceSection: some View {
        Section("Prowadzenie i ostrzeżenia") {
            Toggle("Komunikaty głosowe", isOn: voiceEnabledBinding)
            Toggle("Ostrzegaj o przekroczeniu limitu", isOn: $speedWarningsEnabled)
        }
    }

    private var settingsVoiceSection: some View {
        Section("Głos i komunikaty") {
            Picker("Gadatliwość", selection: voiceVerbosityBinding) {
                ForEach(VoiceVerbosity.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Text(engine.state.voicePreferences.verbosity.detail)
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Głos polski", selection: voiceIdentifierBinding) {
                Text("Automatyczny").tag("")
                ForEach(availablePolishVoices, id: \.identifier) { voice in
                    Text(voice.name).tag(voice.identifier)
                }
            }
            if availablePolishVoices.isEmpty {
                Text("System nie udostępnia listy głosów polskich; aplikacja poprosi o głos systemowy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            voiceSliderRow(
                title: "Tempo mowy",
                value: voiceRateBinding,
                range: 0.38...0.62,
                valueDescription: String(format: "%.0f%%", Double(engine.state.voicePreferences.speechRate) * 200)
            )
            voiceSliderRow(
                title: "Głośność komunikatów",
                value: voiceVolumeBinding,
                range: 0...1,
                valueDescription: String(format: "%.0f%%", Double(engine.state.voicePreferences.volume) * 100)
            )
        }
    }

    private var settingsRoutingSection: some View {
        Section("Preferencje trasy i pojazd elektryczny") {
            Toggle("Unikaj dróg płatnych", isOn: $routePlanningStore.draftPreferences.avoidTolls)
            Toggle("Unikaj autostrad", isOn: $routePlanningStore.draftPreferences.avoidHighways)
            Toggle("Unikaj promów", isOn: $routePlanningStore.draftPreferences.avoidFerries)
            Toggle("Unikaj dróg gruntowych", isOn: $routePlanningStore.draftPreferences.avoidUnpaved)
            Text("Serwer może poprowadzić tym typem drogi, jeśli nie ma rozsądnej alternatywy.")
                .font(.footnote).foregroundStyle(.secondary)

            Toggle("Uwzględnij zasięg EV", isOn: $routePlanningStore.draftPreferences.evPlanningEnabled)
            if routePlanningStore.draftPreferences.evPlanningEnabled {
                TextField("Zasięg przy pełnej baterii (km)", value: $routePlanningStore.draftPreferences.evRangeKilometers,
                          format: .number.precision(.fractionLength(0)))
                Stepper("Poziom baterii: \(routePlanningStore.draftPreferences.evBatteryPercent)%",
                        value: $routePlanningStore.draftPreferences.evBatteryPercent, in: 1...100, step: 5)
                TextField("Zużycie (kWh/100 km)", value: $routePlanningStore.draftPreferences.evConsumptionKWhPer100Km,
                          format: .number.precision(.fractionLength(1)))
                TextField("Maks. moc ładowania auta (kW)", value: $routePlanningStore.draftPreferences.evMaximumChargingPowerKW,
                          format: .number.precision(.fractionLength(0)))
                evConnectorToggle("ccs", title: "CCS")
                evConnectorToggle("type2", title: "Type 2")
                evConnectorToggle("chademo", title: "CHAdeMO")
                Text("Dostępny zasięg: \(Int(routePlanningStore.draftPreferences.availableEVRangeKilometers.rounded())) km. Zaznaczone złącza filtrują stacje; pusty wybór dopuszcza wszystkie znane typy. Czas szacujemy z zużycia auta i mocy w OpenStreetMap, bez sprawdzania zajętości na żywo.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Zastosuj preferencje trasy") {
                Task { await routePlanningStore.applyPreferences(to: engine) }
            }
        }
    }

    private var settingsDefaultRouteSection: some View {
        Section("Typ trasy domyślny") {
            Picker("Środek transportu", selection: $defaultTransportMode) {
                ForEach(TransportMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text("Ten środek transportu będzie wybierany przy rozpoczęciu nowej trasy. Możesz go zmienić w podglądzie trasy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsTrafficSection: some View {
        Section("Ruch na żywo · TomTom") {
            NavigationLink {
                ScrollView { trafficCard.padding() }
                    .navigationTitle("Ruch na żywo")
            } label: {
                Label("Bieżące warunki", systemImage: "car.side")
            }
            Text(trafficConfigured
                 ? "Klucz API zapisany na tym urządzeniu."
                 : "Wpisz klucz API TomTom, aby włączyć bieżący ruch.")
            SecureField("Klucz API TomTom", text: $trafficKey)
            Button("Zapisz klucz") {
                guard !trafficKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if engine.configureTraffic(apiKey: trafficKey) {
                    trafficConfigured = true
                    trafficKey = ""
                } else {
                    engine.state.errorMessage = "Nie udało się zapisać klucza w pęku kluczy."
                }
            }
            .disabled(trafficKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if trafficConfigured {
                Button("Wyłącz ruch i usuń klucz", role: .destructive) {
                    if engine.configureTraffic(apiKey: nil) { trafficConfigured = false }
                    else { engine.state.errorMessage = "Nie udało się usunąć klucza z pęku kluczy." }
                }
            }
        }
    }

    private var settingsValhallaSection: some View {
        Section("Serwer Valhalla") {
            TextField("https://…", text: $serverAddress)
                .autocorrectionDisabled()
            Button("Zapisz serwer") {
                guard let url = URL(string: serverAddress), url.scheme == "https", url.host != nil else {
                    engine.state.errorMessage = "Podaj poprawny adres HTTPS serwera Valhalla."
                    return
                }
                UserDefaults.standard.set(serverAddress, forKey: "routingServer")
                engine.updateProvider(ValhallaRouteProvider(endpoint: url))
                appRouter.dismiss(.settings)
            }
        }
    }

    private var settingsTransitSection: some View {
        Section("Komunikacja miejska · MPK Łódź") {
            Text("Rozkłady autobusów i tramwajów, aktualizacje kursów, opóźnienia i komunikaty są pobierane bezpośrednio z otwartych danych miasta Łodzi. Mapa pokazuje świeże pozycje pojazdów. Rozkład jest zapisywany na urządzeniu i odświeżany raz dziennie.")
            Link("Otwarte dane Łódź", destination: URL(string: "https://otwarte.miasto.lodz.pl/transport_komunikacja/")!)
            Link("Rozkłady MPK Łódź", destination: URL(string: "https://www.mpk.lodz.pl/rozklady/linie.jsp")!)
        }
    }

    private var settingsDisclaimer: some View {
        Text("Mapa, wyszukiwanie, routing, limity i ruch na żywo wymagają internetu. TomTom może zmienić ETA i wybór spośród wariantów Valhalli; limity są informacyjne. Trasy i GPS są zapisywane tylko w lokalnej historii podróży. Tryb offline nie jest dostępny.")
            .font(.footnote)
    }

    var routeSettingsSheet: some View {
        let mode = engine.state.transportMode
        return NavigationStack {
            Form {
                if supportsActiveTripRoadPreferences {
                    Section(mode == .parkRide ? "Odcinek samochodowy" : "Preferencje trasy") {
                        Toggle("Unikaj dróg płatnych", isOn: $routePlanningStore.draftPreferences.avoidTolls)
                        Toggle("Unikaj autostrad", isOn: $routePlanningStore.draftPreferences.avoidHighways)
                        Toggle("Unikaj promów", isOn: $routePlanningStore.draftPreferences.avoidFerries)
                        Toggle("Unikaj dróg gruntowych", isOn: $routePlanningStore.draftPreferences.avoidUnpaved)
                    }
                }

                if mode == .car {
                    Section("Pojazd elektryczny") {
                        Toggle("Uwzględnij zasięg EV", isOn: $routePlanningStore.draftPreferences.evPlanningEnabled)
                        if routePlanningStore.draftPreferences.evPlanningEnabled {
                            TextField("Zasięg przy pełnej baterii (km)", value: $routePlanningStore.draftPreferences.evRangeKilometers,
                                      format: .number.precision(.fractionLength(0)))
                            Stepper("Poziom baterii: \(routePlanningStore.draftPreferences.evBatteryPercent)%",
                                    value: $routePlanningStore.draftPreferences.evBatteryPercent, in: 1...100, step: 5)
                            TextField("Zużycie (kWh/100 km)", value: $routePlanningStore.draftPreferences.evConsumptionKWhPer100Km,
                                      format: .number.precision(.fractionLength(1)))
                            TextField("Maks. moc ładowania auta (kW)", value: $routePlanningStore.draftPreferences.evMaximumChargingPowerKW,
                                      format: .number.precision(.fractionLength(0)))
                            evConnectorToggle("ccs", title: "CCS")
                            evConnectorToggle("type2", title: "Type 2")
                            evConnectorToggle("chademo", title: "CHAdeMO")
                            Text("Złącza, moc i status stacji pochodzą z OpenStreetMap. Brak wpisu o dostępności oznacza stan nieznany; aplikacja nie pobiera zajętości ładowarek.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("Zmiany zostaną użyte przy kolejnym przeliczeniu odcinka samochodowego.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Zastosuj ustawienia trasy") {
                        Task {
                            await routePlanningStore.applyPreferences(to: engine)
                            appRouter.dismiss(.routeSettings)
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationTitle("Ustawienia trasy")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { appRouter.dismiss(.routeSettings) }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func evConnectorToggle(_ connector: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { routePlanningStore.draftPreferences.evConnectorTypes.contains(connector) },
            set: { isEnabled in
                if isEnabled { routePlanningStore.draftPreferences.evConnectorTypes.insert(connector) }
                else { routePlanningStore.draftPreferences.evConnectorTypes.remove(connector) }
            }))
    }

    private func unavailableReason(_ title: String, reason: String) -> some View {
        Text("\(title): \(reason)")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func unavailableToggle(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: .constant(false))
                .disabled(true)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ruch na żywo", systemImage: "car.side")
                    .font(.headline)
                Spacer()
                Button {
                    engine.refreshTraffic(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Odśwież ruch")
            }

            switch engine.state.trafficStatus {
            case .notConfigured:
                Label("Wpisz klucz TomTom w ustawieniach.", systemImage: "key")
                    .foregroundStyle(.secondary)
            case .updating:
                Label("Pobieranie danych o ruchu…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .unavailable(let reason):
                Label("Ruch niedostępny: \(reason)", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            case .available:
                if let flow = engine.state.traffic?.flow {
                    Label(
                        flow.roadClosure
                            ? "Zgłoszone zamknięcie pobliskiego odcinka"
                            : "Pobliska droga: \(flow.currentSpeedKph) km/h · swobodnie \(flow.freeFlowSpeedKph) km/h",
                        systemImage: flow.roadClosure ? "exclamationmark.triangle" : "car.side"
                    )
                } else {
                    Text("Brak pomiaru przepływu przy pozycji.")
                        .foregroundStyle(.secondary)
                }

                if let incidents = engine.state.traffic?.incidents {
                    Text(incidents.isEmpty
                         ? "Brak zgłoszonych utrudnień na pobliskiej trasie."
                         : "Utrudnienia na pobliskiej trasie: \(incidents.count)")
                    ForEach(incidents.prefix(2)) { incident in
                        Text("• \(incident.description)")
                            .lineLimit(2)
                    }
                }

                if let partialError = engine.state.traffic?.partialError {
                    Text(partialError)
                        .foregroundStyle(.secondary)
                }

                if let updatedAt = engine.state.traffic?.updatedAt {
                    Text("Aktualizacja: \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

}
