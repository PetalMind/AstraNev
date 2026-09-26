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
    @State private var showOriginPicker = false
    @State private var openOriginSearchAfterPickerDismiss = false
    @State private var openDestinationSearchAfterPlaceDismiss = false
    @State private var selectingRouteOriginInSearch = false
    @State private var selectingRouteOriginOnMap = false
    @State private var pickedRouteOriginCoordinate: Coordinate?
    @State private var pickedRouteOriginAddress: String?
    @State private var routeOriginGeocodingTask: Task<Void, Never>?
    @State private var savedPlaceMapSelectionKind: PlaceKind?
    @State private var savedPlaceMapCoordinate: Coordinate?
    @State private var savedPlaceMapAddress: String?
    @State private var savedPlaceMapGeocodingTask: Task<Void, Never>?
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
    @State private var showRouteSettings = false
    @State private var showFavorites = false
    @State private var showHistory = false
    @State private var editingSavedPlace: SavedPlace?
    @State private var placePendingRemoval: SavedPlace?
    @State private var showPlaceRemovalConfirmation = false
    @State private var addingWaypoint = false
    @State private var showTrafficDetails = false
    @State private var nearbyRequest: NearbySearchRequest?
    @State private var localData = LocalDataStore()
    @State private var favoriteName = ""
    @State private var isSavingPlace = false
    @State private var destinationExpanded = false
    @State private var routePreviewExpanded = false
    @State private var favoritePulseScale: CGFloat = 1
    @State private var showFavoriteRemovalConfirmation = false
    @State private var trafficKey = ""
    @State private var trafficConfigured = TrafficCredential.read() != nil
    @State private var isMapReady = false
    @State private var discoveryDrawerCollapseRequest = 0
    @State private var routingDraft = RoutingPreferences()
    @State private var navigationPanelExpanded = false
    @State private var quickETAEstimates: [String: PlaceRouteEstimate] = [:]
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
    @AppStorage("defaultTransportMode") private var defaultTransportMode = TransportMode.car.rawValue

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
                case .car: settings.context = .driving
                case .walking: settings.context = .walking
                case .bicycle: settings.context = .cycling
                case .transit: settings.context = .transit
                case .parkRide:
                    if let leg = activeParkRideLeg {
                        switch leg.mode.uppercased() {
                        case "CAR": settings.context = .driving
                        case "WALK": settings.context = .walking
                        default: settings.context = .transit
                        }
                    } else {
                        settings.context = .driving
                    }
                }
            }
        }
        return settings
    }

    private var isNavigating: Bool {
        engine.state.status == .navigating || engine.state.status == .rerouting
    }

    private var activeParkRideLeg: JourneyLeg? {
        guard let legs = engine.state.route?.journey?.legs, !legs.isEmpty else { return nil }
        if let index = engine.state.transitProgress?.legIndex, legs.indices.contains(index) {
            return legs[index]
        }
        return legs.first { $0.arrival > Date() } ?? legs.last
    }

    private var parkRideIsUsingTransitLeg: Bool {
        guard let activeParkRideLeg else { return false }
        return activeParkRideLeg.mode.uppercased() != "CAR"
    }

    private var parkRideIsDrivingLeg: Bool {
        activeParkRideLeg?.mode.uppercased() == "CAR"
    }

    private var isOnRoadDrivingLeg: Bool {
        engine.state.transportMode == .car ||
            (engine.state.transportMode == .parkRide && parkRideIsDrivingLeg)
    }

    private var activeJourneyNearbyCategories: [NearbyPlaceCategory] {
        switch engine.state.transportMode {
        case .car:
            [.fuel, .parking, .charging, .food]
        case .parkRide where parkRideIsDrivingLeg:
            [.fuel, .parking, .charging, .food]
        case .walking, .bicycle, .transit, .parkRide:
            [.food]
        }
    }

    private var supportsActiveTripWaypoints: Bool {
        switch engine.state.transportMode {
        case .car, .walking, .bicycle: true
        case .transit, .parkRide: false
        }
    }

    private var supportsActiveTripTrafficDetails: Bool {
        engine.state.transportMode == .car
    }

    private var supportsActiveTripDestinationParking: Bool {
        engine.state.transportMode == .car
    }

    private var supportsActiveTripRoadPreferences: Bool {
        isOnRoadDrivingLeg
    }

    private var parkRideCarDistanceToTransfer: Double? {
        guard engine.state.transportMode == .parkRide,
              parkRideIsDrivingLeg,
              let location = engine.state.location,
              let coordinates = activeParkRideLeg?.coordinates,
              coordinates.count > 1,
              let projection = MapMatcher.project(location.coordinate, onto: coordinates),
              projection.distanceFromRoute <= max(150, location.accuracy * 2) else { return nil }
        let legLength = zip(coordinates, coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        return max(0, legLength - projection.alongRoute)
    }

    private var activeJourneyTargetText: String {
        let fallback = currentJourneyLeg?.current.name ?? engine.state.destination?.name ?? "celu"
        switch engine.state.transportMode {
        case .car:
            return "Teraz jedziesz do \(fallback)"
        case .walking:
            return "Teraz idziesz do \(fallback)"
        case .bicycle:
            return "Teraz jedziesz rowerem do \(fallback)"
        case .transit:
            guard let leg = activeTransitLeg else { return "Teraz podróżujesz do \(fallback)" }
            return leg.mode == "WALK"
                ? "Teraz idziesz do \(leg.to)"
                : "Teraz jedziesz linią \(leg.line ?? "MPK") do \(leg.to)"
        case .parkRide:
            guard let leg = activeParkRideLeg else { return "Teraz podróżujesz do \(fallback)" }
            if leg.mode == "WALK" { return "Teraz idziesz do \(leg.to)" }
            if leg.mode == "CAR" { return "Teraz jedziesz samochodem do \(leg.to)" }
            return "Teraz jedziesz linią \(leg.line ?? "MPK") do \(leg.to)"
        }
    }

    private var arrivalTitle: String {
        switch engine.state.transportMode {
        case .car: "Cel osiągnięty samochodem!"
        case .walking: "Cel osiągnięty pieszo!"
        case .bicycle: "Cel osiągnięty rowerem!"
        case .transit: "Cel osiągnięty komunikacją miejską!"
        case .parkRide: "Cel osiągnięty w systemie P+R!"
        }
    }

    private var arrivalDistanceCaption: String {
        switch engine.state.transportMode {
        case .car: "samochodem"
        case .walking: "pieszo"
        case .bicycle: "rowerem"
        case .transit: "komunikacją"
        case .parkRide: "trasą P+R"
        }
    }

    private var arrivalSummaryMetric: (symbol: String, value: String, caption: String) {
        let trip = engine.state.lastTrip
        switch engine.state.transportMode {
        case .walking:
            let pace = trip.flatMap { trip -> String? in
                guard trip.distanceMeters > 0, trip.movingSeconds > 0 else { return nil }
                let minutesPerKilometer = Int(ceil(trip.movingSeconds / (trip.distanceMeters / 1_000) / 60))
                return "\(minutesPerKilometer) min/km"
            } ?? "—"
            return ("figure.walk", pace, "tempo")
        case .transit:
            guard let transfers = engine.state.route?.journey?.transferCount else {
                return ("arrow.left.arrow.right", "—", "przesiadek")
            }
            return ("arrow.left.arrow.right", "\(transfers)", transferCaption(transfers))
        case .parkRide:
            guard let journeyTransfers = engine.state.route?.journey?.transferCount else {
                return ("arrow.left.arrow.right", "—", "przesiadek")
            }
            let transfers = journeyTransfers + 1
            return ("arrow.left.arrow.right", "\(transfers)", transferCaption(transfers))
        case .car, .bicycle:
            let symbol = engine.state.transportMode == .car ? "car.side" : "bicycle"
            let speed = trip.map { "\(Int($0.averageSpeedKph.rounded())) km/h" } ?? "—"
            return (symbol, speed, "śr. prędkość")
        }
    }

    private var navigationArrivalCaption: String {
        switch engine.state.transportMode {
        case .walking, .bicycle: "dotarcie"
        case .car, .transit, .parkRide: "przyjazd"
        }
    }

    private func transferCaption(_ count: Int) -> String {
        let lastTwoDigits = count % 100
        let lastDigit = count % 10
        if lastDigit == 1, lastTwoDigits != 11 { return "przesiadka" }
        if (2...4).contains(lastDigit), !(12...14).contains(lastTwoDigits) { return "przesiadki" }
        return "przesiadek"
    }

    private var usesFullBleedNavigationPanel: Bool {
        #if os(iOS)
        isNavigating || engine.state.status == .arrived || isIOSRoutePlanningPreview
        #else
        false
        #endif
    }

    private var isIOSRoutePlanningPreview: Bool {
        #if os(iOS)
        engine.state.destination != nil &&
            (engine.state.status == .routePreview || engine.state.status == .error)
        #else
        false
        #endif
    }

    private var arrivalShareURL: URL? {
        guard let destination = engine.state.destination else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        var queryItems = [URLQueryItem]()
        if let origin = engine.state.route?.coordinates.first {
            queryItems.append(URLQueryItem(
                name: "saddr",
                value: "\(origin.latitude),\(origin.longitude)"))
        }
        queryItems.append(URLQueryItem(
            name: "daddr",
            value: "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"))
        switch engine.state.transportMode {
        case .car, .parkRide: queryItems.append(URLQueryItem(name: "dirflg", value: "d"))
        case .walking: queryItems.append(URLQueryItem(name: "dirflg", value: "w"))
        case .bicycle: break
        case .transit: queryItems.append(URLQueryItem(name: "dirflg", value: "r"))
        }
        components?.queryItems = queryItems
        return components?.url
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

    private var routeOriginPoint: RoutePoint? {
        engine.state.routeOrigin ?? engine.state.location.map {
            RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: $0.coordinate),
                       source: .currentLocation)
        }
    }

    private var isRouteOriginAwayFromUser: Bool {
        guard let origin = engine.state.routeOrigin, !origin.isCurrentLocation else { return false }
        guard let location = engine.state.location else { return true }
        return origin.coordinate.distance(to: location.coordinate) > 100
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
                         onSearchSelect: { destination in
                             if let kind = savedPlaceMapSelectionKind {
                                 saveMapSelectedPlace(destination, as: kind)
                             } else if selectingRouteOriginOnMap {
                                 applyRouteOrigin(destination, source: destination.poi == nil ? .search : .poi)
                             } else {
                                 selectDestination(destination)
                             }
                         },
                         onPlaceSelect: { places in
                             if savedPlaceMapSelectionKind != nil, let place = places.first {
                                 engine.focusMap(on: place.destination.coordinate)
                                 updateSavedPlaceMapSelection(place.destination.coordinate)
                             } else if selectingRouteOriginOnMap, let place = places.first {
                                 engine.focusMap(on: place.destination.coordinate)
                                 updatePickedRouteOrigin(place.destination.coordinate)
                             } else {
                                 presentMapPlaces(places)
                             }
                         },
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
                if savedPlaceMapSelectionKind != nil {
                    engine.focusMap(on: coordinate)
                    updateSavedPlaceMapSelection(coordinate)
                } else if selectingRouteOriginOnMap {
                    engine.focusMap(on: coordinate)
                    updatePickedRouteOrigin(coordinate)
                } else {
                    selectMapCoordinate(coordinate)
                }
            }
            .ignoresSafeArea()

            LinearGradient(colors: [Color.black.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if selectingRouteOriginOnMap {
                routeOriginMapPicker
            } else if let kind = savedPlaceMapSelectionKind {
                savedPlaceMapPicker(kind)
            } else {
            GeometryReader { geometry in
                VStack(spacing: 12) {
                    header
                        .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height + geometry.safeAreaInsets.top + 20 } action: { mapHeaderInset = $0 }

                    if let message = engine.state.errorMessage ?? localData.errorMessage {
                        errorNotice(message)
                            .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)
                    }
                    if isNavigating {
                        gpsStatusIndicator
                            .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)
                    }

                    Spacer(minLength: 16)

                    mapControl(compact: geometry.size.height < 500)
                        .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)

                    Group {
                        if engine.state.status == .idle || (engine.state.status == .error && engine.state.destination == nil) {
                            DiscoveryDrawer(maximumHeight: max(160, geometry.size.height - mapHeaderInset - (geometry.size.height < 500 ? 100 : 160)),
                                            collapseRequest: discoveryDrawerCollapseRequest) { compact in
                                discoveryPanel(compact: compact)
                            }
                        } else if isIOSRoutePlanningPreview {
                            routePlanningSheet(
                                maxHeight: min(geometry.size.height * 0.70,
                                               max(220, geometry.size.height - mapHeaderInset - 108)),
                                bottomInset: geometry.safeAreaInsets.bottom)
                        } else {
                            ScrollView(.vertical) {
                                activePanel
                                    .padding(.horizontal, usesFullBleedNavigationPanel ? 0 : 2)
                                    .padding(.top, usesFullBleedNavigationPanel ? 0 : 2)
                                    .padding(.bottom, isTransitRoutePreview && !usesFullBleedNavigationPanel ? 76 : 0)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                            }
                            .scrollIndicators(.hidden)
                            .frame(height: min(panelHeight, geometry.size.height * (geometry.size.height < 500 ? 0.48 : 0.64)))
                            .overlay(alignment: .bottom) {
                                if isTransitRoutePreview && !usesFullBleedNavigationPanel {
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
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height + geometry.safeAreaInsets.bottom + (usesFullBleedNavigationPanel ? 0 : 24)
                    } action: { mapPanelInset = $0 }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, usesFullBleedNavigationPanel ? 0 : 16)
                .padding(.top, 8)
                .padding(.bottom, usesFullBleedNavigationPanel ? -geometry.safeAreaInsets.bottom : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        .sheet(isPresented: $showSearch, onDismiss: { selectingRouteOriginInSearch = false }) {
            searchSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showOriginPicker, onDismiss: {
            guard openOriginSearchAfterPickerDismiss else { return }
            openOriginSearchAfterPickerDismiss = false
            selectingRouteOriginInSearch = true
            showSearch = true
        }) {
            routeOriginPicker
                .presentationDetents([.medium, .large])
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
                                    set: { if !$0 { selectedMapPlaces = [] } }), onDismiss: {
            guard openDestinationSearchAfterPlaceDismiss else { return }
            openDestinationSearchAfterPlaceDismiss = false
            presentSearch()
        }) {
            selectedMapPlacesSheet
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
                              onSave: { localData.add($0) },
                              onRemoveSaved: { removeFavorite(for: $0) },
                              onRenameSaved: { renameFavorite(for: $0, to: $1) }) { destination in
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
        .onChange(of: engine.state.searchMapCenter) { _, center in
            guard let center else { return }
            if selectingRouteOriginOnMap {
                updatePickedRouteOrigin(center)
            } else if savedPlaceMapSelectionKind != nil {
                updateSavedPlaceMapSelection(center)
            }
        }
        .onChange(of: quickETADestinationFingerprint) { _, _ in
            Task { await refreshQuickDestinationETAs() }
        }
        .onChange(of: engine.state.status) { _, status in
            handleNavigationStatusChange(status)
        }
        .confirmationDialog("Usunąć z Ulubionych?", isPresented: $showFavoriteRemovalConfirmation,
                            titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                guard let destination = engine.state.destination else { return }
                _ = removeFavorite(for: destination)
            }
            Button("Anuluj", role: .cancel) { }
        } message: {
            Text(engine.state.destination?.name ?? "")
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

    private var selectedMapPlacesSheet: some View {
        NavigationStack {
            Group {
                if selectedMapPlaces.count > 1 {
                    List(selectedMapPlaces) { result in
                        mapPlaceSelectionRow(result)
                    }
                    .listStyle(.plain)
                } else if let result = selectedMapPlaces.first {
                    selectedMapPlaceDetails(for: result)
                }
            }
            .navigationTitle(selectedMapPlacesSheetTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { selectedMapPlaces = [] }
                }
            }
        }
    }

    private var selectedMapPlacesSheetTitle: String {
        guard selectedMapPlaces.count > 1 else {
            return selectedMapPlaces.first?.destination.name ?? "Miejsce"
        }
        return "Wybierz miejsce"
    }

    private func mapPlaceSelectionRow(_ result: SearchResult) -> some View {
        let category = result.category ?? "Miejsce"
        let categoryTitle = category.replacingOccurrences(of: "_", with: " ").capitalized
        return Button {
            presentMapPlace(result)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.destination.name)
                    .font(.body.weight(.semibold))
                Text(categoryTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectedMapPlaceDetails(for result: SearchResult) -> some View {
        ScrollView {
            PlaceDetailsView(
                result: result,
                isSaved: isMapPlaceSaved(result),
                onSave: { localData.add(result.navigationDestination) },
                isNavigating: isNavigating,
                primaryActionTitle: isNavigating ? "Dodaj przystanek" : "Wyznacz trasę",
                onRouteFromPlace: { setMapPlaceAsRouteOrigin(result) },
                onRemove: { removeFavorite(for: result.destination) },
                onRename: { renameFavorite(for: result.destination, to: $0) },
                onPlanRoute: { planRoute(from: result) })
                .id(result.placeIdentity.cacheKey)
                .padding()
        }
    }

    private func isMapPlaceSaved(_ result: SearchResult) -> Bool {
        localData.places.contains {
            $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate
        }
    }

    private func setMapPlaceAsRouteOrigin(_ result: SearchResult) {
        let destination = result.navigationDestination
        selectedMapPlaces = []
        localData.recordSearch(destination)
        if engine.state.destination == nil {
            openDestinationSearchAfterPlaceDismiss = true
        }
        Task {
            await engine.setRouteOrigin(RoutePoint(
                destination, source: destination.poi == nil ? .search : .poi))
        }
    }

    private func planRoute(from result: SearchResult) {
        let destination = result.navigationDestination
        selectedMapPlaces = []
        if isNavigating {
            Task { await engine.addWaypoint(destination) }
        } else {
            selectDestination(destination)
        }
    }

    private func revealMapSplash() {
        guard !isMapReady else { return }
        withAnimation(.easeOut(duration: 0.35)) {
            isMapReady = true
        }
    }

    private func handleNavigationStatusChange(_ status: NavigationStatus) {
        switch status {
        case .navigating, .rerouting:
            routePreviewExpanded = false
        case .arrived, .idle:
            routePreviewExpanded = false
            navigationPanelExpanded = false
        case .destinationPreview, .routeCalculating, .routePreview, .error:
            navigationPanelExpanded = false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if isNavigating {
                if engine.state.transportMode == .transit || parkRideIsUsingTransitLeg {
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

                Text("Szukaj miejsca lub połączenia")
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
        .accessibilityHint("Otwiera wyszukiwanie miejsc, adresów i połączeń")
    }

    private var routeEndpointFields: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { showOriginPicker = true } label: {
                    HStack(spacing: 11) {
                        Image(systemName: routeOriginPoint?.isCurrentLocation == true
                              ? "location.fill" : "a.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(routeOriginPoint?.isCurrentLocation == true ? .blue : .accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.055), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routeOriginPoint?.name ?? "Twoja lokalizacja")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("Punkt startowy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Punkt startowy: \(routeOriginPoint?.name ?? "Twoja lokalizacja")")

                Button(action: swapRouteEndpoints) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zamień punkt startowy i cel")
                .disabled(engine.state.destination == nil || routeOriginPoint == nil)
            }
            .frame(minHeight: 48)

            routeWaypointRows(darkStyle: false)

            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, height: 28)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }

            Button(action: presentSearch) {
                HStack(spacing: 11) {
                    Image(systemName: "b.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.state.destination?.name ?? "Dokąd?")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(engine.state.destination?.address ?? "Cel podróży")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cel podróży: \(engine.state.destination?.name ?? "Wybierz miejsce")")

            routeWaypointAddButton()
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    @ViewBuilder
    private func routeWaypointRows(darkStyle: Bool) -> some View {
        ForEach(Array(engine.state.waypoints.enumerated()), id: \.element.id) { index, waypoint in
            routeWaypointConnector(darkStyle: darkStyle)
            routeWaypointRow(waypoint, index: index, darkStyle: darkStyle)
        }
    }

    private func routeWaypointConnector(darkStyle: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(darkStyle ? Color.accentColor.opacity(0.85) : Color.accentColor.opacity(0.65))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: 34)
            Rectangle()
                .fill(darkStyle ? Color.white.opacity(0.08) : Color.primary.opacity(0.055))
                .frame(height: 1)
        }
        .frame(height: 11)
        .accessibilityHidden(true)
    }

    private func routeWaypointRow(_ waypoint: Destination, index: Int, darkStyle: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(darkStyle ? Color.white : Color.accentColor)
                .frame(width: 30, height: 30)
                .background(darkStyle ? Color.accentColor : Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(darkStyle ? Color.white.opacity(0.94) : Color.primary)
                    .lineLimit(1)
                Text(waypoint.address.map { "Przystanek \(index + 1) · \($0)" } ?? "Przystanek \(index + 1)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(darkStyle ? Color.white.opacity(0.56) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 3)

            Menu {
                if index > 0 {
                    Button("Bliżej punktu startowego", systemImage: "arrow.up") {
                        Task { await engine.moveWaypoint(waypoint.id, by: -1) }
                    }
                }
                if index + 1 < engine.state.waypoints.count {
                    Button("Bliżej celu", systemImage: "arrow.down") {
                        Task { await engine.moveWaypoint(waypoint.id, by: 1) }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(darkStyle ? Color.white.opacity(0.72) : Color.secondary)
                    .frame(width: 32, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(engine.state.status != .routePreview || engine.state.waypoints.count < 2)
            .accessibilityLabel("Zmień kolejność przystanku \(index + 1)")

            Button {
                Task { await engine.removeWaypoint(waypoint.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(darkStyle ? Color.white.opacity(0.72) : Color.secondary)
                    .frame(width: 30, height: 34)
                    .background(darkStyle ? Color.white.opacity(0.06) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(engine.state.status != .routePreview)
            .accessibilityLabel("Usuń przystanek \(index + 1)")
        }
        .frame(minHeight: 44)
        .dropDestination(for: String.self) { draggedIDs, location in
            guard engine.state.status == .routePreview,
                  let draggedIDString = draggedIDs.first,
                  let draggedID = UUID(uuidString: draggedIDString),
                  let sourceIndex = engine.state.waypoints.firstIndex(where: { $0.id == draggedID }) else {
                return false
            }

            let targetInsertionIndex = index + (location.y >= 22 ? 1 : 0)
            let finalIndex = targetInsertionIndex - (sourceIndex < targetInsertionIndex ? 1 : 0)
            Task { await engine.reorderWaypoint(draggedID, to: finalIndex) }
            return true
        }
        .draggable(waypoint.id.uuidString)
        .accessibilityHint("Przeciągnij przystanek, aby zmienić jego kolejność na trasie")
    }

    private func routeWaypointAddButton() -> some View {
        Button {
            selectingRouteOriginInSearch = false
            addingWaypoint = true
            showSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("Dodaj przystanek")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .frame(minHeight: 38)
            .padding(.leading, 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(engine.state.waypoints.count >= 8 || engine.state.status != .routePreview)
        .opacity(engine.state.waypoints.count >= 8 || engine.state.status != .routePreview ? 0.5 : 1)
        .accessibilityLabel("Dodaj przystanek przed celem podróży")
    }

    private var routeOriginPicker: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showOriginPicker = false
                        Task { await engine.setRouteOrigin(nil) }
                    } label: {
                        Label("Moja lokalizacja", systemImage: "location.fill")
                    }
                    .foregroundStyle(.blue)
                }

                Section("Dodaj punkt startowy") {
                    Button {
                        openOriginSearchAfterPickerDismiss = true
                        showOriginPicker = false
                    } label: {
                        Label("Wyszukaj miejsce", systemImage: "magnifyingglass")
                    }
                    Button(action: beginRouteOriginMapSelection) {
                        Label("Wybierz na mapie", systemImage: "mappin.and.ellipse")
                    }
                }

                if !localData.places.isEmpty {
                    Section("Zapisane miejsca") {
                        ForEach(localData.places) { place in
                            Button {
                                applyRouteOrigin(
                                    place.navigationDestination,
                                    source: place.kind == .favorite ? .favorite : .savedPlace)
                            } label: {
                                Label(place.displayName, systemImage: place.icon.symbol)
                            }
                        }
                    }
                }

                let recent = Array((localData.searches.map(\.destination) + recentDestinations)
                    .reduce(into: [Destination]()) { values, destination in
                        if !values.contains(where: { $0.coordinate == destination.coordinate }) {
                            values.append(destination)
                        }
                    }.prefix(12))
                if !recent.isEmpty {
                    Section("Ostatnie miejsca") {
                        ForEach(recent) { destination in
                            Button {
                                applyRouteOrigin(destination, source: .history)
                            } label: {
                                Label(destination.name, systemImage: "clock.arrow.circlepath")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Punkt startowy")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { showOriginPicker = false }
                }
            }
        }
    }

    private var routeOriginMapPicker: some View {
        GeometryReader { geometry in
            ZStack {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 39, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    .offset(y: -18)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            selectingRouteOriginOnMap = false
                            engine.state.routeOriginMapSelectionActive = false
                            showOriginPicker = true
                        } label: {
                            Label("Wstecz", systemImage: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Wybierz punkt startu")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(pickedRouteOriginAddress ?? "Przesuń mapę pod pinezkę",
                              systemImage: pickedRouteOriginAddress == nil ? "location.magnifyingglass" : "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if pickedRouteOriginCoordinate != nil {
                            Text("Punkt pod pinezką na środku mapy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(action: confirmRouteOriginMapSelection) {
                            Label("Ustaw jako punkt startu", systemImage: "a.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pickedRouteOriginCoordinate == nil)
                    }
                    .padding(16)
                    .frame(maxWidth: 560)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 16)
                }
                .padding(.top, max(12, geometry.safeAreaInsets.top + 8))
                .padding(.bottom, max(12, geometry.safeAreaInsets.bottom + 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private func savedPlaceMapPicker(_ kind: PlaceKind) -> some View {
        GeometryReader { geometry in
            ZStack {
                Image(systemName: kind.defaultIcon.symbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    .offset(y: -18)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            savedPlaceMapGeocodingTask?.cancel()
                            savedPlaceMapSelectionKind = nil
                            showSearch = true
                        } label: {
                            Label("Wstecz", systemImage: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Zapisz \(kind.title.lowercased())")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(savedPlaceMapAddress ?? "Przesuń mapę pod pinezkę",
                              systemImage: savedPlaceMapAddress == nil ? "location.magnifyingglass" : "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if savedPlaceMapCoordinate != nil {
                            Text("Punkt pod pinezką na środku mapy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(action: confirmSavedPlaceMapSelection) {
                            Label("Zapisz \(kind.title.lowercased())", systemImage: kind.defaultIcon.symbol)
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(savedPlaceMapCoordinate == nil)
                    }
                    .padding(16)
                    .frame(maxWidth: 560)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 16)
                }
                .padding(.top, max(12, geometry.safeAreaInsets.top + 8))
                .padding(.bottom, max(12, geometry.safeAreaInsets.bottom + 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private func beginSavedPlaceMapSelection(as kind: PlaceKind) {
        savedPlaceMapSelectionKind = kind
        let coordinate = engine.state.searchMapCenter ?? engine.state.location?.coordinate
            ?? engine.state.destination?.coordinate
        savedPlaceMapCoordinate = coordinate
        savedPlaceMapAddress = nil
        showSearch = false
        if let coordinate {
            engine.focusMap(on: coordinate, zoom: 15.5)
            updateSavedPlaceMapSelection(coordinate)
        }
    }

    private func updateSavedPlaceMapSelection(_ coordinate: Coordinate) {
        savedPlaceMapCoordinate = coordinate
        savedPlaceMapAddress = nil
        savedPlaceMapGeocodingTask?.cancel()
        savedPlaceMapGeocodingTask = Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, savedPlaceMapSelectionKind != nil,
                  savedPlaceMapCoordinate == coordinate else { return }
            let address = await GUGiKAddressProvider().reverseGeocode(coordinate)
            guard !Task.isCancelled, savedPlaceMapSelectionKind != nil,
                  savedPlaceMapCoordinate == coordinate else { return }
            savedPlaceMapAddress = address
        }
    }

    private func confirmSavedPlaceMapSelection() {
        guard let kind = savedPlaceMapSelectionKind, let coordinate = savedPlaceMapCoordinate else { return }
        let destination = Destination(name: kind.title, coordinate: coordinate, address: savedPlaceMapAddress)
        localData.add(destination, kind: kind)
        savedPlaceMapGeocodingTask?.cancel()
        savedPlaceMapSelectionKind = nil
    }

    private func saveMapSelectedPlace(_ destination: Destination, as kind: PlaceKind) {
        let saved = Destination(name: kind.title, coordinate: destination.coordinate,
                                address: destination.address, poi: destination.poi)
        localData.add(saved, kind: kind)
        savedPlaceMapGeocodingTask?.cancel()
        savedPlaceMapSelectionKind = nil
    }

    private func beginRouteOriginMapSelection() {
        showOriginPicker = false
        selectingRouteOriginOnMap = true
        engine.state.routeOriginMapSelectionActive = true
        let coordinate = engine.state.searchMapCenter ?? engine.state.location?.coordinate
            ?? engine.state.destination?.coordinate
        pickedRouteOriginCoordinate = coordinate
        pickedRouteOriginAddress = nil
        if let coordinate {
            engine.focusMap(on: coordinate, zoom: 15.5)
            updatePickedRouteOrigin(coordinate)
        }
    }

    private func updatePickedRouteOrigin(_ coordinate: Coordinate) {
        pickedRouteOriginCoordinate = coordinate
        pickedRouteOriginAddress = nil
        routeOriginGeocodingTask?.cancel()
        routeOriginGeocodingTask = Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled,
                  selectingRouteOriginOnMap,
                  pickedRouteOriginCoordinate == coordinate else { return }
            let address = await GUGiKAddressProvider().reverseGeocode(coordinate)
            guard !Task.isCancelled,
                  selectingRouteOriginOnMap,
                  pickedRouteOriginCoordinate == coordinate else { return }
            pickedRouteOriginAddress = address
        }
    }

    private func confirmRouteOriginMapSelection() {
        guard let coordinate = pickedRouteOriginCoordinate else { return }
        let address = pickedRouteOriginAddress
        let name = address?.components(separatedBy: ",").first ?? "Wybrany punkt"
        let destination = Destination(name: name, coordinate: coordinate, address: address)
        localData.recordSearch(destination)
        selectingRouteOriginOnMap = false
        engine.state.routeOriginMapSelectionActive = false
        routeOriginGeocodingTask?.cancel()
        Task { await engine.setRouteOrigin(RoutePoint(destination, source: .mapSelection)) }
    }

    private func applyRouteOrigin(_ destination: Destination, source: RoutePointSource) {
        showOriginPicker = false
        showSearch = false
        selectingRouteOriginInSearch = false
        selectingRouteOriginOnMap = false
        engine.state.routeOriginMapSelectionActive = false
        routeOriginGeocodingTask?.cancel()
        if source == .search || source == .mapSelection || source == .poi {
            localData.recordSearch(destination)
        }
        Task { await engine.setRouteOrigin(RoutePoint(destination, source: source)) }
    }

    private func swapRouteEndpoints() {
        Task { await engine.swapRoutePoints() }
    }

    private var maneuverCard: some View {
        let maneuver = engine.state.progress?.nextManeuver
        let maneuverDistance = engine.state.progress?.distanceToNextManeuver ?? .infinity
        let guidanceDistance = maneuverDistance.isFinite
            ? maneuverDistance
            : (engine.state.transportMode == .parkRide
                ? (parkRideCarDistanceToTransfer ?? .infinity)
                : (engine.state.progress?.remainingDistance ?? .infinity))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: maneuver?.iconName
                      ?? (engine.state.transportMode == .parkRide ? "parkingsign.circle.fill" : "arrow.up"))
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.state.status == .rerouting
                         ? "Przeliczanie trasy…"
                         : (guidanceDistance <= 25 ? "TERAZ" : distance(guidanceDistance)))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())

                    Text(maneuver?.displayInstruction
                         ?? (engine.state.transportMode == .parkRide
                             ? "Jedź do parkingu P+R" : "Kontynuuj do celu"))
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
                VStack(alignment: .trailing, spacing: 6) {
                    if guidanceDistance.isFinite, guidanceDistance <= 25 {
                        Text(distance(guidanceDistance))
                            .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    laneGuidance
                }
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

            if let maneuver = engine.state.progress?.nextManeuver,
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
        if let lanes = engine.state.progress?.nextManeuver?.lanes, !lanes.isEmpty {
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
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Planowanie trasy")
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
            routeEndpointFields
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
                    Button("Zapisz", systemImage: "heart") {
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
#if os(iOS)
        routePlanningSheet(maxHeight: 560, bottomInset: 0)
#else
        desktopRoutePreviewCard
#endif
    }

    private var desktopRoutePreviewCard: some View {
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

            routeEndpointFields
            HStack {
                Spacer()
                Button(action: toggleDestinationFavorite) {
                    Image(systemName: isDestinationFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isDestinationFavorite ? Color.red : Color.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .scaleEffect(favoritePulseScale)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDestinationFavorite ? "Usuń cel z ulubionych" : "Zapisz cel w ulubionych")
            }

            if isRouteOriginAwayFromUser, let origin = engine.state.routeOrigin {
                VStack(alignment: .leading, spacing: 8) {
                    if let location = engine.state.location {
                        Label("Start trasy: \(distance(origin.coordinate.distance(to: location.coordinate))) od Ciebie",
                              systemImage: "location.north.line")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Start trasy ustawiono poza bieżącą lokalizacją",
                              systemImage: "location.north.line")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await engine.setRouteOrigin(nil) }
                    } label: {
                        Label("Użyj mojej lokalizacji jako start", systemImage: "location.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }

            transportSelector
            if engine.state.transportMode == .transit || engine.state.transportMode == .parkRide {
                journeyTimeControl
            }

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
                                HStack(spacing: 4) {
                                    Text(delayLabel(TimeInterval(delay)))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(transitDelayColor(delay))
                                    Text(transitTimeSourceLabel(for: firstRide, in: journey))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } else if firstRide.realTime || hasLiveTransitUpdate(for: firstRide) {
                                Text(transitTimeSourceLabel(for: firstRide, in: journey))
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("wg rozkładu")
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
                        Button {
                            Task { await engine.loadLaterTransitConnections(after: firstRide.departure) }
                        } label: {
                            HStack(spacing: 7) {
                                if engine.state.isLoadingLaterTransitRoutes {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "clock.arrow.circlepath")
                                }
                                Text(engine.state.isLoadingLaterTransitRoutes
                                     ? "Szukam późniejszych połączeń…"
                                     : "Pokaż późniejsze połączenia")
                            }
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 38)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(engine.state.isLoadingLaterTransitRoutes
                                  || engine.state.transitPlanningPhase == .enrichingGeometry)
                    }
                    if engine.state.transitPlanningPhase == .enrichingGeometry {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Znaleziono połączenia. Uzupełniam przebieg dojść pieszych…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if journey.legs.contains(where: {
                        $0.mode == "WALK" && $0.walkingTimeIsApproximate
                    }) {
                        Label("Czasy dojść są szacunkowe.", systemImage: "info.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if journey.legs.contains(where: {
                        $0.mode == "WALK" && !$0.hasResolvedWalkingGeometry
                    }) {
                        Label("Przebieg dojść jest pokazany orientacyjnie.", systemImage: "info.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if engine.state.didSearchLaterTransitRoutes && engine.state.laterTransitRoutes.isEmpty {
                    Text("Nie znaleziono późniejszych połączeń w dostępnym rozkładzie.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !engine.state.laterTransitRoutes.isEmpty {
                    laterTransitConnections
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
                                                    HStack(spacing: 4) {
                                                        Text(delayLabel(TimeInterval(delay)))
                                                            .foregroundStyle(transitDelayColor(delay))
                                                        Text(transitTimeSourceLabel(for: leg, in: journey))
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    .font(.caption2)
                                                } else if hasLiveTransitUpdate(for: leg) {
                                                    Text(transitTimeSourceLabel(for: leg, in: journey))
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                } else if leg.realTime {
                                                    Text(transitTimeSourceLabel(for: leg, in: journey))
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                } else if leg.mode != "WALK" {
                                                    Text("wg rozkładu")
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
                }

                if engine.state.transportMode != .transit {
                    beginRouteButton
                }
            } else if engine.state.status == .routeCalculating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(engine.state.transportMode == .transit
                         ? (engine.state.transitPlanningPhase == .loadingSchedule
                            ? "Aktualizuję rozkłady…" : "Szukam połączeń…")
                         : "Wyznaczanie trasy…")
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

    private var routePlanningOptions: [NavigationRoute] {
        var routes = engine.state.routeOptions
        if routes.isEmpty, let route = engine.state.route {
            routes = [route]
        }
        let selectedID = engine.state.route?.id
        return routes.sorted { lhs, rhs in
            let lhsIsSelected = lhs.id == selectedID
            let rhsIsSelected = rhs.id == selectedID
            if lhsIsSelected != rhsIsSelected { return lhsIsSelected }
            return lhs.expectedTravelTime < rhs.expectedTravelTime
        }
    }

    private var routePlanningShareURL: URL? {
        guard let origin = routeOriginPoint, let destination = engine.state.destination else { return nil }
        let originValue = origin.isCurrentLocation
            ? "Current Location"
            : "\(origin.coordinate.latitude),\(origin.coordinate.longitude)"
        let destinationValue = "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"
        let directionsMode: String = switch engine.state.transportMode {
        case .car: "d"
        case .walking: "w"
        case .bicycle: "b"
        case .transit, .parkRide: "r"
        }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "saddr", value: originValue),
            URLQueryItem(name: "daddr", value: destinationValue),
            URLQueryItem(name: "dirflg", value: directionsMode)
        ]
        return components?.url
    }

    private func routePlanningSheet(maxHeight: CGFloat, bottomInset: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 40, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: 40),
            style: .continuous)

        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.48))
                .frame(width: 38, height: 4)
                .padding(.top, 9)
                .padding(.bottom, 12)

            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    routePlanningEndpoints
                    routePlanningTransportSelector

                    if engine.state.transportMode == .transit || engine.state.transportMode == .parkRide {
                        journeyTimeControl
                            .padding(.horizontal, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(NavigationGlassSurface(radius: 17))
                    }

                    if let route = engine.state.route {
                        routePlanningOverview(route)
                        routePlanningAlternatives(for: route)
                        if routePreviewExpanded {
                            routePlanningDetails(for: route)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    } else {
                        routePlanningUnavailable
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 11)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)

            routePlanningFooter(bottomInset: bottomInset)
        }
        .frame(maxWidth: 560)
        .frame(height: maxHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .modifier(NavigationGlassPanelSurface(shape: shape))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { routePreviewExpanded = true }
            } else if value.translation.height > 35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { routePreviewExpanded = false }
            }
        })
    }

    private var routePlanningEndpoints: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: routeOriginPoint?.isCurrentLocation == true ? "location.north.fill" : "a.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 31, height: 31)
                    .background(Color.accentColor, in: Circle())
                Button { showOriginPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routeOriginPoint?.name ?? "Twoja lokalizacja")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("Punkt startowy")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.56))
                    }
                    .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Punkt startowy: \(routeOriginPoint?.name ?? "Twoja lokalizacja")")
                Button(action: swapRouteEndpoints) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .frame(width: 34, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(engine.state.destination == nil || routeOriginPoint == nil)
                .accessibilityLabel("Zamień punkt startowy i cel")
            }

            routeWaypointRows(darkStyle: true)
            routeWaypointConnector(darkStyle: true)

            HStack(spacing: 10) {
                Text("B")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 31, height: 31)
                    .background(Color.red.opacity(0.9), in: Circle())
                Button(action: presentSearch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.state.destination?.name ?? "Dokąd?")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(engine.state.destination?.address ?? "Cel podróży")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.56))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cel podróży: \(engine.state.destination?.name ?? "Nie wybrano")")
                    Button(action: toggleDestinationFavorite) {
                        Image(systemName: isDestinationFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isDestinationFavorite ? Color.red : Color.white.opacity(0.8))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDestinationFavorite ? "Usuń cel z ulubionych" : "Zapisz cel w ulubionych")
            }

            routeWaypointAddButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .modifier(NavigationGlassSurface(radius: 23, interactive: true))
    }

    private var routePlanningTransportSelector: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(TransportMode.allCases) { mode in
                    let selected = engine.state.transportMode == mode
                    Button {
                        Task { await engine.selectTransportMode(mode) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 14, weight: .semibold))
                            Text(mode.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(selected ? Color.accentColor : Color.white.opacity(0.65))
                        .padding(.horizontal, 11)
                        .frame(minHeight: 43)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.045),
                                              lineWidth: selected ? 1.2 : 1)
                        }
                        .modifier(NavigationGlassSurface(radius: 14, interactive: true))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: engine.state.transportMode)
    }

    private func routePlanningOverview(_ route: NavigationRoute) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time(route.expectedTravelTime))
                    .font(.system(size: 31, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(distance(route.distance)) · Przyjazd \(routePlanningArrivalTime(route))")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.67))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let traffic = routePlanningTrafficSummary(for: route) {
                    Label(traffic.title, systemImage: traffic.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(traffic.color)
                        .lineLimit(1)
                }
                if !route.chargingStops.isEmpty {
                    Text("Postoje na ładowanie: \(route.chargingStops.count) · +\(Int((route.chargingDuration / 60).rounded())) min")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Button {
                if isRouteOriginAwayFromUser {
                    navigateToRouteOrigin()
                } else {
                    engine.begin()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isRouteOriginAwayFromUser ? "location.magnifyingglass" : "location.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text(isRouteOriginAwayFromUser ? "Do startu" : "Rozpocznij")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.white)
                .frame(width: 126, height: 58)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(engine.state.status != .routePreview
                      || engine.state.transitPlanningPhase == .enrichingGeometry)
            .opacity(engine.state.status == .routePreview
                     && engine.state.transitPlanningPhase != .enrichingGeometry ? 1 : 0.55)
            .accessibilityLabel(isRouteOriginAwayFromUser ? "Nawiguj do punktu startowego" : "Rozpocznij nawigację")
        }
        .padding(14)
        .modifier(NavigationGlassSurface(radius: 23))
    }

    private func routePlanningArrivalTime(_ route: NavigationRoute) -> String {
        let arrival = route.journey?.arrival ?? Date().addingTimeInterval(max(0, route.expectedTravelTime))
        return arrival.formatted(date: .omitted, time: .shortened)
    }

    private func routePlanningTrafficSummary(for route: NavigationRoute) -> (title: String, symbol: String, color: Color)? {
        guard engine.state.transportMode == .car,
              let traffic = engine.state.traffic else { return nil }
        let segments = traffic.routeFlowSegments.filter { $0.routeID == route.id }
        guard !segments.isEmpty else { return nil }
        let colors = Set(segments.map(\.colorHex))
        let prefix = "Ruch na początku trasy: "
        if colors.contains(RouteColorPalette.closure) {
            return (prefix + "zamknięcie", "exclamationmark.triangle.fill", .red)
        }
        if colors.contains(RouteColorPalette.trafficStationary) {
            return (prefix + "zatrzymany", "exclamationmark.triangle.fill", .red)
        }
        if colors.contains(RouteColorPalette.trafficHeavy) {
            return (prefix + "wolny", "car.side.fill", .orange)
        }
        if colors.contains(RouteColorPalette.trafficSlow) {
            return (prefix + "spowolnienia", "car.side.fill", .orange)
        }
        if colors.contains(RouteColorPalette.trafficModerate) {
            return (prefix + "umiarkowany", "car.side.fill", .yellow)
        }
        guard colors.contains(RouteColorPalette.trafficFree) else { return nil }
        return (prefix + "płynny", "leaf.fill", .green)
    }

    @ViewBuilder
    private func routePlanningAlternatives(for selectedRoute: NavigationRoute) -> some View {
        let routes = routePlanningOptions
        if routes.count > 1 {
            VStack(alignment: .leading, spacing: 7) {
                Text("Alternatywne trasy")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.84))

                ForEach(Array(routes.enumerated()), id: \.element.id) { _, route in
                    let isSelected = route.id == selectedRoute.id
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { engine.select(route) }
                    } label: {
                        HStack(spacing: 9) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(time(route.expectedTravelTime))
                                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(distance(route.distance))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.57))
                            }
                            Spacer(minLength: 3)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(isSelected ? "Wybrana" : "Alternatywna")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.76))
                                Text(routePlanningDifference(route, from: selectedRoute))
                                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.5))
                                .padding(.leading, 3)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
                        .modifier(NavigationGlassSurface(radius: 17, interactive: true))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.07),
                                              lineWidth: isSelected ? 1.3 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(isSelected ? "Wybrana trasa" : "Alternatywna trasa"), \(time(route.expectedTravelTime)), \(distance(route.distance))")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func routePlanningDifference(_ route: NavigationRoute, from selectedRoute: NavigationRoute) -> String {
        let difference = route.expectedTravelTime - selectedRoute.expectedTravelTime
        let minutes = Int(ceil(abs(difference) / 60))
        guard minutes > 0 else { return "Podobny czas" }
        return difference > 0 ? "+\(minutes) min" : "\(minutes) min szybciej"
    }

    private func routePlanningDetails(for route: NavigationRoute) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !route.maneuvers.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Przebieg trasy")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    ForEach(Array(route.maneuvers.prefix(12))) { maneuver in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: maneuver.iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(maneuver.displayInstruction)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.88))
                                if let street = maneuver.streetLine {
                                    Text(street)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.55))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            waypointDetails

            VStack(alignment: .leading, spacing: 7) {
                Text("Opcje trasy")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                routePreferenceToggle("Unikaj autostrad", keyPath: \.avoidHighways)
                routePreferenceToggle("Unikaj dróg płatnych", keyPath: \.avoidTolls)
                routePreferenceToggle("Unikaj promów", keyPath: \.avoidFerries)
                routePreferenceToggle("Unikaj dróg gruntowych", keyPath: \.avoidUnpaved)
            }
            .tint(Color.accentColor)

            if !route.chargingStops.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Ładowanie po drodze")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Szacowany czas postojów: \(Int((route.chargingDuration / 60).rounded())) min")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                    ForEach(route.chargingStops) { stop in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.destination.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("\(stop.connectorTypes.joined(separator: ", ")) · do \(Int(stop.maximumPowerKW.rounded())) kW · postój \(Int((stop.estimatedChargingTime / 60).rounded())) min")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                            Text(stop.availabilityKnown ? "Status: działająca według OpenStreetMap" : "Dostępność ładowarki nieznana")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.52))
                            Text(stop.publicAccess == true ? "Dostęp publiczny według OpenStreetMap" : "Dostęp publiczny niepotwierdzony")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.52))
                        }
                        .padding(.top, 3)
                    }
                }
            }

            if let journey = route.journey {
                routePlanningJourneyDetails(journey)
            }

            if engine.state.transportMode == .car {
                Button { showTrafficDetails = true } label: {
                    Label("Szczegóły ruchu", systemImage: "car.side")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .modifier(NavigationGlassSurface(radius: 21))
    }

    private func routePlanningJourneyDetails(_ journey: Journey) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Połączenie")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Odjazd \(journey.departure.formatted(date: .omitted, time: .shortened)) · Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.8))
            Text("Pieszo \(transitMetricTime(journey.walkingDuration)) · oczekiwanie \(transitMetricTime(journey.waitingDuration)) · przesiadki: \(journey.transferCount)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))
            Text(transitRealtimeStatus(for: journey))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.56))
            if !journey.alerts.isEmpty {
                ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            } else if !journey.alertsFeedAvailable {
                Text("Komunikaty na trasie niedostępne")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
            } else {
                Text("Brak aktywnych komunikatów dla tej trasy")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
            }
            if let attribution = journey.railwayScheduleAttribution {
                Text(attribution)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            ForEach(journey.legs) { leg in
                HStack(alignment: .top, spacing: 8) {
                    Text(leg.departure.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("\(leg.mode == "WALK" ? "Pieszo" : (leg.line ?? leg.mode)) · \(leg.from) → \(leg.to)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var routePlanningUnavailable: some View {
        VStack(alignment: .leading, spacing: 9) {
            if engine.state.status == .routeCalculating {
                HStack(spacing: 9) {
                    ProgressView()
                    Text(engine.state.transportMode == .transit ? "Szukam połączeń…" : "Wyznaczanie trasy…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            } else {
                Text(engine.state.errorMessage ?? "Nie udało się wyznaczyć trasy.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                Button {
                    Task { await engine.planRoute() }
                } label: {
                    Label("Spróbuj ponownie", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 43)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 19))
    }

    private func routePlanningFooter(bottomInset: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    routePreviewExpanded.toggle()
                }
            } label: {
                routePlanningFooterLabel(symbol: routePreviewExpanded ? "chevron.down" : "map",
                                         title: routePreviewExpanded ? "Zwiń" : "Szczegóły\ntrasy")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(routePreviewExpanded ? "Zwiń szczegóły trasy" : "Szczegóły trasy")

            Group {
                if let url = routePlanningShareURL {
                    ShareLink(item: url) {
                        routePlanningFooterLabel(symbol: "square.and.arrow.up", title: "Udostępnij\ntrasę")
                    }
                } else {
                    routePlanningFooterLabel(symbol: "square.and.arrow.up", title: "Udostępnij\ntrasę")
                        .opacity(0.48)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Udostępnij trasę")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, max(12, min(22, bottomInset * 0.55)))
        .background(Color.black.opacity(0.08))
    }

    private func routePlanningFooterLabel(symbol: String, title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 59)
        .modifier(NavigationGlassSurface(radius: 16, interactive: true))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var beginRouteButton: some View {
        Button {
            if isRouteOriginAwayFromUser {
                navigateToRouteOrigin()
            } else {
                engine.begin()
            }
        } label: {
            Label(isRouteOriginAwayFromUser ? "Nawiguj do punktu startowego" : "Rozpocznij",
                  systemImage: isRouteOriginAwayFromUser ? "location.magnifyingglass" :
                    (engine.state.transportMode == .transit ? "tram.fill" : "location.fill"))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(engine.state.status != .routePreview
                  || engine.state.transitPlanningPhase == .enrichingGeometry)
        .opacity(engine.state.status == .routePreview
                 && engine.state.transitPlanningPhase != .enrichingGeometry ? 1 : 0.55)
    }

    private func navigateToRouteOrigin() {
        guard let point = engine.state.routeOrigin, !point.isCurrentLocation else { return }
        let originDestination = point.destination
        engine.state.routeOrigin = nil
        engine.selectDestination(originDestination)
        Task { await engine.planRoute() }
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

    private var journeyTimeControl: some View {
        HStack(spacing: 8) {
            Menu {
                Button { chooseJourneyTimeMode(.now) } label: {
                    Label("Teraz", systemImage: engine.state.journeyTimeMode == .now ? "checkmark" : "clock")
                }
                Button { chooseJourneyTimeMode(.departAt) } label: {
                    Label("Wyjazd o…", systemImage: engine.state.journeyTimeMode == .departAt ? "checkmark" : "arrow.up.right")
                }
                if engine.state.transportMode == .transit {
                    Button { chooseJourneyTimeMode(.arriveBy) } label: {
                        Label("Przyjazd na…", systemImage: engine.state.journeyTimeMode == .arriveBy ? "checkmark" : "mappin")
                    }
                }
            } label: {
                Label(journeyTimeControlTitle, systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .frame(minHeight: 36)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .accessibilityLabel("Kiedy chcesz jechać")
            .disabled(engine.state.status != .routePreview
                      || engine.state.transitPlanningPhase == .enrichingGeometry)

            if engine.state.journeyTimeMode != .now {
                DatePicker(
                    engine.state.journeyTimeMode == .departAt ? "Godzina wyjazdu" : "Godzina przyjazdu",
                    selection: Binding(
                        get: { engine.state.journeyTargetTime },
                        set: { engine.setJourneyTargetTime($0) }),
                    in: Date()...Date().addingTimeInterval(18 * 60 * 60),
                    displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .accessibilityLabel(engine.state.journeyTimeMode == .departAt
                                        ? "Godzina wyjazdu" : "Godzina przyjazdu")
                    .disabled(engine.state.status != .routePreview
                              || engine.state.transitPlanningPhase == .enrichingGeometry)

                Button {
                    Task { await engine.planRoute() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Przelicz połączenia")
                .disabled(engine.state.status != .routePreview
                          || engine.state.transitPlanningPhase == .enrichingGeometry)
            }
            Spacer(minLength: 0)
        }
    }

    private var journeyTimeControlTitle: String {
        switch engine.state.journeyTimeMode {
        case .now: "Teraz"
        case .departAt: "Wyjazd o"
        case .arriveBy: "Przyjazd na"
        }
    }

    private func chooseJourneyTimeMode(_ mode: JourneyTimeMode) {
        engine.setJourneyTimeMode(mode)
        if mode == .now {
            Task { await engine.planRoute() }
        }
    }

    private var laterTransitConnections: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Późniejsze połączenia")
                .font(.subheadline.weight(.semibold))
            ForEach(engine.state.laterTransitRoutes) { route in
                if let journey = route.journey,
                   let firstRide = journey.legs.first(where: { $0.mode != "WALK" }) {
                    Button {
                        engine.selectLaterTransitConnection(route)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(firstRide.departure.formatted(date: .omitted, time: .shortened))  ·  \(time(route.expectedTravelTime))")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                Text(journey.legs.filter { $0.mode != "WALK" }
                                    .map { $0.line ?? "MPK" }.joined(separator: " → "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text("Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if firstRide.realTime {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(firstRide.delaySeconds.map { delayLabel(TimeInterval($0)) } ?? "Na żywo")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(firstRide.delaySeconds.map { transitDelayColor($0) } ?? Color.accentColor)
                                    Text(transitTimeSourceLabel(for: firstRide, in: journey))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("wg rozkładu")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Wybierz późniejsze połączenie")
                }
            }
        }
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

    @ViewBuilder
    private var waypointDetails: some View {
        if !engine.state.waypoints.isEmpty {
            HStack {
                Label("Przystanki pośrednie", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                Text("\(engine.state.waypoints.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.state.waypoints.count >= 2 {
                    Button("Optymalizuj", systemImage: "arrow.triangle.swap") {
                        Task { await engine.optimizeWaypoints() }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(engine.state.status != .routePreview)
                }
            }
        }
    }

    private var routeEndpoints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trasa")
                .font(.subheadline.weight(.semibold))
            Label(engine.state.routeOrigin?.name ??
                  (engine.state.location == nil ? "Pozycja niedostępna" : "Moja lokalizacja"),
                  systemImage: engine.state.routeOrigin?.isCurrentLocation == false ? "a.circle.fill" : "location.fill")
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
        .disabled(engine.state.transitPlanningPhase == .enrichingGeometry)
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
                    Text("Ulubione")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Button("Zobacz wszystkie", systemImage: "heart") { showFavorites = true }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                if !savedPlaceShortcuts.isEmpty {
                    quickDestinationShelf(savedPlaceShortcuts)
                } else {
                    Text("Zapisz Dom, Pracę lub ulubiony adres, aby mieć je zawsze pod ręką.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Ostatnie miejsca")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Button {
                        showHistory = true
                    } label: {
                        Label("Historia", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Historia podróży")
                }
                if !recentPlaceShortcuts.isEmpty {
                    quickDestinationShelf(recentPlaceShortcuts)
                } else {
                    Text("Ostatnio wybrane miejsca pojawią się tutaj.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Text("Szukaj w pobliżu")
                    .font(.headline.weight(.semibold))
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
                .scrollIndicators(.visible)
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

    private func quickDestinationShelf(_ shortcuts: [PlaceShortcut]) -> some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(shortcuts) { shortcut in
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
                                            let routeDistance = shortcut.estimatedDistanceMeters.map(distance)
                                            Text(routeDistance.map { "\(estimatedMinutes) min · \($0)" } ?? "\(estimatedMinutes) min")
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
                    .padding(.trailing, shortcuts.count > 2 ? 10 : 7)
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

                if shortcuts.count > 2, let lastShortcut = shortcuts.last {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if isNavigating && isOnRoadDrivingLeg {
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
#if os(iOS)
        journeyNavigationPanel
#else
        desktopJourneyPanel
#endif
    }

    private var journeyNavigationPanel: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 42, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: 42),
            style: .continuous)

        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.48))
                .frame(width: 38, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 12)

            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    navigationPanelExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    journeySummaryMetric(value: time(engine.state.progress?.remainingTime ?? 0), caption: "do celu")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    journeySummaryMetric(value: distance(engine.state.progress?.remainingDistance ?? 0), caption: "pozostało")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    journeySummaryMetric(value: arrivalTime(engine.state.progress?.remainingTime ?? 0), caption: navigationArrivalCaption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: navigationPanelExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .padding(.leading, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .accessibilityLabel(navigationPanelExpanded ? "Zwiń panel prowadzenia" : "Rozwiń panel prowadzenia")

            if engine.state.transportMode == .transit, let transitLeg = activeTransitLeg {
                Group {
                    if transitLeg.mode == "WALK" {
                        transitWalkNavigationCard(transitLeg)
                    } else {
                        transitNavigationCard(transitLeg)
                    }
                }
                .padding(.top, 16)
            } else {
                journeyDestinationRow
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
            }

            HStack(spacing: 8) {
                journeyFooterAction(symbol: "arrow.triangle.branch", title: "Przegląd\ntrasy") {
                    engine.showRouteOverview()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        navigationPanelExpanded = false
                    }
                }
                journeyFooterAction(symbol: "stop.circle.fill", title: "Zakończ\nnawigację", destructive: true) {
                    engine.stop()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 15)

            if navigationPanelExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle()
                        .fill(Color.white.opacity(0.11))
                        .frame(height: 1)
                    Text("W trakcie podróży")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    journeyActionsGrid

                    if engine.state.transportMode == .transit {
                        transitJourneyTimeline
                    } else if engine.state.transportMode == .parkRide {
                        parkRideJourneyTimeline
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .modifier(NavigationGlassPanelSurface(shape: shape))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = true }
            } else if value.translation.height > 35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = false }
            }
        })
    }

    private var journeyDestinationRow: some View {
        let currentLeg = currentJourneyLeg
        return HStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(activeJourneyTargetText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let following = currentLeg?.following {
                    Text("Po dotarciu: \(following.name)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 18))
        .accessibilityElement(children: .combine)
    }

    private func journeySummaryMetric(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func journeyFooterAction(symbol: String, title: String, destructive: Bool = false,
                                     action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(destructive ? Color.red : Color.white.opacity(0.67))
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 7)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(destructive ? Color.red.opacity(0.1) : Color.white.opacity(0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(destructive ? Color.red.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1)
            }
            .modifier(NavigationGlassSurface(radius: 18, interactive: true))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.replacingOccurrences(of: "\n", with: " "))
    }

    @ViewBuilder
    private var journeyActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
            if activeJourneyNearbyCategories.count == 1,
               let category = activeJourneyNearbyCategories.first {
                Button { presentNearby(category) } label: {
                    journeyActionLabel("\(category.title) po drodze", symbol: category.symbol)
                }
            } else {
                Menu {
                    ForEach(activeJourneyNearbyCategories) { category in
                        Button(category.title, systemImage: category.symbol) {
                            presentNearby(category)
                        }
                    }
                } label: {
                    journeyActionLabel("Po trasie", symbol: "magnifyingglass")
                }
            }
            if supportsActiveTripWaypoints {
                Button {
                    addingWaypoint = true
                    showSearch = true
                } label: {
                    journeyActionLabel("Przystanek", symbol: "plus.circle")
                }
                .disabled(engine.state.waypoints.count >= 8)
            }
            #if os(macOS)
            Button {
                engine.showRouteOverview()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    navigationPanelExpanded = false
                }
            } label: {
                journeyActionLabel("Cała trasa", symbol: "map")
            }
            #endif
            if supportsActiveTripRoadPreferences {
                Button {
                    routingDraft = engine.state.routingPreferences
                    showRouteSettings = true
                } label: {
                    journeyActionLabel(engine.state.transportMode == .parkRide ? "Opcje jazdy" : "Opcje trasy",
                                       symbol: "slider.horizontal.3")
                }
            }
            journeyMapLayersMenu
            if supportsActiveTripTrafficDetails {
                Button { showTrafficDetails = true } label: {
                    journeyActionLabel("Ruch na żywo", symbol: "car.side")
                }
            }
            if supportsActiveTripDestinationParking {
                Button { presentNearby(.parking, nearDestination: true) } label: {
                    journeyActionLabel("Parking na miejscu", symbol: "parkingsign.circle")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var desktopJourneyPanel: some View {
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
                    metric(value: arrivalTime(engine.state.progress?.remainingTime ?? 0), caption: navigationArrivalCaption)
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
                        Text(activeJourneyTargetText)
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
                journeyActionsGrid
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

    private func transitTimeSourceLabel(for leg: JourneyLeg, in journey: Journey) -> String {
        guard leg.realTime || hasLiveTransitUpdate(for: leg) else { return "wg rozkładu" }
        switch journey.realtimeFreshness {
        case .live: return "Na żywo"
        case .degraded: return "Realtime opóźnione"
        case .stale: return "Realtime nieświeże"
        case .unavailable: return "Realtime bez potwierdzonej świeżości"
        }
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
#if os(iOS)
        arrivalSuccessCard
#else
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.green, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(arrivalTitle)
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
                    metric(value: distance(trip.distanceMeters), caption: arrivalDistanceCaption)
                    Spacer()
                    metric(value: time(trip.duration), caption: "czas")
                    Spacer()
                    metric(value: arrivalSummaryMetric.value, caption: arrivalSummaryMetric.caption)
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
#endif
    }

    private var arrivalSuccessCard: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 44, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: 44),
            style: .continuous)

        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.48))
                .frame(width: 38, height: 4)
                .padding(.top, 8)

            ArrivalCelebration()
                .frame(height: 91)
                .padding(.top, 1)

            VStack(spacing: 2) {
                Text(arrivalTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(engine.state.lastTrip?.destination.name ?? engine.state.destination?.name ?? "Podróż zakończona")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            }
            .padding(.top, -3)

            HStack(spacing: 0) {
                arrivalMetric(symbol: engine.state.transportMode.symbol,
                              value: engine.state.lastTrip.map { distance($0.distanceMeters) } ?? "—",
                              caption: arrivalDistanceCaption)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 1, height: 45)
                arrivalMetric(symbol: "clock",
                              value: engine.state.lastTrip.map { time($0.duration) } ?? "—",
                              caption: "czas")
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 1, height: 45)
                arrivalMetric(symbol: arrivalSummaryMetric.symbol,
                              value: arrivalSummaryMetric.value,
                              caption: arrivalSummaryMetric.caption)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 76)
            .modifier(NavigationGlassSurface(radius: 19))
            .padding(.horizontal, 16)
            .padding(.top, 10)

            HStack(spacing: 7) {
                Button {
                    if !isDestinationFavorite, let destination = engine.state.destination {
                        localData.add(destination, kind: .favorite)
                    }
                } label: {
                    arrivalActionLabel(symbol: isDestinationFavorite ? "checkmark" : "star",
                                       title: isDestinationFavorite ? "Zapisano" : "Zapisz\nmiejsce")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDestinationFavorite ? "Miejsce zapisane w ulubionych" : "Zapisz miejsce")

                arrivalShareAction

                Button {
                    engine.stop()
                } label: {
                    arrivalActionLabel(symbol: "paperplane.fill", title: "Zakończ", primary: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zakończ nawigację")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .modifier(NavigationGlassPanelSurface(shape: shape))
    }

    private var arrivalShareAction: some View {
        Group {
            if let url = arrivalShareURL {
                ShareLink(item: url) {
                    arrivalActionLabel(symbol: "square.and.arrow.up", title: "Udostępnij\ntrasę")
                }
            } else {
                arrivalActionLabel(symbol: "square.and.arrow.up", title: "Udostępnij\ntrasę")
                    .opacity(0.55)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Udostępnij trasę")
    }

    private func arrivalMetric(symbol: String, value: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(height: 19)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func arrivalActionLabel(symbol: String, title: String, primary: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 22)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 55)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(primary ? Color(red: 0.05, green: 0.49, blue: 0.97) : Color.white.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(primary ? 0.12 : 0.08), lineWidth: 1)
        }
        .modifier(NavigationGlassSurface(radius: 18, interactive: true))
    }

    private var searchSheet: some View {
        DestinationSearchSheet(
            engine: engine,
            selectingRouteOrigin: selectingRouteOriginInSearch,
            places: localData.places,
            recentDestinations: recentDestinations,
            recentSearches: localData.searches,
            quickEstimates: quickETAEstimates,
            pointSelectionHint: pointSelectionHint,
            onRemoveFavorite: { removeFavorite(for: $0) },
            onRenameFavorite: { renameFavorite(for: $0, to: $1) },
            onRefreshContactPlace: { contactReference, destination in
                localData.updateContactPlace(contactReference, destination: destination)
            },
            onSavePlaceAs: { destination, kind, contactIdentifier in
                localData.add(destination, kind: kind, sourceContactIdentifier: contactIdentifier)
            },
            onSaveCurrentLocation: { kind in
                guard let coordinate = engine.state.location?.coordinate else { return false }
                let address = await GUGiKAddressProvider().reverseGeocode(coordinate)
                let destination = Destination(name: kind.title, coordinate: coordinate, address: address)
                return localData.add(destination, kind: kind)
            },
            onChooseOnMap: { kind in beginSavedPlaceMapSelection(as: kind) },
            onSelectTransitStop: { stop in
                showSearch = false
                openTransitStop(stop)
            },
            onSelectTransitLine: { line in
                showSearch = false
                openTransitLine(line)
            },
            onSelectDestination: { destination, asStop in
                if selectingRouteOriginInSearch {
                    guard !asStop else { return }
                    applyRouteOrigin(destination, source: destination.poi == nil ? .search : .poi)
                } else if addingWaypoint || asStop {
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
        let mode = engine.state.transportMode
        return NavigationStack {
            Form {
                if supportsActiveTripRoadPreferences {
                    Section(mode == .parkRide ? "Odcinek samochodowy" : "Preferencje trasy") {
                        Toggle("Unikaj dróg płatnych", isOn: $routingDraft.avoidTolls)
                        Toggle("Unikaj autostrad", isOn: $routingDraft.avoidHighways)
                        Toggle("Unikaj promów", isOn: $routingDraft.avoidFerries)
                        Toggle("Unikaj dróg gruntowych", isOn: $routingDraft.avoidUnpaved)
                    }
                }

                if mode == .car {
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
                }

                Section {
                    Text("Zmiany zostaną użyte przy kolejnym przeliczeniu odcinka samochodowego.")
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
                                           systemImage: "heart",
                                           description: Text("Dodaj Dom, Pracę albo ulubiony adres z wyszukiwarki."))
                }

                let quickPlaces = [PlaceKind.home, .work].compactMap { kind in
                    localData.places.first(where: { $0.kind == kind })
                }
                if !quickPlaces.isEmpty {
                    Section("Szybkie miejsca") {
                        ForEach(quickPlaces) { place in
                            favoritePlaceRow(place)
                        }
                    }
                }

                let pinnedFavorites = localData.places.filter { $0.kind == .favorite && $0.isPinned }
                if !pinnedFavorites.isEmpty {
                    Section("Przypięte ulubione") {
                        ForEach(pinnedFavorites) { place in
                            favoritePlaceRow(place)
                        }
                    }
                }

                let otherFavorites = localData.places.filter { $0.kind == .favorite && !$0.isPinned }
                if !otherFavorites.isEmpty {
                    Section("Pozostałe ulubione") {
                        ForEach(otherFavorites) { place in
                            favoritePlaceRow(place)
                        }
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
            .sheet(item: $editingSavedPlace) { place in
                SavedPlaceEditorSheet(place: place) { name, icon, isPinned in
                    localData.updatePlace(place.id, customName: name, icon: icon, isPinned: isPinned)
                } onRemove: {
                    localData.removePlace(place.id)
                }
            }
            .confirmationDialog("Usunąć to miejsce z Ulubionych?",
                                isPresented: $showPlaceRemovalConfirmation,
                                titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    if let placePendingRemoval { localData.removePlace(placePendingRemoval.id) }
                    placePendingRemoval = nil
                }
                Button("Anuluj", role: .cancel) { placePendingRemoval = nil }
            } message: {
                Text(placePendingRemoval?.displayName ?? "")
            }
        }
    }

    private func favoritePlaceRow(_ place: SavedPlace) -> some View {
        HStack(spacing: 12) {
            Button {
                showFavorites = false
                selectDestination(place.navigationDestination, recordSearch: false)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: place.icon.symbol)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.displayName).foregroundStyle(.primary)
                        Text(place.sourceContactIdentifier != nil
                             ? "Z Kontaktów · \(place.destination.address ?? place.kind.title)"
                             : (place.destination.address ?? place.kind.title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let estimate = quickETAEstimates[place.id.uuidString] {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(estimate.minutes) min")
                            Text(distance(estimate.distanceMeters))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingSavedPlace = place
            } label: {
                Image(systemName: "pencil")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edytuj nazwę miejsca \(place.displayName)")

            Menu {
                if place.kind == .favorite {
                    Button(place.isPinned ? "Odepnij od wyszukiwarki" : "Przypnij pod wyszukiwarką",
                           systemImage: place.isPinned ? "pin.slash" : "pin") {
                        localData.updatePlace(place.id, customName: place.customName,
                                              isPinned: !place.isPinned)
                    }
                }
                Button("Usuń", systemImage: "trash", role: .destructive) {
                    placePendingRemoval = place
                    showPlaceRemovalConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Opcje miejsca \(place.displayName)")
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
                                    Task { await engine.previewNewTrip(item.destination) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.destination.name).foregroundStyle(.primary)
                                        Text(item.searchedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button("Zapisz do ulubionych", systemImage: "heart") {
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
                                Button("Zapisz cel do ulubionych", systemImage: "heart") {
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

    private var savedPlaceShortcuts: [PlaceShortcut] {
        var shortcuts: [PlaceShortcut] = []

        for kind in [PlaceKind.home, .work, .favorite] {
            for place in localData.places where place.kind == kind && (kind != .favorite || place.isPinned) {
                guard !shortcuts.contains(where: { $0.destination.coordinate == place.destination.coordinate }) else { continue }
                shortcuts.append(PlaceShortcut(
                    id: place.id.uuidString,
                    title: place.displayName,
                    symbol: place.icon.symbol,
                    destination: place.navigationDestination,
                    isRecent: false,
                    estimatedMinutes: quickETAEstimates[place.id.uuidString]?.minutes,
                    estimatedDistanceMeters: quickETAEstimates[place.id.uuidString]?.distanceMeters
                ))
            }
        }
        return Array(shortcuts.prefix(6))
    }

    private var recentPlaceShortcuts: [PlaceShortcut] {
        var candidates: [(date: Date, shortcut: PlaceShortcut)] = []
        for search in localData.searches {
            candidates.append((search.searchedAt, PlaceShortcut(
                id: "recent-\(search.id.uuidString)",
                title: search.destination.name,
                symbol: "clock.arrow.circlepath",
                destination: search.destination,
                isRecent: true
            )))
        }

        for trip in localData.trips {
            candidates.append((trip.endedAt, PlaceShortcut(
                id: "trip-\(trip.id.uuidString)",
                title: trip.destination.name,
                symbol: "clock.arrow.circlepath",
                destination: trip.destination,
                isRecent: true
            )))
        }

        var shortcuts: [PlaceShortcut] = []
        for candidate in candidates.sorted(by: { $0.date > $1.date }) {
            guard shortcuts.count < 6 else { break }
            guard !shortcuts.contains(where: {
                $0.destination.coordinate == candidate.shortcut.destination.coordinate
            }) else { continue }
            shortcuts.append(candidate.shortcut)
        }
        return shortcuts
    }

    private var quickETADestinationFingerprint: String {
        savedPlaceShortcuts.prefix(6).compactMap { shortcut in
            localData.places.first(where: { $0.id.uuidString == shortcut.id })
        }.map { place in
            let coordinate = place.destination.coordinate
            return "\(place.id.uuidString):\(coordinate.latitude),\(coordinate.longitude)"
        }.joined(separator: "|")
    }

    private func refreshQuickDestinationETAs() async {
        guard !quickETAInFlight, let origin = engine.state.location?.coordinate else { return }
        let priorityDestinations = Array(savedPlaceShortcuts.prefix(6))
        guard !priorityDestinations.isEmpty else {
            quickETAEstimates = [:]
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
        quickETAEstimates = [:]
        defer { quickETAInFlight = false }

        var estimates: [String: PlaceRouteEstimate] = [:]
        for shortcut in priorityDestinations.prefix(2) {
            guard let estimate = await engine.estimatedCarRouteEstimate(to: shortcut.destination) else { continue }
            estimates[shortcut.id] = estimate
        }
        quickETAEstimates = estimates
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
        selectingRouteOriginInSearch = false
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

    private func selectMapCoordinate(_ coordinate: Coordinate) {
        let destination = Destination(name: "Wybrany punkt", coordinate: coordinate)
        selectDestination(destination, recordSearch: false)
        Task {
            guard let address = await GUGiKAddressProvider().reverseGeocode(coordinate),
                  let current = engine.state.destination,
                  current.id == destination.id else { return }
            engine.state.destination = Destination(id: current.id, name: current.name,
                                                   coordinate: current.coordinate, address: address)
        }
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
        let activeWaypoint = engine.state.waypoints.first
        let activeDestination = engine.state.destination
        let activeNavigationTarget = engine.state.navigationTarget?.coordinate
        mapPlaceEstimateTask = Task {
            do {
                let destinationCoordinate: Coordinate
                if result.isPOI {
                    destinationCoordinate = await POIAccessResolver.shared.resolve(
                        for: result.navigationDestination, mode: mode)?.coordinate
                        ?? result.destination.coordinate
                } else {
                    destinationCoordinate = result.destination.coordinate
                }
                let provider = ValhallaRouteProvider(endpoint: endpoint)
                var updated = selected
                if navigationActive {
                    let routeTarget: Coordinate?
                    if let activeWaypoint {
                        if activeWaypoint.poi != nil {
                            routeTarget = await POIAccessResolver.shared.resolve(for: activeWaypoint, mode: mode)?.coordinate
                                ?? activeWaypoint.coordinate
                        } else {
                            routeTarget = activeWaypoint.coordinate
                        }
                    } else if activeDestination?.poi != nil {
                        routeTarget = activeNavigationTarget ?? activeDestination?.coordinate
                    } else {
                        routeTarget = activeDestination?.coordinate
                    }
                    guard let routeTarget else {
                        guard selectedMapPlaces.first?.id == requestID else { return }
                        updated.travelEstimateStatus = .unavailable
                        selectedMapPlaces = [updated]
                        return
                    }
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
        Task { await engine.previewNewTrip(trip.destination) }
    }

    private func saveCurrentPlace(as kind: PlaceKind) {
        guard let destination = engine.state.destination else { return }
        let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        localData.add(destination, kind: kind, customName: name.isEmpty ? nil : name)
        favoriteName = ""
        isSavingPlace = false
    }

    private func toggleDestinationFavorite() {
        guard let destination = engine.state.destination else { return }
        if isDestinationFavorite {
            showFavoriteRemovalConfirmation = true
            return
        }
        guard localData.add(destination, kind: .favorite) else { return }
        animateFavoritePulse()
    }

    private func animateFavoritePulse() {
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

    private func removeFavorite(for destination: Destination) -> Bool {
        guard let place = localData.places.first(where: {
            $0.kind == .favorite && $0.destination.coordinate == destination.coordinate
        }) else { return false }
        localData.removePlace(place.id)
        return !localData.places.contains { $0.id == place.id }
    }

    private func renameFavorite(for destination: Destination, to name: String) -> Bool {
        guard let place = localData.places.first(where: {
            $0.kind == .favorite && $0.destination.coordinate == destination.coordinate
        }) else { return false }
        return localData.updatePlace(place.id, customName: name)
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

private struct ArrivalCelebration: View {
    private let green = Color(red: 0.16, green: 0.82, blue: 0.36)
    private let pieces = [
        ArrivalConfettiPiece(id: 0, x: -128, y: -8, width: 10, height: 4, angle: -52, color: Color(red: 0.12, green: 0.61, blue: 1)),
        ArrivalConfettiPiece(id: 1, x: -106, y: 25, width: 9, height: 4, angle: 38, color: Color(red: 0.97, green: 0.72, blue: 0.20)),
        ArrivalConfettiPiece(id: 2, x: -88, y: -20, width: 9, height: 4, angle: 66, color: Color(red: 0.97, green: 0.31, blue: 0.58)),
        ArrivalConfettiPiece(id: 3, x: -65, y: 19, width: 8, height: 4, angle: -40, color: Color(red: 0.13, green: 0.80, blue: 0.43)),
        ArrivalConfettiPiece(id: 4, x: -41, y: -37, width: 9, height: 4, angle: 64, color: Color(red: 0.12, green: 0.61, blue: 1)),
        ArrivalConfettiPiece(id: 5, x: -21, y: 28, width: 8, height: 4, angle: 26, color: Color(red: 0.97, green: 0.72, blue: 0.20)),
        ArrivalConfettiPiece(id: 6, x: 21, y: -34, width: 8, height: 4, angle: 72, color: Color(red: 0.13, green: 0.80, blue: 0.43)),
        ArrivalConfettiPiece(id: 7, x: 45, y: 31, width: 9, height: 4, angle: -43, color: Color(red: 0.97, green: 0.31, blue: 0.58)),
        ArrivalConfettiPiece(id: 8, x: 66, y: -15, width: 9, height: 4, angle: 35, color: Color(red: 0.12, green: 0.61, blue: 1)),
        ArrivalConfettiPiece(id: 9, x: 88, y: 17, width: 10, height: 4, angle: -62, color: Color(red: 0.97, green: 0.72, blue: 0.20)),
        ArrivalConfettiPiece(id: 10, x: 108, y: -29, width: 9, height: 4, angle: 58, color: Color(red: 0.13, green: 0.80, blue: 0.43)),
        ArrivalConfettiPiece(id: 11, x: 130, y: 9, width: 10, height: 4, angle: -18, color: Color(red: 0.97, green: 0.31, blue: 0.58))
    ]

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Capsule()
                    .fill(piece.color)
                    .frame(width: piece.width, height: piece.height)
                    .rotationEffect(.degrees(piece.angle))
                    .offset(x: piece.x, y: piece.y)
            }

            Circle()
                .stroke(green.opacity(0.13), lineWidth: 13)
                .frame(width: 96, height: 96)
            Circle()
                .stroke(green.opacity(0.24), lineWidth: 8)
                .frame(width: 75, height: 75)
            Circle()
                .fill(green)
                .frame(width: 52, height: 52)
                .shadow(color: green.opacity(0.42), radius: 11, y: 2)
            Image(systemName: "checkmark")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

private struct ArrivalConfettiPiece: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let angle: Double
    let color: Color
}

private struct NearbySearchRequest: Identifiable {
    let id = UUID()
    let category: NearbyPlaceCategory
    let nearDestination: Bool
}

private enum DestinationSearchScope: String, CaseIterable, Identifiable {
    case places = "Miejsca"
    case transit = "Kolej i MPK"

    var id: String { rawValue }
}

private struct DestinationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let engine: NavigationEngine
    let selectingRouteOrigin: Bool
    let places: [SavedPlace]
    let recentDestinations: [Destination]
    let recentSearches: [SearchHistoryEntry]
    let quickEstimates: [String: PlaceRouteEstimate]
    let pointSelectionHint: String
    let onRemoveFavorite: (Destination) -> Bool
    let onRenameFavorite: (Destination, String) -> Bool
    let onRefreshContactPlace: (String, Destination) -> Bool
    let onSavePlaceAs: (Destination, PlaceKind, String?) -> Bool
    let onSaveCurrentLocation: (PlaceKind) async -> Bool
    let onChooseOnMap: (PlaceKind) -> Void
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
    @State private var savingKind: PlaceKind?
    @State private var savedPlaceNotice: String?
    @State private var saveAlertMessage = ""
    @State private var showSaveAlert = false
    @State private var contactsAccessStatus = ContactsAccessStatus.current()
    @State private var isRequestingContactsAccess = false
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var localMatches: [LocalSearchSuggestion] {
        let needle = normalized(trimmedQuery)
        guard !needle.isEmpty else { return [] }

        var matches: [LocalSearchSuggestion] = []
        for place in places where normalized(place.displayName).contains(needle) {
            append(place.navigationDestination, subtitle: place.kind.title, symbol: place.icon.symbol, to: &matches)
        }
        for destination in recentDestinations where normalized(destination.name).contains(needle) {
            append(destination, subtitle: selectingRouteOrigin ? "Ostatnie miejsce" : "Ostatni cel",
                   symbol: "clock.arrow.circlepath", to: &matches)
        }
        for item in recentSearches where normalized(item.destination.name).contains(needle) {
            append(item.destination, subtitle: "Ostatnie wyszukiwanie", symbol: "magnifyingglass", to: &matches)
        }
        return Array(matches.prefix(5))
    }

    private var visibleRemoteResults: [SearchResult] {
        // Contact destinations stay grouped separately from place results.
        results.filter { !$0.isContact }
    }

    private var visibleContactResults: [SearchResult] {
        results.filter(\.isContact)
    }

    private var contactResultActionTitle: String {
        if savingKind != nil { return "Zapisz" }
        if selectingRouteOrigin { return "Start" }
        if alongRoute || QueryClassifier().classify(query).alongRoute { return "Dodaj" }
        return "Trasa"
    }

    private var contactResultActionSymbol: String {
        if savingKind != nil { return "plus" }
        if selectingRouteOrigin { return "location" }
        if alongRoute || QueryClassifier().classify(query).alongRoute { return "plus" }
        return "arrow.turn.down.right"
    }

    private var contactResultActionHint: String {
        if let savingKind { return "Zapisz ten adres jako \(savingKind.title.lowercased())." }
        if selectingRouteOrigin { return "Użyj tego adresu jako punktu startowego." }
        if alongRoute || QueryClassifier().classify(query).alongRoute {
            return "Dodaj ten adres jako przystanek do trasy."
        }
        return "Wyznacz trasę do tego adresu kontaktu."
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
                if let savedPlaceNotice {
                    Label(savedPlaceNotice, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                if !selectingRouteOrigin && searchScope == .places && trimmedQuery.isEmpty {
                    quickPlacesSection
                }
                if !selectingRouteOrigin {
                    Picker("Rodzaj wyszukiwania", selection: $searchScope) {
                        ForEach(DestinationSearchScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: searchScope) { _, _ in startSearch(query) }
                }

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
                                contactsResultsSection
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
            .navigationTitle(selectingRouteOrigin ? "Skąd zaczynasz?" :
                             savingKind.map { "Dodaj \($0.title.lowercased())" } ?? "Szukaj")
            .alert("Nie udało się dodać miejsca", isPresented: $showSaveAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(saveAlertMessage)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { dismiss() }
                }
            }
            .onAppear {
                contactsAccessStatus = ContactsAccessStatus.current()
                query = ""
                if selectingRouteOrigin {
                    searchScope = .places
                    alongRoute = false
                }
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
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !isRequestingContactsAccess else { return }
                let previousStatus = contactsAccessStatus
                contactsAccessStatus = ContactsAccessStatus.current()
                if previousStatus != contactsAccessStatus, !trimmedQuery.isEmpty {
                    startSearch(query)
                }
            }
            .onDisappear {
                searchTask?.cancel()
                transitSearchTask?.cancel()
                let closingSearchID = currentSearchID
                Task { @MainActor in
                    await Task.yield()
                    guard currentSearchID == closingSearchID else { return }
                    engine.state.searchResults = []
                }
            }
        }
    }

    private func startSearch(_ value: String, includeUUGFallback: Bool = false) {
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
                let routeTarget: Coordinate?
                if let waypoint = state.waypoints.first {
                    if waypoint.poi != nil {
                        routeTarget = await POIAccessResolver.shared.resolve(for: waypoint,
                                                                              mode: state.transportMode)?.coordinate
                            ?? waypoint.coordinate
                    } else {
                        routeTarget = waypoint.coordinate
                    }
                } else if state.destination?.poi != nil {
                    routeTarget = state.navigationTarget?.coordinate ?? state.destination?.coordinate
                } else {
                    routeTarget = state.destination?.coordinate
                }
                let context = SearchContext(origin: state.location?.coordinate, area: searchArea,
                                            route: remainingRoute,
                                            routeTarget: routeTarget,
                                            mode: state.transportMode, preferences: state.routingPreferences,
                                            localDestinations: places.map(\.navigationDestination) + recentSearches.map(\.destination))
                let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "https://valhalla1.openstreetmap.de")!
                let effectiveQuery = alongRoute && !QueryClassifier.normalize(trimmed).hasSuffix(" po trasie") ? trimmed + " po trasie" : trimmed
                let found = try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint))
                    .search(effectiveQuery, context: context, includeUUGFallback: includeUUGFallback) { partial in
                    guard !Task.isCancelled, currentSearchID == requestID else { return }
                    results = partial
                    engine.state.searchResults = results
                }
                guard !Task.isCancelled, currentSearchID == requestID else { return }
                results = found
                engine.state.searchResults = results
                isSearching = false
                didCompleteSearchWithNoResults = found.isEmpty
                var didRefreshSavedContact = false
                for result in found {
                    guard let contactReference = contactIdentifier(for: result),
                          places.contains(where: { $0.sourceContactIdentifier == contactReference }) else { continue }
                    if onRefreshContactPlace(contactReference, result.navigationDestination) {
                        didRefreshSavedContact = true
                    }
                }
                if didRefreshSavedContact {
                    savedPlaceNotice = "Zaktualizowano zapisany adres z Kontaktów."
                }
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
            TextField(searchScope == .places
                      ? (savingKind.map { "Adres lub miejsce dla \($0.title.lowercased())" }
                         ?? (selectingRouteOrigin ? "Adres, miejsce lub kontakt" : "Adres, miejsce, marka lub kontakt"))
                      : "Linia lub przystanek", text: $query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: query) { _, value in startSearch(value) }
                .onSubmit { startSearch(query, includeUUGFallback: true) }

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

    private var quickPlacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SZYBKIE MIEJSCA")
                    .font(.caption.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                addPlaceMenu
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach([PlaceKind.home, .work], id: \.self) { kind in
                        if let place = places.first(where: { $0.kind == kind }) {
                            quickPlaceCard(place)
                        } else {
                            Button {
                                beginAddressSave(as: kind)
                            } label: {
                                Label("Dodaj \(kind.title.lowercased())", systemImage: "plus")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 13)
                                    .frame(minHeight: 62)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 15))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }

                    ForEach(pinnedFavoritePlaces) { place in
                        quickPlaceCard(place)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

        }
    }

    private var pinnedFavoritePlaces: [SavedPlace] {
        var seen = Set<String>()
        return places.filter { place in
            guard place.kind == .favorite, place.isPinned else { return false }
            let coordinate = place.destination.coordinate
            let key = "\(coordinate.latitude),\(coordinate.longitude)"
            return seen.insert(key).inserted
        }.prefix(6).map { $0 }
    }

    private func quickPlaceCard(_ place: SavedPlace) -> some View {
        Button {
            handleDestination(place.navigationDestination, contactIdentifier: place.sourceContactIdentifier)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: place.icon.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let estimate = quickEstimates[place.id.uuidString] {
                        Text("\(estimate.minutes) min · \(formattedRouteDistance(estimate.distanceMeters))")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(place.destination.address ?? place.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: place.kind == .favorite ? 145 : 158, minHeight: 62, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.045)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pokaż miejsce \(place.displayName)")
    }

    private var addPlaceMenu: some View {
        Menu {
            Menu("Wyszukaj adres", systemImage: "magnifyingglass") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) { beginAddressSave(as: kind) }
                }
            }
            Menu("Moja lokalizacja", systemImage: "location.fill") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) { saveCurrentLocation(as: kind) }
                }
            }
            Menu("Wybierz na mapie", systemImage: "mappin.and.ellipse") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) {
                        onChooseOnMap(kind)
                        dismiss()
                    }
                }
            }
            Menu("Adres kontaktu", systemImage: "person.crop.circle") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) { beginContactSave(as: kind) }
                }
            }
        } label: {
            Label("Dodaj", systemImage: "plus")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11)
                .frame(minHeight: 34)
                .background(Color.accentColor.opacity(0.09), in: Capsule())
        }
        .accessibilityLabel("Dodaj zapisane miejsce")
    }

    private func beginAddressSave(as kind: PlaceKind) {
        savingKind = kind
        savedPlaceNotice = nil
        isSearchFocused = true
    }

    private func beginContactSave(as kind: PlaceKind) {
        beginAddressSave(as: kind)
        if contactsAccessStatus == .notDetermined {
            requestContactsAccess()
        } else if !contactsAccessStatus.canReadContacts {
            saveAlertMessage = "Włącz dostęp do Kontaktów w Ustawieniach, aby wyszukać zapisany adres."
            showSaveAlert = true
        }
    }

    private func saveCurrentLocation(as kind: PlaceKind) {
        Task {
            let saved = await onSaveCurrentLocation(kind)
            if saved {
                withAnimation(.easeInOut(duration: 0.18)) {
                    savedPlaceNotice = "Zapisano \(kind.title.lowercased()) z bieżącej lokalizacji."
                }
            } else {
                saveAlertMessage = "Bieżąca lokalizacja jest niedostępna. Spróbuj ponownie, gdy mapa ustali Twoją pozycję."
                showSaveAlert = true
            }
        }
    }

    private func formattedRouteDistance(_ meters: Double) -> String {
        let kilometers = NumberFormatter()
        kilometers.locale = Locale(identifier: "pl_PL")
        kilometers.minimumFractionDigits = 1
        kilometers.maximumFractionDigits = 1
        return "\(kilometers.string(from: NSNumber(value: meters / 1_000)) ?? "—") km"
    }

    @ViewBuilder
    private var contactsResultsSection: some View {
        if !visibleContactResults.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Kontakty")
                ForEach(visibleContactResults, id: \.placeIdentity.cacheKey) { result in
                    Button {
                        selectResult(result)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 38, height: 38)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.destination.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(result.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if let summary = result.travelSummary {
                                    Text(summary)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Label(contactResultActionTitle, systemImage: contactResultActionSymbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(contactResultActionHint)
                }
            }
        } else if !trimmedQuery.isEmpty && contactsAccessStatus != .authorized {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Kontakty")
                if contactsAccessStatus == .notDetermined {
                    Button(action: requestContactsAccess) {
                        Label("Szukaj w Kontaktach", systemImage: "person.crop.circle.badge.plus")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    Text("NaviAstra użyje zapisanych nazw i adresów, aby znaleźć cel nawigacji.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(contactsAccessStatus == .restricted
                         ? "Dostęp do Kontaktów jest ograniczony przez system."
                         : "Dostęp do Kontaktów jest wyłączony. Możesz go zmienić w Ustawieniach systemowych.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func requestContactsAccess() {
        Task {
            isRequestingContactsAccess = true
            let status = await ContactsSearchProvider().requestAccess()
            isRequestingContactsAccess = false
            contactsAccessStatus = status
            if contactsAccessStatus.canReadContacts {
                startSearch(query)
            }
        }
    }

    @ViewBuilder
    private var savedDestinations: some View {
        if !places.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Zapisane miejsca")
                ForEach(places.prefix(5)) { place in
                    destinationRow(place.navigationDestination,
                                   subtitle: place.destination.address ?? place.kind.title,
                                   symbol: place.icon.symbol)
                }
            }
        }

        if !recentDestinations.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Ostatnie")
                ForEach(recentDestinations) { destination in
                    destinationRow(destination,
                                   subtitle: selectingRouteOrigin ? "Ostatnie miejsce" : "Ostatni cel",
                                   symbol: "clock.arrow.circlepath")
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
            ContentUnavailableView(selectingRouteOrigin ? "Wyszukaj punkt startowy" : "Wpisz cel podróży",
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
                        onSave: {
                            onSavePlaceAs(result.navigationDestination, .favorite,
                                          contactIdentifier(for: result))
                        },
                        onRemove: { onRemoveFavorite(result.destination) },
                        onRename: { onRenameFavorite(result.destination, $0) },
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
        if let kind = savingKind {
            saveDestination(result.navigationDestination, as: kind,
                            contactIdentifier: contactIdentifier(for: result))
            return
        }
        let asStop = alongRoute || QueryClassifier().classify(query).alongRoute
        onSelectDestination(result.navigationDestination, asStop)
        if selectingRouteOrigin { return }
        if !asStop, QueryClassifier().classify(query).intent == .coordinates,
           engine.state.destination?.id == result.destination.id {
            let destinationID = result.destination.id
            Task {
                guard let address = await GUGiKAddressProvider().reverseGeocode(result.destination.coordinate),
                      let current = engine.state.destination,
                      current.id == destinationID else { return }
                engine.state.destination = Destination(id: current.id, name: current.name,
                                                       coordinate: current.coordinate, address: address)
            }
            return
        }
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
            handleDestination(destination, contactIdentifier: nil)
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

    private func handleDestination(_ destination: Destination, contactIdentifier: String?) {
        guard let kind = savingKind else {
            onSelectDestination(destination, false)
            return
        }
        saveDestination(destination, as: kind, contactIdentifier: contactIdentifier)
    }

    private func saveDestination(_ destination: Destination, as kind: PlaceKind,
                                 contactIdentifier: String?) {
        guard onSavePlaceAs(destination, kind, contactIdentifier) else {
            saveAlertMessage = "Miejsce nie zostało zapisane na urządzeniu. Spróbuj ponownie."
            showSaveAlert = true
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            savingKind = nil
            savedPlaceNotice = "Dodano do \(kind.title)."
        }
        query = ""
        results = []
        searchError = nil
        didCompleteSearchWithNoResults = false
        engine.state.searchResults = []
        isSearchFocused = false
    }

    private func contactIdentifier(for result: SearchResult) -> String? {
        guard result.isContact, let providerID = result.providerID,
              providerID.hasPrefix("contact-") else { return nil }
        return providerID
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
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
    var estimatedDistanceMeters: Double? = nil
}

private struct SavedPlaceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let place: SavedPlace
    let onSave: (String, SavedPlaceIcon, Bool) -> Void
    let onRemove: () -> Void

    @State private var name: String
    @State private var icon: SavedPlaceIcon
    @State private var isPinned: Bool
    @State private var confirmingRemoval = false

    init(place: SavedPlace, onSave: @escaping (String, SavedPlaceIcon, Bool) -> Void,
         onRemove: @escaping () -> Void) {
        self.place = place
        self.onSave = onSave
        self.onRemove = onRemove
        _name = State(initialValue: place.customName ?? (place.kind == .favorite ? place.destination.name : ""))
        _icon = State(initialValue: place.icon)
        _isPinned = State(initialValue: place.isPinned)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(place.kind == .favorite ? "Nazwa ulubionego miejsca" : "Nazwa miejsca") {
                    TextField("Wpisz nazwę", text: $name)
                }

                Section("Szczegóły miejsca") {
                    LabeledContent("Adres", value: place.destination.address ?? "Zapisane współrzędne")
                        .lineLimit(2)
                    if place.sourceContactIdentifier != nil {
                        Label("Adres powiązany z Kontaktami", systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if place.kind == .favorite {
                    Section("Ikona") {
                        HStack(spacing: 0) {
                            ForEach(SavedPlaceIcon.allCases) { option in
                                Button {
                                    icon = option
                                } label: {
                                    Image(systemName: option.symbol)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(icon == option ? Color.accentColor : Color.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                        .background(icon == option ? Color.accentColor.opacity(0.1) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.title)
                                .accessibilityAddTraits(icon == option ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    Section("Ikona") {
                        Label(place.kind.title, systemImage: place.kind.defaultIcon.symbol)
                            .foregroundStyle(.secondary)
                    }
                }

                if place.kind == .favorite {
                    Section {
                        Toggle("Przypięte pod wyszukiwarką", isOn: $isPinned)
                    } footer: {
                        Text("Przypięte miejsca pojawiają się w szybkich skrótach.")
                    }
                }

                Section {
                    Button("Usuń miejsce", role: .destructive) { confirmingRemoval = true }
                }
            }
            .navigationTitle("Edytuj miejsce")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        onSave(name, icon, isPinned)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Usunąć to miejsce z Ulubionych?", isPresented: $confirmingRemoval,
                                titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Button("Anuluj", role: .cancel) { }
            } message: {
                Text(place.displayName)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
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

/// A shared translucent shell for the route preview, active trip, and arrival panels.
private struct NavigationGlassPanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: UnevenRoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content
                    .background(Color(red: 0.045, green: 0.075, blue: 0.12).opacity(0.98), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            } else if #available(iOS 26.0, macOS 26.0, *) {
                content
                    .background(shape.fill(Color(red: 0.045, green: 0.075, blue: 0.12).opacity(0.18)))
                    .glassEffect(.regular.interactive(), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            } else {
                content
                    .background {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(
                                LinearGradient(
                                    colors: [Color(red: 0.12, green: 0.18, blue: 0.26).opacity(0.44),
                                             Color(red: 0.045, green: 0.075, blue: 0.12).opacity(0.58)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                        }
                    }
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: -8)
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
        let candidates = [min(140, maximum), min(360, maximum), maximum]
        var uniqueHeights: [CGFloat] = []
        for candidate in candidates {
            if uniqueHeights.last.map({ abs($0 - candidate) > 1 }) ?? true {
                uniqueHeights.append(candidate)
            }
        }
        return uniqueHeights
    }
    private var selectedDetent: Int { min(max(detent, 0), heights.count - 1) }
    private var detentNames: [String] {
        switch heights.count {
        case 1: ["Zwinięty"]
        case 2: ["Zwinięty", "Rozwinięty"]
        default: ["Zwinięty", "Średni", "Rozwinięty"]
        }
    }
    private var height: CGFloat {
        let baseHeight = heights[selectedDetent] - translation
        let minimumHeight = heights[0]
        let maximumHeight = heights[heights.count - 1]
        return min(maximumHeight, max(minimumHeight, baseHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                let nextDetent = selectedDetent == heights.count - 1
                    ? max(0, selectedDetent - 1)
                    : selectedDetent + 1
                settle(at: nextDetent)
            } label: {
                ZStack {
                    Capsule()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 38, height: 5)
                    Image(systemName: selectedDetent == heights.count - 1 ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 18)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Panel eksploracji")
            .accessibilityValue(detentNames[selectedDetent])
            .accessibilityAdjustableAction { direction in
                settle(at: direction == .increment
                       ? min(heights.count - 1, selectedDetent + 1)
                       : max(0, selectedDetent - 1))
            }
            .highPriorityGesture(DragGesture(minimumDistance: 6)
                .updating($translation) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    let projected = heights[selectedDetent] - value.predictedEndTranslation.height
                    let closest = heights.indices.min {
                        abs(heights[$0] - projected) < abs(heights[$1] - projected)
                    } ?? selectedDetent
                    settle(at: closest)
                })
            ScrollView { content(selectedDetent == 0) }
                .scrollIndicators(.hidden)
        }
        .frame(height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .modifier(NavigationGlassSurface(radius: 30))
        .onChange(of: collapseRequest) { _, _ in settle(at: 0) }
    }

    private func settle(at value: Int) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88)) {
            detent = min(max(value, 0), heights.count - 1)
        }
    }
}
