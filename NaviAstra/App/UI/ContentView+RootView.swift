import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    private var navigationMapScene: MapScene {
        let navigationState = navigationStore.state
        let commands = MapSceneCommands(
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
                    navigationStore.focusMap(on: place.destination.coordinate)
                    updateSavedPlaceMapSelection(place.destination.coordinate)
                } else if selectingRouteOriginOnMap, let place = places.first {
                    navigationStore.focusMap(on: place.destination.coordinate)
                    updatePickedRouteOrigin(place.destination.coordinate)
                } else {
                    presentMapPlaces(places)
                }
            },
            onTransitStopSelect: { openTransitStop($0) },
            onTransitVehicleSelect: { openTransitVehicle($0) },
            onParkedCarSelect: { openParkedCarDetails() },
            onRouteSelect: { routeID in
                guard let route = navigationState.routeOptions.first(where: { $0.id == routeID }) else { return }
                navigationStore.select(route)
            },
            onCyclingPathsStatus: { mapStore.cyclingPathsStatus = $0 },
            onRoadPOIStatus: { mapStore.roadPOIStatus = $0 },
            onTransitViewportChange: { transitStore.updateMapStops(in: $0) },
            onMapPan: {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    routePreviewDetent = .peek
                    destinationExpanded = false
                    navigationPanelDetent = .peek
                    if !placeStore.selectedMapPlaces.isEmpty {
                        selectedMapPlaceDetent = .peek
                    }
                }
                if navigationState.destination == nil {
                    discoveryDrawerCollapseRequest += 1
                }
            },
            onLongPress: { coordinate in
                if savedPlaceMapSelectionKind != nil {
                    navigationStore.focusMap(on: coordinate)
                    updateSavedPlaceMapSelection(coordinate)
                } else if selectingRouteOriginOnMap {
                    navigationStore.focusMap(on: coordinate)
                    updatePickedRouteOrigin(coordinate)
                } else {
                    mapActionCoordinate = coordinate
                    showMapLocationActions = true
                }
            }
        )

        return MapScene(
            navigationState: navigationState,
            energyPolicy: navigationStore.energyPolicy,
            transit: MapSceneTransitData(
                vehicles: navigationState.transitVehicles,
                stops: transitStopsForMap(navigationState.transitStops),
                selectedStopID: selectedTransitStopID,
                selectedRouteID: selectedTransitRouteID,
                selectedTripID: selectedTransitTripID,
                selectedTripStopIDs: transitStopIDsForMap,
                activeStopID: activeTransitStopID,
                alightingStopID: alightingTransitStopID,
                lineCoordinates: transitLineCoordinatesForMap,
                lineColor: selectedTransitLine?.colorHex
            ),
            parkedCar: placeStore.parkedCar,
            settings: navigationMapSettings,
            isSearchPresented: appRouter.sheet == .search,
            routePreviewExpanded: routePreviewExpanded,
            isBottomSheetDragging: isMapBottomSheetDragging,
            viewportPadding: CameraPadding(top: Double(mapHeaderInset), left: 24,
                                           bottom: Double(mapPanelInset), right: 24),
            commands: commands,
            selectedPlace: placeStore.selectedMapPlaces.count == 1 ? placeStore.selectedMapPlaces.first : nil
        )
    }

    @ViewBuilder
    private var transitPreviewBeginRouteOverlay: some View {
        if isTransitRoutePreview && !usesFullBleedNavigationPanel {
            beginRouteButton
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
        }
    }

    private var shouldShowDiscoveryDrawer: Bool {
        let status = navigationStore.state.status
        return status == .idle || (status == .error && navigationStore.state.destination == nil)
    }

    private var isMapBottomSheetExpanded: Bool {
#if os(iOS)
        if !placeStore.selectedMapPlaces.isEmpty { return selectedMapPlaceDetent == .expanded }
        if shouldShowDiscoveryDrawer { return discoverySheetDetent == .expanded }
        if isIOSRoutePlanningPreview { return routePreviewDetent == .expanded }
        if isNavigating { return navigationPanelDetent == .expanded }
#endif
        return false
    }

    private func mapControlStack(in geometry: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                header
#if os(iOS)
                journeyNavigationGuidanceOverlay
#endif
            }
            .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)
            .onGeometryChange(for: CGFloat.self) {
                max(0, $0.frame(in: .global).maxY - geometry.frame(in: .global).minY) +
                    geometry.safeAreaInsets.top + 20
            } action: { mapHeaderInset = $0 }

            if let message = navigationStore.state.errorMessage ?? placeStore.errorMessage {
                errorNotice(message)
                    .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)
            }
            if isNavigating && !isMapBottomSheetExpanded {
                gpsStatusIndicator
                    .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)
            }

            Spacer(minLength: 16)

            if !isMapBottomSheetExpanded {
                mapControl(compact: geometry.size.height < 500)
                    .padding(.horizontal, usesFullBleedNavigationPanel ? 16 : 0)
            }

            navigationMapPanel(in: geometry)
                .overlay(alignment: .topLeading) {
                    cyclingMapAttribution
                        .padding(.leading, 18)
                        .alignmentGuide(.top) { $0[.bottom] + 6 }
                }
                .onGeometryChange(for: CGFloat.self) {
                    max(0, geometry.frame(in: .global).maxY - $0.frame(in: .global).minY) +
                        geometry.safeAreaInsets.bottom + 12
                } action: { mapPanelInset = $0 }
        }
        .frame(width: min(560, max(0, geometry.size.width - (usesFullBleedNavigationPanel ? 0 : 32))))
        .padding(.horizontal, usesFullBleedNavigationPanel ? 0 : 16)
        .padding(.top, 8)
        .padding(.bottom, usesFullBleedNavigationPanel ? -geometry.safeAreaInsets.bottom : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: navigationStore.state.route?.id) { _, _ in
            journeyGuidanceExpanded = false
            currentStepExpandedOverride = nil
            routePlanningDetailsExpanded = false
            showsFullTransitItinerary = false
        }
        .onChange(of: navigationStore.state.progress?.nextManeuver?.id) { _, _ in
            journeyGuidanceExpanded = false
            currentStepExpandedOverride = nil
        }
        .onChange(of: isCurrentStepGuidanceExpanded) { _, expanded in
            if !expanded { journeyGuidanceExpanded = false }
        }
        .onChange(of: isNavigating) { _, navigating in
            if navigating, navigationStore.state.transportMode == .transit {
                navigationPanelDetent = .medium
            } else if !navigating {
                journeyGuidanceExpanded = false
                currentStepExpandedOverride = nil
            }
        }
    }

    @ViewBuilder
    private func navigationMapPanel(in geometry: GeometryProxy) -> some View {
#if os(iOS)
        if !placeStore.selectedMapPlaces.isEmpty {
            selectedMapPlacesBottomSheet(
                maxHeight: min(geometry.size.height * 0.88,
                               max(220, geometry.size.height - mapHeaderInset - 28)),
                bottomInset: geometry.safeAreaInsets.bottom)
        } else {
            standardNavigationMapPanel(in: geometry)
        }
#else
        standardNavigationMapPanel(in: geometry)
#endif
    }

    @ViewBuilder
    private func standardNavigationMapPanel(in geometry: GeometryProxy) -> some View {
        if shouldShowDiscoveryDrawer {
            DiscoveryDrawer(
                maximumHeight: max(160, min(geometry.size.height * 0.88,
                                            geometry.size.height - mapHeaderInset - 28)),
                collapseRequest: discoveryDrawerCollapseRequest,
                detent: $discoverySheetDetent,
                isDragging: $isMapBottomSheetDragging) { compact in
                    discoveryPanel(compact: compact)
                }
        } else if isIOSRoutePlanningPreview {
            routePlanningSheet(
                maxHeight: min(geometry.size.height * 0.88,
                               max(220, geometry.size.height - mapHeaderInset - 28)),
                bottomInset: geometry.safeAreaInsets.bottom)
        } else {
#if os(iOS)
            if isNavigating {
                let standardPanelHeight = min(geometry.size.height * 0.88,
                                              max(140, geometry.size.height - mapHeaderInset - 132))
                let availablePanelHeight = navigationStore.state.transportMode == .transit
                    ? min(standardPanelHeight, max(220, geometry.size.height * 0.68))
                    : standardPanelHeight
                journeyNavigationPanel(
                    maxHeight: availablePanelHeight)
            } else {
                activeScrollableMapPanel(in: geometry)
            }
#else
            activeScrollableMapPanel(in: geometry)
#endif
        }
    }

    private func activeScrollableMapPanel(in geometry: GeometryProxy) -> some View {
        ScrollView(.vertical) {
            activePanel
                .padding(.horizontal, usesFullBleedNavigationPanel ? 0 : 2)
                .padding(.top, usesFullBleedNavigationPanel ? 0 : 2)
                .padding(.bottom, isTransitRoutePreview && !usesFullBleedNavigationPanel ? 76 : 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        }
        .scrollIndicators(.hidden)
        .frame(height: min(panelHeight, geometry.size.height *
                           (geometry.size.height < 500 ? 0.48 : 0.64)))
        .overlay(alignment: .bottom) { transitPreviewBeginRouteOverlay }
    }

    private func nearbyPlacesSheet(for request: NearbySearchRequest) -> some View {
        NearbyPlacesSheet(
            navigationStore: navigationStore,
            nearDestination: request.nearDestination,
            initialCategory: request.category,
            savedPlaces: placeStore.places,
            onSave: { placeStore.add($0) },
            onRemoveSaved: { removeFavorite(for: $0) },
            onRenameSaved: { renameFavorite(for: $0, to: $1) },
            onSelect: { destination in
                Task {
                    await navigationStore.selectNearbyPlace(
                        destination, asFinalParking: request.nearDestination)
                    placeStore.nearbyRequest = nil
                }
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }

    private var rootMapContent: some View {
        ZStack {
            mapCanvas
            mapTopGradient
            mapInteractionLayer
#if os(iOS)
            navigationSpeedOverlay
#endif
            parkedCarActionOverlay
            parkedCarToastOverlay
        }
    }

#if os(iOS)
    @ViewBuilder
    private var navigationSpeedOverlay: some View {
        if isNavigating && isOnRoadDrivingLeg && !isMapBottomSheetExpanded {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    speedCard(at: context.date)
                    navigationTrafficIncidentBanner
                    navigationRoadDataFooter
                }
            }
            .frame(maxWidth: 230, alignment: .leading)
            .frame(maxWidth: 560, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 16)
            .padding(.bottom, mapPanelInset + 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .zIndex(2)
        }
    }
#endif

    @ViewBuilder
    private var mapCanvas: some View {
        if scenePhase == .active {
            MapLibreView(scene: navigationMapScene)
                .ignoresSafeArea()
        } else {
            Color.clear.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var cyclingMapAttribution: some View {
        if case .loaded = mapStore.cyclingPathsStatus {
            Link("© OpenStreetMap contributors",
                 destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var mapTopGradient: some View {
        LinearGradient(colors: [Color.black.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var mapInteractionLayer: some View {
        if selectingRouteOriginOnMap {
            routeOriginMapPicker
        } else if let kind = savedPlaceMapSelectionKind {
            savedPlaceMapPicker(kind)
        } else {
            GeometryReader { geometry in
                mapControlStack(in: geometry)
            }
        }
    }

    private var parkedCarActionOverlay: some View {
        parkedCarFloatingAction
            .frame(maxWidth: 560, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 18)
            .padding(.bottom, mapPanelInset + 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .zIndex(2)
    }

    private var parkedCarToastOverlay: some View {
        parkedCarToastView
            .frame(maxWidth: 560)
            .padding(.top, mapHeaderInset + 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .zIndex(3)
    }

    private var transitJourneyRefreshKey: String {
        let routeID = navigationStore.state.route?.id.uuidString ?? "no-route"
        let transportMode = navigationStore.state.transportMode.rawValue
        let activity = scenePhase == .active ? "foreground" : "background"
        return routeID + "-" + transportMode + "-" + activity
    }

    private var selectedMapPlacesSheetBinding: Binding<Bool> {
        Binding(
            get: {
#if os(iOS)
                false
#else
                !placeStore.selectedMapPlaces.isEmpty
#endif
            },
            set: { isPresented in
                if !isPresented { placeStore.selectedMapPlaces = [] }
            })
    }

    private var selectedMapPlacesSheetPresentation: some View {
        selectedMapPlacesSheet
            .onDisappear { mapPlaceEstimateTask?.cancel() }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }

    private func handleSelectedMapPlacesSheetDismissal() {
        guard openDestinationSearchAfterPlaceDismiss else { return }
        openDestinationSearchAfterPlaceDismiss = false
        presentSearch()
    }

    private func dismissSelectedMapPlaces() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            placeStore.selectedMapPlaces = []
        }
    }

    private func selectedMapPlacesBottomSheet(maxHeight: CGFloat, bottomInset: CGFloat = 0) -> some View {
        NavigationBottomSheet(detent: $selectedMapPlaceDetent,
                              maximumHeight: maxHeight,
                              accessibilityLabel: "Szczegóły miejsca",
                              appearance: .discovery,
                              isDragging: $isMapBottomSheetDragging,
                              mediumHeightFraction: 0.58,
                              onClose: dismissSelectedMapPlaces,
                              closeAccessibilityLabel: "Zamknij szczegóły miejsca") { detent, _ in
            Group {
                if detent == .peek {
                    selectedMapPlacesPeek
                } else if placeStore.selectedMapPlaces.count > 1 {
                    selectedMapPlacesChoices
                } else if let result = placeStore.selectedMapPlaces.first {
                    selectedMapPlaceDetails(for: result,
                                            presentation: detent == .expanded ? .full : .medium,
                                            embeddedInBottomSheet: true,
                                            showsPrimaryAction: false)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, detent == .peek ? 4 : 10)
            .padding(.bottom, detent == .peek ? 4 : 18)
        } footer: { detent, _ in
            if detent != .peek,
               placeStore.selectedMapPlaces.count == 1,
               let result = placeStore.selectedMapPlaces.first {
                Button {
                    planRoute(from: result)
                } label: {
                    Label(isNavigating ? "Dodaj przystanek" : "Wyznacz trasę",
                          systemImage: isNavigating ? "plus" : "arrow.triangle.turn.up.right.diamond")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, max(12, min(22, bottomInset * 0.55)))
                .background(.ultraThinMaterial)
            } else {
                EmptyView()
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onDisappear {
            mapPlaceEstimateTask?.cancel()
            handleSelectedMapPlacesSheetDismissal()
        }
    }

    private var rootPreferredColorScheme: ColorScheme? {
        guard mapCapabilities.supportsApplicationDarkMode else { return nil }
        switch mapSettings.appearance {
        case .auto: return nil
        case .night: return .dark
        case .day: return .light
        }
    }

    private var rootPresentationContent: some View {
        rootMapContent
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
            .task(id: transitJourneyRefreshKey) {
                guard scenePhase == .active else { return }
                await refreshTransitJourneyDetails()
            }
            .preferredColorScheme(rootPreferredColorScheme)
#if os(iOS)
            .fullScreenCover(isPresented: $isARNavigationPresented) {
                if let route = navigationStore.state.route {
                    ARNavigationView(route: route,
                                     progress: navigationStore.state.progress,
                                     location: navigationStore.state.location,
                                     onClose: { isARNavigationPresented = false })
                } else {
                    ContentUnavailableView("Brak aktywnej trasy", systemImage: "location.slash")
                }
            }
            .onChange(of: isNavigating) { _, active in
                if !active { isARNavigationPresented = false }
            }
            .onChange(of: navigationStore.state.transportMode) { _, mode in
                if mode != .walking { isARNavigationPresented = false }
            }
#endif
    }

    private var rootContentWithPrimarySheets: some View {
        rootPresentationContent
            .sheet(item: appSheetBinding, onDismiss: handleAppSheetDismissal) { destination in
                appSheet(destination)
            }
            .sheet(item: $transitStore.selectedSheet) { selection in
                TransitDetailsSheet(selection: selection, transitStore: transitStore,
                                    onSelectDeparture: { departure in
                    openTransitDeparture(departure)
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }

    private var rootContentWithPlaceSheets: some View {
        rootContentWithPrimarySheets
            .sheet(item: $selectedParkedCar) { car in
                parkedCarDetailsSheet(for: car)
            }
            .sheet(isPresented: selectedMapPlacesSheetBinding,
                   onDismiss: handleSelectedMapPlacesSheetDismissal) {
                selectedMapPlacesSheetPresentation
            }
    }

    private var rootContentWithAllSheets: some View {
        rootContentWithPlaceSheets
            .sheet(item: $placeStore.nearbyRequest) { request in
                nearbyPlacesSheet(for: request)
            }
    }

    private var rootContentWithLifecycle: some View {
        rootContentWithAllSheets
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                Task { @MainActor in mapStore.reloadFromDefaults() }
            }

    }

    private var rootContentWithStateObservers: some View {
        rootContentWithLifecycle
            .onChange(of: navigationStore.state.destination?.id) { _, _ in
                destinationExpanded = false
                routePreviewExpanded = false
                isSavingPlace = false
            }
            .onChange(of: navigationStore.state.location?.coordinate) { _, _ in
                guard scenePhase == .active else { return }
                Task { await refreshQuickDestinationETAs() }
            }
            .onChange(of: navigationStore.state.searchMapCenter) { _, center in
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
            .onChange(of: navigationStore.state.status) { previous, status in
                handleNavigationStatusChange(status, previous: previous)
                navigationStore.refreshEnergyPolicy()
            }
    }

    var body: some View {
        rootContentWithStateObservers
            .foregroundStyle(Color.naviTextPrimary)
            .overlay(alignment: .top) {
                FavoriteFeedbackOverlay(feedback: $favoriteFeedback)
                    .padding(.top, 104)
            }
            .modifier(rootConfirmationDialogs)
    }

    private var rootConfirmationDialogs: ContentViewRootDialogs {
        let favoriteRemovalMessage: String
        if let destinationName = navigationStore.state.destination?.name {
            favoriteRemovalMessage = destinationName
        } else {
            favoriteRemovalMessage = ""
        }

        return ContentViewRootDialogs(
            showFavoriteRemovalConfirmation: $showFavoriteRemovalConfirmation,
            showParkedCarReplacementConfirmation: $showParkedCarReplacementConfirmation,
            showMapLocationActions: $showMapLocationActions,
            favoriteRemovalMessage: favoriteRemovalMessage,
            onRemoveFavorite: {
                guard let destination = navigationStore.state.destination else { return }
                _ = removeFavorite(for: destination)
            },
            onReplaceParkedCar: {
                guard let coordinate = pendingParkedCarCoordinate else { return }
                persistParkedCar(at: coordinate, accuracy: pendingParkedCarAccuracy,
                                 parkedAt: pendingParkedCarDate ?? Date())
                pendingParkedCarCoordinate = nil
                pendingParkedCarAccuracy = nil
                pendingParkedCarDate = nil
            },
            onCancelParkedCarReplacement: {
                pendingParkedCarCoordinate = nil
                pendingParkedCarAccuracy = nil
                pendingParkedCarDate = nil
            },
            onSaveParkedCarHere: {
                guard let coordinate = mapActionCoordinate else { return }
                requestParkedCarSave(at: coordinate, accuracy: nil)
                mapActionCoordinate = nil
            },
            onSelectMapPointAsDestination: {
                guard let coordinate = mapActionCoordinate else { return }
                selectMapCoordinate(coordinate)
                mapActionCoordinate = nil
            },
            onCancelMapLocationActions: { mapActionCoordinate = nil })
    }

    private func parkedCarDetailsSheet(for car: ParkedCar) -> some View {
        let distanceMeters = currentParkedCarLocation.map { location in
            location.coordinate.distance(to: car.coordinate)
        }
        let initialPhotoData = placeStore.parkedCarPhotoData(for: car)
        let sheet = ParkedCarDetailsSheet(
            car: car,
            distanceMeters: distanceMeters,
            initialPhotoData: initialPhotoData,
            startsEditing: parkedCarStartsInEditMode,
            onGuide: { guideToParkedCar(car) },
            onUpdate: { updated in
                guard placeStore.parkedCar?.id == updated.id,
                      placeStore.updateParkedCar(updated) else { return }
                selectedParkedCar = updated
            },
            onSavePhoto: { data in placeStore.saveParkedCarPhoto(data) },
            onRemove: {
                if placeStore.removeParkedCar() { selectedParkedCar = nil }
            })
#if os(iOS)
        return sheet
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
#else
        return sheet
#endif
    }

}

private struct ContentViewRootDialogs: ViewModifier {
    @Binding var showFavoriteRemovalConfirmation: Bool
    @Binding var showParkedCarReplacementConfirmation: Bool
    @Binding var showMapLocationActions: Bool

    let favoriteRemovalMessage: String
    let onRemoveFavorite: () -> Void
    let onReplaceParkedCar: () -> Void
    let onCancelParkedCarReplacement: () -> Void
    let onSaveParkedCarHere: () -> Void
    let onSelectMapPointAsDestination: () -> Void
    let onCancelMapLocationActions: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Usunąć z Ulubionych?", isPresented: $showFavoriteRemovalConfirmation,
                                titleVisibility: .visible) {
                Button("Usuń", role: .destructive, action: onRemoveFavorite)
                Button("Anuluj", role: .cancel) { }
            } message: {
                Text(favoriteRemovalMessage)
            }
            .confirmationDialog("Masz zapisane miejsce samochodu",
                                isPresented: $showParkedCarReplacementConfirmation,
                                titleVisibility: .visible) {
                Button("Zastąp lokalizację", role: .destructive, action: onReplaceParkedCar)
                Button("Anuluj", role: .cancel, action: onCancelParkedCarReplacement)
            } message: {
                Text("Poprzednie miejsce zostanie zastąpione.")
            }
            .confirmationDialog("Punkt na mapie", isPresented: $showMapLocationActions,
                                titleVisibility: .visible) {
                Button("Tu zaparkowałem", systemImage: "car.side.fill", action: onSaveParkedCarHere)
                Button("Wybierz jako cel", systemImage: "mappin.and.ellipse",
                       action: onSelectMapPointAsDestination)
                Button("Anuluj", role: .cancel, action: onCancelMapLocationActions)
            }
    }
}
