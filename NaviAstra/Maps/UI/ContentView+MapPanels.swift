import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    @ViewBuilder
    var activePanel: some View {
        switch navigationStore.state.status {
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
        case .error where navigationStore.state.destination != nil:
            routePreviewCard
        case .idle, .error:
            discoveryPanel()
        }
    }

    var selectedMapPlacesSheet: some View {
        NavigationStack {
            Group {
                if placeStore.selectedMapPlaces.count > 1 {
                    List(placeStore.selectedMapPlaces) { result in
                        mapPlaceSelectionRow(result)
                    }
                    .listStyle(.plain)
                } else if let result = placeStore.selectedMapPlaces.first {
                    selectedMapPlaceDetails(for: result)
                }
            }
            .navigationTitle(selectedMapPlacesSheetTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { placeStore.selectedMapPlaces = [] }
                }
            }
        }
    }

    var selectedMapPlacesSheetTitle: String {
        guard placeStore.selectedMapPlaces.count > 1 else {
            return placeStore.selectedMapPlaces.first?.destination.name ?? "Miejsce"
        }
        return "Wybierz miejsce"
    }

    func mapPlaceSelectionRow(_ result: SearchResult) -> some View {
        return Button {
            presentMapPlace(result)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.destination.name)
                    .font(.body.weight(.semibold))
                Text(mapPlaceSelectionSubtitle(result))
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
                    .lineLimit(2)
                if let distance = mapPlaceSelectionDistance(result) {
                    Text(distance)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pokaż miejsce \(result.destination.name), \(mapPlaceSelectionSubtitle(result))")
    }

    var selectedMapPlacesPeek: some View {
        let results = placeStore.selectedMapPlaces
        let result = results.first
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                selectedMapPlaceDetent = .medium
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(results.count == 1 ? (result?.destination.name ?? "Miejsce") : "Miejsca w pobliżu · \(results.count)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                    if results.count == 1, let result {
                        Text(selectedMapPlaceCompactSummary(result))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                    } else if !results.isEmpty {
                        Text("Wybierz jedno z \(results.count) miejsc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                    } else {
                        Text("Wybierz szczegóły jednego z miejsc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(results.count == 1
                            ? "\(result?.destination.name ?? "Miejsce"), \(result.map { selectedMapPlaceCompactSummary($0) } ?? "")"
                            : "Miejsca w pobliżu, liczba: \(results.count)")
        .accessibilityHint(results.count == 1 ? "Rozwiń szczegóły miejsca" : "Rozwiń listę miejsc")
    }

    private func selectedMapPlaceCompactSummary(_ result: SearchResult) -> String {
        if let summary = result.travelSummary { return summary }
        if let straightDistance = result.straightDistance {
            return "W linii prostej · \(distance(straightDistance))"
        }
        return result.destination.address
            ?? result.category?.replacingOccurrences(of: "_", with: " ").capitalized
            ?? "Wybrane miejsce"
    }

    private func mapPlaceSelectionSubtitle(_ result: SearchResult) -> String {
        let category = (result.category ?? "Miejsce")
            .replacingOccurrences(of: "_", with: " ").capitalized
        guard let address = result.destination.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else { return category }
        return "\(category) · \(address)"
    }

    private func mapPlaceSelectionDistance(_ result: SearchResult) -> String? {
        guard let value = result.selectionDistanceFromTap else { return nil }
        return "\(distance(value)) od wskazanego punktu"
    }

    var selectedMapPlacesChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wybierz miejsce")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.naviTextPrimary)
                Spacer()
                Text("\(placeStore.selectedMapPlaces.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.naviTextSecondary)
            }

            ForEach(placeStore.selectedMapPlaces) { result in
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        presentMapPlace(result)
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: result.isPOI ? "mappin.and.ellipse" : "mappin")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.destination.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.naviTextPrimary)
                                .lineLimit(1)
                            Text(mapPlaceSelectionSubtitle(result))
                                .font(.caption)
                                .foregroundStyle(Color.naviTextSecondary)
                                .lineLimit(2)
                            if let distance = mapPlaceSelectionDistance(result) {
                                Text(distance)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pokaż miejsce \(result.destination.name), \(mapPlaceSelectionSubtitle(result))")
            }
        }
    }

    @ViewBuilder
    func selectedMapPlaceDetails(for result: SearchResult,
                                 presentation: PlaceDetailsPresentation = .full,
                                 embeddedInBottomSheet: Bool = false,
                                 showsPrimaryAction: Bool = true) -> some View {
        let details = PlaceDetailsView(
            result: result,
            isSaved: isMapPlaceSaved(result),
            onSave: { placeStore.add(result.navigationDestination) },
            isNavigating: isNavigating,
            primaryActionTitle: isNavigating ? "Dodaj przystanek" : "Wyznacz trasę",
            presentation: presentation,
            embeddedInBottomSheet: embeddedInBottomSheet,
            showsPrimaryAction: showsPrimaryAction,
            onRouteFromPlace: { setMapPlaceAsRouteOrigin(result) },
            onRemove: { removeFavorite(for: result.destination) },
            onRename: { renameFavorite(for: result.destination, to: $0) },
            onPlanRoute: { planRoute(from: result) })

        if embeddedInBottomSheet {
            details.id(result.placeIdentity.cacheKey)
        } else {
            ScrollView {
                details
                    .id(result.placeIdentity.cacheKey)
                    .padding()
            }
        }
    }

    func isMapPlaceSaved(_ result: SearchResult) -> Bool {
        placeStore.places.contains {
            $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate
        }
    }

    func setMapPlaceAsRouteOrigin(_ result: SearchResult) {
        let destination = result.navigationDestination
        if navigationStore.state.destination == nil {
            openDestinationSearchAfterPlaceDismiss = true
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            placeStore.selectedMapPlaces = []
        }
        placeStore.recordSearch(destination)
        Task {
            await navigationStore.setRouteOrigin(RoutePoint(
                destination, source: destination.poi == nil ? .search : .poi))
        }
    }

    func planRoute(from result: SearchResult) {
        let destination = result.navigationDestination
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            placeStore.selectedMapPlaces = []
        }
        if isNavigating {
            Task { await navigationStore.addWaypoint(destination) }
        } else {
            selectDestination(destination)
        }
    }

    func handleNavigationStatusChange(_ status: NavigationStatus, previous: NavigationStatus? = nil) {
        switch status {
        case .navigating, .rerouting:
            routePreviewExpanded = false
            parkedCarPromptExpiresAt = nil
        case .arrived, .idle:
            routePreviewExpanded = false
            navigationPanelExpanded = false
            if status == .arrived, navigationStore.state.transportMode == .car {
                arrivalCarPromptDismissed = false
                parkedCarPromptExpiresAt = Date().addingTimeInterval(5 * 60)
            } else if status == .idle, previous != .arrived {
                parkedCarPromptExpiresAt = nil
            }
        case .destinationPreview, .routeCalculating, .routePreview, .error:
            navigationPanelExpanded = false
            parkedCarPromptExpiresAt = nil
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if isNavigating {
#if os(iOS)
                // Active iOS guidance is rendered by the dedicated overlay.
                EmptyView()
#else
                if navigationStore.state.transportMode == .transit || parkRideIsUsingTransitLeg {
                    transitNavigationHeader
                } else {
                    currentStepGuidanceCard
                }
#endif
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
                Button { appRouter.present(.settings) } label: {
                    circleSurface { Image(systemName: "gearshape").font(.title3) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ustawienia")
            }
        }
    }

    @ViewBuilder
    var gpsStatusIndicator: some View {
        let fixAge = navigationStore.state.location.map { Date().timeIntervalSince($0.timestamp) } ?? .infinity
        let warning: (String, String, Color)? = switch navigationStore.state.gpsQuality {
        case .good, .excellent: nil
        case .predicted where fixAge < 15: nil
        case .predicted, .weak: ("Sygnał GPS słaby", "location.circle", Color(naviHex: NaviAstraColorPalette.warning))
        case .noSignal: ("Słaby sygnał GPS · prowadzenie może być niedokładne", "location.slash", Color(naviHex: NaviAstraColorPalette.danger))
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
    var mapLayerMenuActions: some View {
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
                        mapStore.mapDimension = dimension.rawValue
                    } label: {
                        mapMenuLabel(dimension.title, selected: mapStore.mapDimension == dimension.rawValue)
                    }
                }
            }
        }

        Section("Warstwy") {
            if mapCapabilities.supportsTrafficOverlay {
                Toggle("Ruch drogowy", isOn: $mapStore.mapTrafficVisible)
            }
            if mapCapabilities.supportsPOIToggle {
                Toggle("Punkty POI", isOn: $mapStore.mapPOIVisible)
            }
            if mapCapabilities.supportsTransitOverlay {
                Toggle("Wyróżnij kolej i tramwaje", isOn: $mapStore.mapTransitVisible)
            }
            if mapCapabilities.supportsCyclingOverlay {
                Toggle("Ścieżki rowerowe", isOn: $mapStore.mapCyclingVisible)
                if mapStore.mapCyclingVisible {
                    cyclingPathsStatusLabel
                }
            }
            if mapCapabilities.supports3DBuildings {
                Toggle("Budynki 3D", isOn: $mapStore.mapBuildingsVisible)
            }
        }
    }

    @ViewBuilder
    private var cyclingPathsStatusLabel: some View {
        switch mapStore.cyclingPathsStatus {
        case .disabled:
            EmptyView()
        case .zoomIn:
            Label("Zbliż mapę, aby pobrać dane", systemImage: "plus.magnifyingglass")
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
        case .loading:
            Label("Pobieranie ścieżek z OSM…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
        case .loaded(count: 0, truncated: _):
            Label("Brak oznaczonych ścieżek w tym widoku", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
        case .loaded(let count, let truncated):
            Label(truncated ? "OpenStreetMap · ponad \(count) odc." : "OpenStreetMap · \(count) odc.",
                  systemImage: "bicycle")
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
        case .unavailable:
            Label("Dane OpenStreetMap są niedostępne", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
        }
    }

    var mapLayersMenu: some View {
        Menu {
            mapLayerMenuActions
        } label: {
            circleSurface {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.naviTextPrimary)
            }
        }
        .accessibilityLabel("Wygląd i warstwy mapy")
    }

    var journeyMapLayersMenu: some View {
        Menu {
            mapLayerMenuActions
        } label: {
            journeyActionLabel("Wygląd i warstwy", symbol: "square.3.layers.3d")
        }
        .accessibilityLabel("Wygląd i warstwy mapy")
    }

    func mapMenuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    var routePreviewHeader: some View {
        HStack(spacing: 11) {
            Button {
                navigationStore.stop()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.naviTextPrimary)
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

    var searchButton: some View {
        Button(action: presentSearch) {
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Szukaj miejsca lub połączenia")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.naviTextPrimary)
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

    var routeEndpointFields: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { appRouter.present(.originPicker) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: routeOriginPoint?.isCurrentLocation == true
                              ? "location.fill" : "a.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(routeOriginPoint?.isCurrentLocation == true
                                ? Color(naviHex: colorScheme == .dark
                                    ? NaviAstraColorPalette.userLocationNight
                                    : NaviAstraColorPalette.userLocationDay)
                                : Color.naviTextPrimary)
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.055), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routeOriginPoint?.name ?? "Twoja lokalizacja")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.naviTextPrimary)
                                .lineLimit(1)
                            Text("Punkt startowy")
                                .font(.caption)
                                .foregroundStyle(Color.naviTextSecondary)
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
                .disabled(navigationStore.state.destination == nil || routeOriginPoint == nil)
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
                        Text(navigationStore.state.destination?.name ?? "Dokąd?")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.naviTextPrimary)
                            .lineLimit(1)
                        Text(navigationStore.state.destination?.address ?? "Cel podróży")
                            .font(.caption)
                            .foregroundStyle(Color.naviTextSecondary)
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
            .accessibilityLabel("Cel podróży: \(navigationStore.state.destination?.name ?? "Wybierz miejsce")")

            routeWaypointAddButton()
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    @ViewBuilder
    func routeWaypointRows(darkStyle: Bool) -> some View {
        ForEach(Array(navigationStore.state.waypoints.enumerated()), id: \.element.id) { index, waypoint in
            routeWaypointConnector(darkStyle: darkStyle)
            routeWaypointRow(waypoint, index: index, darkStyle: darkStyle)
        }
    }

    func routeWaypointConnector(darkStyle: Bool) -> some View {
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

    func routeWaypointRow(_ waypoint: Destination, index: Int, darkStyle: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(darkStyle ? Color.white : Color.accentColor)
                .frame(width: 30, height: 30)
                .background(darkStyle ? Color.accentColor : Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(darkStyle ? Color.white.opacity(0.94) : Color.naviTextPrimary)
                    .lineLimit(1)
                Text(waypoint.address.map { "Przystanek \(index + 1) · \($0)" } ?? "Przystanek \(index + 1)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(darkStyle ? Color.white.opacity(0.56) : Color.naviTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 3)

            routeStopDragHandle(identifier: waypoint.id.uuidString,
                                label: "przystanek \(index + 1)",
                                darkStyle: darkStyle)

            Button {
                Task { await navigationStore.removeWaypoint(waypoint.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(darkStyle ? Color.white.opacity(0.72) : Color.naviTextSecondary)
                    .frame(width: 44, height: 44)
                    .background(darkStyle ? Color.white.opacity(0.06) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(navigationStore.state.status != .routePreview)
            .accessibilityLabel("Usuń przystanek \(index + 1)")
        }
        .frame(minHeight: 44)
        .dropDestination(for: String.self) { draggedIDs, location in
            guard let draggedID = draggedIDs.first else { return false }
            return acceptRouteStopDrop(draggedID,
                                       targetID: waypoint.id.uuidString,
                                       insertAfterTarget: location.y >= 22)
        } isTargeted: { isTargeted in
            updateRouteStopDropTarget(waypoint.id.uuidString, isTargeted: isTargeted)
        }
        .modifier(RouteStopDropTargetHighlight(isTargeted: routeStopDropTargetID == waypoint.id.uuidString))
        .accessibilityHint("Przeciągnij przystanek, aby zmienić jego kolejność na trasie")
    }

    func routeWaypointAddButton() -> some View {
        Button {
            selectingRouteOriginInSearch = false
            addingWaypoint = true
            appRouter.present(.search)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 35, height: 35)
                    .background {
                        Circle().fill(
                            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing))
                    }
                Text("Dodaj przystanek")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(navigationStore.state.waypoints.count >= 8 || navigationStore.state.status != .routePreview)
        .opacity(navigationStore.state.waypoints.count >= 8 || navigationStore.state.status != .routePreview ? 0.5 : 1)
        .accessibilityLabel("Dodaj przystanek przed celem podróży")
    }

    var routeOriginPicker: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        appRouter.dismiss(.originPicker)
                        Task { await navigationStore.setRouteOrigin(nil) }
                    } label: {
                        Label("Moja lokalizacja", systemImage: "location.fill")
                    }
                    .foregroundStyle(Color(naviHex: colorScheme == .dark
                        ? NaviAstraColorPalette.userLocationNight : NaviAstraColorPalette.userLocationDay))
                }

                Section("Dodaj punkt startowy") {
                    Button {
                        openOriginSearchAfterPickerDismiss = true
                        appRouter.dismiss(.originPicker)
                    } label: {
                        Label("Wyszukaj miejsce", systemImage: "magnifyingglass")
                    }
                    Button(action: beginRouteOriginMapSelection) {
                        Label("Wybierz na mapie", systemImage: "mappin.and.ellipse")
                    }
                }

                if !placeStore.places.isEmpty {
                    Section("Zapisane miejsca") {
                        ForEach(placeStore.places) { place in
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

                let recent = Array((placeStore.searches.map(\.destination) + recentDestinations)
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
                    Button("Anuluj") { appRouter.dismiss(.originPicker) }
                }
            }
        }
    }

    var routeOriginMapPicker: some View {
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
                            navigationStore.state.routeOriginMapSelectionActive = false
                            appRouter.present(.originPicker)
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
                                .foregroundStyle(Color.naviTextSecondary)
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

    func savedPlaceMapPicker(_ kind: PlaceKind) -> some View {
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
                            appRouter.present(.search)
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
                                .foregroundStyle(Color.naviTextSecondary)
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

    func beginSavedPlaceMapSelection(as kind: PlaceKind) {
        savedPlaceMapSelectionKind = kind
        let coordinate = navigationStore.state.searchMapCenter ?? navigationStore.state.location?.coordinate
            ?? navigationStore.state.destination?.coordinate
        savedPlaceMapCoordinate = coordinate
        savedPlaceMapAddress = nil
        appRouter.dismiss(.search)
        if let coordinate {
            navigationStore.focusMap(on: coordinate, zoom: 15.5)
            updateSavedPlaceMapSelection(coordinate)
        }
    }

    func updateSavedPlaceMapSelection(_ coordinate: Coordinate) {
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

    func confirmSavedPlaceMapSelection() {
        guard let kind = savedPlaceMapSelectionKind, let coordinate = savedPlaceMapCoordinate else { return }
        let destination = Destination(name: kind.title, coordinate: coordinate, address: savedPlaceMapAddress)
        let saved = kind == .favorite
            ? addFavoriteWithFeedback(destination, failureToast: false)
            : placeStore.add(destination, kind: kind)
        guard saved else { return }
        savedPlaceMapGeocodingTask?.cancel()
        savedPlaceMapSelectionKind = nil
    }

    func saveMapSelectedPlace(_ destination: Destination, as kind: PlaceKind) {
        let saved = Destination(name: kind.title, coordinate: destination.coordinate,
                                address: destination.address, poi: destination.poi)
        let didSave = kind == .favorite
            ? addFavoriteWithFeedback(saved, failureToast: false)
            : placeStore.add(saved, kind: kind)
        guard didSave else { return }
        savedPlaceMapGeocodingTask?.cancel()
        savedPlaceMapSelectionKind = nil
    }

    func beginRouteOriginMapSelection() {
        appRouter.dismiss(.originPicker)
        selectingRouteOriginOnMap = true
        navigationStore.state.routeOriginMapSelectionActive = true
        let coordinate = navigationStore.state.searchMapCenter ?? navigationStore.state.location?.coordinate
            ?? navigationStore.state.destination?.coordinate
        pickedRouteOriginCoordinate = coordinate
        pickedRouteOriginAddress = nil
        if let coordinate {
            navigationStore.focusMap(on: coordinate, zoom: 15.5)
            updatePickedRouteOrigin(coordinate)
        }
    }

    func updatePickedRouteOrigin(_ coordinate: Coordinate) {
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

    func confirmRouteOriginMapSelection() {
        guard let coordinate = pickedRouteOriginCoordinate else { return }
        let address = pickedRouteOriginAddress
        let name = address?.components(separatedBy: ",").first ?? "Wybrany punkt"
        let destination = Destination(name: name, coordinate: coordinate, address: address)
        placeStore.recordSearch(destination)
        selectingRouteOriginOnMap = false
        navigationStore.state.routeOriginMapSelectionActive = false
        routeOriginGeocodingTask?.cancel()
        Task { await navigationStore.setRouteOrigin(RoutePoint(destination, source: .mapSelection)) }
    }

    func applyRouteOrigin(_ destination: Destination, source: RoutePointSource) {
        appRouter.dismiss(.originPicker)
        appRouter.dismiss(.search)
        selectingRouteOriginInSearch = false
        selectingRouteOriginOnMap = false
        navigationStore.state.routeOriginMapSelectionActive = false
        routeOriginGeocodingTask?.cancel()
        if source == .search || source == .mapSelection || source == .poi {
            placeStore.recordSearch(destination)
        }
        Task { await navigationStore.setRouteOrigin(RoutePoint(destination, source: source)) }
    }

    func swapRouteEndpoints() {
        Task { await navigationStore.swapRoutePoints() }
    }
}
