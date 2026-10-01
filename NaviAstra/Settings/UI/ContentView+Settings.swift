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
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Zamknij") { appRouter.dismiss(.settings) }
            }
        }
        // Load once for the sheet, so returning from a category preserves route edits.
        .onAppear { routePlanningStore.loadPreferences(from: navigationStore) }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 680)
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("Nawigacja") {
                settingsCategory("Trasy i pojazd", subtitle: defaultTransportTitle,
                                 icon: "point.topleft.down.curvedto.point.bottomright.up") {
                    settingsRoutePage
                }
                settingsCategory("Głos i ostrzeżenia",
                                 subtitle: navigationStore.state.voiceEnabled
                                    ? "Głos włączony · \(navigationStore.state.voicePreferences.verbosity.title)"
                                    : "Komunikaty głosowe wyłączone",
                                 icon: "speaker.wave.2.fill") {
                    settingsGuidancePage
                }
            }
            Section("Mapa") {
                settingsCategory("Wygląd i zawartość mapy",
                                 subtitle: "\((MapAppearance(rawValue: mapStore.mapAppearance) ?? .auto).title) · \((MapDimension(rawValue: mapStore.mapDimension) ?? .flat).title)",
                                 icon: "map.fill") {
                    settingsMapPage
                }
            }
            Section("Usługi nawigacyjne") {
                settingsCategory("Ruch drogowy",
                                 subtitle: trafficConfigured ? "TomTom · klucz zapisany" : "TomTom · wymaga klucza API",
                                 icon: "car.side.fill") {
                    settingsPage("Ruch drogowy") { settingsTrafficSection }
                }
                settingsCategory("Komunikacja publiczna", subtitle: "Transitous i MPK Łódź",
                                 icon: "tram.fill") {
                    settingsPage("Komunikacja publiczna") { settingsTransitSection }
                }
            }
            Section("Aplikacja") {
                settingsCategory("Zaawansowane", subtitle: "Serwer wyznaczania tras",
                                 icon: "slider.horizontal.3") {
                    settingsPage("Zaawansowane") { settingsValhallaSection }
                }
                settingsCategory("Dane i prywatność", subtitle: "Internet i lokalna historia podróży",
                                 icon: "info.circle.fill") {
                    settingsPage("Dane i prywatność") {
                        Section("Dostępność i dane") { settingsDisclaimer }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var defaultTransportTitle: String {
        (TransportMode(rawValue: defaultTransportMode) ?? .car).title
    }

    private func settingsCategory<Destination: View>(
        _ title: String, subtitle: String, icon: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.naviTextPrimary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        }
    }

    private func settingsPage<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    private var settingsMapPage: some View {
        settingsPage("Mapa") {
            settingsAppearanceSection
            settingsMapTypeSection
            settingsCameraSection
            settingsMapDetailsSection
            Section("Miejsca i punkty drogowe") {
                settingsCategory("Kategorie miejsc",
                                 subtitle: mapStore.mapPOIVisible ? "Parkingi, paliwo, restauracje i inne miejsca" : "Miejsca na mapie są ukryte",
                                 icon: "mappin.and.ellipse") {
                    settingsPage("Kategorie miejsc") { settingsPOISection }
                }
                settingsCategory("Punkty drogowe", subtitle: "Fotoradary, kamery i sygnalizacja",
                                 icon: "camera.fill") {
                    settingsPage("Punkty drogowe") { settingsSafetyPOISection }
                }
            }
        }
    }

    private var settingsGuidancePage: some View {
        settingsPage("Głos i ostrzeżenia") {
            settingsVoiceSection
            settingsGuidanceSection
        }
    }

    private var settingsRoutePage: some View {
        settingsPage("Trasy i pojazd") {
            settingsDefaultRouteSection
            settingsRoutingSection
            settingsElectricVehicleSection
            if routePlanningStore.draftPreferences.evPlanningEnabled {
                Section {
                    evConnectorToggle("ccs", title: "CCS")
                    evConnectorToggle("type2", title: "Type 2")
                    evConnectorToggle("chademo", title: "CHAdeMO")
                } header: {
                    Text("Złącza ładowania")
                } footer: {
                    Text("Zaznaczone złącza filtrują stacje. Pusty wybór dopuszcza wszystkie znane typy.")
                }
            }
            Section {
                Button {
                    Task { await routePlanningStore.applyPreferences(to: navigationStore) }
                } label: {
                    Text("Zastosuj preferencje trasy")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            } footer: {
                Text("Domyślny środek transportu zapisuje się automatycznie. Preferencje dróg i pojazdu elektrycznego zatwierdź przyciskiem powyżej.")
            }
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
                Toggle("Miejsca na mapie", isOn: $mapStore.mapPOIVisible)
            } else {
                unavailableToggle("Miejsca na mapie", reason: "Obecny styl mapy nie pozwala osobno ukryć punktów zainteresowania.")
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
        Section {
            ForEach(MapPOICategory.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { mapStore.mapPOICategories & category.mask != 0 },
                    set: { enabled in
                        if enabled { mapStore.mapPOICategories |= category.mask }
                        else { mapStore.mapPOICategories &= ~category.mask }
                    }))
            }
            .disabled(!mapStore.mapPOIVisible)
        } header: {
            Text("Kategorie miejsc na mapie")
        } footer: {
            if !mapStore.mapPOIVisible {
                Text("Kategorie są nieaktywne, ponieważ miejsca na mapie są ukryte. Włącz je w sekcji Szczegóły mapy.")
            }
            Text("Podczas prowadzenia mapa wybiera z zaznaczonych kategorii miejsca przydatne dla danego sposobu podróży. Przy celu wyróżnia parkingi i przystanki.")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        }
    }

    private var settingsSafetyPOISection: some View {
        Group {
            Section {
                settingsSafetyCategoryToggles
            } header: {
                Text("Widoczność na mapie")
            } footer: {
                Text("Te przełączniki dotyczą mapy. Komunikaty głosowe ustawisz w kategorii Głos i ostrzeżenia.")
            }
            Section("Dane drogowe") {
                roadPOIStatusLabel
                DisclosureGroup("Źródła i ograniczenia danych") {
                    settingsRoadDataDescription
                }
                Link("CANARD / GITD · źródło i licencja CC BY 4.0", destination: CANARDRoadDataProvider.mapURL)
                    .font(.footnote)
            }
        }
    }

    private var settingsSafetyCategoryToggles: some View {
        ForEach(MapSafetyPOICategory.allCases) { category in
            Toggle(category.title, isOn: Binding(
                get: { mapStore.mapSafetyPOICategories & category.mask != 0 },
                set: { enabled in
                    if enabled { mapStore.mapSafetyPOICategories |= category.mask }
                    else { mapStore.mapSafetyPOICategories &= ~category.mask }
                }))
        }
    }

    private var settingsRoadDataDescription: some View {
        Text("Punkty pochodzą z OpenStreetMap oraz publicznej mapy CANARD w Polsce. Dane CANARD są odświeżane co 24 godziny i mają charakter poglądowy. Kamery monitoringu i sygnalizatory pojawiają się po zbliżeniu mapy. Sygnalizacja oznacza lokalizację świateł, bez informacji o ich aktualnym kolorze.")
            .font(.footnote)
            .foregroundStyle(Color.naviTextSecondary)
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
            Label("Pobieranie punktów drogowych…", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        case .loaded(count: 0):
            Label("Brak oznaczonych punktów w tym widoku", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        case .loaded(let count):
            Label("Źródła drogowe · \(count) punktów", systemImage: "mappin.and.ellipse")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        case .partial(let count, let message):
            Label("\(count) punktów · \(message)", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
        case .unavailable:
            Label("Dane punktów drogowych są niedostępne", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
        }
    }

    private var settingsGuidanceSection: some View {
        Section {
            Toggle("Ostrzegaj o przekroczeniu limitu", isOn: $speedWarningsEnabled)
        } header: {
            Text("Ostrzeżenia o prędkości")
        } footer: {
            Text("Limity prędkości mają charakter informacyjny. Zawsze stosuj się do znaków drogowych.")
        }
    }

    private var settingsVoiceSection: some View {
        Section("Komunikaty głosowe") {
            Toggle("Komunikaty głosowe", isOn: voiceEnabledBinding)
            Picker("Szczegółowość komunikatów", selection: voiceVerbosityBinding) {
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
        Section {
            Toggle("Unikaj dróg płatnych", isOn: $routePlanningStore.draftPreferences.avoidTolls)
            Toggle("Unikaj autostrad", isOn: $routePlanningStore.draftPreferences.avoidHighways)
            Toggle("Unikaj promów", isOn: $routePlanningStore.draftPreferences.avoidFerries)
            Toggle("Unikaj dróg gruntowych", isOn: $routePlanningStore.draftPreferences.avoidUnpaved)
        } header: {
            Text("Preferencje dróg")
        } footer: {
            Text("Serwer może poprowadzić tym typem drogi, jeśli nie ma rozsądnej alternatywy.")
        }
    }

    private var settingsElectricVehicleSection: some View {
        Section {
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
                LabeledContent("Dostępny zasięg",
                               value: "\(Int(routePlanningStore.draftPreferences.availableEVRangeKilometers.rounded())) km")
            }
        } header: {
            Text("Pojazd elektryczny")
        } footer: {
            if routePlanningStore.draftPreferences.evPlanningEnabled {
                Text("Czas ładowania szacujemy z zużycia auta i mocy w OpenStreetMap, bez sprawdzania zajętości na żywo.")
            }
        }
    }

    private var settingsDefaultRouteSection: some View {
        Section {
            Picker("Środek transportu", selection: $defaultTransportMode) {
                ForEach(TransportMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
        } header: {
            Text("Nowa trasa")
        } footer: {
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
        Group {
            Section("Dostępność połączeń") {
                Text("Trasy, wyszukiwanie przystanków, odjazdy i przystanki widoczne na mapie korzystają z Transitous w obsługiwanych regionach. Dostępność i realtime zależą od źródeł danych Transitous. Rzeczywiste pozycje pojazdów są obecnie dostępne tylko z feedu MPK Łódź.")
                    .foregroundStyle(Color.naviTextSecondary)
            }
            Section {
                TextField("Publiczny e-mail lub URL projektu", text: $transitousContact)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("Kontakt dla usługi Transitous")
            } footer: {
                Text("Zapytania o trasę i przystanki oraz obszar widoczny na mapie są wysyłane do Transitous. Usługa wymaga publicznego kontaktu w User-Agent; jej zasady proszą też o kontakt przed użyciem kosztownego routingu.")
            }
            Section("Źródła i zasady usług") {
                Link("Transitous · zasady API", destination: URL(string: "https://transitous.org/api/")!)
                Link("Transitous · źródła danych", destination: URL(string: "https://transitous.org/sources/")!)
                Link("MPK Łódź · otwarte dane", destination: transitStore.region.dataPortalURL)
                Link("MPK Łódź · rozkład jazdy", destination: transitStore.region.scheduleURL)
            }
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
