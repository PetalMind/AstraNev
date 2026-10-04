import SwiftUI

private struct RoutePlanningEndpointMarker: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbolName: String
    var isCurrentLocation = false

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: symbolName == "flag.fill" ? 13 : 14, weight: .semibold))
            .foregroundStyle(isCurrentLocation || colorScheme == .light
                ? Color.white
                : Color(naviHex: NaviAstraColorPalette.textPrimaryDay))
            .frame(width: 31, height: 31)
            .background(Color(naviHex: markerColor), in: Circle())
    }

    private var markerColor: UInt32 {
        if isCurrentLocation {
            return colorScheme == .dark ? NaviAstraColorPalette.userLocationNight : NaviAstraColorPalette.userLocationDay
        }
        return colorScheme == .dark
            ? NaviAstraColorPalette.textPrimaryNight
            : NaviAstraColorPalette.textPrimaryDay
    }
}

extension ContentView {
    private var routePlanningOptions: [NavigationRoute] {
        var routes = navigationStore.state.routeOptions
        if routes.isEmpty, let route = navigationStore.state.route {
            routes = [route]
        }
        let selectedID = navigationStore.state.route?.id
        return routes.sorted { lhs, rhs in
            let lhsIsSelected = lhs.id == selectedID
            let rhsIsSelected = rhs.id == selectedID
            if lhsIsSelected != rhsIsSelected { return lhsIsSelected }
            return lhs.expectedTravelTime < rhs.expectedTravelTime
        }
    }

    private var routePlanningCarouselRoutes: [NavigationRoute] {
        var routes = navigationStore.state.routeOptions
        if let selected = navigationStore.state.route,
           !routes.contains(where: { $0.id == selected.id }) {
            routes.insert(selected, at: 0)
        }
        return routes
    }

    private var routeStopIdentifiers: [String] {
        ["route-origin"] + navigationStore.state.waypoints.map { $0.id.uuidString } + ["route-destination"]
    }

    func acceptRouteStopDrop(_ sourceID: String, targetID: String, insertAfterTarget: Bool) -> Bool {
        defer { routeStopDropTargetID = nil }
        guard navigationStore.state.status == .routePreview,
              sourceID != targetID else { return false }

        if (sourceID == "route-origin" && targetID == "route-destination") ||
            (sourceID == "route-destination" && targetID == "route-origin") {
            swapRouteEndpoints()
            routeStopReorderFeedbackToken += 1
            return true
        }

        let stopIDs = routeStopIdentifiers
        guard let sourceIndex = stopIDs.firstIndex(of: sourceID),
              let targetIndex = stopIDs.firstIndex(of: targetID) else { return false }
        let insertionIndex = targetIndex + (insertAfterTarget ? 1 : 0)
        let finalIndex = insertionIndex - (sourceIndex < insertionIndex ? 1 : 0)
        guard sourceIndex != finalIndex else { return true }
        Task { await navigationStore.reorderRouteStop(sourceID, to: finalIndex) }
        routeStopReorderFeedbackToken += 1
        return true
    }

    func updateRouteStopDropTarget(_ identifier: String, isTargeted: Bool) {
        if isTargeted {
            routeStopDropTargetID = identifier
        } else if routeStopDropTargetID == identifier {
            routeStopDropTargetID = nil
        }
    }

    private func moveRouteStopForAccessibility(_ sourceID: String, by offset: Int) {
        guard let sourceIndex = routeStopIdentifiers.firstIndex(of: sourceID),
              routeStopIdentifiers.indices.contains(sourceIndex + offset) else { return }
        let targetID = routeStopIdentifiers[sourceIndex + offset]
        _ = acceptRouteStopDrop(sourceID,
                                targetID: targetID,
                                insertAfterTarget: offset > 0)
    }

