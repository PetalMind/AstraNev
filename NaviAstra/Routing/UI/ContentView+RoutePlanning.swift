import SwiftUI

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
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 40, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: 40),
            style: .continuous)

        return VStack(spacing: 0) {
            routePlanningDragHandle

            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    routePlanningEndpoints
                    routePlanningTransportSelector

                    if navigationStore.state.transportMode == .transit || navigationStore.state.transportMode == .parkRide {
                        journeyTimeControl
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let route = navigationStore.state.route {
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
    }

    private var routePlanningDragHandle: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.48))
                .frame(width: 38, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
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
                Button { appRouter.present(.originPicker) } label: {
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
                .disabled(navigationStore.state.destination == nil || routeOriginPoint == nil)
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
                        Text(navigationStore.state.destination?.name ?? "Dokąd?")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(navigationStore.state.destination?.address ?? "Cel podróży")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.56))
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
                    let selected = navigationStore.state.transportMode == mode
                    Button {
                        Task { await navigationStore.selectTransportMode(mode) }
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
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: navigationStore.state.transportMode)
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
                if navigationStore.state.transportMode == .transit, let journey = route.journey {
                    routePlanningJourneyOverview(journey, darkStyle: true, compact: true)
                }
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
                    navigationStore.begin()
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
            .disabled(navigationStore.state.status != .routePreview
                      || navigationStore.state.transitPlanningPhase == .enrichingGeometry)
            .opacity(navigationStore.state.status == .routePreview
                     && navigationStore.state.transitPlanningPhase != .enrichingGeometry ? 1 : 0.55)
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
        guard navigationStore.state.transportMode == .car,
              let traffic = navigationStore.state.traffic else { return nil }
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
                        withAnimation(.easeInOut(duration: 0.25)) { navigationStore.select(route) }
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(time(route.expectedTravelTime))
                                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let journey = route.journey {
                                    routePlanningJourneyOverview(journey, darkStyle: true, compact: true)
                                } else {
                                    Text(distance(route.distance))
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.57))
                                }
                            }
                            Spacer(minLength: 3)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(isSelected ? "Wybrana" : "Alternatywna")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.76))
                                if !isSelected {
                                    Text(routePlanningDifference(route, from: selectedRoute))
                                        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                                        .foregroundStyle(Color.white.opacity(0.55))
                                }
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
                    .accessibilityLabel("\(isSelected ? "Wybrana trasa" : "Alternatywna trasa"), \(time(route.expectedTravelTime)), \(distance(route.distance))\(routePlanningAccessibilitySummary(route))")
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
                routePlanningJourneyDetails(journey, darkStyle: true)
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
        let primary = darkStyle ? Color.white : Color.primary
        let secondary = darkStyle ? Color.white.opacity(0.64) : Color.primary.opacity(0.62)
        let realtime = routePlanningRealtimeSummary(for: journey)
        return VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 5) {
                Image(systemName: rides.first.map { routePlanningTransitSymbol(for: $0) } ?? "figure.walk")
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
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
        let primary = darkStyle ? Color.white : Color.primary
        let secondary = darkStyle ? Color.white.opacity(0.64) : Color.primary.opacity(0.62)
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
                        .foregroundStyle(.orange)
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
        let primary = darkStyle ? Color.white : Color.primary
        let secondary = darkStyle ? Color.white.opacity(0.62) : Color.primary.opacity(0.62)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isWalking ? "figure.walk" : routePlanningTransitSymbol(for: leg))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isWalking ? Color.accentColor : .white)
                .frame(width: 26, height: 26)
                .background(isWalking ? Color.accentColor.opacity(0.15) : mapTransitColor(leg.lineColorHex ?? 0x2867B2),
                            in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if !isWalking, let line = leg.line {
                        Text(line)
                            .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(mapTransitColor(leg.lineColorHex ?? 0x2867B2), in: Capsule())
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
        case .live: ("Na żywo", "dot.radiowaves.left.and.right", .green)
        case .degraded: ("Realtime opóźnione", "clock.badge.exclamationmark", .orange)
        case .stale: ("Realtime nieświeże", "clock", .secondary)
        case .unavailable: ("Tylko rozkład", "clock", .secondary)
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

    private var routePlanningUnavailable: some View {
        VStack(alignment: .leading, spacing: 9) {
            if navigationStore.state.status == .routeCalculating {
                HStack(spacing: 9) {
                    ProgressView()
                    Text(navigationStore.state.transportMode == .transit ? "Szukam połączeń…" : "Wyznaczanie trasy…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            } else {
                Text(navigationStore.state.errorMessage ?? "Nie udało się wyznaczyć trasy.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                Button {
                    Task { await navigationStore.planRoute() }
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

}
