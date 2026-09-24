import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var transportSelectionNamespace
    @State private var engine = NavigationEngine(routeProvider: ValhallaRouteProvider(endpoint: URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "") ?? URL(string: "https://valhalla1.openstreetmap.de")!))
    @State private var panelHeight: CGFloat = 320
    @State private var mapPanelInset: CGFloat = 340
    @State private var mapHeaderInset: CGFloat = 100
    @State private var showSearch = false
    @State private var selectedMapPlaces: [SearchResult] = []
    @State private var selectedTransitSheet: TransitSheetSelection?
    @State private var selectedTransitStopID: String?
    @State private var selectedTransitRouteID: String?
    @State private var selectedTransitTripID: String?
    @State private var selectedTransitTripStopIDs: Set<String> = []
    @State private var selectedTransitLine: TransitLineDetails?
    @State private var selectedTransitTripCoordinates: [Coordinate] = []
    @State private var liveTransitTripDetails: TransitTripDetails?
    @State private var mapPlaceEstimateTask: Task<Void, Never>?
    @State private var serverAddress = UserDefaults.standard.string(forKey: "routingServer") ?? "https://valhalla1.openstreetmap.de"
    @State private var showSettings = false
    @State private var showVoiceControls = false
    @State private var showRouteSettings = false
    @State private var showFavorites = false
    @State private var showHistory = false
    @State private var addingWaypoint = false
    @State private var showTrafficDetails = false
    @State private var nearbyRequest: NearbySearchRequest?
    @State private var localData = LocalDataStore()
    @State private var favoriteName = ""
    @State private var isSavingPlace = false
    @State private var destinationExpanded = false
    @State private var routePreviewExpanded = false
    @State private var favoritePulseScale: CGFloat = 1
    @State private var trafficKey = ""
    @State private var trafficConfigured = TrafficCredential.read() != nil
    @State private var isMapReady = false
    @State private var discoveryDrawerCollapseRequest = 0
    @State private var routingDraft = RoutingPreferences()
    @State private var navigationPanelExpanded = false
    @State private var quickETAMinutes: [String: Int] = [:]
    @State private var quickETAOrigin: Coordinate?
    @State private var quickETADestinationKey = ""
    @State private var quickETAUpdatedAt = Date.distantPast
    @State private var quickETAInFlight = false
    @AppStorage("mapBase") private var mapBase = BaseMap.standard.rawValue
    @AppStorage("mapAppearance") private var mapAppearance = MapAppearance.auto.rawValue
    @AppStorage("mapDimension") private var mapDimension = MapDimension.flat.rawValue
    @AppStorage("mapTrafficVisible") private var mapTrafficVisible = true
    @AppStorage("mapPOICategories") private var mapPOICategories = MapPOICategory.allMask
    @AppStorage("mapPOIVisible") private var mapPOIVisible = true
    @AppStorage("mapBuildingsVisible") private var mapBuildingsVisible = true
    @AppStorage("mapTransitVisible") private var mapTransitVisible = false
    @AppStorage("mapCyclingVisible") private var mapCyclingVisible = false
    @AppStorage("speedWarningsEnabled") private var speedWarningsEnabled = true

    private var mapCapabilities: MapProviderCapabilities { ActiveMapProvider.capabilities }

    private var plannedTransitLegForSelectedTrip: JourneyLeg? {
        guard let selectedTransitTripID else { return nil }
        return engine.state.route?.journey?.legs.first(where: { $0.tripID == selectedTransitTripID })
    }

    private var transitLineCoordinatesForMap: [Coordinate] {
        if let plannedTransitLegForSelectedTrip { return plannedTransitLegForSelectedTrip.coordinates }
        if !selectedTransitTripCoordinates.isEmpty { return selectedTransitTripCoordinates }
        return selectedTransitLine?.coordinates ?? []
    }

    private var transitStopIDsForMap: Set<String> {
        if let plannedTransitLegForSelectedTrip {
            return Set(plannedTransitLegForSelectedTrip.transitStops.map(\.stopID))
        }
        return selectedTransitTripStopIDs
    }

    private var activeNavigationTransitLeg: JourneyLeg? {
        guard isNavigating, let legs = engine.state.route?.journey?.legs else { return nil }
        if let index = engine.state.transitProgress?.legIndex, legs.indices.contains(index) {
            if legs[index].mode != "WALK" { return legs[index] }
            return legs.dropFirst(index + 1).first { $0.mode != "WALK" }
        }
        return legs.first { $0.mode != "WALK" && $0.arrival > Date() }
    }

    private var activeTransitStopID: String? {
        if let progress = engine.state.transitProgress,
           let legs = engine.state.route?.journey?.legs,
           legs.indices.contains(progress.legIndex), legs[progress.legIndex].mode != "WALK" {
            return progress.nextStop?.stopID
        }
        return activeNavigationTransitLeg?.transitStops.first?.stopID
    }

    private var alightingTransitStopID: String? {
        activeNavigationTransitLeg?.transitStops.last?.stopID
    }

    private var supportedBaseMap: Binding<String> {
        Binding(
            get: {
                let requested = BaseMap(rawValue: mapBase) ?? .standard
                return mapCapabilities.supports(requested) ? requested.rawValue : BaseMap.standard.rawValue
            },
            set: { value in
                guard let selected = BaseMap(rawValue: value), mapCapabilities.supports(selected) else { return }
                mapBase = selected.rawValue
            })
    }

    private var mapSettings: MapSettings {
        let requestedBase = BaseMap(rawValue: mapBase) ?? .standard
        return MapSettings(
            baseMap: mapCapabilities.supports(requestedBase) ? requestedBase : .standard,
            appearance: MapAppearance(rawValue: mapAppearance) ?? .auto,
            cameraMode: mapCapabilities.supports3DCamera ? (MapDimension(rawValue: mapDimension) ?? .flat) : .flat,
            overlays: MapOverlays(
                traffic: mapCapabilities.supportsTrafficOverlay && mapTrafficVisible,
                poi: mapCapabilities.supportsPOIToggle && mapPOIVisible,
                buildings3D: mapCapabilities.supports3DBuildings && mapBuildingsVisible,
                transit: mapCapabilities.supportsTransitOverlay && mapTransitVisible,
                cycling: mapCapabilities.supportsCyclingOverlay && mapCyclingVisible),
            poiCategories: Set(MapPOICategory.allCases.filter { mapPOICategories & $0.mask != 0 }))
    }

    private var navigationMapSettings: MapSettings {
        var settings = mapSettings
        if engine.state.destination != nil && engine.state.status != .idle {
            let shouldShowContextualPOI = isNavigating || engine.state.status == .arrived
            if !shouldShowContextualPOI { settings.overlays.poi = false }
        }
        if isNavigating || engine.state.status == .arrived {
            if engine.state.status == .arrived || (engine.state.progress?.remainingDistance ?? .infinity) < 500 {
                settings.context = .approachingDestination
            } else {
                switch engine.state.transportMode {
                case .car, .parkRide: settings.context = .driving
                case .walking: settings.context = .walking
                case .bicycle: settings.context = .cycling
                case .transit: settings.context = .transit
                }
            }
        }
        return settings
    }

    private var isNavigating: Bool {
        engine.state.status == .navigating || engine.state.status == .rerouting
    }

    private var availablePolishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "pl-PL" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var voiceEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.state.voiceEnabled },
            set: { engine.setVoiceEnabled($0) })
    }

    private var voiceVerbosityBinding: Binding<VoiceVerbosity> {
        Binding(
            get: { engine.state.voicePreferences.verbosity },
            set: { value in updateVoicePreferences { $0.verbosity = value } })
    }

    private var voiceIdentifierBinding: Binding<String> {
        Binding(
            get: {
                let identifier = engine.state.voicePreferences.voiceIdentifier ?? ""
                return availablePolishVoices.contains(where: { $0.identifier == identifier }) ? identifier : ""
            },
            set: { value in updateVoicePreferences { $0.voiceIdentifier = value.isEmpty ? nil : value } })
    }

    private var voiceRateBinding: Binding<Double> {
        Binding(
            get: { Double(engine.state.voicePreferences.speechRate) },
            set: { value in updateVoicePreferences { $0.speechRate = Float(value) } })
    }

    private var voiceVolumeBinding: Binding<Double> {
        Binding(
            get: { Double(engine.state.voicePreferences.volume) },
            set: { value in updateVoicePreferences { $0.volume = Float(value) } })
    }

    private func updateVoicePreferences(_ update: (inout VoiceGuidancePreferences) -> Void) {
        var preferences = engine.state.voicePreferences
        update(&preferences)
        engine.setVoicePreferences(preferences)
    }

    private var hasRoutePreviewContext: Bool {
        engine.state.destination != nil && !isNavigating &&
            (engine.state.status == .routePreview || engine.state.status == .routeCalculating || engine.state.status == .error)
    }

    private var isTransitRoutePreview: Bool {
        engine.state.status == .routePreview && engine.state.transportMode == .transit
    }

    private var isDestinationFavorite: Bool {
        guard let destination = engine.state.destination else { return false }
        return localData.places.contains {
            $0.kind == .favorite && $0.destination.coordinate == destination.coordinate
        }
    }

    private var pointSelectionHint: String {
        #if os(macOS)
        "Wyszukaj adres lub miejsce albo kliknij dwukrotnie mapę, aby wybrać punkt."
        #else
        "Wyszukaj adres lub miejsce albo przytrzymaj mapę, aby wybrać punkt."
        #endif
    }

    var body: some View {
        ZStack {
            MapLibreView(state: engine.state, transitVehicles: engine.state.transitVehicles,
                         transitStops: engine.state.transitStops,
                         selectedTransitStopID: selectedTransitStopID,
                         selectedTransitRouteID: selectedTransitRouteID,
                         selectedTransitTripID: selectedTransitTripID,
                         selectedTransitTripStopIDs: transitStopIDsForMap,
                         activeTransitStopID: activeTransitStopID,
                         alightingTransitStopID: alightingTransitStopID,
                         transitLineCoordinates: transitLineCoordinatesForMap,
                         transitLineColor: selectedTransitLine?.colorHex,
                         settings: navigationMapSettings,
                         isSearchPresented: showSearch,
                         routePreviewExpanded: routePreviewExpanded,
                         viewportPadding: CameraPadding(top: Double(mapHeaderInset), left: 24,
                                                        bottom: Double(mapPanelInset), right: 24),
                         onSearchSelect: { destination in selectDestination(destination) },
                         onPlaceSelect: { presentMapPlaces($0) },
                         onTransitStopSelect: { openTransitStop($0) },
                         onTransitVehicleSelect: { openTransitVehicle($0) },
                         onMapReady: revealMapSplash,
                         onMapPan: {
                             withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                 routePreviewExpanded = false
                                 destinationExpanded = false
                                 navigationPanelExpanded = false
                             }
                             if engine.state.destination == nil {
                                 discoveryDrawerCollapseRequest += 1
                             }
                         }) { coordinate in
                let destination = Destination(name: "Wybrany punkt", coordinate: coordinate)
                selectDestination(destination, recordSearch: false)
            }
            .ignoresSafeArea()

            LinearGradient(colors: [Color.black.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { geometry in
                VStack(spacing: 12) {
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height + geometry.safeAreaInsets.top + 20 } action: { mapHeaderInset = $0 }

                    if let message = engine.state.errorMessage ?? localData.errorMessage {
                        errorNotice(message)
                    }
                    if isNavigating { gpsStatusIndicator }

                    Spacer(minLength: 16)

                    mapControl(compact: geometry.size.height < 500)

                    Group {
                        if engine.state.status == .idle || (engine.state.status == .error && engine.state.destination == nil) {
                            DiscoveryDrawer(maximumHeight: max(160, geometry.size.height - mapHeaderInset - (geometry.size.height < 500 ? 100 : 160)),
                                            collapseRequest: discoveryDrawerCollapseRequest) { compact in
                                discoveryPanel(compact: compact)
                            }
                        } else {
                            ScrollView(.vertical) {
                                activePanel
                                    .padding(2)
                                    .padding(.bottom, isTransitRoutePreview ? 76 : 0)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                            }
                            .scrollIndicators(.hidden)
                            .frame(height: min(panelHeight, geometry.size.height * (geometry.size.height < 500 ? 0.48 : 0.64)))
                            .overlay(alignment: .bottom) {
                                if isTransitRoutePreview {
                                    beginRouteButton
                                        .padding(.horizontal, 16)
                                        .padding(.top, 10)
                                        .padding(.bottom, 8)
                                        .frame(maxWidth: .infinity)
                                        .background(.ultraThinMaterial)
                                }
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height + geometry.safeAreaInsets.bottom + 24 } action: { mapPanelInset = $0 }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isMapReady {
                MapLoadingSplash()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .task(id: "\(engine.state.route?.id.uuidString ?? "no-route")-\(engine.state.transportMode.rawValue)") {
            await refreshTransitJourneyDetails()
        }
        .preferredColorScheme(!mapCapabilities.supportsApplicationDarkMode || mapSettings.appearance == .auto ? nil :
                              (mapSettings.appearance == .night ? .dark : .light))
        .sheet(isPresented: $showSearch) {
            searchSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedTransitSheet) { selection in
            TransitDetailsSheet(selection: selection, onSelectDeparture: { departure in
                openTransitDeparture(departure)
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(get: { !selectedMapPlaces.isEmpty },
                                    set: { if !$0 { selectedMapPlaces = [] } })) {
            NavigationStack {
                Group {
                    if selectedMapPlaces.count > 1 {
                        List(selectedMapPlaces) { result in
                            Button {
                                presentMapPlace(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.destination.name)
                                        .font(.body.weight(.semibold))
                                    Text(result.category?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Miejsce")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    } else if let result = selectedMapPlaces.first {
                        ScrollView {
                            PlaceDetailsView(
                                result: result,
                                isSaved: localData.places.contains {
                                    $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate
                                },
                                onSave: { localData.add(result.destination) },
                                isNavigating: isNavigating,
                                primaryActionTitle: isNavigating ? "Dodaj przystanek" : "Wyznacz trasę",
                                onPlanRoute: {
                                    selectedMapPlaces = []
                                    if isNavigating {
                                        Task { await engine.addWaypoint(result.destination) }
                                    } else {
                                        selectDestination(result.destination)
                                    }
                                })
                                .id(result.placeIdentity.cacheKey)
                                .padding()
                        }
                    }
                }
                .navigationTitle(selectedMapPlaces.count > 1 ? "Wybierz miejsce" : (selectedMapPlaces.first?.destination.name ?? "Miejsce"))
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Zamknij") { selectedMapPlaces = [] }
                    }
                }
            }
            .onDisappear { mapPlaceEstimateTask?.cancel() }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showRouteSettings) { routeSettingsSheet }
        .sheet(isPresented: $showFavorites) { favoritesSheet }
        .sheet(isPresented: $showHistory) { historySheet }
        .sheet(item: $nearbyRequest) { request in
            NearbyPlacesSheet(engine: engine, nearDestination: request.nearDestination,
                              initialCategory: request.category,
                              savedPlaces: localData.places,
                              onSave: { localData.add($0) }) { destination in
                Task {
                    await engine.selectNearbyPlace(destination, asFinalParking: request.nearDestination)
                    nearbyRequest = nil
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTrafficDetails) { trafficDetailsSheet }
        .task {
            engine.onTripFinished = { trip in localData.addTrip(trip) }
            engine.startLocation()
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, !isMapReady else { return }
            revealMapSplash()
        }
        .onChange(of: engine.state.destination?.id) { _, _ in
            destinationExpanded = false
            routePreviewExpanded = false
            isSavingPlace = false
        }
        .onChange(of: engine.state.location?.coordinate) { _, _ in
            Task { await refreshQuickDestinationETAs() }
        }
        .onChange(of: quickETADestinationFingerprint) { _, _ in
            Task { await refreshQuickDestinationETAs() }
        }
        .onChange(of: engine.state.status) { _, status in
            if status == .navigating || status == .rerouting || status == .arrived || status == .idle {
                routePreviewExpanded = false
            }
            if status != .navigating && status != .rerouting { navigationPanelExpanded = false }
        }
    }

    @ViewBuilder
    private var activePanel: some View {
        switch engine.state.status {
        case .destinationPreview:
            destinationCard
        case .routeCalculating:
            routeCalculatingCard
        case .routePreview:
            routePreviewCard
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .navigating, .rerouting:
            journeyPanel
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .arrived:
            arrivalCard
        case .error where engine.state.destination != nil:
            routePreviewCard
        case .idle, .error:
            discoveryPanel()
        }
    }

    private func revealMapSplash() {
        guard !isMapReady else { return }
        withAnimation(.easeOut(duration: 0.35)) {
            isMapReady = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if isNavigating {
                if engine.state.transportMode == .transit {
                    transitNavigationHeader
                } else {
                    maneuverCard
                }
            } else if hasRoutePreviewContext {
                routePreviewHeader
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("NaviAstra")
                        .font(.headline)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .modifier(NavigationGlassSurface(radius: 24))
                Spacer()
                Button { showSettings = true } label: {
                    circleSurface { Image(systemName: "gearshape").font(.title3) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ustawienia")
            }
        }
    }

    @ViewBuilder
    private var gpsStatusIndicator: some View {
        let fixAge = engine.state.location.map { Date().timeIntervalSince($0.timestamp) } ?? .infinity
        let warning: (String, String, Color)? = switch engine.state.gpsQuality {
        case .good, .excellent: nil
        case .predicted where fixAge < 15: nil
        case .predicted, .weak: ("Sygnał GPS słaby", "location.circle", .orange)
        case .noSignal: ("Słaby sygnał GPS · prowadzenie może być niedokładne", "location.slash", .red)
        }
        if let warning {
            Label(warning.0, systemImage: warning.1)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(warning.2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel(warning.0)
        }
    }

    @ViewBuilder
    private var mapLayerMenuActions: some View {
        Section("Mapa") {
            ForEach(BaseMap.allCases.filter { mapCapabilities.supports($0) }) { baseMap in
                Button {
                    supportedBaseMap.wrappedValue = baseMap.rawValue
                } label: {
                    mapMenuLabel(baseMap.title, selected: supportedBaseMap.wrappedValue == baseMap.rawValue)
                }
            }

            if mapCapabilities.supports3DCamera {
                ForEach(MapDimension.allCases) { dimension in
                    Button {
                        mapDimension = dimension.rawValue
                    } label: {
                        mapMenuLabel(dimension.title, selected: mapDimension == dimension.rawValue)
                    }
                }
            }
        }

        Section("Warstwy") {
            if mapCapabilities.supportsTrafficOverlay {
                Toggle("Ruch drogowy", isOn: $mapTrafficVisible)
            }
            if mapCapabilities.supportsPOIToggle {
                Toggle("Punkty POI", isOn: $mapPOIVisible)
            }
            if mapCapabilities.supportsTransitOverlay {
                Toggle("Wyróżnij kolej i tramwaje", isOn: $mapTransitVisible)
            }
            if mapCapabilities.supportsCyclingOverlay {
                Toggle("Trasy rowerowe", isOn: $mapCyclingVisible)
            }
            if mapCapabilities.supports3DBuildings {
                Toggle("Budynki 3D", isOn: $mapBuildingsVisible)
            }
        }
    }

    private var mapLayersMenu: some View {
        Menu {
            mapLayerMenuActions
        } label: {
            circleSurface {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityLabel("Wygląd i warstwy mapy")
    }

    private var journeyMapLayersMenu: some View {
        Menu {
            mapLayerMenuActions
        } label: {
            journeyActionLabel("Wygląd i warstwy", symbol: "square.3.layers.3d")
        }
        .accessibilityLabel("Wygląd i warstwy mapy")
    }

    private func mapMenuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    private var routePreviewHeader: some View {
        HStack(spacing: 11) {
            Button {
                engine.stop()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wróć do mapy")

            Text("Podgląd trasy")
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 28))
    }

    private var searchButton: some View {
        Button(action: presentSearch) {
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Dokąd chcesz jechać?")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Otwiera wyszukiwanie miejsca lub adresu")
    }

    private var maneuverCard: some View {
        let maneuver = engine.state.progress?.nextManeuver
        let maneuverDistance = engine.state.progress?.distanceToNextManeuver ?? .infinity
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: engine.state.transportMode == .parkRide
                      ? "parkingsign.circle.fill" : (maneuver?.iconName ?? "arrow.up"))
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.state.status == .rerouting
                         ? "Przeliczanie trasy…"
                     : (engine.state.transportMode == .parkRide
                        ? distance(engine.state.progress?.remainingDistance ?? 0)
                        : (maneuverDistance <= 25 ? "TERAZ" : distance(maneuverDistance))))
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())

                    Text(engine.state.transportMode == .parkRide
                         ? "Podróż łączy samochód i komunikację"
                         : (maneuver?.displayInstruction ?? "Kontynuuj do celu"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let streetLine = maneuver?.streetLine {
                        Text(streetLine)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
                laneGuidance
            }

            if engine.state.transportMode == .car, let incident = nextRouteTrafficIncident {
                HStack(spacing: 7) {
                    Image(systemName: incident.isRoadClosure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(incident.isRoadClosure ? Color.red : Color.orange)
                    Text("\(incident.category.mapLabel) · za \(distance(max(0, (incident.distanceAlongRoute ?? 0) - (engine.state.progress?.traveledDistance ?? 0))))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if let delay = incident.delaySeconds, delay > 0 {
                        Text("+\(max(1, Int((Double(delay) / 60).rounded()))) min")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }

            if engine.state.transportMode != .parkRide,
               let maneuver = engine.state.progress?.nextManeuver,
               let exitNumber = maneuver.exitNumber {
                HStack(spacing: 6) {
                    Image(systemName: maneuver.iconName)
                    Text("Zjazd \(exitNumber)")
                    if let road = maneuver.exitRoad { Text("· \(road)") }
                    if let toward = maneuver.exitToward { Text("· kierunek \(toward)") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 21))
        .accessibilityElement(children: .combine)
    }

    private var nextRouteTrafficIncident: TrafficIncident? {
        guard engine.state.route != nil else { return nil }
        let traveledDistance = engine.state.progress?.traveledDistance ?? 0
        return (engine.state.traffic?.incidents ?? [])
            .filter { incident in
                guard let distance = incident.distanceAlongRoute else { return false }
                return distance > traveledDistance && distance <= traveledDistance + 12_000
            }
            .min { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
    }

    private var transitNavigationHeader: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            transitNavigationHeaderContent(at: context.date)
        }
    }

    private func transitNavigationHeaderContent(at date: Date) -> some View {
        let leg = activeTransitLeg
        let tracking = leg.flatMap { transitProgress(for: $0) }
        let isWalking = leg?.mode.uppercased() == "WALK"
        let liveNextStop = liveTransitTripDetails?.tripID == leg?.tripID
            ? liveTransitTripDetails?.nextStops.first { $0.arrival > date } : nil
        let liveTrackedStop = tracking?.nextStop.flatMap { trackedStop in
            liveTransitTripDetails?.tripID == leg?.tripID
                ? liveTransitTripDetails?.nextStops.first(where: { $0.stopID == trackedStop.stopID }) : nil
        }
        let nextStop = tracking?.nextStop ?? liveNextStop ?? leg?.transitStops.first { $0.arrival > date }
        let waitingForDeparture = !isWalking && tracking?.isOnVehicle != true && (leg?.departure ?? date) > date
        let walkingMinutes = tracking.map { Int(ceil($0.distanceToLegEnd / 1.25 / 60)) }
        let remainingMinutes = isWalking
            ? (walkingMinutes ?? max(0, Int(ceil((leg?.arrival ?? date).timeIntervalSince(date) / 60))))
            : max(0, Int(ceil((leg?.arrival ?? date).timeIntervalSince(date) / 60)))
        let title: String
        if isWalking {
            title = "Idź do \(leg?.to ?? "przystanku")"
        } else if waitingForDeparture {
            title = "Wsiądź na \(leg?.from ?? "przystanku")"
        } else if tracking?.isOnVehicle == true, tracking?.stopsUntilAlighting == 1 {
            title = "Wysiadaj na \(leg?.to ?? "następnym przystanku")"
        } else {
            title = "Następny · \(nextStop?.name ?? leg?.to ?? "przystanek")"
        }
        let eta: String
        if isWalking {
            eta = "\(remainingMinutes) min"
        } else if waitingForDeparture {
            eta = transitETA(leg?.departure ?? date, now: date)
        } else if let liveTrackedStop {
            eta = transitETA(liveTrackedStop.arrival, now: date)
        } else if let nextStop {
            eta = transitETA(nextStop.arrival, now: date)
        } else {
            eta = "—"
        }

        let subtitle: String
        if isWalking {
            subtitle = "Pieszo · około \(remainingMinutes) min"
        } else if tracking?.isOnVehicle == true {
            subtitle = "Linia \(leg?.line ?? "MPK") · wysiadka: \(leg?.to ?? "cel") · \(tracking?.stopsUntilAlighting ?? 0) przyst."
        } else {
            subtitle = "Linia \(leg?.line ?? "MPK") · kierunek \(leg?.to ?? "")"
        }

        return HStack(spacing: 12) {
            if let leg, !isWalking {
                Text(leg.line ?? "MPK")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 42)
                    .background(mapTransitColor(leg.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 13))
            } else {
                Image(systemName: "figure.walk")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 42)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(eta)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(isWalking ? "do przystanku" : waitingForDeparture ? "do odjazdu" : "do przystanku")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 21))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var laneGuidance: some View {
        if engine.state.transportMode != .parkRide,
           let lanes = engine.state.progress?.nextManeuver?.lanes, !lanes.isEmpty {
            HStack(spacing: 4) {
                ForEach(lanes) { lane in
                    Image(systemName: laneSymbol(lane.indications))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(lane.valid ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: 20, height: 30)
                        .background(lane.valid ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .accessibilityLabel("Wskazówki wyboru pasa")
        }
    }

    private func laneSymbol(_ indications: [String]) -> String {
        let value = indications.joined(separator: " ").lowercased()
        if value.contains("uturn") { return "arrow.uturn.left" }
        if value.contains("left") && value.contains("right") { return "arrow.up.left.and.arrow.up.right" }
        if value.contains("left") { return "arrow.turn.up.left" }
        if value.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 34, height: 4)
                .frame(maxWidth: .infinity)
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(engine.state.destination?.name ?? "Wybrane miejsce")
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button(destinationExpanded ? "Zwiń" : "Rozwiń",
                       systemImage: destinationExpanded ? "chevron.down" : "chevron.up") {
                    withAnimation(.easeInOut(duration: 0.25)) { destinationExpanded.toggle() }
                }
                .labelStyle(.iconOnly)
                Button("Zamknij", systemImage: "xmark") { engine.stop() }
                    .labelStyle(.iconOnly)
            }
            if let destination = engine.state.destination {
                Text(destination.address ?? "\(destination.coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(destination.coordinate.longitude.formatted(.number.precision(.fractionLength(5))))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(destinationExpanded ? 3 : 1)
            }
            Button {
                Task { await engine.planRoute() }
            } label: {
                Label("Wyznacz trasę", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if destinationExpanded, let destination = engine.state.destination {
                Divider()
                HStack(spacing: 14) {
                    Button("Zapisz", systemImage: "star") {
                        isSavingPlace = true
                        favoriteName = destination.name
                    }
                    .buttonStyle(.bordered)
                    if let url = URL(string: "https://maps.apple.com/?ll=\(destination.coordinate.latitude),\(destination.coordinate.longitude)") {
                        ShareLink(item: url) { Label("Udostępnij", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                }
                if isSavingPlace {
                    HStack {
                        TextField("Nazwa miejsca", text: $favoriteName)
                        Menu("Zapisz jako") {
                            ForEach(PlaceKind.allCases, id: \.self) { kind in
                                Button(kind.title) { saveCurrentPlace(as: kind); isSavingPlace = false }
                            }
                        }
                    }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 26))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -40 { destinationExpanded = true }
            if value.translation.height > 40 { destinationExpanded = false }
        })
    }

    private var routeCalculatingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.state.destination != nil {
                transportSelector
            }
            HStack(spacing: 12) {
                ProgressView()
                Text("Wyznaczanie trasy…")
                    .font(.headline)
                    .contentTransition(.opacity)
                Spacer()
                Button("Anuluj", systemImage: "xmark") { engine.stop() }
                    .labelStyle(.iconOnly)
            }
        }
        .padding(14)
        .modifier(NavigationGlassSurface(radius: 26))
    }

    private var routePreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    routePreviewExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(routePreviewExpanded ? "Zwiń szczegóły" : "Szczegóły trasy")
                    Spacer()
                    Image(systemName: routePreviewExpanded ? "chevron.down" : "chevron.up")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(routePreviewExpanded ? "Zwiń szczegóły trasy" : "Rozwiń szczegóły trasy")

            HStack(spacing: 10) {
                Button {
                    showSearch = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.1), in: Circle())
                        Text(engine.state.destination?.name ?? "Wyznaczanie trasy")
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zmień cel podróży")

                Button(action: toggleDestinationFavorite) {
                    Image(systemName: isDestinationFavorite ? "star.fill" : "star")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isDestinationFavorite ? Color.accentColor : Color.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .scaleEffect(favoritePulseScale)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDestinationFavorite ? "Usuń cel z ulubionych" : "Zapisz cel w ulubionych")
            }

            transportSelector

            if let route = engine.state.route {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(time(route.expectedTravelTime))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text("PODRÓŻ")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(distance(route.distance))
                            .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                        Text("TRASA")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 7) {
                    ForEach(Array(engine.state.routeOptions.enumerated()), id: \.element.id) { item in
                        routeOption(item.element, index: item.offset + 1,
                                    selectedRoute: route, isSelected: item.element.id == route.id)
                    }
                }

                if engine.state.transportMode == .transit, let journey = route.journey {
                    let transitLegs = journey.legs.filter { $0.mode != "WALK" }
                    if let firstRide = transitLegs.first {
                        let rideDuration = transitLegs.reduce(0.0) {
                            $0 + $1.arrival.timeIntervalSince($1.departure)
                        }
                        HStack(spacing: 8) {
                            Text(firstRide.line ?? "MPK")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(mapTransitColor(firstRide.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 7))
                            Text(transitLegs.map { $0.line ?? "MPK" }.joined(separator: " → "))
                                .font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let delay = displayedTransitDelay(for: firstRide), abs(delay) >= 30 {
                                Text(delayLabel(TimeInterval(delay))).font(.caption.weight(.semibold))
                                    .foregroundStyle(transitDelayColor(delay))
                            } else if hasLiveTransitUpdate(for: firstRide) {
                                Label("Na żywo", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 5) {
                            Text("Wsiadasz \(firstRide.departure.formatted(date: .omitted, time: .shortened))")
                            Text("·")
                            Text("Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text("Pojazdami \(transitMetricTime(rideDuration)) · pieszo \(transitMetricTime(journey.walkingDuration)) · czekanie \(transitMetricTime(journey.waitingDuration)) · przesiadki: \(journey.transferCount)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                if routePreviewExpanded {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 15) {
                            routeEndpoints
                            waypointDetails
                            if !route.chargingStops.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Ładowanie po drodze")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Szacowany czas postojów: \(Int((route.chargingDuration / 60).rounded())) min")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(route.chargingStops) { stop in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stop.destination.name).font(.caption.weight(.medium))
                                            Text("\(stop.connectorTypes.joined(separator: ", ")) · do \(Int(stop.maximumPowerKW.rounded())) kW · postój \(Int((stop.estimatedChargingTime / 60).rounded())) min")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text(stop.availabilityKnown ? "Status: działająca według OpenStreetMap" : "Dostępność ładowarki nieznana")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text(stop.publicAccess == true ? "Dostęp publiczny według OpenStreetMap" : "Dostęp publiczny niepotwierdzony")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Opcje trasy")
                                    .font(.subheadline.weight(.semibold))
                                routePreferenceToggle("Unikaj autostrad", keyPath: \.avoidHighways)
                                routePreferenceToggle("Unikaj dróg płatnych", keyPath: \.avoidTolls)
                                routePreferenceToggle("Unikaj promów", keyPath: \.avoidFerries)
                            }

                            if let journey = route.journey {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Połączenie")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Odjazd \(journey.departure.formatted(date: .omitted, time: .shortened)) · Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                    Text(transitRealtimeStatus(for: journey))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if journey.alertsFeedAvailable && journey.alerts.isEmpty {
                                        Text("Brak aktywnych komunikatów dla tej trasy")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    } else if !journey.alertsFeedAvailable {
                                        Text("Komunikaty na trasie niedostępne")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let attribution = journey.railwayScheduleAttribution {
                                        Text(attribution)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if journey.scheduleIsCached {
                                        Text("Rozkład pobrany z pamięci urządzenia")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                    ForEach(journey.legs) { leg in
                                        HStack(alignment: .top, spacing: 9) {
                                            Text(leg.departure.formatted(date: .omitted, time: .shortened))
                                                .monospacedDigit()
                                            VStack(alignment: .leading, spacing: 2) {
                                                let legTitle = leg.mode == "WALK"
                                                    ? (leg.isTransfer ? "Przesiadka pieszo" : "Dojście pieszo")
                                                    : (leg.line ?? leg.mode)
                                                Text("\(legTitle) · \(leg.from) → \(leg.to)")
                                                if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                                                    Text(delayLabel(TimeInterval(delay)))
                                                        .font(.caption2).foregroundStyle(transitDelayColor(delay))
                                                } else if hasLiveTransitUpdate(for: leg) {
                                                    Label("Na żywo", systemImage: "dot.radiowaves.left.and.right")
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                } else if leg.realTime {
                                                    Text("wg aktualizacji realtime")
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .font(.caption)
                                    }
                                }
                            }

                            if engine.state.transportMode == .car {
                                Button {
                                    showTrafficDetails = true
                                } label: {
                                    Label("Szczegóły ruchu", systemImage: "car.side")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.plain)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                        isSavingPlace.toggle()
                                    }
                                    if !isSavingPlace { favoriteName = "" }
                                } label: {
                                    Label(isSavingPlace ? "Zamknij zapis" : "Zapisz miejsce",
                                          systemImage: isSavingPlace ? "checkmark" : "star")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.plain)

                                if isSavingPlace {
                                    HStack(spacing: 8) {
                                        TextField("Nazwa miejsca", text: $favoriteName)
                                            .textFieldStyle(.roundedBorder)
                                            .submitLabel(.done)
                                        Menu {
                                            ForEach(PlaceKind.allCases, id: \.self) { kind in
                                                Button(kind.title, systemImage: kind == .home ? "house" : kind == .work ? "briefcase" : "star") {
                                                    saveCurrentPlace(as: kind)
                                                }
                                            }
                                        } label: {
                                            Label("Zapisz jako", systemImage: "checkmark")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .frame(height: 240)
                    .scrollIndicators(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Button {
                        addingWaypoint = true
                        showSearch = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text(engine.state.waypoints.isEmpty
                                 ? "Dodaj przystanek"
                                 : "Przystanki · \(engine.state.waypoints.count)")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.state.waypoints.count >= 8 || engine.state.status != .routePreview)
                }

                if engine.state.transportMode != .transit {
                    beginRouteButton
                }
            } else if engine.state.status == .routeCalculating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Wyznaczanie trasy…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                HStack {
                    Text(engine.state.errorMessage ?? "Nie udało się wyznaczyć trasy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Spróbuj ponownie") { Task { await engine.planRoute() } }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 7)
        .padding(.bottom, 11)
        .modifier(NavigationGlassSurface(radius: 26))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { routePreviewExpanded = true }
            } else if value.translation.height > 35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { routePreviewExpanded = false }
            }
        })
    }

    private var beginRouteButton: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                engine.begin()
            }
        } label: {
            Label("Rozpocznij", systemImage: engine.state.transportMode == .transit ? "tram.fill" : "location.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(engine.state.status != .routePreview)
        .opacity(engine.state.status == .routePreview ? 1 : 0.55)
    }

    private var transportSelector: some View {
        HStack(spacing: 5) {
            ForEach(TransportMode.allCases) { mode in
                Button {
                    Task { await engine.selectTransportMode(mode) }
                } label: {
                    Group {
                        if engine.state.transportMode == mode {
                            HStack(spacing: 8) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(mode.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        } else {
                            VStack(spacing: 3) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 15, weight: .medium))
                                Text(compactTitle(for: mode))
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                    }
                    .foregroundStyle(engine.state.transportMode == mode ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: engine.state.transportMode == mode ? 132 : .infinity)
                    .layoutPriority(engine.state.transportMode == mode ? 1 : 0)
                    .frame(minHeight: 48)
                    .padding(.horizontal, engine.state.transportMode == mode ? 5 : 0)
                    .background {
                        if engine.state.transportMode == mode {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
                                }
                                .matchedGeometryEffect(id: "selected-transport", in: transportSelectionNamespace)
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(engine.state.transportMode == mode ? .isSelected : [])
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: engine.state.transportMode)
    }

    private func compactTitle(for mode: TransportMode) -> String {
        switch mode {
        case .car: "Auto"
        case .walking: "Pieszo"
        case .bicycle: "Rower"
        case .transit: "Komunikacja"
        case .parkRide: "P+R"
        }
    }

    private var waypointDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Przystanki pośrednie")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if engine.state.waypoints.count >= 2 {
                    Button("Optymalizuj", systemImage: "arrow.triangle.swap") {
                        Task { await engine.optimizeWaypoints() }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(engine.state.status != .routePreview)
                }
            }

            ForEach(Array(engine.state.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    Text(waypoint.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Przenieś wyżej", systemImage: "chevron.up") {
                        Task { await engine.moveWaypoint(waypoint.id, by: -1) }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(index == 0 || engine.state.status != .routePreview)
                    Button("Przenieś niżej", systemImage: "chevron.down") {
                        Task { await engine.moveWaypoint(waypoint.id, by: 1) }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(index == engine.state.waypoints.count - 1 || engine.state.status != .routePreview)
                    Button("Usuń przystanek", systemImage: "xmark.circle.fill", role: .destructive) {
                        Task { await engine.removeWaypoint(waypoint.id) }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(engine.state.status != .routePreview)
                }
            }

            Button {
                addingWaypoint = true
                showSearch = true
            } label: {
                Label("Dodaj przystanek", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(engine.state.waypoints.count >= 8 || engine.state.status != .routePreview)
        }
    }

    private var routeEndpoints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trasa")
                .font(.subheadline.weight(.semibold))
            Label(engine.state.location == nil ? "Pozycja niedostępna" : "Moja pozycja",
                  systemImage: "location.fill")
                .font(.subheadline)
                .foregroundStyle(engine.state.location == nil ? Color.secondary : Color.primary)
            Label(engine.state.destination?.name ?? "Cel podróży",
                  systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private func routePreferenceToggle(_ title: String,
                                      keyPath: WritableKeyPath<RoutingPreferences, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { engine.state.routingPreferences[keyPath: keyPath] },
            set: { value in
                var preferences = engine.state.routingPreferences
                preferences[keyPath: keyPath] = value
                Task { await engine.updateRoutingPreferences(preferences) }
            }
        ))
        .font(.subheadline)
    }

    private func routeOption(_ route: NavigationRoute, index: Int,
                             selectedRoute: NavigationRoute, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                engine.select(route)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(routeOptionTime(route, selectedRoute: selectedRoute, isSelected: isSelected))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(routeTransitSummary(route) ?? distance(route.distance))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 9)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.05))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Trasa \(index), \(time(route.expectedTravelTime)), \(distance(route.distance))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func routeTransitSummary(_ route: NavigationRoute) -> String? {
        guard let journey = route.journey else { return nil }
        let lines = journey.legs.filter { $0.mode != "WALK" }.compactMap(\.line)
        guard !lines.isEmpty else { return nil }
        let walkingMinutes = journey.legs.filter { $0.mode == "WALK" }
            .reduce(0) { $0 + max(0, Int(ceil($1.arrival.timeIntervalSince($1.departure) / 60))) }
        return lines.joined(separator: " → ") + (walkingMinutes > 0 ? " · pieszo \(walkingMinutes) min" : "")
    }

    private func routeOptionTime(_ route: NavigationRoute, selectedRoute: NavigationRoute,
                                 isSelected: Bool) -> String {
        guard !isSelected else { return compactRouteTime(route.expectedTravelTime) }
        let difference = route.expectedTravelTime - selectedRoute.expectedTravelTime
        let minutes = Int(ceil(abs(difference) / 60))
        guard minutes > 0 else { return compactRouteTime(route.expectedTravelTime) }
        return "\(difference > 0 ? "+" : "−")\(minutes) min"
    }

    private func compactRouteTime(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(seconds / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(totalMinutes) min" }
        return "\(hours):\(String(format: "%02d", minutes))"
    }

    private func transitMetricTime(_ seconds: TimeInterval) -> String {
        seconds > 0 ? compactRouteTime(seconds) : "0 min"
    }

    private func discoveryPanel(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            searchButton
            nearbyTransitCard
            if !compact {
                HStack(alignment: .firstTextBaseline) {
                    Text("Dokąd ruszamy?")
                        .font(.title2.bold())
                    Spacer()
                    Button { showHistory = true } label: {
                        Label("Ostatnie", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                HStack {
                    Text("Szybki dostęp")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Zobacz wszystkie", systemImage: "star") { showFavorites = true }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                if !quickDestinations.isEmpty {
                    quickDestinationShelf
                } else {
                    Text("Zapisz Dom, Pracę lub ulubiony adres, aby mieć je zawsze pod ręką.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach([NearbyPlaceCategory.fuel, .charging, .parking, .food]) { category in
                            Button { presentNearby(category) } label: {
                                Label(category.title, systemImage: category.symbol)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 13)
                                    .frame(minHeight: 44)
                                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Miejsca w pobliżu")
            }
        }
        .padding(18)

    }

    @ViewBuilder
    private var nearbyTransitCard: some View {
        if let stop = engine.state.nearbyTransitStop,
           !engine.state.nearbyTransitDepartures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { openTransitStop(stop) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tram.fill").foregroundStyle(Color.accentColor)
                        Text("Transport w pobliżu").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer()
                        if let location = engine.state.location?.coordinate {
                            Text(distance(location.distance(to: stop.coordinate)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(stop.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(engine.state.nearbyTransitDepartures.prefix(3)) { departure in
                    Button { openTransitDeparture(departure) } label: {
                        TimelineView(.periodic(from: .now, by: 20)) { context in
                            HStack(spacing: 9) {
                                Text(departure.line).font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white).frame(minWidth: 30, minHeight: 24)
                                    .background(mapTransitColor(departure.colorHex), in: RoundedRectangle(cornerRadius: 7))
                                Text(departure.destination).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 3)
                                Text(transitETA(departure.estimatedDeparture, now: context.date))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(transitDelayColor(departure.delaySeconds))
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
        }
    }

    private func transitETA(_ departure: Date, now: Date) -> String {
        let minutes = Int(ceil(departure.timeIntervalSince(now) / 60))
        return minutes <= 0 ? "teraz" : time(TimeInterval(minutes * 60))
    }

    private func transitDelayColor(_ seconds: Int?) -> Color {
        guard let seconds else { return .primary }
        guard seconds > 0 else { return .secondary }
        let minutes = seconds / 60
        if minutes > 5 { return .red }
        if minutes >= 3 { return .orange }
        return .primary
    }

    private var quickDestinationShelf: some View {
        Group {
            if !quickDestinations.isEmpty {
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(quickDestinations) { shortcut in
                                    Button {
                                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                            selectDestination(shortcut.destination)
                                        }
                                    } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: shortcut.symbol)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(Color.accentColor)
                                                .frame(width: 20)

                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(shortcut.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                if let estimatedMinutes = shortcut.estimatedMinutes {
                                                    Text("\(estimatedMinutes) min")
                                                        .font(.caption.weight(.medium).monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 13)
                                        .frame(minWidth: 112, minHeight: 54, alignment: .leading)
                                        .background(Color.primary.opacity(0.045), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.045)))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Pokaż miejsce \(shortcut.title)")
                                    .accessibilityHint(shortcut.isRecent ? "Ostatnio wybrane miejsce" : "Zapisane miejsce")
                                    .id(shortcut.id)
                                }
                            }
                            .padding(.leading, 7)
                            .padding(.trailing, quickDestinations.count > 2 ? 10 : 7)
                        }
                        .scrollIndicators(.hidden)
                        .mask(LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.82),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing))

                        if quickDestinations.count > 2, let lastShortcut = quickDestinations.last {
                            Button {
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    proxy.scrollTo(lastShortcut.id, anchor: .trailing)
                                }
                            } label: {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 37, height: 42)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pokaż kolejne miejsca")
                        }
                    }
                    .padding(.vertical, 4)

                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voiceQuickControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle("Komunikaty głosowe", isOn: voiceEnabledBinding)
            Picker("Gadatliwość", selection: voiceVerbosityBinding) {
                ForEach(VoiceVerbosity.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("Głos polski", selection: voiceIdentifierBinding) {
                Text("Automatyczny").tag("")
                ForEach(availablePolishVoices, id: \.identifier) { voice in
                    Text(voice.name).tag(voice.identifier)
                }
            }
            voiceSliderRow(
                title: "Tempo",
                value: voiceRateBinding,
                range: 0.38...0.62,
                valueDescription: String(format: "%.0f%%", Double(engine.state.voicePreferences.speechRate) * 200)
            )
            voiceSliderRow(
                title: "Głośność",
                value: voiceVolumeBinding,
                range: 0...1,
                valueDescription: String(format: "%.0f%%", Double(engine.state.voicePreferences.volume) * 100)
            )
            Button("Więcej ustawień głosu") {
                showVoiceControls = false
                showSettings = true
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(16)
        .frame(width: 300)
    }

    private func voiceSliderRow(title: String, value: Binding<Double>,
                                range: ClosedRange<Double>, valueDescription: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(valueDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func mapControl(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        return HStack(alignment: .bottom) {
            if isNavigating && engine.state.transportMode == .car {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    speedCard(at: context.date)
                }
            }
            Spacer()
            layout {
                if isNavigating {
                    Button {
                        engine.setVoiceEnabled(!engine.state.voiceEnabled)
                    } label: {
                        circleSurface {
                            Image(systemName: engine.state.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(engine.state.voiceEnabled ? Color.accentColor : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(engine.state.voiceEnabled ? "Wyłącz komunikaty głosowe" : "Włącz komunikaty głosowe")
                    Button {
                        showVoiceControls.toggle()
                    } label: {
                        circleSurface {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sterowanie głosem")
                    .popover(isPresented: $showVoiceControls) { voiceQuickControls }
                } else {
                    mapLayersMenu
                }
                Button {
                    if isNavigating {
                        engine.returnToFollow()
                    } else if engine.state.cameraState == .routeOverview {
                        engine.returnToFollow()
                    } else if engine.state.route != nil {
                        engine.showRouteOverview()
                    } else {
                        engine.returnToFollow()
                    }
                } label: {
                    circleSurface {
                        Image(systemName: isNavigating ? "location.north.fill"
                              : engine.state.cameraState == .routeOverview ? "location.fill" : "scope")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(isNavigating ? "Wróć do nawigacji" : "Moja pozycja", systemImage: "location.fill") {
                        engine.returnToFollow()
                    }
                    if engine.state.route != nil {
                        Button("Cała trasa", systemImage: "map") {
                            engine.showRouteOverview()
                        }
                    }
                }
                .accessibilityLabel(isNavigating
                    ? "Wróć do prowadzenia"
                    : (engine.state.route == nil ? "Moja pozycja" : (engine.state.cameraState == .routeOverview ? "Wróć do mapy" : "Przegląd trasy")))
                .accessibilityHint(isNavigating
                    ? "Ustawia kamerę na bieżącej pozycji i kierunku podróży"
                    : "Przełącza między mapą i przeglądem trasy")
            }
        }
    }

    private var journeyPanel: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    navigationPanelExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    metric(value: time(engine.state.progress?.remainingTime ?? 0), caption: "do celu")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metric(value: distance(engine.state.progress?.remainingDistance ?? 0), caption: "pozostało")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metric(value: arrivalTime(engine.state.progress?.remainingTime ?? 0), caption: "przyjazd")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: navigationPanelExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(navigationPanelExpanded ? "Zwiń panel prowadzenia" : "Rozwiń panel prowadzenia")

            if engine.state.transportMode == .transit, let transitLeg = activeTransitLeg {
                if transitLeg.mode == "WALK" {
                    transitWalkNavigationCard(transitLeg)
                } else {
                    transitNavigationCard(transitLeg)
                }
            } else if let currentLeg = currentJourneyLeg {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Teraz jedziesz do \(currentLeg.current.name)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let following = currentLeg.following {
                            Text("Po dotarciu: \(following.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }

            if navigationPanelExpanded {
                Divider()
                Text("W trakcie podróży")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                    Menu {
                        Button("Paliwo", systemImage: NearbyPlaceCategory.fuel.symbol) { presentNearby(.fuel) }
                        Button("Parking", systemImage: NearbyPlaceCategory.parking.symbol) { presentNearby(.parking) }
                        Button("Ładowarki", systemImage: NearbyPlaceCategory.charging.symbol) { presentNearby(.charging) }
                        Button("Jedzenie", systemImage: NearbyPlaceCategory.food.symbol) { presentNearby(.food) }
                    } label: {
                        journeyActionLabel("Po trasie", symbol: "magnifyingglass")
                    }
                    Button {
                        addingWaypoint = true
                        showSearch = true
                    } label: {
                        journeyActionLabel("Przystanek", symbol: "plus.circle")
                    }
                    .disabled(engine.state.waypoints.count >= 8)
                    Button {
                        engine.showRouteOverview()
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                            navigationPanelExpanded = false
                        }
                    } label: {
                        journeyActionLabel("Cała trasa", symbol: "map")
                    }
                    Button {
                        routingDraft = engine.state.routingPreferences
                        showRouteSettings = true
                    } label: {
                        journeyActionLabel("Opcje trasy", symbol: "slider.horizontal.3")
                    }
                    journeyMapLayersMenu
                    Button { showTrafficDetails = true } label: {
                        journeyActionLabel("Ruch na żywo", symbol: "car.side")
                    }
                    Button { presentNearby(.parking, nearDestination: true) } label: {
                        journeyActionLabel("Parking na miejscu", symbol: "parkingsign.circle")
                    }
                }
                .buttonStyle(.plain)
                if engine.state.transportMode == .transit {
                    transitJourneyTimeline
                } else if engine.state.transportMode == .parkRide {
                    parkRideJourneyTimeline
                }
                Divider()
                Button(role: .destructive) { engine.stop() } label: {
                    Label("Zakończ nawigację", systemImage: "stop.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.red)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .modifier(NavigationGlassSurface(radius: 23))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = true }
            } else if value.translation.height > 35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = false }
            }
        })
    }

    private func journeyActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var currentJourneyLeg: (current: Destination, following: Destination?)? {
        guard let route = engine.state.route, let destination = engine.state.destination else { return nil }
        var stops = engine.state.waypoints + engine.state.evChargingStops
        if !stops.contains(where: { $0.coordinate == destination.coordinate }) { stops.append(destination) }
        let ordered = stops.compactMap { stop -> (Destination, Double)? in
            guard let projection = MapMatcher.project(stop.coordinate, onto: route.coordinates) else { return nil }
            return (stop, projection.alongRoute)
        }.sorted { $0.1 < $1.1 }
        guard !ordered.isEmpty else { return (destination, nil) }
        let routeLength = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let progressFraction = route.distance > 0
            ? (engine.state.progress?.traveledDistance ?? 0) / route.distance : 0
        let traveledGeometry = routeLength * max(0, min(1, progressFraction))
        let currentIndex = ordered.firstIndex { $0.1 > traveledGeometry + 30 } ?? (ordered.count - 1)
        return (ordered[currentIndex].0,
                ordered.indices.contains(currentIndex + 1) ? ordered[currentIndex + 1].0 : nil)
    }

    private var activeTransitLegIndex: Int? {
        guard let legs = engine.state.route?.journey?.legs, !legs.isEmpty else { return nil }
        if let tracked = engine.state.transitProgress?.legIndex, legs.indices.contains(tracked) {
            return tracked
        }
        return legs.firstIndex { leg in
            let liveArrival = liveTransitTripDetails?.tripID == leg.tripID
                ? liveTransitTripDetails?.nextStops.last?.arrival : nil
            return (liveArrival ?? leg.arrival) > Date()
        } ?? legs.indices.last
    }

    private var activeTransitLeg: JourneyLeg? {
        guard let legs = engine.state.route?.journey?.legs,
              let index = activeTransitLegIndex, legs.indices.contains(index) else { return nil }
        return legs[index]
    }

    private func transitProgress(for leg: JourneyLeg) -> TransitNavigationProgress? {
        guard let legs = engine.state.route?.journey?.legs,
              let progress = engine.state.transitProgress,
              legs.indices.contains(progress.legIndex),
              legs[progress.legIndex].id == leg.id else { return nil }
        return progress
    }

    private func liveTransitDetails(for leg: JourneyLeg) -> TransitTripDetails? {
        guard liveTransitTripDetails?.tripID == leg.tripID else { return nil }
        return liveTransitTripDetails
    }

    private func liveTransitStop(_ stopID: String, for leg: JourneyLeg) -> TransitJourneyStop? {
        guard let details = liveTransitDetails(for: leg) else { return nil }
        return details.nextStops.first(where: { $0.stopID == stopID })
            ?? details.pastStops.first(where: { $0.stopID == stopID })
    }

    private func displayedTransitDelay(for leg: JourneyLeg) -> Int? {
        let liveAlightingDelay = leg.transitStops.last.flatMap {
            liveTransitStop($0.stopID, for: leg)?.delaySeconds
        }
        let liveUpcomingDelay = liveTransitDetails(for: leg)?.nextStops
            .first(where: { $0.delaySeconds != nil })?.delaySeconds
        return liveAlightingDelay ?? liveUpcomingDelay ?? leg.delaySeconds
    }

    private func hasLiveTransitUpdate(for leg: JourneyLeg) -> Bool {
        guard engine.state.route?.journey?.realtimeFreshness == .live else { return false }
        guard let details = liveTransitDetails(for: leg) else { return false }
        return details.nextStops.contains(where: { $0.hasRealtime })
            || details.pastStops.contains(where: { $0.hasRealtime })
    }

    private func transitRealtimeStatus(for journey: Journey) -> String {
        let time = journey.realtimeFeedUpdatedAt?.formatted(date: .omitted, time: .shortened)
        switch journey.realtimeFreshness {
        case .live:
            return "Aktualizacje opóźnień na żywo · \(time ?? "teraz")"
        case .degraded:
            return "Opóźnione aktualizacje realtime · \(time ?? "bez czasu")"
        case .stale:
            return "Dane realtime są nieświeże · pokazano rozkład"
        case .unavailable:
            return "Dane o opóźnieniach niedostępne · pokazano rozkład"
        }
    }

    private func transitFreshnessIndicator(for journey: Journey) -> some View {
        let presentation = switch journey.realtimeFreshness {
        case .live: ("dot.radiowaves.left.and.right", Color.green)
        case .degraded: ("clock.badge.exclamationmark", Color.orange)
        case .stale: ("clock", Color.secondary)
        case .unavailable: ("minus.circle", Color.secondary)
        }
        return Label(transitRealtimeStatus(for: journey), systemImage: presentation.0)
            .font(.caption2.weight(.medium))
            .foregroundStyle(presentation.1)
            .lineLimit(2)
            .accessibilityElement(children: .combine)
    }

    private func refreshTransitJourneyDetails() async {
        guard engine.state.transportMode == .transit else {
            liveTransitTripDetails = nil
            engine.updateTransitTripDetails(nil, tripID: nil)
            return
        }
        while !Task.isCancelled {
            await engine.refreshTransitRouteIfNeeded()
            guard !Task.isCancelled else { return }
            let legs = engine.state.route?.journey?.legs ?? []
            let activeIndex = activeTransitLegIndex ?? 0
            let nextRide = legs.indices.first { index in
                index >= activeIndex && legs[index].tripID != nil
            }.map { legs[$0] }
            if let leg = nextRide, let tripID = leg.tripID,
               let serviceDate = leg.serviceDate, let sequence = leg.transitStops.first?.sequence {
                let provider = LodzTransitRouteProvider()
                let tripDetails = await provider.tripDetails(tripID: tripID, serviceDate: serviceDate,
                                                             fromStopSequence: sequence)
                guard !Task.isCancelled else { return }
                engine.updateTransitTripDetails(tripDetails, tripID: tripID)
                let lineDetails: TransitLineDetails?
                if selectedTransitRouteID == leg.routeID, let selectedTransitLine {
                    lineDetails = selectedTransitLine
                } else if let routeID = leg.routeID {
                    lineDetails = await provider.lineDetails(for: routeID)
                } else {
                    lineDetails = nil
                }
                liveTransitTripDetails = tripDetails
                selectedTransitRouteID = leg.routeID
                selectedTransitTripID = tripID
                selectedTransitTripStopIDs = Set((tripDetails?.pastStops ?? []).map(\.stopID)
                    + (tripDetails?.currentStopID.map { [$0] } ?? [])
                    + (tripDetails?.nextStops ?? []).map(\.stopID))
                selectedTransitLine = lineDetails
                selectedTransitTripCoordinates = tripDetails?.coordinates ?? []
            } else {
                liveTransitTripDetails = nil
                engine.updateTransitTripDetails(nil, tripID: nil)
                selectedTransitRouteID = nil
                selectedTransitTripID = nil
                selectedTransitTripStopIDs = []
                selectedTransitLine = nil
                selectedTransitTripCoordinates = []
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func transitWalkNavigationCard(_ leg: JourneyLeg) -> some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let tracking = transitProgress(for: leg)
            let remaining = tracking.map { max(0, Int(ceil($0.distanceToLegEnd / 1.25 / 60))) }
                ?? max(0, Int(ceil(leg.arrival.timeIntervalSince(context.date) / 60)))
            let nextRide = engine.state.route?.journey?.legs.first {
                $0.mode != "WALK" && $0.departure >= leg.arrival && $0.from == leg.to
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor).frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idź do \(leg.to)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("Pieszo · około \(remaining) min").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let nextRide {
                        Text(nextRide.departure.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let nextRide {
                    HStack(spacing: 7) {
                        Text(nextRide.line ?? "MPK").font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(mapTransitColor(nextRide.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 7))
                        Text("Następnie · \(nextRide.to)").font(.caption).lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func transitNavigationCard(_ leg: JourneyLeg) -> some View {
        TimelineView(.periodic(from: .now, by: 20.0)) { context in
            let tracking = transitProgress(for: leg)
            let upcoming = leg.transitStops.filter { $0.arrival > context.date }
            let liveDetails = liveTransitTripDetails?.tripID == leg.tripID ? liveTransitTripDetails : nil
            let liveUpcoming = liveDetails?.nextStops.filter { $0.arrival > context.date } ?? []
            let alightingStopID = leg.transitStops.last?.stopID
            let liveAlightingStop = (liveDetails?.pastStops ?? []).first(where: { $0.stopID == alightingStopID })
                ?? (liveDetails?.nextStops ?? []).first(where: { $0.stopID == alightingStopID })
            let nextStop = tracking?.nextStop ?? liveUpcoming.first ?? upcoming.first
            let displayedDelay = displayedTransitDelay(for: leg)
            let displayedArrival = liveAlightingStop?.arrival ?? leg.arrival
            let minutesUntilDeparture = max(0, Int(ceil(leg.departure.timeIntervalSince(context.date) / 60)))
            let scheduledProgress = leg.transitStops.isEmpty ? 0 :
                Double(leg.transitStops.count - upcoming.count) / Double(leg.transitStops.count)
            let progress = tracking?.legFraction ?? scheduledProgress
            let stopsRemaining = tracking?.stopsUntilAlighting ?? upcoming.count
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(leg.line ?? "MPK")
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white).frame(minWidth: 42, minHeight: 34)
                        .background(mapTransitColor(leg.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.to).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(minutesUntilDeparture > 0
                             ? "Odjazd za \(transitETA(leg.departure, now: context.date))"
                             : "W podróży · do \(leg.to)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(compactRouteTime(max(0, displayedArrival.timeIntervalSince(context.date))))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                if let nextStop {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                        Text(minutesUntilDeparture > 0 ? "Wsiądź na \(leg.from)" : "Następny · \(nextStop.name)")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(minutesUntilDeparture > 0
                             ? leg.departure.formatted(date: .omitted, time: .shortened)
                             : transitETA(nextStop.arrival, now: context.date))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(Color.accentColor).frame(width: max(8, geometry.size.width * min(1, max(0, progress))))
                        HStack(spacing: 0) {
                            ForEach(leg.transitStops.indices, id: \.self) { index in
                                Circle().fill(Double(index) / Double(max(1, leg.transitStops.count - 1)) <= progress
                                              ? .white : Color.secondary.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                if index < leg.transitStops.count - 1 { Spacer(minLength: 0) }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .frame(height: 8)
                Text("Jeszcze \(stopsRemaining) przyst. do \(leg.to)")
                    .font(.caption).foregroundStyle(.secondary)
                if let delay = displayedDelay, abs(delay) >= 30 {
                    Text("Rozkład \(leg.departure.formatted(date: .omitted, time: .shortened)) · \(delayLabel(TimeInterval(delay)))")
                        .font(.caption).foregroundStyle(transitDelayColor(delay))
                } else if liveDetails?.nextStops.first?.hasRealtime == true {
                    Label("Aktualizacja na żywo", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var transitJourneyTimeline: some View {
        Group {
            if let journey = engine.state.route?.journey {
                VStack(spacing: 10) {
                    transitFreshnessIndicator(for: journey)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: leg.mode == "WALK" ? "figure.walk"
                                : leg.mode == "RAIL" ? "train.side.front.car"
                                : leg.mode == "TRAM" ? "tram.fill" : "bus.fill")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(leg.mode == "WALK" ? "Idź do \(leg.to)" : "\(leg.line ?? "MPK") · \(leg.to)")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(leg.departure.formatted(date: .omitted, time: .shortened)) · \(leg.from)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if leg.mode != "WALK", !leg.transitStops.isEmpty {
                                    Text("\(max(1, leg.transitStops.count - 1)) przystanków")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                                    Text(delayLabel(TimeInterval(delay))).font(.caption.weight(.semibold))
                                        .foregroundStyle(transitDelayColor(delay))
                                } else if hasLiveTransitUpdate(for: leg) {
                                    Label("Na żywo", systemImage: "dot.radiowaves.left.and.right")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        if index < journey.legs.count - 1 {
                            Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 2, height: 9)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                        }
                    }
                    ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var parkRideJourneyTimeline: some View {
        Group {
            if let journey = engine.state.route?.journey {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Etapy podróży")
                        .font(.subheadline.weight(.semibold))
                    transitFreshnessIndicator(for: journey)
                    HStack(alignment: .top, spacing: 8) {
                        metric(value: time(journey.arrival.timeIntervalSince(journey.departure)), caption: "całość")
                        if journey.walkingDuration > 0 {
                            metric(value: time(journey.walkingDuration), caption: "pieszo")
                        }
                        if journey.waitingDuration > 0 {
                            metric(value: time(journey.waitingDuration), caption: "oczekiwanie")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 0) {
                        ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: parkRideLegSymbol(leg.mode))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 30, height: 30)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(parkRideLegTitle(leg))
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(leg.departure.formatted(date: .omitted, time: .shortened))–\(leg.arrival.formatted(date: .omitted, time: .shortened)) · \(time(max(0, leg.arrival.timeIntervalSince(leg.departure))))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(leg.from)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !leg.transitStops.isEmpty {
                                        Text("\(max(1, leg.transitStops.count - 1)) przystanków")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                                        Text(delayLabel(TimeInterval(delay)))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(transitDelayColor(delay))
                                    } else if hasLiveTransitUpdate(for: leg) {
                                        Label("Na żywo", systemImage: "dot.radiowaves.left.and.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)

                            if leg.mode == "CAR" {
                                HStack(spacing: 9) {
                                    Image(systemName: "parkingsign.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 30, height: 25)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Parking P+R · \(leg.to)")
                                            .font(.caption.weight(.semibold))
                                        Text("Koniec odcinka autem · przesiadka na komunikację")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 1)
                                .padding(.vertical, 7)
                                .accessibilityElement(children: .combine)
                            }

                            if index < journey.legs.count - 1 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 2, height: 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 14)
                                    .padding(.vertical, 3)
                            }
                        }
                    }
                    ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func parkRideLegSymbol(_ mode: String) -> String {
        switch mode {
        case "CAR": "car.fill"
        case "WALK": "figure.walk"
        case "RAIL": "train.side.front.car"
        case "TRAM": "tram.fill"
        default: "bus.fill"
        }
    }

    private func parkRideLegTitle(_ leg: JourneyLeg) -> String {
        switch leg.mode {
        case "CAR": "Samochodem do \(leg.to)"
        case "WALK": "Pieszo · \(leg.to)"
        case "RAIL": "\(leg.line ?? "Pociąg") · \(leg.to)"
        case "TRAM": "\(leg.line.flatMap { $0.isEmpty ? nil : $0 } ?? "Tramwaj") · \(leg.to)"
        default: "\(leg.line ?? "Autobus") · \(leg.to)"
        }
    }

    private var arrivalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.green, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Dotarłeś do celu")
                        .font(.headline)
                    Text(engine.state.destination?.name ?? "Podróż zakończona")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if let trip = engine.state.lastTrip {
                HStack(spacing: 0) {
                    metric(value: distance(trip.distanceMeters), caption: "przejechano")
                    Spacer()
                    metric(value: time(trip.duration), caption: "czas")
                    Spacer()
                    metric(value: "\(Int(trip.averageSpeedKph.rounded())) km/h", caption: "średnio")
                }
                HStack(spacing: 0) {
                    metric(value: timeAllowingZero(trip.stoppedSeconds), caption: "postój")
                    Spacer()
                    metric(value: "\(trip.rerouteCount)", caption: "przeliczenia")
                    Spacer()
                    if let delay = trip.delaySeconds {
                        metric(value: delayLabel(delay), caption: "względem ETA")
                    } else {
                        metric(value: "—", caption: "względem ETA")
                    }
                }
            }

            Button {
                engine.stop()
            } label: {
                Text("Zamknij podsumowanie")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(17)
        .modifier(NavigationGlassSurface(radius: 25))
    }

    private var searchSheet: some View {
        DestinationSearchSheet(
            engine: engine,
            places: localData.places,
            recentDestinations: recentDestinations,
            recentSearches: localData.searches,
            pointSelectionHint: pointSelectionHint,
            onSavePlace: { localData.add($0) },
            onSelectTransitStop: { stop in
                showSearch = false
                openTransitStop(stop)
            },
            onSelectTransitLine: { line in
                showSearch = false
                openTransitLine(line)
            },
            onSelectDestination: { destination, asStop in
                if addingWaypoint || asStop {
                    localData.recordSearch(destination)
                    Task {
                        await engine.addWaypoint(destination)
                    }
                    addingWaypoint = false
                    showSearch = false
                } else {
                    selectDestination(destination)
                }
            }
        )
    }

    private func openTransitStop(_ stop: TransitStop) {
        if let center = engine.state.searchMapCenter ?? engine.state.location?.coordinate,
           center.distance(to: stop.coordinate) > 700 {
            engine.focusMap(on: stop.coordinate)
        }
        selectedTransitStopID = stop.id
        selectedTransitRouteID = nil
        selectedTransitTripID = nil
        selectedTransitTripStopIDs = []
        selectedTransitLine = nil
        selectedTransitTripCoordinates = []
        selectedTransitSheet = .stop(stop)
    }

    private func openTransitVehicle(_ vehicle: TransitVehicle) {
        selectedTransitStopID = nil
        selectedTransitRouteID = vehicle.routeID
        selectedTransitTripID = vehicle.tripID
        selectedTransitTripStopIDs = []
        selectedTransitTripCoordinates = []
        selectedTransitSheet = .vehicle(vehicle)
        Task {
            let provider = LodzTransitRouteProvider()
            async let line = provider.lineDetails(for: vehicle.routeID)
            async let trip = provider.vehicleDetails(id: vehicle.id)
            let (lineDetails, tripDetails) = await (line, trip)
            selectedTransitLine = lineDetails
            if let tripDetails {
                selectedTransitTripStopIDs = Set((tripDetails.pastStops + tripDetails.nextStops).map(\.stopID)
                    + (tripDetails.currentStopID.map { [$0] } ?? []))
            } else {
                selectedTransitTripStopIDs = []
            }
            selectedTransitTripCoordinates = tripDetails?.coordinates ?? []
        }
    }

    private func openTransitLine(_ line: TransitLineSearchResult) {
        selectedTransitStopID = nil
        selectedTransitRouteID = line.id
        selectedTransitTripID = nil
        selectedTransitTripStopIDs = []
        selectedTransitLine = nil
        selectedTransitTripCoordinates = []
        Task {
            guard let details = await LodzTransitRouteProvider().lineDetails(for: line.id) else { return }
            selectedTransitLine = details
            if let center = engine.state.searchMapCenter ?? engine.state.location?.coordinate,
               let midpoint = details.coordinates.dropFirst(details.coordinates.count / 2).first,
               center.distance(to: midpoint) > 2_000 {
                engine.focusMap(on: midpoint, zoom: 12.8)
            }
            selectedTransitSheet = .line(details)
        }
    }

    private func openTransitDeparture(_ departure: TransitDeparture) {
        selectedTransitStopID = departure.stopID
        selectedTransitRouteID = departure.routeID
        selectedTransitTripID = departure.tripID
        selectedTransitTripStopIDs = []
        selectedTransitTripCoordinates = []
        selectedTransitSheet = .departure(departure)
        Task {
            let provider = LodzTransitRouteProvider()
            async let line = provider.lineDetails(for: departure.routeID)
            async let trip = provider.tripDetails(for: departure)
            let (lineDetails, tripDetails) = await (line, trip)
            selectedTransitLine = lineDetails
            if let tripDetails {
                selectedTransitTripStopIDs = Set((tripDetails.pastStops + tripDetails.nextStops).map(\.stopID)
                    + (tripDetails.currentStopID.map { [$0] } ?? []))
            } else {
                selectedTransitTripStopIDs = []
            }
            selectedTransitTripCoordinates = tripDetails?.coordinates ?? []
        }
        selectedTransitSheet = .departure(departure)
    }

    private func destinationRow(_ destination: Destination, subtitle: String?, symbol: String) -> some View {
        Button {
            selectDestination(destination)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var trafficDetailsSheet: some View {
        NavigationStack {
            ScrollView { trafficCard.padding() }
                .navigationTitle("Ruch na żywo")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Zamknij") { showTrafficDetails = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var settingsSheet: some View {
        NavigationStack {
            settingsForm
                .navigationTitle("Ustawienia")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Zamknij") { showSettings = false }
                    }
                }
                .onAppear { routingDraft = engine.state.routingPreferences }
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
            Toggle("Unikaj dróg płatnych", isOn: $routingDraft.avoidTolls)
            Toggle("Unikaj autostrad", isOn: $routingDraft.avoidHighways)
            Toggle("Unikaj promów", isOn: $routingDraft.avoidFerries)
            Toggle("Unikaj dróg gruntowych", isOn: $routingDraft.avoidUnpaved)
            Text("Serwer może poprowadzić tym typem drogi, jeśli nie ma rozsądnej alternatywy.")
                .font(.footnote).foregroundStyle(.secondary)

            Toggle("Uwzględnij zasięg EV", isOn: $routingDraft.evPlanningEnabled)
            if routingDraft.evPlanningEnabled {
                TextField("Zasięg przy pełnej baterii (km)", value: $routingDraft.evRangeKilometers,
                          format: .number.precision(.fractionLength(0)))
                Stepper("Poziom baterii: \(routingDraft.evBatteryPercent)%",
                        value: $routingDraft.evBatteryPercent, in: 1...100, step: 5)
                TextField("Zużycie (kWh/100 km)", value: $routingDraft.evConsumptionKWhPer100Km,
                          format: .number.precision(.fractionLength(1)))
                TextField("Maks. moc ładowania auta (kW)", value: $routingDraft.evMaximumChargingPowerKW,
                          format: .number.precision(.fractionLength(0)))
                evConnectorToggle("ccs", title: "CCS")
                evConnectorToggle("type2", title: "Type 2")
                evConnectorToggle("chademo", title: "CHAdeMO")
                Text("Dostępny zasięg: \(Int(routingDraft.availableEVRangeKilometers.rounded())) km. Zaznaczone złącza filtrują stacje; pusty wybór dopuszcza wszystkie znane typy. Czas szacujemy z zużycia auta i mocy w OpenStreetMap, bez sprawdzania zajętości na żywo.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Zastosuj preferencje trasy") {
                Task { await engine.updateRoutingPreferences(routingDraft) }
            }
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
                showSettings = false
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

    private var routeSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Preferencje trasy") {
                    Toggle("Unikaj dróg płatnych", isOn: $routingDraft.avoidTolls)
                    Toggle("Unikaj autostrad", isOn: $routingDraft.avoidHighways)
                    Toggle("Unikaj promów", isOn: $routingDraft.avoidFerries)
                    Toggle("Unikaj dróg gruntowych", isOn: $routingDraft.avoidUnpaved)
                }

                Section("Pojazd elektryczny") {
                    Toggle("Uwzględnij zasięg EV", isOn: $routingDraft.evPlanningEnabled)
                    if routingDraft.evPlanningEnabled {
                        TextField("Zasięg przy pełnej baterii (km)", value: $routingDraft.evRangeKilometers,
                                  format: .number.precision(.fractionLength(0)))
                        Stepper("Poziom baterii: \(routingDraft.evBatteryPercent)%",
                                value: $routingDraft.evBatteryPercent, in: 1...100, step: 5)
                        TextField("Zużycie (kWh/100 km)", value: $routingDraft.evConsumptionKWhPer100Km,
                                  format: .number.precision(.fractionLength(1)))
                        TextField("Maks. moc ładowania auta (kW)", value: $routingDraft.evMaximumChargingPowerKW,
                                  format: .number.precision(.fractionLength(0)))
                        evConnectorToggle("ccs", title: "CCS")
                        evConnectorToggle("type2", title: "Type 2")
                        evConnectorToggle("chademo", title: "CHAdeMO")
                        Text("Złącza, moc i status stacji pochodzą z OpenStreetMap. Brak wpisu o dostępności oznacza stan nieznany; aplikacja nie pobiera zajętości ładowarek.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Zmiany zostaną użyte przy kolejnym przeliczeniu trasy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Zastosuj ustawienia trasy") {
                        Task {
                            await engine.updateRoutingPreferences(routingDraft)
                            showRouteSettings = false
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationTitle("Ustawienia trasy")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { showRouteSettings = false }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func evConnectorToggle(_ connector: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { routingDraft.evConnectorTypes.contains(connector) },
            set: { isEnabled in
                if isEnabled { routingDraft.evConnectorTypes.insert(connector) }
                else { routingDraft.evConnectorTypes.remove(connector) }
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

    private var favoritesSheet: some View {
        NavigationStack {
            List {
                if localData.places.isEmpty {
                    ContentUnavailableView("Brak zapisanych miejsc",
                                           systemImage: "star",
                                           description: Text("Zapisz cel po wyznaczeniu trasy, aby łatwo do niego wrócić."))
                }

                ForEach(localData.places) { place in
                    HStack(spacing: 12) {
                        Button {
                            showFavorites = false
                            selectDestination(place.destination, recordSearch: false)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: place.kind == .home ? "house" : place.kind == .work ? "briefcase" : "star")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(place.destination.name)
                                        .foregroundStyle(.primary)
                                    Text(place.kind.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(role: .destructive) {
                            localData.removePlace(place.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Usuń \(place.destination.name)")
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Ulubione miejsca")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { showFavorites = false }
                }
            }
        }
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                if localData.trips.isEmpty && localData.searches.isEmpty {
                    ContentUnavailableView("Brak zakończonych podróży",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Wyszukane miejsca i zakończone podróże pojawią się tutaj."))
                }

                if !localData.searches.isEmpty {
                    Section("Ostatnie wyszukiwania") {
                        ForEach(localData.searches) { item in
                            HStack(spacing: 10) {
                                Button {
                                    showHistory = false
                                    Task { await engine.preview(item.destination) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.destination.name).foregroundStyle(.primary)
                                        Text(item.searchedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button("Zapisz do ulubionych", systemImage: "star") {
                                    localData.add(item.destination)
                                }
                                .labelStyle(.iconOnly)
                                Button("Usuń wyszukiwanie", systemImage: "trash", role: .destructive) {
                                    localData.removeSearch(item.id)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                }

                if !localData.trips.isEmpty {
                    Section("Przebyte trasy") {
                        ForEach(localData.trips) { trip in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(trip.destination.name).font(.headline)
                                    Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.secondary)
                                    Text("\(distance(trip.distanceMeters)) · \(time(trip.duration)) · średnio \(Int(trip.averageSpeedKph.rounded())) km/h")
                                        .font(.caption)
                                    Text("\(trip.arrived ? "Dojechano" : "Przerwano") · postoje \(timeAllowingZero(trip.stoppedSeconds)) · przeliczenia \(trip.rerouteCount)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button("Wyznacz tę trasę ponownie", systemImage: "arrow.triangle.turn.up.right.diamond") {
                                    replayTrip(trip)
                                }
                                .labelStyle(.iconOnly)
                                Button("Zapisz cel do ulubionych", systemImage: "star") {
                                    localData.add(trip.destination)
                                }
                                .labelStyle(.iconOnly)
                                Button("Usuń podróż", systemImage: "trash", role: .destructive) {
                                    localData.removeTrip(trip.id)
                                }
                                .labelStyle(.iconOnly)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Historia podróży")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { showHistory = false }
                }
            }
        }
    }

    private var quickDestinations: [PlaceShortcut] {
        var shortcuts: [PlaceShortcut] = []

        for kind in [PlaceKind.home, .work, .favorite] {
            for place in localData.places where place.kind == kind {
                guard !shortcuts.contains(where: { $0.destination.coordinate == place.destination.coordinate }) else { continue }
                shortcuts.append(PlaceShortcut(
                    id: place.id.uuidString,
                    title: kind == .favorite ? place.destination.name : kind.title,
                    symbol: kind == .home ? "house.fill" : kind == .work ? "briefcase.fill" : "star.fill",
                    destination: place.destination,
                    isRecent: false,
                    estimatedMinutes: kind == .favorite ? nil : quickETAMinutes[place.id.uuidString]
                ))
            }
        }

        for search in localData.searches {
            guard shortcuts.count < 6 else { break }
            guard !shortcuts.contains(where: { $0.destination.coordinate == search.destination.coordinate }) else { continue }
            shortcuts.append(PlaceShortcut(
                id: "recent-\(search.id.uuidString)",
                title: search.destination.name,
                symbol: "clock.arrow.circlepath",
                destination: search.destination,
                isRecent: true
            ))
        }

        for trip in localData.trips where shortcuts.count < 6 {
            guard !shortcuts.contains(where: { $0.destination.coordinate == trip.destination.coordinate }) else { continue }
            shortcuts.append(PlaceShortcut(
                id: "trip-\(trip.id.uuidString)",
                title: trip.destination.name,
                symbol: "clock.arrow.circlepath",
                destination: trip.destination,
                isRecent: true
            ))
        }

        return Array(shortcuts.prefix(6))
    }

    private var quickETADestinationFingerprint: String {
        [PlaceKind.home, .work].compactMap { kind in
            localData.places.first(where: { $0.kind == kind })
        }.map { place in
            let coordinate = place.destination.coordinate
            return "\(place.id.uuidString):\(coordinate.latitude),\(coordinate.longitude)"
        }.joined(separator: "|")
    }

    private func refreshQuickDestinationETAs() async {
        guard !quickETAInFlight, let origin = engine.state.location?.coordinate else { return }
        let priorityDestinations = quickDestinations.filter { $0.symbol == "house.fill" || $0.symbol == "briefcase.fill" }
        guard !priorityDestinations.isEmpty else {
            quickETAMinutes = [:]
            quickETADestinationKey = quickETADestinationFingerprint
            return
        }

        let destinationKey = quickETADestinationFingerprint
        let movedMeters = quickETAOrigin.map { $0.distance(to: origin) } ?? .infinity
        let isFresh = Date().timeIntervalSince(quickETAUpdatedAt) < 180
        guard destinationKey != quickETADestinationKey || movedMeters >= 750 || !isFresh else { return }

        quickETAInFlight = true
        quickETAOrigin = origin
        quickETADestinationKey = destinationKey
        quickETAUpdatedAt = Date()
        quickETAMinutes = [:]
        defer { quickETAInFlight = false }

        var estimates: [String: Int] = [:]
        for shortcut in priorityDestinations.prefix(2) {
            guard let seconds = await engine.estimatedCarTravelTime(to: shortcut.destination) else { continue }
            estimates[shortcut.id] = max(1, Int(ceil(seconds / 60)))
        }
        quickETAMinutes = estimates
    }

    private var recentDestinations: [Destination] {
        var destinations: [Destination] = []
        for trip in localData.trips {
            guard !destinations.contains(where: { $0.coordinate == trip.destination.coordinate }) else { continue }
            destinations.append(trip.destination)
            if destinations.count == 5 { break }
        }
        return destinations
    }

    private func metric(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func speedCard(at now: Date) -> some View {
        let fresh = engine.state.location.map { now.timeIntervalSince($0.timestamp) < 15 } ?? false
        let speed = fresh ? engine.state.location?.speed : nil
        let current = speed.flatMap { $0 >= 0 ? Int(($0 * 3.6).rounded()) : nil }
        let limit = fresh ? engine.state.speedLimitKph : nil
        let aboveLimit = speedWarningsEnabled && (current.map { value in limit.map { value > $0 + 5 } ?? false } ?? false)
        let routeDistance = engine.state.progress?.traveledDistance ?? 0
        let nextRoadAlert = engine.state.roadSafetyAlerts
            .filter { alert in
                guard alert.type.isEnforcement || alert.type == .speedLimitChange,
                      let distance = alert.distanceAlongRoute else { return false }
                return distance >= routeDistance && distance <= routeDistance + 2_000
            }
            .min { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }

        if let current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let limit {
                        Text(String(limit))
                            .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                            .frame(width: 38, height: 38)
                            .background(.background, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 2))
                            .accessibilityLabel("Limit \(limit) kilometrów na godzinę")
                    }
                    VStack(spacing: 0) {
                        Text(String(current))
                            .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(aboveLimit ? .red : .primary)
                            .contentTransition(.numericText())
                        Text(engine.state.speedLimitSource.map { "\($0.shortTitle) · km/h" } ?? "km/h")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let alert = nextRoadAlert {
                    HStack(spacing: 5) {
                        Image(systemName: alert.type.symbolName)
                        Text("\(alert.title) · \(alert.distanceText(from: routeDistance))")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                } else if let message = engine.state.speedLimitMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if case .loading = engine.state.roadSafetyStatus {
                    Label("Pobieranie ostrzeżeń drogowych…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if case .unavailable = engine.state.roadSafetyStatus {
                    Label("Ostrzeżenia drogowe niedostępne", systemImage: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if case .available = engine.state.roadSafetyStatus {
                    Text("© OpenStreetMap contributors")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(aboveLimit ? Color.red.opacity(0.7) : Color.primary.opacity(0.07), lineWidth: 1.5))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(limit.map { "Prędkość \(current) kilometrów na godzinę, limit \($0)" } ??
                                "Prędkość \(current) kilometrów na godzinę")
        }
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.orange.opacity(0.15)))
    }

    private func circleSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 48, height: 48)
            .modifier(NavigationGlassSurface(radius: 24, interactive: true))
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
    }

    private func presentSearch() {
        showSearch = true
    }

    private func presentNearby(_ category: NearbyPlaceCategory, nearDestination: Bool = false) {
        nearbyRequest = NearbySearchRequest(category: category, nearDestination: nearDestination)
    }

    private func selectDestination(_ destination: Destination, recordSearch: Bool = true) {
        showSearch = false
        if recordSearch { localData.recordSearch(destination) }
        engine.selectDestination(destination)
        Task { await engine.planRoute() }
    }

    private func presentMapPlaces(_ places: [SearchResult]) {
        mapPlaceEstimateTask?.cancel()
        guard !places.isEmpty else { return }
        if places.count == 1, let place = places.first {
            presentMapPlace(place)
        } else {
            selectedMapPlaces = places
        }
    }

    private func presentMapPlace(_ result: SearchResult) {
        mapPlaceEstimateTask?.cancel()
        let origin = engine.state.location?.coordinate
        let navigationActive = isNavigating
        let mode = engine.state.transportMode
        let canRequestETA = origin != nil && mode != .transit && mode != .parkRide
        var selected = result
        selected.travelEstimateStatus = canRequestETA ? .calculating : .unavailable

        if navigationActive {
            if let origin, let route = engine.state.route?.coordinates,
               let currentProjection = MapMatcher.project(origin, onto: route) {
                let futureRoute = Array(route.dropFirst(currentProjection.segment))
                selected.detourDistance = MapMatcher.project(result.destination.coordinate, onto: futureRoute)?.distanceFromRoute
            }
        } else if let origin {
            selected.straightDistance = origin.distance(to: result.destination.coordinate)
        }
        selectedMapPlaces = [selected]

        guard canRequestETA, let origin else { return }
        let requestID = selected.id
        let preferences = engine.state.routingPreferences
        let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ??
                           "https://valhalla1.openstreetmap.de")!
        let destinationCoordinate = result.destination.coordinate
        let routeTarget = engine.state.waypoints.first?.coordinate ?? engine.state.destination?.coordinate
        mapPlaceEstimateTask = Task {
            do {
                let provider = ValhallaRouteProvider(endpoint: endpoint)
                var updated = selected
                if navigationActive, let routeTarget {
                    let rows = try await provider.searchMatrix(
                        sources: [origin, destinationCoordinate],
                        targets: [destinationCoordinate, routeTarget],
                        mode: mode, preferences: preferences)
                    guard rows.count == 2, rows.allSatisfy({ $0.count == 2 }),
                          selectedMapPlaces.first?.id == requestID else { return }
                    if let toPlace = rows[0][0].time,
                       let baseline = rows[0][1].time,
                       let onward = rows[1][1].time {
                        updated.detour = max(0, toPlace + onward - baseline)
                        updated.travelEstimateStatus = .notRequested
                    } else {
                        updated.travelEstimateStatus = .unavailable
                    }
                } else if !navigationActive {
                    let rows = try await provider.searchMatrix(
                        sources: [origin], targets: [destinationCoordinate],
                        mode: mode, preferences: preferences)
                    guard selectedMapPlaces.first?.id == requestID,
                          let cell = rows.first?.first else { return }
                    updated.travelTime = cell.time
                    updated.travelDistance = cell.distance.map { $0 * 1_000 }
                    updated.travelEstimateStatus = cell.time == nil ? .unavailable : .notRequested
                } else {
                    updated.travelEstimateStatus = .unavailable
                }
                guard !Task.isCancelled else { return }
                selectedMapPlaces = [updated]
            } catch {
                guard !Task.isCancelled, selectedMapPlaces.first?.id == requestID else { return }
                var updated = selectedMapPlaces[0]
                updated.travelEstimateStatus = .unavailable
                guard !Task.isCancelled else { return }
                selectedMapPlaces = [updated]
            }
        }
    }

    private func replayTrip(_ trip: TripRecord) {
        showHistory = false
        engine.state.waypoints = trip.waypoints
        Task { await engine.preview(trip.destination) }
    }

    private func saveCurrentPlace(as kind: PlaceKind) {
        guard let destination = engine.state.destination else { return }
        let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        localData.add(
            Destination(name: name.isEmpty ? destination.name : name, coordinate: destination.coordinate),
            kind: kind
        )
        favoriteName = ""
        isSavingPlace = false
    }

    private func toggleDestinationFavorite() {
        guard let destination = engine.state.destination else { return }
        let wasFavorite = isDestinationFavorite
        if let saved = localData.places.first(where: {
            $0.kind == .favorite && $0.destination.coordinate == destination.coordinate
        }) {
            localData.removePlace(saved.id)
        } else {
            localData.add(destination, kind: .favorite)
        }
        guard isDestinationFavorite != wasFavorite else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.52)) {
            favoritePulseScale = 1.15
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                favoritePulseScale = 1
            }
        }
        #if os(iOS)
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.prepare()
        haptic.impactOccurred()
        #endif
    }

    private func distance(_ meters: Double) -> String {
        guard meters >= 1000 else { return "\(Int(meters)) m" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let kilometers = formatter.string(from: NSNumber(value: meters / 1000)) ?? String(meters / 1000)
        return "\(kilometers) km"
    }

    private func time(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(seconds / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(totalMinutes) min" }
        guard minutes > 0 else { return "\(hours) godz." }
        return "\(hours) godz. \(minutes) min"
    }

    private func arrivalTime(_ seconds: TimeInterval) -> String {
        (engine.state.estimatedArrival ?? Date().addingTimeInterval(max(0, seconds)))
            .formatted(date: .omitted, time: .shortened)
    }

    private func timeAllowingZero(_ seconds: TimeInterval) -> String {
        guard seconds > 30 else { return "0 min" }
        return time(seconds)
    }

    private func delayLabel(_ seconds: TimeInterval) -> String {
        guard abs(seconds) >= 60 else { return "Na czas" }
        let sign = seconds > 0 ? "+" : "−"
        return sign + time(abs(seconds))
    }
}

private struct NearbySearchRequest: Identifiable {
    let id = UUID()
    let category: NearbyPlaceCategory
    let nearDestination: Bool
}

private struct NearbyPlacesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let engine: NavigationEngine
    let nearDestination: Bool
    let initialCategory: NearbyPlaceCategory
    let savedPlaces: [SavedPlace]
    let onSave: (Destination) -> Bool
    let onSelect: (Destination) -> Void
    @State private var category: NearbyPlaceCategory
    @State private var retryID = UUID()
    @State private var expandedRadius = false
    @State private var openNowOnly = false
    @State private var open24HoursOnly = false
    @State private var selectedFuelType: String?
    @State private var selectedOperator: String?
    @State private var minimumChargingPower: Double?
    @State private var selectedConnector: String?

    init(engine: NavigationEngine, nearDestination: Bool, initialCategory: NearbyPlaceCategory,
         savedPlaces: [SavedPlace], onSave: @escaping (Destination) -> Bool,
         onSelect: @escaping (Destination) -> Void) {
        self.engine = engine
        self.nearDestination = nearDestination
        self.initialCategory = initialCategory
        self.savedPlaces = savedPlaces
        self.onSave = onSave
        self.onSelect = onSelect
        _category = State(initialValue: initialCategory)
    }

    private var categories: [NearbyPlaceCategory] {
        nearDestination ? [.parking, .parkRide] : [.fuel, .food, .parking, .charging, .parkRide]
    }

    private var nearestSearch: Bool {
        !nearDestination && engine.state.status != .navigating && engine.state.status != .rerouting
    }

    private var availableOperators: [String] {
        Array(Set(engine.state.nearbySuggestions
            .filter { $0.candidate.category == category }
            .compactMap { $0.candidate.operatorOrBrand })).sorted()
    }

    private var availableFuelTypes: [String] {
        Array(Set(engine.state.nearbySuggestions
            .filter { $0.candidate.category == .fuel }
            .flatMap { $0.candidate.fuelTypes })).sorted()
    }

    private var availableConnectors: [String] {
        Array(Set(engine.state.nearbySuggestions
            .filter { $0.candidate.category == .charging }
            .flatMap { $0.candidate.chargingStation?.connectorTypes ?? [] })).sorted()
    }

    private var availablePowerThresholds: [Double] {
        [50.0, 100.0, 150.0].filter { threshold in
            engine.state.nearbySuggestions.contains {
                $0.candidate.category == .charging && ($0.candidate.chargingStation?.maximumPowerKW ?? 0) >= threshold
            }
        }
    }

    private var hasOpeningHoursData: Bool {
        engine.state.nearbySuggestions.contains { $0.candidate.category == category && $0.candidate.isOpenNow != nil }
    }

    private var has24HourData: Bool {
        engine.state.nearbySuggestions.contains { $0.candidate.category == category && $0.candidate.isOpen24Hours }
    }

    private var hasApplicableFilters: Bool {
        category == .fuel
            ? hasOpeningHoursData || has24HourData || !availableFuelTypes.isEmpty || !availableOperators.isEmpty
            : category == .charging && (!availableConnectors.isEmpty || !availablePowerThresholds.isEmpty || !availableOperators.isEmpty)
    }

    private var activeFilterCount: Int {
        (openNowOnly ? 1 : 0) + (open24HoursOnly ? 1 : 0) +
            (selectedFuelType == nil ? 0 : 1) + (selectedOperator == nil ? 0 : 1) +
            (minimumChargingPower == nil ? 0 : 1) + (selectedConnector == nil ? 0 : 1)
    }

    private var filteredSuggestions: [RouteStopSuggestion] {
        engine.state.nearbySuggestions.filter { suggestion in
            let candidate = suggestion.candidate
            if openNowOnly && candidate.isOpenNow != true { return false }
            if open24HoursOnly && !candidate.isOpen24Hours { return false }
            if let selectedFuelType, !candidate.fuelTypes.contains(selectedFuelType) { return false }
            if let selectedOperator, candidate.operatorOrBrand != selectedOperator { return false }
            if let minimumChargingPower,
               (candidate.chargingStation?.maximumPowerKW ?? 0) < minimumChargingPower { return false }
            if let selectedConnector,
               !(candidate.chargingStation?.connectorTypes.contains(selectedConnector) ?? false) { return false }
            return true
        }
    }

    private func clearFilters() {
        openNowOnly = false
        open24HoursOnly = false
        selectedFuelType = nil
        selectedOperator = nil
        minimumChargingPower = nil
        selectedConnector = nil
    }

    private func fuelTypeTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "octane_95": "Benzyna 95"
        case "octane_98": "Benzyna 98"
        case "diesel": "Diesel"
        case "lpg": "LPG"
        case "cng": "CNG"
        case "h2": "Wodór"
        case "e10": "E10"
        case "e85": "E85"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func connectorTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "ccs", "ccs2", "ccs_combo_2": "CCS"
        case "type2", "type_2": "Type 2"
        case "chademo": "CHAdeMO"
        case "tesla_supercharger": "Tesla"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func supplementalDetails(for candidate: NearbyPlaceCandidate) -> [String] {
        var details: [String] = []
        if let operatorName = candidate.operatorOrBrand { details.append(operatorName) }
        if candidate.isOpen24Hours {
            details.append("Otwarte 24h")
        } else if let rawHours = candidate.openingHours,
                  let timeZoneIdentifier = candidate.timeZoneIdentifier
                    ?? PlaceTimeZoneResolver.cachedIdentifier(for: candidate.destination.coordinate),
                  let status = PlaceOpeningHours(rawValue: rawHours,
                                                 coordinate: candidate.destination.coordinate,
                                                 countryCode: candidate.countryCode,
                                                 timeZoneIdentifier: timeZoneIdentifier).statusText() {
            details.append(status)
        }
        if candidate.category == .fuel {
            if !candidate.fuelTypes.isEmpty {
                details.append(candidate.fuelTypes.map(fuelTypeTitle).joined(separator: " · "))
            }
        } else if candidate.category == .charging, let station = candidate.chargingStation {
            var capabilities: [String] = []
            if let power = station.maximumPowerKW {
                capabilities.append("\(Int(power.rounded())) kW")
            }
            if !station.connectorTypes.isEmpty {
                capabilities.append(station.connectorTypes.map(connectorTitle).joined(separator: " / "))
            }
            if !capabilities.isEmpty { details.append(capabilities.joined(separator: " · ")) }
            if let count = station.chargingPointCount { details.append(chargingPointCountTitle(count)) }
            if station.availability == .unavailable { details.append("Oznaczona jako niedziałająca w OSM") }
        }
        return details
    }

    private func expandedDetails(for candidate: NearbyPlaceCandidate) -> [String] {
        if candidate.category == .fuel {
            return candidate.fuelTypes.map(fuelTypeTitle)
        }
        guard candidate.category == .charging, let station = candidate.chargingStation else { return [] }
        var details: [String] = []
        var capabilities: [String] = []
        if let power = station.maximumPowerKW {
            capabilities.append("\(Int(power.rounded())) kW")
        }
        if !station.connectorTypes.isEmpty {
            capabilities.append(station.connectorTypes.map(connectorTitle).joined(separator: " / "))
        }
        if !capabilities.isEmpty { details.append(capabilities.joined(separator: " · ")) }
        if let count = station.chargingPointCount { details.append(chargingPointCountTitle(count)) }
        if station.availability == .unavailable { details.append("Oznaczona jako niedziałająca w OSM") }
        details.append("Brak danych o wolnych stanowiskach na żywo")
        return details
    }

    private func chargingPointCountTitle(_ count: Int) -> String {
        let remainder = count % 100
        let suffix: String
        if (12...14).contains(remainder) {
            suffix = "punktów ładowania"
        } else {
            switch count % 10 {
            case 1: suffix = "punkt ładowania"
            case 2...4: suffix = "punkty ładowania"
            default: suffix = "punktów ładowania"
            }
        }
        return "\(count) \(suffix)"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories) { value in
                            Button {
                                guard category != value else { return }
                                category = value
                                expandedRadius = false
                                clearFilters()
                                engine.state.nearbySuggestions = []
                                engine.state.nearbyStatus = .searching
                            } label: {
                                Label(value.title, systemImage: value.symbol)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(category == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(category == value ? .isSelected : [])
                        }
                    }
                }

                if hasApplicableFilters {
                    HStack {
                        Menu {
                            if hasOpeningHoursData {
                                Toggle("Otwarte teraz", isOn: $openNowOnly)
                            }
                            if has24HourData {
                                Toggle("Całodobowe 24h", isOn: $open24HoursOnly)
                            }
                            if category == .fuel {
                                if !availableFuelTypes.isEmpty {
                                    Picker("Rodzaj paliwa", selection: $selectedFuelType) {
                                        Text("Dowolne").tag(Optional<String>.none)
                                        ForEach(availableFuelTypes, id: \.self) { value in
                                            Text(fuelTypeTitle(value)).tag(Optional<String>.some(value))
                                        }
                                    }
                                }
                            }
                            if category == .charging {
                                if !availablePowerThresholds.isEmpty {
                                    Picker("Moc minimalna", selection: $minimumChargingPower) {
                                        Text("Dowolna").tag(Optional<Double>.none)
                                        ForEach(availablePowerThresholds, id: \.self) { value in
                                            Text("Co najmniej \(Int(value)) kW").tag(Optional<Double>.some(value))
                                        }
                                    }
                                }
                                if !availableConnectors.isEmpty {
                                    Picker("Złącze", selection: $selectedConnector) {
                                        Text("Dowolne").tag(Optional<String>.none)
                                        ForEach(availableConnectors, id: \.self) { value in
                                            Text(connectorTitle(value)).tag(Optional<String>.some(value))
                                        }
                                    }
                                }
                            }
                            if !availableOperators.isEmpty {
                                Picker("Operator", selection: $selectedOperator) {
                                    Text("Dowolny").tag(Optional<String>.none)
                                    ForEach(availableOperators, id: \.self) { value in
                                        Text(value).tag(Optional<String>.some(value))
                                    }
                                }
                            }
                            if activeFilterCount > 0 {
                                Divider()
                                Button("Wyczyść filtry", systemImage: "xmark.circle", action: clearFilters)
                            }
                        } label: {
                            Label(activeFilterCount == 0 ? "Filtry" : "Filtry · \(activeFilterCount)",
                                  systemImage: "line.3.horizontal.decrease.circle")
                                .font(.subheadline.weight(.medium))
                        }
                        Spacer()
                    }
                }

                Text(nearDestination
                     ? "Parking jest wyszukiwany w pobliżu celu. Dostępność wolnych miejsc nie jest sprawdzana."
                     : nearestSearch
                        ? "\(category.title) w promieniu do \(expandedRadius ? 15 : 5) km od Twojej lokalizacji."
                        : "Miejsca do 1,5 km od pozostałej trasy. Czas objazdu uzupełniamy po znalezieniu wyników.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                switch engine.state.nearbyStatus {
                case .idle, .searching:
                    ProgressView(nearDestination
                                 ? "Szukam parkingów do 2 km od celu…"
                                 : nearestSearch ? "Szukam najbliższych miejsc…" : "Szukam miejsc wzdłuż trasy…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable(let message):
                    ContentUnavailableView("Nie udało się wyszukać miejsc",
                                           systemImage: "magnifyingglass",
                                           description: Text(message))
                    Button("Spróbuj ponownie") { retryID = UUID() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                case .available:
                    if engine.state.nearbySuggestions.isEmpty {
                        ContentUnavailableView("Brak miejsc w pobliżu",
                                               systemImage: category.symbol,
                                               description: Text(nearestSearch
                                                   ? "Możesz rozszerzyć wyszukiwanie do 15 km."
                                                   : "Spróbuj innej kategorii lub wyszukaj w innym miejscu."))
                    } else if filteredSuggestions.isEmpty {
                        VStack(spacing: 8) {
                            ContentUnavailableView("Brak wyników z tymi filtrami",
                                                   systemImage: "line.3.horizontal.decrease.circle",
                                                   description: Text("Zmień filtry albo wyczyść je, aby zobaczyć wszystkie miejsca."))
                            Button("Wyczyść filtry", action: clearFilters)
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Text("Znaleziono: \(filteredSuggestions.count)")
                            .font(.subheadline.weight(.semibold))
                        List(Array(filteredSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                            let result = searchResult(suggestion)
                            let details = supplementalDetails(for: suggestion.candidate)
                            let operatorName = suggestion.candidate.operatorOrBrand
                            let remainingDetails = operatorName == nil ? details : Array(details.dropFirst())
                            let shouldEstimateOnExpand = nearestSearch
                                && suggestion.estimateStatus != .calculating
                                && (suggestion.travelTime == nil || suggestion.travelDistance == nil)
                            let estimateOnExpand: (() -> Void)? = shouldEstimateOnExpand
                                ? { _ = Task { await engine.estimateNearbyTravel(for: suggestion.id) } }
                                : nil
                            let navigationActive = engine.state.status == .navigating || engine.state.status == .rerouting
                            let primaryActionTitle = nearDestination
                                ? "Wybierz parking"
                                : navigationActive ? "Dodaj przystanek" : "Jedź"
                            PlaceSearchResultRow(
                                result: result, index: index + 1,
                                isSaved: savedPlaces.contains { $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate },
                                onSave: { onSave(result.destination) },
                                onSelect: {
                                    onSelect(result.destination)
                                    dismiss()
                                },
                                isNavigating: navigationActive,
                                primaryActionTitle: primaryActionTitle,
                                supplementalDetails: remainingDetails,
                                expandedDetails: expandedDetails(for: suggestion.candidate),
                                showsSourceSubtitle: false,
                                primaryMetaLine: operatorName,
                                onExpand: estimateOnExpand)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .navigationTitle(nearDestination
                             ? "Parking przy celu"
                             : nearestSearch ? category.title : "\(category.title) po trasie")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { dismiss() }
                }
            }
            .task(id: "\(category.rawValue)-\(retryID)-\(expandedRadius)") {
                await engine.searchNearbyPlaces(category, nearDestination: nearDestination,
                                                searchRadius: expandedRadius ? 15_000 : 5_000,
                                                resultLimit: expandedRadius ? 50 : 25)
            }
            .safeAreaInset(edge: .bottom) {
                if nearestSearch, !expandedRadius, engine.state.nearbyStatus == .available,
                   engine.state.nearbySuggestions.allSatisfy({ $0.estimateStatus != .calculating }) {
                    Button {
                        expandedRadius = true
                    } label: {
                        Label("Pokaż więcej · do 15 km", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
    }

    private func searchResult(_ suggestion: RouteStopSuggestion) -> SearchResult {
        let candidate = suggestion.candidate
        let category: String = switch candidate.category {
        case .fuel: "fuel"
        case .food: "restaurant"
        case .parking, .parkRide: "parking"
        case .charging: "charging_station"
        }
        return SearchResult(destination: candidate.destination, street: nil, houseNumber: nil,
                            city: nil, countryCode: candidate.countryCode, isPOI: true,
                            osmID: candidate.id.replacingOccurrences(of: "-", with: ":"),
                            category: candidate.osmCategory ?? category,
                            brand: candidate.brand, operatorName: candidate.operatorName,
                            openingHours: candidate.openingHours,
                            timeZoneIdentifier: candidate.timeZoneIdentifier,
                            straightDistance: nearDestination
                                ? engine.state.destination.map { $0.coordinate.distance(to: candidate.destination.coordinate) }
                                : nearestSearch
                                    ? engine.state.location?.coordinate.distance(to: candidate.destination.coordinate)
                                    : nil,
                            travelTime: suggestion.travelTime, travelDistance: suggestion.travelDistance,
                            detour: suggestion.detourSeconds, travelEstimateStatus: suggestion.estimateStatus)
    }

}

private enum DestinationSearchScope: String, CaseIterable, Identifiable {
    case places = "Miejsca"
    case transit = "Kolej i MPK"

    var id: String { rawValue }
}

private struct DestinationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let engine: NavigationEngine
    let places: [SavedPlace]
    let recentDestinations: [Destination]
    let recentSearches: [SearchHistoryEntry]
    let pointSelectionHint: String
    let onSavePlace: (Destination) -> Bool
    let onSelectTransitStop: (TransitStop) -> Void
    let onSelectTransitLine: (TransitLineSearchResult) -> Void
    let onSelectDestination: (Destination, Bool) -> Void

    @State private var query = ""
    @State private var searchScope: DestinationSearchScope = .places
    @State private var results: [SearchResult] = []
    @State private var transitResults = TransitSearchResults(stops: [], lines: [])
    @State private var isTransitSearching = false
    @State private var searchError: SearchError?
    @State private var didCompleteSearchWithNoResults = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var transitSearchTask: Task<Void, Never>?
    @State private var currentSearchID = UUID()
    @State private var searchArea: Coordinate?
    @State private var alongRoute = false
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var localMatches: [LocalSearchSuggestion] {
        let needle = normalized(trimmedQuery)
        guard !needle.isEmpty else { return [] }

        var matches: [LocalSearchSuggestion] = []
        for place in places where normalized(place.destination.name).contains(needle) {
            append(place.destination, subtitle: place.kind.title, symbol: symbol(for: place.kind), to: &matches)
        }
        for destination in recentDestinations where normalized(destination.name).contains(needle) {
            append(destination, subtitle: "Ostatni cel", symbol: "clock.arrow.circlepath", to: &matches)
        }
        for item in recentSearches where normalized(item.destination.name).contains(needle) {
            append(item.destination, subtitle: "Ostatnie wyszukiwanie", symbol: "magnifyingglass", to: &matches)
        }
        return Array(matches.prefix(5))
    }

    private var visibleRemoteResults: [SearchResult] {
        // A saved/history entry must not hide a freshly ranked nearby result.
        results
    }

    private var hasResultsForCurrentScope: Bool {
        switch searchScope {
        case .places:
            !results.isEmpty || !localMatches.isEmpty
        case .transit:
            !transitResults.stops.isEmpty || !transitResults.lines.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                Picker("Rodzaj wyszukiwania", selection: $searchScope) {
                    ForEach(DestinationSearchScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: searchScope) { _, _ in startSearch(query) }

                HStack {
                    if let center = engine.state.searchMapCenter {
                        Button("Szukaj w tym obszarze") {
                            searchArea = center
                            startSearch(query)
                        }
                    }
                    if searchArea != nil {
                        Button("Blisko mnie") { searchArea = nil; startSearch(query) }
                    }
                    if engine.state.status == .navigating && searchScope == .places {
                        Toggle("Po trasie", isOn: $alongRoute)
                            .onChange(of: alongRoute) { _, _ in startSearch(query) }
                    }
                }
                .font(.caption)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if trimmedQuery.isEmpty {
                            if searchScope == .places {
                                savedDestinations
                            } else {
                                ContentUnavailableView("Szukaj pociągu, stacji lub linii",
                                                       systemImage: "tram.fill",
                                                       description: Text("Wpisz numer pociągu lub linii albo nazwę stacji i przystanku w Polsce."))
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 28)
                            }
                        } else {
                            if searchScope == .places {
                                matchingDestinations
                                searchStatus
                                remoteResults
                            } else {
                                transitResultsSection
                                searchStatus
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity)
            .navigationTitle("Szukaj")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { dismiss() }
                }
            }
            .onAppear {
                query = ""
                results = []
                transitResults = TransitSearchResults(stops: [], lines: [])
                searchError = nil
                didCompleteSearchWithNoResults = false
                isSearching = false
                isTransitSearching = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isSearchFocused = true
                }
            }
            .onChange(of: engine.state.location?.coordinate) { previous, current in
                // A query entered before the first GPS fix must be retried with that fix.
                if previous == nil, current != nil, searchArea == nil, !trimmedQuery.isEmpty {
                    startSearch(query)
                }
            }
            .onDisappear {
                searchTask?.cancel()
                transitSearchTask?.cancel()
                engine.state.searchResults = []
            }
        }
    }

    private func startSearch(_ value: String) {
        searchTask?.cancel()
        transitSearchTask?.cancel()
        currentSearchID = UUID()
        searchError = nil
        didCompleteSearchWithNoResults = false
        isSearching = false
        isTransitSearching = false
        results = []
        transitResults = TransitSearchResults(stops: [], lines: [])
        engine.state.searchResults = []
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { isSearching = false; isTransitSearching = false; return }
        let requestID = currentSearchID

        if searchScope == .transit {
            isTransitSearching = true
            transitSearchTask = Task {
                do {
                    try await Task.sleep(for: .milliseconds(450))
                } catch {
                    return
                }
                guard !Task.isCancelled, currentSearchID == requestID else { return }
                let center = searchArea ?? engine.state.location?.coordinate
                let matches = await LodzTransitRouteProvider().search(trimmed, near: center)
                guard !Task.isCancelled, currentSearchID == requestID else { return }
                transitResults = matches
                isTransitSearching = false
                didCompleteSearchWithNoResults = matches.stops.isEmpty && matches.lines.isEmpty
            }
            return
        }

        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, currentSearchID == requestID else { return }
                let state = engine.state
                var remainingRoute: [Coordinate] = []
                if state.status == .navigating, let route = state.route, let origin = state.location?.coordinate,
                   let projection = MapMatcher.project(origin, onto: route.coordinates) {
                    remainingRoute = [projection.coordinate] + Array(route.coordinates.dropFirst(projection.segment + 1))
                }
                let context = SearchContext(origin: state.location?.coordinate, area: searchArea,
                                            route: remainingRoute, routeTarget: state.waypoints.first?.coordinate ?? state.destination?.coordinate,
                                            mode: state.transportMode, preferences: state.routingPreferences,
                                            localDestinations: places.map(\.destination) + recentSearches.map(\.destination))
                let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "https://valhalla1.openstreetmap.de")!
                let effectiveQuery = alongRoute && !QueryClassifier.normalize(trimmed).hasSuffix(" po trasie") ? trimmed + " po trasie" : trimmed
                let found = try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint)).search(effectiveQuery, context: context) { partial in
                    guard !Task.isCancelled, currentSearchID == requestID else { return }
                    results = partial
                    engine.state.searchResults = visibleRemoteResults
                }
                guard !Task.isCancelled, currentSearchID == requestID else { return }
                results = found
                engine.state.searchResults = visibleRemoteResults
                isSearching = false
                didCompleteSearchWithNoResults = found.isEmpty
            } catch {
                guard !Task.isCancelled, currentSearchID == requestID else { return }
                isSearching = false
                searchError = SearchError.classify(error)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.accentColor)
            TextField(searchScope == .places ? "Adres, marka lub kategoria" : "Linia lub przystanek", text: $query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: query) { _, value in startSearch(value) }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    searchError = nil
                    didCompleteSearchWithNoResults = false
                    isSearching = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Wyczyść wyszukiwanie")
            }
        }
        .font(.body)
        .padding(.horizontal, 15)
        .frame(height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var savedDestinations: some View {
        if !places.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Zapisane miejsca")
                ForEach(places.prefix(5)) { place in
                    destinationRow(place.destination, subtitle: place.kind.title, symbol: symbol(for: place.kind))
                }
            }
        }

        if !recentDestinations.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Ostatnie")
                ForEach(recentDestinations) { destination in
                    destinationRow(destination, subtitle: "Ostatni cel", symbol: "clock.arrow.circlepath")
                }
            }
        }

        if !recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Ostatnie wyszukiwania")
                ForEach(recentSearches.prefix(5)) { item in
                    destinationRow(item.destination,
                                   subtitle: item.searchedAt.formatted(date: .abbreviated, time: .shortened),
                                   symbol: "magnifyingglass")
                }
            }
        }

        if places.isEmpty && recentDestinations.isEmpty && recentSearches.isEmpty {
            ContentUnavailableView("Wpisz cel podróży",
                                   systemImage: "magnifyingglass",
                                   description: Text(pointSelectionHint))
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
        }
    }

    @ViewBuilder
    private var matchingDestinations: some View {
        if !localMatches.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Zapisane i ostatnie")
                ForEach(localMatches) { suggestion in
                    destinationRow(suggestion.destination, subtitle: suggestion.subtitle, symbol: suggestion.symbol)
                }
            }
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        if isSearching {
            ProgressView(results.isEmpty ? "Wyszukiwanie miejsc…" : "Uzupełnianie wyników…")
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        } else if let searchError, results.isEmpty,
                  transitResults.stops.isEmpty, transitResults.lines.isEmpty, !isTransitSearching {
            VStack(spacing: 10) {
                Image(systemName: "mappin.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(searchError.localizedDescription)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if searchError.canRetry {
                    Button("Ponów wyszukiwanie") { startSearch(query) }
                        .buttonStyle(.bordered)
                } else {
                    Text("Możesz też zmienić obszar wyszukiwania.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
        } else if didCompleteSearchWithNoResults, !hasResultsForCurrentScope,
                  !isSearching, !isTransitSearching {
            VStack(spacing: 8) {
                Image(systemName: "mappin.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Nie znaleziono wyników dla „\(trimmedQuery)”")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Zmień nazwę miejsca albo wybierz inny obszar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
        }
    }

    @ViewBuilder
    private var remoteResults: some View {
        if !visibleRemoteResults.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Wyniki")
                ForEach(Array(visibleRemoteResults.enumerated()), id: \.element.placeIdentity.cacheKey) { index, result in
                    PlaceSearchResultRow(
                        result: result,
                        index: index + 1,
                        isSaved: places.contains { $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate },
                        onSave: { onSavePlace(result.destination) },
                        onSelect: { selectResult(result) },
                        isNavigating: alongRoute || QueryClassifier().classify(query).alongRoute,
                        primaryActionTitle: alongRoute || QueryClassifier().classify(query).alongRoute ? "Dodaj przystanek" : "Wyznacz trasę")
                }
            }
        }
    }

    @ViewBuilder
    private var transitResultsSection: some View {
        if isTransitSearching || !transitResults.stops.isEmpty || !transitResults.lines.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Transport publiczny")
                if isTransitSearching && transitResults.stops.isEmpty && transitResults.lines.isEmpty {
                    ProgressView("Szukam linii i przystanków…").font(.caption).padding(.vertical, 5)
                }
                if !transitResults.lines.isEmpty {
                    Text("Linie").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 3)
                    ForEach(transitResults.lines) { line in
                        Button {
                            isSearchFocused = false
                            onSelectTransitLine(line)
                            dismiss()
                        } label: {
                            HStack(spacing: 11) {
                                Text(line.name).font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white).frame(minWidth: 36, minHeight: 30)
                                    .background(mapTransitColor(line.colorHex), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.mode == "RAIL" ? "Pociąg" : line.mode == "TRAM" ? "Tramwaj" : "Autobus")
                                        .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    if !line.directions.isEmpty {
                                        Text(line.directions).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !transitResults.stops.isEmpty {
                    Text("Stacje i przystanki").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 3)
                    ForEach(transitResults.stops) { stop in
                        Button {
                            isSearchFocused = false
                            onSelectTransitStop(stop)
                            dismiss()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "tram.fill")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stop.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    if !stop.lines.isEmpty {
                                        Text(stop.lines.prefix(6).joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func selectResult(_ result: SearchResult) {
        searchTask?.cancel()
        isSearchFocused = false
        let asStop = alongRoute || QueryClassifier().classify(query).alongRoute
        onSelectDestination(result.destination, asStop)
        guard result.isAddress else { return }
        Task {
            let precise = await GUGiKAddressProvider().preciseDestination(for: result)
            if let precise,
               engine.state.status == .destinationPreview || engine.state.status == .routeCalculating ||
                engine.state.status == .routePreview || engine.state.status == .error,
               engine.state.destination?.id == result.destination.id {
                engine.selectDestination(precise)
                await engine.planRoute()
            }
        }
    }

    private func destinationRow(_ destination: Destination, subtitle: String, symbol: String) -> some View {
        Button {
            isSearchFocused = false
            onSelectDestination(destination, false)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
    }

    private func symbol(for kind: PlaceKind) -> String {
        switch kind {
        case .home: "house"
        case .work: "briefcase"
        case .favorite: "star"
        }
    }

    private func append(_ destination: Destination, subtitle: String, symbol: String,
                        to suggestions: inout [LocalSearchSuggestion]) {
        guard !suggestions.contains(where: { $0.destination.coordinate == destination.coordinate }) else { return }
        suggestions.append(LocalSearchSuggestion(destination: destination, subtitle: subtitle, symbol: symbol))
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


}

private func mapTransitColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xff) / 255,
          green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255)
}

private struct LocalSearchSuggestion: Identifiable {
    let destination: Destination
    let subtitle: String
    let symbol: String
    var id: UUID { destination.id }
}

private struct PlaceShortcut: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var destination: Destination
    var isRecent: Bool
    var estimatedMinutes: Int? = nil
}

private struct MapLoadingSplash: View {
    private let accent = Color(red: 0.36, green: 0.91, blue: 0.82)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.075, blue: 0.13), Color(red: 0.012, green: 0.025, blue: 0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            Circle()
                .fill(accent.opacity(0.13))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: 70, y: -110)

            VStack(spacing: 25) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 92, height: 92)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 29, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 29, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: accent.opacity(0.2), radius: 24, y: 8)

                VStack(spacing: 8) {
                    Text("NAVI ASTRA")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .tracking(3.5)
                        .foregroundStyle(.white)

                    Text("Przygotowujemy mapę…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.66))
                }

                ProgressView()
                    .tint(accent)
                    .scaleEffect(1.08)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}

/// Shared floating surfaces. Keep nested content opaque enough for map legibility.
private struct NavigationGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat = 26
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(.background, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.2)))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.3)))
                .shadow(color: .black.opacity(0.1), radius: 18, y: 6)
        }
    }
}

/// Three resting heights, with scrolling confined to the content and dragging to the handle.
private struct DiscoveryDrawer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var maximumHeight: CGFloat
    var collapseRequest: Int
    @ViewBuilder var content: (Bool) -> Content
    @State private var detent = 1
    @GestureState private var translation: CGFloat = 0

    private var heights: [CGFloat] {
        let maximum = max(140, maximumHeight)
        return [min(140, maximum), min(360, maximum), maximum]
    }
    private var height: CGFloat { min(heights[2], max(heights[0], heights[detent] - translation)) }

    var body: some View {
        VStack(spacing: 0) {
            Button { settle(at: detent == 2 ? 0 : detent + 1) } label: {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 38, height: 5)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wysokość panelu wyszukiwania")
            .accessibilityValue(["Zwinięty", "Średni", "Rozwinięty"][detent])
            .accessibilityAdjustableAction { direction in
                settle(at: direction == .increment ? min(2, detent + 1) : max(0, detent - 1))
            }
            .highPriorityGesture(DragGesture(minimumDistance: 6)
                .updating($translation) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    let projected = heights[detent] - value.predictedEndTranslation.height
                    let closest = heights.indices.min { abs(heights[$0] - projected) < abs(heights[$1] - projected) } ?? 1
                    settle(at: closest)
                })
            ScrollView { content(height < 180) }
                .scrollIndicators(.hidden)
        }
        .frame(height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .modifier(NavigationGlassSurface(radius: 30))
        .onChange(of: collapseRequest) { _, _ in settle(at: 0) }
    }

    private func settle(at value: Int) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88)) {
            detent = value
        }
    }
}
