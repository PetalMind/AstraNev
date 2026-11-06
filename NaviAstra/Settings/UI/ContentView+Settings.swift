import SwiftUI
import AVFoundation

extension ContentView {
    var trafficDetailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
#if os(iOS)
                    routeCongestionDetailsCard
#endif
                    trafficCard
                }
                .padding()
            }
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
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Zamknij") { appRouter.dismiss(.settings) }
                    }
                }
        }
        #if os(iOS)
        .presentationSizing(.form)
        .presentationDragIndicator(.visible)
        #endif
        // Load once for the sheet, so returning from a category preserves route edits.
        .onAppear { routePlanningStore.loadPreferences(from: navigationStore) }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 680)
        #endif
    }

    private var settingsForm: some View {
        #if os(iOS)
        IOSSettingsIndex(summary: settingsSummary, destination: settingsDestination)
        #else
        Form {
            Section("Nawigacja") {
                settingsCategory("Personalizacja tras", subtitle: "Twoje trasy, skróty i preferowane drogi",
                                 icon: "point.3.connected.trianglepath.dotted") {
                    DrivingPersonalizationView(endpoint: URL(string: serverAddress))
                }
                NavigationLink("Zasięg, ślady GPS i obszary omijane") {
                    ValhallaToolsView(endpoint: URL(string: serverAddress),
                        origin: navigationStore.state.location?.coordinate,
                        navigation: navigationStore, trips: placeStore.trips)
                }
                settingsCategory("Paliwo i koszty jazdy", subtitle: energyStore.selectedVehicle?.name ?? "Pojazdy, tankowania i ładowania",
                                 icon: "fuelpump.fill") {
                    EnergyDashboard(store: energyStore, places: placeStore, coordinate: navigationStore.state.location?.coordinate)
                }
                settingsCategory("Historia przejazdów", subtitle: "Wszystkie przejazdy, ślady GPS i oceny prowadzenia",
                                 icon: "clock.arrow.circlepath") {
                    settingsTripHistoryPage
                }
                settingsCategory("Trasy i pojazd", subtitle: defaultTransportTitle,
                                 icon: "point.topleft.down.curvedto.point.bottomright.up") {
                    settingsRoutePage
                }
                settingsCategory("Twój znacznik",
                                 subtitle: mapStore.transportPositionIconsEnabled ? "Modele i kolory" : "Klasyczna strzałka",
                                 icon: "location.north.circle") {
                    NavigationMarkerSettingsView(store: mapStore)
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
                #if os(iOS)
                settingsCategory("Mapy offline", subtitle: "Pobieranie i zarządzanie obszarami",
                                 icon: "arrow.down.circle.fill") {
                    OfflineMapsView(location: navigationStore.state.location?.coordinate,
                                    destination: navigationStore.state.destination,
                                    savedPlaces: placeStore.places,
                                    route: navigationStore.state.route?.coordinates ?? [])
                }
                #endif
            }
            Section("Usługi nawigacyjne") {
                settingsCategory("Ruch drogowy",
                                 subtitle: TrafficCredential.read() != nil ? "TomTom, GDDKiA i zgłoszenia" : "GDDKiA i zgłoszenia · bez pomiaru TomTom",
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
                        #if os(iOS)
                        Section("Źródła mapy i licencje") {
                            SatelliteMapCredits()
                            Link("OpenFreeMap · mapa bazowa", destination: URL(string: "https://openfreemap.org")!)
                            Link("OpenStreetMap · autorzy i licencja ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            Link("InPost · wyszukiwanie punktów po numerze", destination: URL(string: "https://inpost.pl/znajdz-paczkomat")!)
                            Link("MapLibre · silnik mapy", destination: URL(string: "https://maplibre.org")!)
                            if MapTilerEnvironmentStyle.configuredURL != nil {
                                Link("MapTiler · szczegóły otoczenia", destination: URL(string: "https://www.maptiler.com/copyright/")!)
                                Text("Otoczenie pochodzi z MapTiler Planet v4. Szczegóły pojawiają się wraz ze zbliżeniem i zależą od danych w danym miejscu. Symbole przejść nie określają rodzaju oznakowania ani pierwszeństwa.")
                                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
                            }
                        }
                        #endif
                        settingsShopLogoCredits
                        Section("Ikonografia nawigacji") {
                            Link("Mapbox Directions Icons · CC0 1.0",
                                 destination: URL(string: "https://github.com/mapbox/directions-icons")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        #endif
    }

    #if os(iOS)
    private func settingsSummary(_ category: IOSSettingsCategory) -> String {
        switch category {
        case .routes: defaultTransportTitle
        case .guidance: navigationStore.state.voiceEnabled
            ? "Głos włączony · \(navigationStore.state.voicePreferences.verbosity.title)"
            : "Komunikaty głosowe wyłączone"
        case .personalization: "Twoje trasy, skróty i preferowane drogi"
        case .marker: mapStore.transportPositionIconsEnabled ? "Modele i kolory" : "Klasyczna strzałka"
        case .energy: energyStore.selectedVehicle?.name ?? "Pojazdy, tankowania i ładowania"
        case .history: "Przejazdy i oceny prowadzenia"
        case .map: "\((MapAppearance(rawValue: mapStore.mapAppearance) ?? .auto).title) · \((MapDimension(rawValue: mapStore.mapDimension) ?? .flat).title)"
        case .offline: "Pobieranie map do użycia bez internetu"
        case .traffic: "Korki i utrudnienia w pobliżu"
        case .transit: "Połączenia, przystanki i odjazdy"
        case .advanced: "Zasięg podróży i obszary omijane"
        case .privacy: "Lokalna historia, źródła danych i licencje"
        }
    }

    @ViewBuilder
    private func settingsDestination(_ category: IOSSettingsCategory) -> some View {
        switch category {
        case .routes: settingsRoutePage
        case .guidance: settingsGuidancePage
        case .personalization: DrivingPersonalizationView(endpoint: URL(string: serverAddress))
        case .marker: NavigationMarkerSettingsView(store: mapStore)
        case .energy:
            EnergyDashboard(store: energyStore, places: placeStore,
                            coordinate: navigationStore.state.location?.coordinate)
        case .history: settingsTripHistoryPage
        case .map: settingsMapPage
        case .offline:
            OfflineMapsView(location: navigationStore.state.location?.coordinate,
                            destination: navigationStore.state.destination,
                            savedPlaces: placeStore.places,
                            route: navigationStore.state.route?.coordinates ?? [])
        case .traffic: settingsPage("Ruch drogowy") { settingsTrafficSection }
        case .transit: settingsPage("Komunikacja publiczna") { settingsTransitSection }
        case .advanced:
            settingsPage("Narzędzia tras") {
                Section("Planowanie") {
                    NavigationLink("Zasięg i obszary omijane") {
                        ValhallaToolsView(endpoint: URL(string: serverAddress),
                            origin: navigationStore.state.location?.coordinate,
                            navigation: navigationStore, trips: placeStore.trips)
                    }
                }
                settingsValhallaSection
            }
        case .privacy:
            settingsPage("Dane i prywatność") {
                Section("Dostępność i dane") { settingsDisclaimer }
                Section("Źródła mapy i licencje") {
                    SatelliteMapCredits()
                    Link("OpenFreeMap · mapa bazowa", destination: URL(string: "https://openfreemap.org")!)
                    Link("OpenStreetMap · autorzy i licencja ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link("InPost · wyszukiwanie punktów po numerze", destination: URL(string: "https://inpost.pl/znajdz-paczkomat")!)
                    Link("MapLibre · silnik mapy", destination: URL(string: "https://maplibre.org")!)
                    if MapTilerEnvironmentStyle.configuredURL != nil {
                        Link("MapTiler · szczegóły otoczenia", destination: URL(string: "https://www.maptiler.com/copyright/")!)
                        Text("Symbole przejść nie określają pierwszeństwa.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                settingsShopLogoCredits
                Section("Ikonografia nawigacji") {
                    Link("Mapbox Directions Icons · CC0 1.0", destination: URL(string: "https://github.com/mapbox/directions-icons")!)
                }
            }
        }
    }
    #endif

    private var settingsTripHistoryPage: some View {
        RouteHistoryView(store: placeStore, onPlanTrip: { trip in
            appRouter.dismiss(.settings)
            replayTrip(trip)
        }, onSearch: { destination in
            appRouter.dismiss(.settings)
            Task { await navigationStore.previewNewTrip(destination) }
        }, onFavorite: { destination in
            addFavoriteWithFeedback(destination)
        }, onClose: {
            appRouter.dismiss(.settings)
        }, energyStore: energyStore, embeddedInNavigation: true)
        .overlay(alignment: .top) {
            FavoriteFeedbackOverlay(feedback: $favoriteFeedback)
                .padding(.top, 48)
        }
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
            .environment(\.locale, PolishRegionalFormat.locale)
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
            settingsWeatherSection
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
            #if os(iOS)
            VoiceAssistantSettings(assistant: voiceAssistant)
            #endif
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
                Text("Zmiany zapisują się automatycznie i będą użyte przy kolejnym wyznaczeniu lub przeliczeniu trasy.")
                    .font(.footnote)
                    .foregroundStyle(Color.naviTextSecondary)
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
                unavailableReason("Mapa satelitarna", reason: "Niedostępna.")
            }
            #if os(iOS)
            if mapStore.mapBase == BaseMap.satellite.rawValue {
                Text("Zdjęcia satelitarne wymagają internetu i nie są pobierane do map offline.")
                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            }
            #endif
            if !mapCapabilities.supportsTerrain {
                unavailableReason("Mapa terenowa", reason: "Niedostępna.")
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
                Text("Wybrana mapa nie ma wariantu nocnego.")
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
                unavailableToggle("Budynki 3D", reason: "Niedostępne dla wybranej mapy.")
            }
        }
    }

    private var settingsMapDetailsSection: some View {
        Section("Szczegóły mapy") {
            if mapCapabilities.supportsTrafficOverlay {
                Toggle("Ruch drogowy", isOn: $mapStore.mapTrafficVisible)
            } else {
                unavailableToggle("Ruch drogowy", reason: "Niedostępny dla wybranej mapy.")
            }
            if mapCapabilities.supportsPOIToggle {
                Toggle("Miejsca na mapie", isOn: $mapStore.mapPOIVisible)
            } else {
                unavailableToggle("Miejsca na mapie", reason: "Wybrana mapa nie pozwala ukrywać miejsc.")
            }
            if mapCapabilities.supportsTransitOverlay {
                Toggle("Wyróżnij kolej i tramwaje", isOn: $mapStore.mapTransitVisible)
            } else {
                unavailableToggle("Transport publiczny", reason: "Niedostępny dla wybranej mapy.")
            }
            if mapCapabilities.supportsCyclingOverlay {
                Toggle("Ścieżki rowerowe", isOn: $mapStore.mapCyclingVisible)
            } else {
                unavailableToggle("Ścieżki rowerowe", reason: "Niedostępne dla wybranej mapy.")
            }
        }
    }

    private var settingsPOISection: some View {
        Group {
            Section {
                Toggle("Loga sklepów", isOn: $mapStore.shopLogosEnabled)
            } header: {
                Text("Wygląd sklepów")
            } footer: {
                Text("Pokazuj loga zamiast ikon sklepów po zbliżeniu mapy.")
            }
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
                Text("Podczas nawigacji widoczne są wybrane miejsca przydatne w podróży.")
                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            }
        }
    }

    private var settingsShopLogoCredits: some View {
        Section("Logotypy sklepów") {
            Text("Dane sklepów: OpenStreetMap. Logotypy: Wikidata i Wikimedia Commons. Znaki towarowe należą do ich właścicieli.")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            Link("OpenStreetMap · źródło danych", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            Link("Wikimedia Commons", destination: URL(string: "https://commons.wikimedia.org")!)
            if ShopPOILogoStore.shared.credits.isEmpty {
                Text("Informacje o autorach i licencjach pojawią się po pobraniu logotypów.")
                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
            }
            ForEach(ShopPOILogoStore.shared.credits) { credit in
                VStack(alignment: .leading, spacing: 4) {
                    Link(credit.name, destination: credit.sourcePageURL)
                    Text(credit.attribution).font(.caption).foregroundStyle(Color.naviTextSecondary)
                    if let licenseURL = credit.licenseURL {
                        Link(credit.licenseName ?? "Licencja", destination: licenseURL).font(.caption)
                    } else if let license = credit.licenseName {
                        Text(license).font(.caption).foregroundStyle(Color.naviTextSecondary)
                    }
                }
            }
        }
    }

    private var settingsSafetyPOISection: some View {
        Group {
            Section {
                Toggle("Znaki drogowe", isOn: $mapStore.mapRoadSignsVisible)
                settingsSafetyCategoryToggles
            } header: {
                Text("Szczegóły drogowe")
            } footer: {
                Text("Szczegóły zobaczysz po zbliżeniu mapy. Podczas jazdy wyświetlamy ostrzeżenia dotyczące Twojej trasy.")
            }
            Section("Dane drogowe") {
                #if !os(iOS)
                roadPOIStatusLabel
                #endif
                DisclosureGroup("Źródła i ograniczenia danych") {
                    settingsRoadDataDescription
                }
                Link("CANARD / GITD · źródło i licencja CC BY 4.0", destination: CANARDRoadDataProvider.mapURL)
                    .font(.footnote)
            }
        }
    }

    private var settingsSafetyCategoryToggles: some View {
        ForEach(MapSafetyPOICategory.allCases.filter { $0 != .trafficSigns }) { category in
            Toggle(category.title, isOn: Binding(
                get: { mapStore.mapSafetyPOICategories & category.mask != 0 },
                set: { enabled in
                    if enabled { mapStore.mapSafetyPOICategories |= category.mask }
                    else { mapStore.mapSafetyPOICategories &= ~category.mask }
                }))
        }
    }

    private var settingsRoadDataDescription: some View {
        Text("Dane: OpenStreetMap i CANARD / GITD. Mapa ma charakter pomocniczy — stosuj się do znaków na drodze. Symbole sygnalizacji wskazują miejsce świateł, nie ich aktualny kolor.")
            .font(.footnote)
            .foregroundStyle(Color.naviTextSecondary)
    }

    @ViewBuilder
    var roadPOIStatusLabel: some View {
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
            VoiceSettingsPicker(selection: voiceIdentifierBinding)
            VoiceSettingsSlider(
                title: "Tempo mowy",
                value: voiceRateBinding,
                range: 0.38...0.62,
                percentageMultiplier: 200
            )
            VoiceSettingsSlider(
                title: "Głośność komunikatów",
                value: voiceVolumeBinding,
                range: 0...1,
                percentageMultiplier: 100
            )
        }
    }

    private var settingsRoutingSection: some View {
        Section {
            Toggle("Unikaj dróg płatnych", isOn: routePreferenceBinding(\.avoidTolls))
            Toggle("Unikaj autostrad", isOn: routePreferenceBinding(\.avoidHighways))
            Toggle("Unikaj promów", isOn: routePreferenceBinding(\.avoidFerries))
            Toggle("Unikaj dróg gruntowych", isOn: routePreferenceBinding(\.avoidUnpaved))
        } header: {
            Text("Preferencje dróg")
        } footer: {
            Text("Trasa może uwzględniać te drogi, gdy nie ma rozsądnej alternatywy.")
        }
    }

    private var settingsElectricVehicleSection: some View {
        Section {
            Toggle("Uwzględnij zasięg EV", isOn: routePreferenceBinding(\.evPlanningEnabled))
            if routePlanningStore.draftPreferences.evPlanningEnabled {
                TextField("Zasięg przy pełnej baterii (km)", value: routePreferenceBinding(\.evRangeKilometers),
                          format: .number.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale))
                Stepper("Poziom baterii: \(routePlanningStore.draftPreferences.evBatteryPercent)%",
                        value: routePreferenceBinding(\.evBatteryPercent), in: 1...100, step: 5)
                TextField("Zużycie (kWh/100 km)", value: routePreferenceBinding(\.evConsumptionKWhPer100Km),
                          format: .number.precision(.fractionLength(1)).locale(PolishRegionalFormat.locale))
                TextField("Maks. moc ładowania auta (kW)", value: routePreferenceBinding(\.evMaximumChargingPowerKW),
                          format: .number.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale))
                LabeledContent("Dostępny zasięg",
                               value: "\(Int(routePlanningStore.draftPreferences.availableEVRangeKilometers.rounded())) km")
                EVBatteryStatusView(navigation: navigationStore,
                    enteredPercent: routePlanningStore.draftPreferences.evBatteryPercent)
            }
        } header: {
            Text("Pojazd elektryczny")
        } footer: {
            if routePlanningStore.draftPreferences.evPlanningEnabled {
                Text("Czas ładowania jest szacunkowy. Zajętość ładowarek nie jest sprawdzana na żywo.")
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
        Section("Ruch i zdarzenia drogowe") {
            NavigationLink {
                ScrollView { trafficCard.padding() }
                    .navigationTitle("Ruch na żywo")
            } label: {
                Label("Bieżące warunki", systemImage: "car.side")
            }
            Text("Zgłoszenia zapisane lokalnie są widoczne tylko na tym urządzeniu.")
                .font(.footnote)
                .foregroundStyle(Color.naviTextSecondary)
        }
    }

    private var settingsValhallaSection: some View {
        Section {
            DisclosureGroup("Własny serwer tras") {
                TextField("Adres serwera (https://…)", text: $serverAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button("Zapisz serwer") {
                    guard let url = URL(string: serverAddress), url.scheme == "https", url.host != nil else {
                        navigationStore.state.errorMessage = "Podaj poprawny adres serwera zaczynający się od https://."
                        return
                    }
                    UserDefaults.standard.set(serverAddress, forKey: "routingServer")
                    navigationStore.updateRoutingEndpoint(url)
                    appRouter.dismiss(.settings)
                }
            }
        }
    }

    private var settingsTransitSection: some View {
        Group {
            Section("Dostępność połączeń") {
                Text("Pozycje pojazdów na żywo są dostępne dla MPK Łódź. W pozostałych regionach korzystamy z dostępnych rozkładów i odjazdów.")
                    .foregroundStyle(Color.naviTextSecondary)
            }
            #if !os(iOS)
            Section {
                TextField("Publiczny e-mail lub URL projektu", text: $transitousContact)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("Kontakt dla usługi Transitous")
            } footer: {
                Text("Usługa wymaga adresu kontaktowego twórcy aplikacji.")
            }
            #else
            if TransitousClientConfiguration().userAgent == nil {
                Section("Przywróć dostęp do połączeń") {
                    Text("Zapisana konfiguracja komunikacji publicznej jest nieprawidłowa.")
                        .font(.footnote).foregroundStyle(Color.naviTextSecondary)
                    Button("Przywróć ustawienia domyślne") { transitousContact = "" }
                }
            }
            #endif
            Section("Prywatność") {
                Text("Zapytania o połączenia i przystanki oraz widoczny obszar mapy są wysyłane do Transitous.")
                    .font(.footnote).foregroundStyle(Color.naviTextSecondary)
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
        #if os(iOS)
        let text = "Trasy offline wymagają pobranych danych drogowych. Wyszukiwanie i ruch na żywo wymagają internetu. Historia przejazdów i zapis drogi są przechowywane na urządzeniu."
        #else
        let text = "Mapa, wyszukiwanie, routing, limity i ruch na żywo wymagają internetu. TomTom może zmienić ETA i wybór spośród wariantów Valhalli; limity są informacyjne. Trasy i GPS są zapisywane tylko w lokalnej historii podróży. Tryb offline nie jest dostępny."
        #endif
        return Text(text).font(.footnote)
    }

    var routeSettingsSheet: some View {
        let mode = navigationStore.state.transportMode
        return NavigationStack {
            Form {
                Section {
                    NavigationLink("Profile, dostępność i preferencje") {
                        ValhallaPreferencesView(navigation: navigationStore)
                    }
                    NavigationLink("Zasięg i obszary omijane") {
                        ValhallaToolsView(endpoint: URL(string: serverAddress),
                            origin: routeOriginPoint?.coordinate ?? navigationStore.state.location?.coordinate,
                            navigation: navigationStore, trips: placeStore.trips)
                    }
                }
                if supportsActiveTripRoadPreferences {
                    Section("Preferencje trasy") {
                        Toggle("Unikaj dróg płatnych", isOn: routePreferenceBinding(\.avoidTolls))
                        Toggle("Unikaj autostrad", isOn: routePreferenceBinding(\.avoidHighways))
                        Toggle("Unikaj promów", isOn: routePreferenceBinding(\.avoidFerries))
                        Toggle("Unikaj dróg gruntowych", isOn: routePreferenceBinding(\.avoidUnpaved))
                    }
                }

                if mode == .car {
                    Section("Pojazd elektryczny") {
                        Toggle("Uwzględnij zasięg EV", isOn: routePreferenceBinding(\.evPlanningEnabled))
                        if routePlanningStore.draftPreferences.evPlanningEnabled {
                            TextField("Zasięg przy pełnej baterii (km)", value: routePreferenceBinding(\.evRangeKilometers),
                                      format: .number.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale))
                            Stepper("Poziom baterii: \(routePlanningStore.draftPreferences.evBatteryPercent)%",
                                    value: routePreferenceBinding(\.evBatteryPercent), in: 1...100, step: 5)
                            TextField("Zużycie (kWh/100 km)", value: routePreferenceBinding(\.evConsumptionKWhPer100Km),
                                      format: .number.precision(.fractionLength(1)).locale(PolishRegionalFormat.locale))
                            TextField("Maks. moc ładowania auta (kW)", value: routePreferenceBinding(\.evMaximumChargingPowerKW),
                                      format: .number.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale))
                            evConnectorToggle("ccs", title: "CCS")
                            evConnectorToggle("type2", title: "Type 2")
                            evConnectorToggle("chademo", title: "CHAdeMO")
                            EVBatteryStatusView(navigation: navigationStore,
                                enteredPercent: routePlanningStore.draftPreferences.evBatteryPercent)
                            Text("Sprawdź dostępność ładowarki przed przyjazdem. Aplikacja nie pokazuje zajętości na żywo.")
                                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
                        }
                    }
                }

                Section {
                    Text("Zmiany zapisują się automatycznie. W podglądzie przeliczają trasę, a podczas nawigacji zostaną użyte przy kolejnym przeliczeniu.")
                        .font(.footnote)
                        .foregroundStyle(Color.naviTextSecondary)
                }
            }
            .navigationTitle("Ustawienia trasy")
            .environment(\.locale, PolishRegionalFormat.locale)
            .onAppear { routePlanningStore.loadPreferences(from: navigationStore) }
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
                routePlanningStore.updatePreferences({ preferences in
                    if isEnabled { preferences.evConnectorTypes.insert(connector) }
                    else { preferences.evConnectorTypes.remove(connector) }
                }, to: navigationStore)
            }))
    }

    private func routePreferenceBinding<Value>(
        _ keyPath: WritableKeyPath<RoutingPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { routePlanningStore.draftPreferences[keyPath: keyPath] },
            set: { value in
                routePlanningStore.updatePreference(keyPath, value: value, to: navigationStore)
            })
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

#if os(iOS)
            Button { showsRoadReportEditor = true } label: {
                Label("Zgłoś zdarzenie lub kontrolę", systemImage: "plus.bubble.fill")
            }
            .sheet(isPresented: $showsRoadReportEditor) {
                let location = navigationStore.state.location
                let reliable = location.map { $0.accuracy >= 0 && $0.accuracy <= 50 &&
                    (-5...60).contains(Date().timeIntervalSince($0.timestamp)) } == true
                RoadReportEditor(coordinate: reliable ? location?.coordinate : nil, locationTimestamp: location?.timestamp) {
                    navigationStore.refreshTraffic(force: true)
                }
            }
#endif
            Text("Dane: TomTom i GDDKiA. Zgłoszenia użytkowników mogą być niepotwierdzone.")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
            switch navigationStore.state.trafficStatus {
            case .notConfigured:
                Label("Informacje o ruchu są teraz niedostępne.", systemImage: "wifi.slash")
                    .foregroundStyle(Color.naviTextSecondary)
            case .updating:
                Label("Pobieranie danych o ruchu…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.naviTextSecondary)
            case .unavailable:
                Label("Nie udało się odświeżyć informacji o ruchu.", systemImage: "wifi.slash")
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
                    Text("Brak aktualnego pomiaru ruchu w pobliżu.")
                        .foregroundStyle(Color.naviTextSecondary)
                }

                if let incidents = navigationStore.state.traffic?.incidents {
                    if navigationStore.state.traffic?.incidentDataAvailable == true {
                        Text(incidents.isEmpty
                             ? "W dostępnych danych nie znaleziono zgłoszeń dla tego obszaru."
                             : "Utrudnienia w pobliżu: \(incidents.count)")
                    } else {
                        Text("Brak aktualnych danych o zdarzeniach dla tego obszaru.")
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    ForEach(incidents.prefix(2)) { incident in
                        Text("• \(incident.description) · \(incident.sources.map(\.title).joined(separator: ", "))")
                            .lineLimit(2)
                    }
                }

                #if !os(iOS)
                if let partialError = navigationStore.state.traffic?.partialError {
                    Text(partialError)
                        .foregroundStyle(Color.naviTextSecondary)
                }
                #endif

                if let updatedAt = navigationStore.state.traffic?.updatedAt {
                    Text("Aktualizacja: \(PolishRegionalFormat.time(updatedAt))")
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

private struct VoiceSettingsPicker: View {
    @Binding var selection: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var voices: [AVSpeechSynthesisVoice] = []

    private var polishVoices: [AVSpeechSynthesisVoice] {
        voices.filter { $0.language.hasPrefix("pl-") || $0.language == "pl" }
    }

    private var otherVoices: [AVSpeechSynthesisVoice] {
        voices.filter { !$0.language.hasPrefix("pl-") && $0.language != "pl" }
    }

    var body: some View {
        Picker("Głos nawigacji", selection: $selection) {
            Text("Automatyczny (polski)").tag("")
            if !selection.isEmpty && !voices.contains(where: { $0.identifier == selection }) {
                Text("Wybrany głos niedostępny (używany polski)").tag(selection)
            }
            Section("Polskie") {
                ForEach(polishVoices, id: \.identifier) { voice in
                    Text(label(for: voice)).tag(voice.identifier)
                }
            }
            Section("Pozostałe języki") {
                ForEach(otherVoices, id: \.identifier) { voice in
                    Text(label(for: voice)).tag(voice.identifier)
                }
            }
        }
        .onAppear(perform: refreshVoices)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshVoices() }
        }
        Text("Komunikaty są po polsku. Głosy innych języków mogą czytać je z obcym akcentem. Lista zawiera głosy udostępnione przez system na tym urządzeniu.")
            .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        if polishVoices.isEmpty {
            Text("System nie udostępnia polskiego głosu. Wybierz dostępny głos lub pobierz polski głos w ustawieniach dostępności urządzenia.")
                .font(.footnote).foregroundStyle(Color.naviTextSecondary)
        }
        Text("Dodatkowe głosy i warianty jakości pobierzesz w ustawieniach dostępności urządzenia. Po powrocie do aplikacji lista odświeży się automatycznie.")
            .font(.footnote).foregroundStyle(Color.naviTextSecondary)
    }

    private func refreshVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            let first = label(for: $0)
            let second = label(for: $1)
            if first == second { return $0.identifier < $1.identifier }
            return first.localizedStandardCompare(second) == .orderedAscending
        }
    }

    private func label(for voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale(identifier: "pl_PL").localizedString(forIdentifier: voice.language) ?? voice.language
        let quality: String
        switch voice.quality {
        case .enhanced: quality = "ulepszony"
        case .premium: quality = "premium"
        default: quality = "standardowy"
        }
        return "\(voice.name) · \(language) · \(quality)"
    }
}

// Keep drag updates inside the row; persist the preference when editing ends.
private struct VoiceSettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let percentageMultiplier: Double
    @State private var draftValue: Double
    @State private var isEditing = false

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>,
         percentageMultiplier: Double) {
        self.title = title
        self._value = value
        self.range = range
        self.percentageMultiplier = percentageMultiplier
        self._draftValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f%%", draftValue * percentageMultiplier))
                    .foregroundStyle(Color.naviTextSecondary)
                    .monospacedDigit()
            }
            Slider(value: $draftValue, in: range) { editing in
                isEditing = editing
                if !editing { value = draftValue }
            }
        }
        .onChange(of: value) { _, newValue in
            guard !isEditing else { return }
            draftValue = newValue
        }
        .onDisappear {
            if isEditing {
                value = draftValue
                isEditing = false
            }
        }
    }
}
