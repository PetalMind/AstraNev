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
                .onAppear { routePlanningStore.loadPreferences(from: navigationStore) }
        }
    }

    private var settingsForm: some View {
        Form {
            settingsMapTypeSection
            settingsAppearanceSection
            settingsCameraSection
            settingsMapDetailsSection
            settingsSafetyPOISection
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
            Picker("Wygląd", selection: $mapStore.mapAppearance) {
                ForEach(MapAppearance.allCases) { value in Text(value.title).tag(value.rawValue) }
            }
            .disabled(!mapCapabilities.supportsApplicationDarkMode)
            if !mapCapabilities.supportsMapDarkStyle {
                Text("Styl mapy nie obsługuje wariantu nocnego. Wybór zmienia tylko wygląd aplikacji.")
                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            }
        }
    }

    private var settingsCameraSection: some View {
        Section("Perspektywa i budynki") {
            Picker("Kamera", selection: $mapStore.mapDimension) {
                ForEach(MapDimension.allCases) { value in Text(value.title).tag(value.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(!mapCapabilities.supports3DCamera)
            if mapCapabilities.supports3DBuildings {
                Toggle("Budynki 3D", isOn: $mapStore.mapBuildingsVisible)
            } else {
                unavailableToggle("Budynki 3D", reason: "Obecny styl mapy nie udostępnia osobnej warstwy budynków.")
            }
        }
    }

    private var settingsMapDetailsSection: some View {
        Section("Szczegóły mapy") {
            if mapCapabilities.supportsTrafficOverlay {
                Toggle("Ruch drogowy", isOn: $mapStore.mapTrafficVisible)
            } else {
                unavailableToggle("Ruch drogowy", reason: "Obecny dostawca nie udostępnia warstwy ruchu.")
            }
            if mapCapabilities.supportsPOIToggle {
                Toggle("POI", isOn: $mapStore.mapPOIVisible)
            } else {
                unavailableToggle("POI", reason: "Obecny styl mapy nie pozwala osobno ukryć punktów zainteresowania.")
            }
            if mapCapabilities.supportsTransitOverlay {
                Toggle("Wyróżnij kolej i tramwaje", isOn: $mapStore.mapTransitVisible)
            } else {
                unavailableToggle("Transport publiczny", reason: "Brak niezależnej warstwy u obecnego dostawcy mapy.")
            }
            if mapCapabilities.supportsCyclingOverlay {
                Toggle("Ścieżki rowerowe (OSM)", isOn: $mapStore.mapCyclingVisible)
            } else {
                unavailableToggle("Ścieżki rowerowe (OSM)", reason: "Brak niezależnej warstwy u obecnego dostawcy mapy.")
            }
        }
    }

    private var settingsPOISection: some View {
        Section("Kategorie miejsc na mapie") {
            ForEach(MapPOICategory.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { mapStore.mapPOICategories & category.mask != 0 },
                    set: { enabled in
                        if enabled { mapStore.mapPOICategories |= category.mask }
                        else { mapStore.mapPOICategories &= ~category.mask }
                    }))
            }
            .disabled(!mapStore.mapPOIVisible)
            Text("Podczas prowadzenia mapa wybiera z zaznaczonych kategorii miejsca przydatne dla danego sposobu podróży. Przy celu wyróżnia parkingi i przystanki.")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        }
    }

    private var settingsSafetyPOISection: some View {
        Section("Fotoradary, kamery i sygnalizacja") {
            ForEach(MapSafetyPOICategory.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { mapStore.mapSafetyPOICategories & category.mask != 0 },
                    set: { enabled in
                        if enabled { mapStore.mapSafetyPOICategories |= category.mask }
                        else { mapStore.mapSafetyPOICategories &= ~category.mask }
                    }))
            }
            Text("Punkty pochodzą z OpenStreetMap. Przy oddalonym widoku kamery monitoringu i sygnalizatory pojawiają się dopiero po zbliżeniu mapy.")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            roadPOIStatusLabel
        }
    }

    @ViewBuilder
    private var roadPOIStatusLabel: some View {
        switch mapStore.roadPOIStatus {
        case .disabled:
            EmptyView()
        case .zoomIn:
            Label("Zbliż mapę, aby pobrać te punkty", systemImage: "plus.magnifyingglass")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        case .loading:
            Label("Pobieranie punktów z OpenStreetMap…", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        case .loaded(count: 0):
            Label("Brak oznaczonych punktów w tym widoku", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        case .loaded(let count):
            Label("OpenStreetMap · \(count) punktów", systemImage: "mappin.and.ellipse")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        case .unavailable:
            Label("Dane OpenStreetMap są niedostępne", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
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
            Text(navigationStore.state.voicePreferences.verbosity.detail)
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            Picker("Głos polski", selection: voiceIdentifierBinding) {
                Text("Automatyczny").tag("")
                ForEach(availablePolishVoices, id: \.identifier) { voice in
                    Text(voice.name).tag(voice.identifier)
                }
            }
            if availablePolishVoices.isEmpty {
                Text("System nie udostępnia listy głosów polskich; aplikacja poprosi o głos systemowy.")
                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            }
            voiceSliderRow(
                title: "Tempo mowy",
                value: voiceRateBinding,
                range: 0.38...0.62,
                valueDescription: String(format: "%.0f%%", Double(navigationStore.state.voicePreferences.speechRate) * 200)
            )
            voiceSliderRow(
                title: "Głośność komunikatów",
                value: voiceVolumeBinding,
                range: 0...1,
                valueDescription: String(format: "%.0f%%", Double(navigationStore.state.voicePreferences.volume) * 100)
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
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)

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
                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            }
            Button("Zastosuj preferencje trasy") {
                Task { await routePlanningStore.applyPreferences(to: navigationStore) }
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
                .foregroundStyle(Color.naviTextSecondary)
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
                if navigationStore.configureTraffic(apiKey: trafficKey) {
                    trafficConfigured = true
                    trafficKey = ""
                } else {
                    navigationStore.state.errorMessage = "Nie udało się zapisać klucza w pęku kluczy."
                }
            }
            .disabled(trafficKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if trafficConfigured {
                Button("Wyłącz ruch i usuń klucz", role: .destructive) {
                    if navigationStore.configureTraffic(apiKey: nil) { trafficConfigured = false }
                    else { navigationStore.state.errorMessage = "Nie udało się usunąć klucza z pęku kluczy." }
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
                    navigationStore.state.errorMessage = "Podaj poprawny adres HTTPS serwera Valhalla."
                    return
                }
                UserDefaults.standard.set(serverAddress, forKey: "routingServer")
                navigationStore.updateRoutingEndpoint(url)
                appRouter.dismiss(.settings)
            }
        }
    }

    private var settingsTransitSection: some View {
        Section("Komunikacja publiczna") {
            Text("Trasy, wyszukiwanie przystanków, odjazdy i przystanki widoczne na mapie korzystają z Transitous w obsługiwanych regionach. Dostępność i realtime zależą od źródeł danych Transitous. Rzeczywiste pozycje pojazdów są obecnie dostępne tylko z feedu MPK Łódź.")
            Text("Zapytania o trasę i przystanki oraz obszar widoczny na mapie są wysyłane do Transitous. Usługa wymaga publicznego kontaktu w User-Agent; jej zasady proszą też o kontakt przed użyciem kosztownego routingu.")
            TextField("Publiczny e-mail lub URL projektu · User-Agent", text: $transitousContact)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Link("Transitous · zasady API", destination: URL(string: "https://transitous.org/api/")!)
            Link("Transitous · źródła danych", destination: URL(string: "https://transitous.org/sources/")!)
            Link("MPK Łódź · otwarte dane", destination: transitStore.region.dataPortalURL)
            Link("MPK Łódź · rozkład jazdy", destination: transitStore.region.scheduleURL)
        }
    }

    private var settingsDisclaimer: some View {
        Text("Mapa, wyszukiwanie, routing, limity i ruch na żywo wymagają internetu. TomTom może zmienić ETA i wybór spośród wariantów Valhalli; limity są informacyjne. Trasy i GPS są zapisywane tylko w lokalnej historii podróży. Tryb offline nie jest dostępny.")
            .font(.footnote)
    }

    var routeSettingsSheet: some View {
        let mode = navigationStore.state.transportMode
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
                                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
                        }
                    }
                }

                Section {
                    Text("Zmiany zostaną użyte przy kolejnym przeliczeniu odcinka samochodowego.")
                        .font(.footnote)
                        .foregroundStyle(Color.naviTextSecondary)
                    Button("Zastosuj ustawienia trasy") {
                        Task {
                            await routePlanningStore.applyPreferences(to: navigationStore)
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
            .foregroundStyle(Color.naviTextSecondary)
    }

    private func unavailableToggle(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: .constant(false))
                .disabled(true)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(Color.naviTextSecondary)
        }
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ruch na żywo", systemImage: "car.side")
                    .font(.headline)
                Spacer()
                Button {
                    navigationStore.refreshTraffic(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Odśwież ruch")
            }

            switch navigationStore.state.trafficStatus {
            case .notConfigured:
                Label("Wpisz klucz TomTom w ustawieniach.", systemImage: "key")
                    .foregroundStyle(Color.naviTextSecondary)
            case .updating:
                Label("Pobieranie danych o ruchu…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.naviTextSecondary)
            case .unavailable(let reason):
                Label("Ruch niedostępny: \(reason)", systemImage: "wifi.slash")
                    .foregroundStyle(Color.naviTextSecondary)
            case .available:
                if let flow = navigationStore.state.traffic?.flow {
                    Label(
                        flow.roadClosure
                            ? "Zgłoszone zamknięcie pobliskiego odcinka"
                            : "Pobliska droga: \(flow.currentSpeedKph) km/h · swobodnie \(flow.freeFlowSpeedKph) km/h",
                        systemImage: flow.roadClosure ? "exclamationmark.triangle" : "car.side"
                    )
                } else {
                    Text("Brak pomiaru przepływu przy pozycji.")
                        .foregroundStyle(Color.naviTextSecondary)
                }

                if let incidents = navigationStore.state.traffic?.incidents {
                    Text(incidents.isEmpty
                         ? "Brak zgłoszonych utrudnień na pobliskiej trasie."
                         : "Utrudnienia na pobliskiej trasie: \(incidents.count)")
                    ForEach(incidents.prefix(2)) { incident in
                        Text("• \(incident.description)")
                            .lineLimit(2)
                    }
                }

                if let partialError = navigationStore.state.traffic?.partialError {
                    Text(partialError)
                        .foregroundStyle(Color.naviTextSecondary)
                }

                if let updatedAt = navigationStore.state.traffic?.updatedAt {
                    Text("Aktualizacja: \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .font(.subheadline)
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

}