    @ViewBuilder
    func routeStopDragHandle(identifier: String, label: String, darkStyle: Bool = false) -> some View {
        if navigationStore.state.status == .routePreview {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(routeStopDropTargetID == identifier
                                 ? Color.accentColor
                                 : (darkStyle ? Color.white.opacity(0.86) : Color.primary.opacity(0.72)))
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(routeStopDropTargetID == identifier
                              ? Color.accentColor.opacity(0.14)
                              : (darkStyle ? Color.white.opacity(0.075) : Color.primary.opacity(0.045)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(darkStyle ? Color.white.opacity(0.1) : Color.primary.opacity(0.09), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .draggable(identifier) { routeStopDragPreview(label: label) }
                .accessibilityLabel("Zmień kolejność: \(label)")
                .accessibilityHint("Przeciągnij uchwyt na pozycję docelową. Możesz też użyć dostępnych akcji.")
                .accessibilityActions {
                    if let index = routeStopIdentifiers.firstIndex(of: identifier) {
                        if index > 0 {
                            Button("Bliżej punktu startowego") {
                                moveRouteStopForAccessibility(identifier, by: -1)
                            }
                        }
                        if index + 1 < routeStopIdentifiers.count {
                            Button("Bliżej celu") {
                                moveRouteStopForAccessibility(identifier, by: 1)
                            }
                        }
                    }
                }
        } else {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(darkStyle ? Color.white.opacity(0.3) : Color.naviTextSecondary.opacity(0.55))
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    private func routeStopDragPreview(label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Zmień kolejność")
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.naviTextSecondary.opacity(0.68))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.naviTextPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(NavigationGlassSurface(radius: 16, interactive: true))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.48), lineWidth: 1)
        }
    }

    private var routePlanningShareURL: URL? {
        guard let origin = routeOriginPoint, let destination = navigationStore.state.destination else { return nil }
        let originValue = origin.isCurrentLocation
            ? "Current Location"
            : "\(origin.coordinate.latitude),\(origin.coordinate.longitude)"
        let destinationValue = "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"
        let directionsMode: String = switch navigationStore.state.transportMode {
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

    func routePlanningSheet(maxHeight: CGFloat, bottomInset: CGFloat) -> some View {
        NavigationBottomSheet(detent: $routePreviewDetent,
                              maximumHeight: maxHeight,
                              accessibilityLabel: "Podgląd trasy",
                              appearance: .discovery,
                              isDragging: $isMapBottomSheetDragging,
                              mediumHeightFraction: 0.72,
                              minimumPeekHeight: navigationStore.state.route != nil || navigationStore.state.status == .error
                                  ? 220 : nil,
                              hidesExpandedChevron: true) { detent, _ in
            Group {
                switch detent {
                case .peek:
                    if maxHeight < 300 || (navigationStore.state.route == nil && navigationStore.state.status != .error) {
                        EmptyView()
                    } else {
                        routePlanningPeek
                    }
                case .medium:
                    VStack(spacing: 6) {
                        routePlanningTransportSelector
                        routePlanningCompactEndpoints
                        if navigationStore.state.route == nil {
                            routePlanningUnavailable
                        }
                    }
                case .expanded:
                    VStack(spacing: 10) {
                        routePlanningExpandedHeader
                        routePlanningTransportSelector
                        routePlanningCompactEndpoints

                        if navigationStore.state.transportMode == .transit || navigationStore.state.transportMode == .parkRide {
                            journeyTimeControl
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let route = navigationStore.state.route {
                            routePlanningExpandedRouteOptions(for: route)
                            Button {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                                    routePlanningDetailsExpanded.toggle()
                                }
                            } label: {
                                Label(routePlanningDetailsExpanded ? "Ukryj szczegóły trasy" : "Szczegóły trasy",
                                      systemImage: routePlanningDetailsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(routePlanningDetailsExpanded
                                               ? "Ukryj ustawienia i szczegóły trasy"
                                               : "Pokaż ustawienia i szczegóły trasy")
                            if routePlanningDetailsExpanded {
                                routePlanningDetails(for: route, showsManeuvers: false)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        } else {
                            routePlanningUnavailable
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, detent == .peek ? 0 : 4)
        } footer: { detent, _ in
            if detent == .expanded, navigationStore.state.status == .routePreview {
                EmptyView()
            } else {
                routePlanningFooter(bottomInset: bottomInset,
                                    compact: detent != .expanded || maxHeight < 360,
                                    medium: detent == .medium && maxHeight >= 360,
                                    showsSecondaryActions: detent != .peek &&
                                        (detent == .expanded || maxHeight >= 600))
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: routeStopReorderFeedbackToken)
    }

    private var routePlanningCompactEndpoints: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoutePlanningEndpointMarker(
                    symbolName: routeOriginPoint?.isCurrentLocation == true ? "location.north.fill" : "a.circle.fill",
                    isCurrentLocation: routeOriginPoint?.isCurrentLocation == true)

                Button { appRouter.present(.originPicker) } label: {
                    Text(routeOriginPoint?.name ?? "Twoja lokalizacja")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Punkt startowy: \(routeOriginPoint?.name ?? "Twoja lokalizacja")")

                Button(action: swapRouteEndpoints) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.naviTextSecondary.opacity(0.62))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(navigationStore.state.destination == nil || routeOriginPoint == nil)
                .accessibilityLabel("Zamień punkt startowy i cel")

                routeStopDragHandle(identifier: "route-origin", label: "punkt startowy")
            }
            .dropDestination(for: String.self) { draggedIDs, location in
                guard let draggedID = draggedIDs.first else { return false }
                return acceptRouteStopDrop(draggedID, targetID: "route-origin", insertAfterTarget: location.y >= 22)
            } isTargeted: { isTargeted in
                updateRouteStopDropTarget("route-origin", isTargeted: isTargeted)
            }
            .modifier(RouteStopDropTargetHighlight(isTargeted: routeStopDropTargetID == "route-origin"))

            routeWaypointRows(darkStyle: false)
            routeWaypointConnector(darkStyle: false)

            HStack(spacing: 10) {
                RoutePlanningEndpointMarker(symbolName: "flag.fill")

                Button(action: presentSearch) {
                    Text(navigationStore.state.destination?.name ?? "Dokąd?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cel podróży: \(navigationStore.state.destination?.name ?? "Nie wybrano")")

                routeStopDragHandle(identifier: "route-destination", label: "cel podróży")
            }
            .dropDestination(for: String.self) { draggedIDs, location in
                guard let draggedID = draggedIDs.first else { return false }
                return acceptRouteStopDrop(draggedID, targetID: "route-destination", insertAfterTarget: location.y >= 22)
            } isTargeted: { isTargeted in
                updateRouteStopDropTarget("route-destination", isTargeted: isTargeted)
            }
            .modifier(RouteStopDropTargetHighlight(isTargeted: routeStopDropTargetID == "route-destination"))

            routeWaypointAddButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(NavigationGlassSurface(radius: 19, interactive: true))
    }

    private var routePlanningExpandedHeader: some View {
        HStack(spacing: 12) {
            if let url = routePlanningShareURL {
                ShareLink(item: url) {
                    routePlanningHeaderIcon("square.and.arrow.up", accessibilityLabel: "Udostępnij trasę")
                }
                .buttonStyle(.plain)
            } else {
                Button {} label: {
                    routePlanningHeaderIcon("square.and.arrow.up", accessibilityLabel: "Udostępnianie trasy niedostępne")
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
            }

            Spacer(minLength: 0)

            VStack(spacing: 5) {
                Text("Trasa")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.naviTextPrimary)

                if navigationStore.state.transportMode == .car {
                    routePlanningAvoidTollsChip
                }
            }

            Spacer(minLength: 0)

            Button {
                navigationStore.stop()
            } label: {
                routePlanningHeaderIcon("xmark", accessibilityLabel: "Zamknij planowanie trasy")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }

    private func routePlanningHeaderIcon(_ symbol: String, accessibilityLabel: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.naviTextSecondary.opacity(0.92))
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(0.055), in: Circle())
            .contentShape(Circle())
            .accessibilityLabel(accessibilityLabel)
    }

    private var routePlanningAvoidTollsChip: some View {
        let isEnabled = navigationStore.state.routingPreferences.avoidTolls
        return Button {
            var preferences = navigationStore.state.routingPreferences
            preferences.avoidTolls.toggle()
            Task { await navigationStore.updateRoutingPreferences(preferences) }
        } label: {
            Text("Unikaj opłat")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isEnabled ? Color.white : Color.naviTextInactive)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isEnabled ? Color.accentColor : Color.naviTextInactive.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unikaj dróg płatnych")
        .accessibilityValue(isEnabled ? "Włączone" : "Wyłączone")
    }

    private var routePlanningPeek: some View {
        Button {
            routePreviewDetent = .medium
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(navigationStore.state.destination?.name ?? "Podgląd trasy")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                    if navigationStore.state.status == .error {
                        Text(navigationStore.state.errorMessage ?? "Nie udało się wyznaczyć trasy.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary.opacity(0.78))
                            .lineLimit(2)
                    } else {
                        Text("Start: \(routeOriginPoint?.name ?? "Twoja lokalizacja")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary.opacity(0.66))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.naviTextSecondary.opacity(0.55))
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(routePlanningPeekAccessibilityLabel)
        .accessibilityHint("Rozwiń panel, aby zobaczyć przystanki i alternatywne trasy")
    }

    private var routePlanningPeekAccessibilityLabel: String {
        let destination = navigationStore.state.destination?.name ?? "wybranego celu"
        guard let route = navigationStore.state.route else {
            if navigationStore.state.status == .error {
                let details = navigationStore.state.errorMessage.map { ". \($0)" } ?? ""
                return "Nie udało się wyznaczyć trasy do \(destination)\(details)"
            }
            return "Trasa do \(destination) jest przygotowywana"
        }
        return "Trasa do \(destination), \(time(route.expectedTravelTime)), przyjazd \(routePlanningArrivalTime(route)), \(distance(route.distance))"
    }

    private var routePlanningEndpoints: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoutePlanningEndpointMarker(
                    symbolName: routeOriginPoint?.isCurrentLocation == true ? "location.north.fill" : "a.circle.fill",
                    isCurrentLocation: routeOriginPoint?.isCurrentLocation == true)
                Button { appRouter.present(.originPicker) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routeOriginPoint?.name ?? "Twoja lokalizacja")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.naviTextPrimary)
                            .lineLimit(1)
                        Text("Punkt startowy")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary.opacity(0.56))
                    }
                    .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Punkt startowy: \(routeOriginPoint?.name ?? "Twoja lokalizacja")")
                routeStopDragHandle(identifier: "route-origin", label: "punkt startowy")
                Button(action: swapRouteEndpoints) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.naviTextSecondary.opacity(0.62))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(navigationStore.state.destination == nil || routeOriginPoint == nil)
                .accessibilityLabel("Zamień punkt startowy i cel")
            }
            .dropDestination(for: String.self) { draggedIDs, location in
                guard let draggedID = draggedIDs.first else { return false }
                return acceptRouteStopDrop(draggedID, targetID: "route-origin", insertAfterTarget: location.y >= 24)
            } isTargeted: { isTargeted in
                updateRouteStopDropTarget("route-origin", isTargeted: isTargeted)
            }
            .modifier(RouteStopDropTargetHighlight(isTargeted: routeStopDropTargetID == "route-origin"))

            routeWaypointRows(darkStyle: false)
            routeWaypointConnector(darkStyle: false)

            HStack(spacing: 10) {
                RoutePlanningEndpointMarker(symbolName: "flag.fill")
                Button(action: presentSearch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(navigationStore.state.destination?.name ?? "Dokąd?")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.naviTextPrimary)
                            .lineLimit(1)
                        Text(navigationStore.state.destination?.address ?? "Cel podróży")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary.opacity(0.56))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cel podróży: \(navigationStore.state.destination?.name ?? "Nie wybrano")")
                    Button(action: toggleDestinationFavorite) {
                        Image(systemName: isDestinationFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isDestinationFavorite ? Color.accentColor : Color.naviTextSecondary)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDestinationFavorite ? "Usuń cel z ulubionych" : "Zapisz cel w ulubionych")
                routeStopDragHandle(identifier: "route-destination", label: "cel podróży")
            }
            .dropDestination(for: String.self) { draggedIDs, location in
                guard let draggedID = draggedIDs.first else { return false }
                return acceptRouteStopDrop(draggedID, targetID: "route-destination", insertAfterTarget: location.y >= 24)
            } isTargeted: { isTargeted in
                updateRouteStopDropTarget("route-destination", isTargeted: isTargeted)
            }
            .modifier(RouteStopDropTargetHighlight(isTargeted: routeStopDropTargetID == "route-destination"))

            routeWaypointAddButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .modifier(NavigationGlassSurface(radius: 23, interactive: true))
    }

    private var routePlanningTransportSelector: some View {
        HStack(spacing: 3) {
            ForEach(routePlanningTransportModes) { mode in
                let selected = navigationStore.state.transportMode == mode
                Button {
                    Task { await navigationStore.selectTransportMode(mode) }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.naviTextSecondary.opacity(selected ? 1 : 0.78))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 27, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.13))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .modifier(NavigationGlassSurface(radius: 32, interactive: true))
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: navigationStore.state.transportMode)
    }

    private var routePlanningTransportModes: [TransportMode] {
        [.car, .walking, .transit, .bicycle, .parkRide]
    }

    private func routePlanningArrivalTime(_ route: NavigationRoute) -> String {
        let arrival = route.journey?.arrival ?? Date().addingTimeInterval(max(0, route.expectedTravelTime))
        return arrival.formatted(date: .omitted, time: .shortened)
    }

    private func routePlanningTrafficSummary(for route: NavigationRoute) -> (title: String, symbol: String, color: Color)? {
        guard navigationStore.state.transportMode == .car,
              let traffic = navigationStore.state.traffic else { return nil }
        let segments = traffic.routeFlowSegments.filter { $0.routeID == route.id }
        guard !segments.isEmpty else { return nil }
        let colors = Set(segments.map(\.colorHex))
        let prefix = "Ruch na początku trasy: "
        if segments.contains(where: \.isRoadClosure) {
            return (prefix + "zamknięcie", "nosign", Color(naviHex: NaviAstraColorPalette.closure))
        }
        if colors.contains(RouteColorPalette.trafficHeavy) {
            return (prefix + "duże spowolnienie", "exclamationmark.triangle.fill",
                    Color(naviHex: NaviAstraColorPalette.danger))
        }
        if colors.contains(RouteColorPalette.trafficSlow) {
            return (prefix + "spowolnienia", "car.side.fill", Color(naviHex: NaviAstraColorPalette.trafficSlow))
        }
        if colors.contains(RouteColorPalette.trafficModerate) {
            return (prefix + "umiarkowany", "car.side.fill", Color(naviHex: NaviAstraColorPalette.trafficModerate))
        }
        guard colors.contains(RouteColorPalette.trafficFree) else { return nil }
        return (prefix + "płynny", "leaf.fill", Color(naviHex: NaviAstraColorPalette.success))
    }

    @ViewBuilder
    private func routePlanningExpandedRouteOptions(for selectedRoute: NavigationRoute) -> some View {
        let routes = routePlanningOptions.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
        let fastestRouteID = routes.min { $0.expectedTravelTime < $1.expectedTravelTime }?.id
        if !routes.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(routes.enumerated()), id: \.element.id) { item in
                    routePlanningExpandedRouteCard(
                        item.element,
                        index: item.offset,
                        isSelected: item.element.id == selectedRoute.id,
                        isFastest: item.element.id == fastestRouteID)
                }
            }
        }
    }

    private func routePlanningExpandedRouteCard(_ route: NavigationRoute, index: Int,
                                                isSelected: Bool,
                                                isFastest: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { navigationStore.select(route) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(time(route.expectedTravelTime))
                        .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                    Text("U celu \(routePlanningArrivalTime(route)) · \(distance(route.distance))")
                        .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.naviTextSecondary.opacity(0.68))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let journey = route.journey {
                        routePlanningJourneyOverview(journey, darkStyle: false, compact: true)
                    }
                    if isFastest {
                        Text("Najszybsza")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(naviHex: NaviAstraColorPalette.success))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Trasa \(index + 1), \(time(route.expectedTravelTime)), \(distance(route.distance))\(routePlanningAccessibilitySummary(route))")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            routePlanningStartAction(compact: true, expandedCard: true) {
                startRoutePlanningOption(route)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .modifier(NavigationStableSurface(radius: 21))
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                              lineWidth: isSelected ? 2 : 1)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private func startRoutePlanningOption(_ route: NavigationRoute) {
        guard navigationStore.state.status == .routePreview else { return }
        navigationStore.select(route)
        if isRouteOriginAwayFromUser {
            navigateToRouteOrigin()
        } else {
            navigationStore.begin()
        }
    }

    private func routePlanningDetails(for route: NavigationRoute, showsManeuvers: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsManeuvers, !route.maneuvers.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Przebieg trasy")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                    ForEach(Array(route.maneuvers.prefix(12))) { maneuver in
                        HStack(alignment: .top, spacing: 9) {
                            ManeuverIcon(type: maneuver.type, fallbackSymbol: maneuver.iconName, size: 18)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(maneuver.displayInstruction)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.naviTextSecondary.opacity(0.88))
                                if let street = maneuver.streetLine {
                                    Text(street)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.naviTextSecondary.opacity(0.55))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            waypointDetails

            if navigationStore.state.transportMode == .car {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Opcje jazdy")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                    routePreferenceToggle("Unikaj autostrad", keyPath: \.avoidHighways)
                    routePreferenceToggle("Unikaj dróg płatnych", keyPath: \.avoidTolls)
                    routePreferenceToggle("Unikaj promów", keyPath: \.avoidFerries)
                    routePreferenceToggle("Unikaj dróg gruntowych", keyPath: \.avoidUnpaved)
                    Text("Unikanie autostrad, opłat i promów jest preferencją. Trasa może je zawierać, gdy są potrzebne do dojazdu.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
                .tint(Color.accentColor)
            }

            if !route.chargingStops.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Ładowanie po drodze")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                    Text("Szacowany czas postojów: \(Int((route.chargingDuration / 60).rounded())) min")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.naviTextSecondary.opacity(0.62))
                    Text("Czas ładowania jest szacunkiem z rezerwą na spadek mocy i podłączenie. Pogoda, zużycie energii i kolejki mogą wydłużyć podróż.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    ForEach(route.chargingStops) { stop in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.destination.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.naviTextPrimary)
                            Text("\(stop.connectorTypes.joined(separator: ", ")) · do \(Int(stop.maximumPowerKW.rounded())) kW · postój \(Int((stop.estimatedChargingTime / 60).rounded())) min")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.naviTextSecondary.opacity(0.62))
                            Text(stop.availabilityKnown ? "Status: działająca według OpenStreetMap" : "Dostępność ładowarki nieznana")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.naviTextSecondary.opacity(0.52))
                            Text(stop.publicAccess == true ? "Dostęp publiczny według OpenStreetMap" : "Dostęp publiczny niepotwierdzony")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.naviTextSecondary.opacity(0.52))
                        }
                        .padding(.top, 3)
                    }
                }
            }

            if let journey = route.journey {
                routePlanningJourneyDetails(journey, darkStyle: false)
            }

            if navigationStore.state.transportMode == .car {
                Button { appRouter.present(.trafficDetails) } label: {
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

    func routePlanningJourneyOverview(_ journey: Journey,
                                      darkStyle: Bool,
                                      compact: Bool = false) -> some View {
        let rides = journey.legs.filter { $0.mode != "WALK" }
        let primary = Color.naviTextPrimary
        let secondary = Color.naviTextSecondary
        let walkingColor = Color(naviHex: colorScheme == .dark
            ? NaviAstraColorPalette.walkingRouteNight : NaviAstraColorPalette.walkingRouteDay)
        let realtime = routePlanningRealtimeSummary(for: journey)
        return VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 5) {
                Image(systemName: rides.first.map { routePlanningTransitSymbol(for: $0) } ?? "figure.walk")
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
                    .foregroundStyle(rides.first.map {
                        mapTransitColor($0.lineColorHex ?? NaviAstraColorPalette.transitFallback)
                    } ?? walkingColor)
                Text(rides.isEmpty ? "Dojście pieszo" : rides.map { $0.line ?? $0.mode }.joined(separator: " → "))
                    .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Label(realtime.title, systemImage: realtime.symbol)
                    .font(.system(size: compact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(realtime.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(spacing: 4) {
                Text("Wsiadasz \(rides.first?.departure.formatted(date: .omitted, time: .shortened) ?? journey.departure.formatted(date: .omitted, time: .shortened))")
                Text("·")
                Text("Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
            }
            .font(.system(size: compact ? 9 : 10, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(secondary)
            HStack(spacing: 10) {
                Label("Pieszo \(transitMetricTime(journey.walkingDuration))", systemImage: "figure.walk")
                Label("\(journey.transferCount) \(transferCaption(journey.transferCount))", systemImage: "arrow.triangle.swap")
            }
            .font(.system(size: compact ? 9 : 10, weight: .medium))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            if let firstRide = rides.first {
                Label("Wsiadanie: \(firstRide.from)", systemImage: "mappin.and.ellipse")
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .combine)
    }

    func routePlanningJourneyDetails(_ journey: Journey, darkStyle: Bool) -> some View {
        let primary = Color.naviTextPrimary
        let secondary = Color.naviTextSecondary
        return VStack(alignment: .leading, spacing: 9) {
            Text("Połączenie")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary)
            routePlanningJourneyOverview(journey, darkStyle: darkStyle)
            Text("Oczekiwanie \(transitMetricTime(journey.waitingDuration))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondary)
            Text(transitRealtimeStatus(for: journey))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondary)
            if !journey.alerts.isEmpty {
                ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
                }
            } else if !journey.alertsFeedAvailable {
                Text("Komunikaty na trasie niedostępne")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondary)
            } else {
                Text("Brak aktywnych komunikatów dla tej trasy")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondary)
            }
            if let attribution = journey.railwayScheduleAttribution {
                Text(attribution)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(secondary)
            }
            if journey.scheduleIsCached {
                Text("Rozkład pobrany z pamięci urządzenia")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                    routePlanningJourneyLeg(leg, in: journey, darkStyle: darkStyle)
                    if index < journey.legs.count - 1 {
                        Rectangle()
                            .fill(darkStyle ? Color.white.opacity(0.16) : Color.primary.opacity(0.12))
                            .frame(width: 2, height: 12)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func routePlanningJourneyLeg(_ leg: JourneyLeg,
                                        in journey: Journey,
                                        darkStyle: Bool) -> some View {
        let isWalking = leg.mode == "WALK"
        let primary = Color.naviTextPrimary
        let secondary = Color.naviTextSecondary
        let walkingColor = Color(naviHex: colorScheme == .dark
            ? NaviAstraColorPalette.walkingRouteNight : NaviAstraColorPalette.walkingRouteDay)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isWalking ? "figure.walk" : routePlanningTransitSymbol(for: leg))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isWalking ? walkingColor : .white)
                .frame(width: 26, height: 26)
                .background(isWalking ? walkingColor.opacity(0.15) : mapTransitColor(leg.lineColorHex ?? NaviAstraColorPalette.transitFallback),
                            in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if !isWalking, let line = leg.line {
                        Text(line)
                            .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(mapTransitColor(leg.lineColorHex ?? NaviAstraColorPalette.transitFallback), in: Capsule())
                    } else {
                        Text(isWalking ? (leg.isTransfer ? "Przesiadka pieszo" : "Dojście pieszo") : "Transport publiczny")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(primary)
                    }
                    Spacer(minLength: 4)
                    Text("\(leg.departure.formatted(date: .omitted, time: .shortened))–\(leg.arrival.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
                Text("\(leg.from) → \(leg.to)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    if isWalking {
                        Text(transitMetricTime(leg.arrival.timeIntervalSince(leg.departure)))
                            .foregroundStyle(secondary)
                        if leg.walkingTimeIsApproximate {
                            Text("Czas dojścia szacunkowy")
                                .foregroundStyle(secondary)
                        } else if !leg.hasResolvedWalkingGeometry {
                            Text("Przebieg dojścia orientacyjny")
                                .foregroundStyle(secondary)
                        }
                    } else {
                        if leg.transitStops.count > 1 {
                            Text("\(leg.transitStops.count) przyst.")
                                .foregroundStyle(secondary)
                        }
                        if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                            Text(delayLabel(TimeInterval(delay)))
                                .foregroundStyle(transitDelayColor(delay))
                            Text(transitTimeSourceLabel(for: leg, in: journey))
                                .foregroundStyle(secondary)
                        } else if leg.realTime || hasLiveTransitUpdate(for: leg) {
                            Text(transitTimeSourceLabel(for: leg, in: journey))
                                .foregroundStyle(secondary)
                        } else {
                            Text("wg rozkładu")
                                .foregroundStyle(secondary)
                        }
                    }
                }
                .font(.system(size: 9, weight: .medium))
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(darkStyle ? Color.white.opacity(0.055) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func routePlanningTransitSymbol(for leg: JourneyLeg) -> String {
        switch leg.mode.uppercased() {
        case "BUS": "bus.fill"
        case "RAIL", "TRAIN": "train.side.front.car"
        default: "tram.fill"
        }
    }

    private func routePlanningRealtimeSummary(for journey: Journey) -> (title: String, symbol: String, color: Color) {
        switch journey.realtimeFreshness {
        case .live: ("Na żywo", "dot.radiowaves.left.and.right", Color(naviHex: NaviAstraColorPalette.success))
        case .degraded: ("Realtime opóźnione", "clock.badge.exclamationmark", Color(naviHex: NaviAstraColorPalette.warning))
        case .stale: ("Realtime nieświeże", "clock", Color.naviTextSecondary)
        case .unavailable: ("Tylko rozkład", "clock", Color(naviHex: NaviAstraColorPalette.info))
        }
    }

    private func routePlanningAccessibilitySummary(_ route: NavigationRoute) -> String {
        guard let journey = route.journey else { return "" }
        let lines = journey.legs.filter { $0.mode != "WALK" }
            .map { $0.line ?? $0.mode }
            .joined(separator: " do ")
        let departure = journey.legs.first(where: { $0.mode != "WALK" })?.departure ?? journey.departure
        let lineSummary = lines.isEmpty ? "dojście pieszo" : "linie \(lines)"
        return ", \(lineSummary), wsiadasz \(departure.formatted(date: .omitted, time: .shortened)), przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened)), pieszo \(transitMetricTime(journey.walkingDuration)), \(journey.transferCount) \(transferCaption(journey.transferCount)), \(routePlanningRealtimeSummary(for: journey).title)"
    }

    @ViewBuilder
    private var routePlanningUnavailable: some View {
        if navigationStore.state.status == .error {
            Text(navigationStore.state.errorMessage ?? "Nie udało się wyznaczyć trasy.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.naviTextSecondary.opacity(0.75))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NavigationGlassSurface(radius: 19))
        }
    }

    private func routePlanningFooter(bottomInset: CGFloat, compact: Bool, medium: Bool,
                                    showsSecondaryActions: Bool) -> some View {
        VStack(spacing: 7) {
            if navigationStore.state.status == .routePreview,
               let route = navigationStore.state.route {
                routePlanningSelectedRouteCard(route, compact: compact, medium: medium)
            } else if navigationStore.state.status == .error {
                Button {
                    Task { await navigationStore.planRoute() }
                } label: {
                    Label(compact ? "Ponów" : "Spróbuj ponownie", systemImage: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            } else if navigationStore.state.status == .routeCalculating {
                HStack(spacing: 9) {
                    ProgressView()
                    Text(navigationStore.state.transportMode == .transit ? "Szukam połączeń…" : "Wyznaczanie trasy…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.naviTextSecondary.opacity(0.78))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }

            if showsSecondaryActions {
                routePlanningSecondaryActions(compact: compact)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, compact ? 0 : 8)
        .padding(.bottom, compact ? 8 : max(12, min(22, bottomInset * 0.55)))
        .background(.regularMaterial)
    }

    private func routePlanningSecondaryActions(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                navigationStore.stop()
            } label: {
                Label("Anuluj trasę", systemImage: "xmark")
                    .font(compact ? .system(size: 13, weight: .medium) : .subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: compact ? 38 : 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.naviTextSecondary.opacity(0.7))
            .accessibilityLabel("Anuluj trasę")

            if let url = routePlanningShareURL {
                ShareLink(item: url) {
                    Label("Udostępnij", systemImage: "square.and.arrow.up")
                        .font(compact ? .system(size: 13, weight: .medium) : .subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: compact ? 38 : 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.naviTextSecondary.opacity(0.7))
                .accessibilityLabel("Udostępnij trasę")
            } else {
                Button {} label: {
                    Label("Udostępnij", systemImage: "square.and.arrow.up")
                        .font(compact ? .system(size: 13, weight: .medium) : .subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: compact ? 38 : 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.naviTextSecondary.opacity(0.42))
                .disabled(true)
                .accessibilityLabel("Udostępnianie trasy niedostępne")
            }
        }
    }

    private func routePlanningSelectedRouteCard(_ route: NavigationRoute, compact: Bool,
                                                medium: Bool) -> some View {
        let routes = routePlanningCarouselRoutes
        let selectedIndex = routes.firstIndex(where: { $0.id == route.id }) ?? 0

        return HStack(spacing: medium ? 14 : (compact ? 12 : 16)) {
            VStack(alignment: .leading, spacing: medium ? 5 : (compact ? 3 : 7)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(time(route.expectedTravelTime))
                        .font(.system(size: medium ? 30 : (compact ? 23 : 34), weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if routes.count > 1 {
                        Text("\(selectedIndex + 1) / \(routes.count)")
                            .font((medium ? Font.headline : (compact ? Font.caption : Font.subheadline))
                                .weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.naviTextSecondary.opacity(0.62))
                    }
                }

                Text("U celu \(routePlanningArrivalTime(route)) · \(distance(route.distance))")
                    .font(.system(size: medium ? 14 : (compact ? 11 : 14), weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.naviTextSecondary.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if !compact, let traffic = routePlanningTrafficSummary(for: route) {
                    Label(traffic.title, systemImage: traffic.symbol)
                        .font(.system(size: medium ? 11 : 12, weight: .semibold))
                        .foregroundStyle(traffic.color)
                        .lineLimit(1)
                }

                if routes.count > 1 {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(routes.indices, id: \.self) { index in
                                Capsule()
                                    .fill(index == selectedIndex ? Color.accentColor : Color.primary.opacity(0.2))
                                    .frame(width: index == selectedIndex ? 13 : 5, height: 5)
                            }
                        }
                        .accessibilityHidden(true)
                        Text("Przesuń, aby zmienić trasę")
                            .font(.system(size: compact && !medium ? 10 : 12, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
            routePlanningStartAction(compact: true, emphasized: medium || !compact, medium: medium)
        }
        .padding(medium ? 12 : (compact ? 9 : 16))
        .frame(maxWidth: .infinity, minHeight: medium ? 112 : (compact ? 70 : 208), alignment: .leading)
        .modifier(NavigationStableSurface(radius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard routes.count > 1, abs(value.translation.width) > abs(value.translation.height) * 1.25,
                  abs(value.translation.width) >= 36 else { return }
            selectAdjacentRoute(by: value.translation.width < 0 ? 1 : -1)
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wybrana trasa, \(time(route.expectedTravelTime)), przyjazd \(routePlanningArrivalTime(route)), \(distance(route.distance))")
        .accessibilityValue(routes.isEmpty ? "Wybrana trasa" : "Trasa \(selectedIndex + 1) z \(routes.count)")
        .accessibilityHint(routes.count > 1 ? "Przesuń w lewo lub prawo, aby wybrać inną trasę. Możesz też użyć regulacji VoiceOver." : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selectAdjacentRoute(by: 1)
            case .decrement: selectAdjacentRoute(by: -1)
            @unknown default: break
            }
        }
    }

    private func selectAdjacentRoute(by offset: Int) {
        guard navigationStore.state.status == .routePreview,
              let selectedID = navigationStore.state.route?.id else { return }
        let routes = routePlanningCarouselRoutes
        guard let selectedIndex = routes.firstIndex(where: { $0.id == selectedID }),
              routes.indices.contains(selectedIndex + offset) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            navigationStore.select(routes[selectedIndex + offset])
        }
    }

    private func routePlanningStartAction(compact: Bool = false, emphasized: Bool = false,
                                          medium: Bool = false, expandedCard: Bool = false,
                                          action: (() -> Void)? = nil) -> some View {
        let canStart = navigationStore.state.status == .routePreview && navigationStore.state.route != nil
        return Button {
            if let action {
                action()
            } else if isRouteOriginAwayFromUser {
                navigateToRouteOrigin()
            } else {
                navigationStore.begin()
            }
        } label: {
            VStack(spacing: compact && !emphasized && !expandedCard ? 4 : 9) {
                Image(systemName: isRouteOriginAwayFromUser ? "location.magnifyingglass" : "location.fill")
                    .font(.system(size: compact ? (medium || expandedCard ? 22 : (emphasized ? 26 : 18)) : 17, weight: .bold))
                Text(compact ? "Start" : (isRouteOriginAwayFromUser ? "Nawiguj do startu" : "Rozpocznij nawigację"))
                    .font(.system(size: compact ? (medium ? 17 : (expandedCard ? 16 : (emphasized ? 20 : 13))) : 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: compact ? nil : .infinity,
                   minHeight: compact ? (medium ? 88 : (expandedCard ? 92 : (emphasized ? 130 : 58))) : 56)
            .frame(width: compact ? (medium ? 88 : (expandedCard ? 92 : (emphasized ? 112 : 72))) : nil)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.55)
        .accessibilityLabel(isRouteOriginAwayFromUser ? "Nawiguj do punktu startowego" : "Rozpocznij nawigację")
    }

}

struct RouteStopDropTargetHighlight: ViewModifier {
    let isTargeted: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.14) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
            }
            .animation(.easeOut(duration: 0.16), value: isTargeted)
    }
}
