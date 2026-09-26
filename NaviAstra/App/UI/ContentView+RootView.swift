import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    private var navigationMapScene: MapScene {
        let navigationState = engine.state
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
                if navigationState.destination == nil {
                    discoveryDrawerCollapseRequest += 1
                }
            },
            onLongPress: { coordinate in
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
        )

        return MapScene(
            navigationState: navigationState,
            transit: MapSceneTransitData(
                vehicles: navigationState.transitVehicles,
                stops: navigationState.transitStops,
                selectedStopID: selectedTransitStopID,
                selectedRouteID: selectedTransitRouteID,
                selectedTripID: selectedTransitTripID,
                selectedTripStopIDs: transitStopIDsForMap,
                activeStopID: activeTransitStopID,
                alightingStopID: alightingTransitStopID,
                lineCoordinates: transitLineCoordinatesForMap,
                lineColor: selectedTransitLine?.colorHex
            ),
            settings: navigationMapSettings,
            isSearchPresented: appRouter.sheet == .search,
            routePreviewExpanded: routePreviewExpanded,
            viewportPadding: CameraPadding(top: Double(mapHeaderInset), left: 24,
                                           bottom: Double(mapPanelInset), right: 24),
            commands: commands
        )
    }

    var body: some View {
        ZStack {
            MapLibreView(scene: navigationMapScene)
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
        .sheet(item: appSheetBinding, onDismiss: handleAppSheetDismissal) { destination in
            appSheet(destination)
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

}
