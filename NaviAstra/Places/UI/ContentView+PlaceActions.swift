import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var savedPlaceShortcuts: [PlaceShortcut] {
        var shortcuts: [PlaceShortcut] = []

        for kind in [PlaceKind.home, .work, .favorite] {
            for place in placeStore.places where place.kind == kind && (kind != .favorite || place.isPinned) {
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

    var recentPlaceShortcuts: [RecentPlaceShortcut] {
        var candidates: [RecentPlaceShortcut] = []
        for search in placeStore.searches {
            candidates.append(RecentPlaceShortcut(
                id: "recent-\(search.id.uuidString)",
                destination: search.destination,
                usedAt: search.searchedAt
            ))
        }

        for trip in placeStore.trips {
            candidates.append(RecentPlaceShortcut(
                id: "trip-\(trip.id.uuidString)",
                destination: trip.destination,
                usedAt: trip.endedAt
            ))
        }

        var recent: [RecentPlaceShortcut] = []
        for candidate in candidates.sorted(by: { $0.usedAt > $1.usedAt }) {
            guard recent.count < 6 else { break }
            guard !recent.contains(where: {
                $0.destination.coordinate == candidate.destination.coordinate
            }) else { continue }
            recent.append(candidate)
        }
        return recent
    }

    var quickETADestinationFingerprint: String {
        savedPlaceShortcuts.prefix(6).compactMap { shortcut in
            placeStore.places.first(where: { $0.id.uuidString == shortcut.id })
        }.map { place in
            let coordinate = place.destination.coordinate
            return "\(place.id.uuidString):\(coordinate.latitude),\(coordinate.longitude)"
        }.joined(separator: "|")
    }

    func refreshQuickDestinationETAs() async {
        guard !quickETAInFlight, let origin = navigationStore.state.location?.coordinate else { return }
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
            guard let estimate = await navigationStore.estimatedCarRouteEstimate(to: shortcut.destination) else { continue }
            estimates[shortcut.id] = estimate
        }
        quickETAEstimates = estimates
    }

    var recentDestinations: [Destination] {
        var destinations: [Destination] = []
        for trip in placeStore.trips {
            guard !destinations.contains(where: { $0.coordinate == trip.destination.coordinate }) else { continue }
            destinations.append(trip.destination)
            if destinations.count == 5 { break }
        }
        return destinations
    }

    func metric(value: String, caption: String) -> some View {
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
    func speedCard(at now: Date) -> some View {
        let fresh = navigationStore.state.location.map { now.timeIntervalSince($0.timestamp) < 15 } ?? false
        let speed = navigationStore.state.location?.speed
        let current: Int? = speed.flatMap { value -> Int? in
            guard value.isFinite, fresh || value <= 0 else { return nil }
            return Int((max(0, value) * 3.6).rounded())
        }
        let limit = navigationStore.state.speedLimitKph
        let aboveLimit = speedWarningsEnabled && (current.map { value in limit.map { value > $0 + 5 } ?? false } ?? false)
        let routeDistance = navigationStore.state.progress?.traveledDistance ?? 0
        let nextRoadAlert = nextNavigationRoadSafetyAlert
        let speedDescription = current.map { "Prędkość \($0) kilometrów na godzinę" } ?? "Prędkość niedostępna"
        let accessibilityDescription = [
            limit.map { "Limit \($0) kilometrów na godzinę" },
            speedDescription,
            navigationStore.state.speedLimitSource.map { "Źródło limitu: \($0.shortTitle)" },
            nextRoadAlert.map { "\($0.title), za \($0.distanceText(from: routeDistance))" }
        ].compactMap { $0 }.joined(separator: ", ")

        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 6) {
                if let limit {
                    VStack(spacing: 3) {
                        Text(String(limit))
                            .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.black)
                            .frame(width: 54, height: 54)
                            .background(Color.white, in: Circle())
                            .overlay(Circle().strokeBorder(Color.red, lineWidth: 4))
                            .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
                            .accessibilityHidden(true)
                        if let source = navigationStore.state.speedLimitSource {
                            Text(source.shortTitle)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.82))
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 76)
                }

                VStack(spacing: 0) {
                    Text(current.map(String.init) ?? "—")
                        .font(.system(size: 29, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(aboveLimit ? Color.red : Color.black)
                        .contentTransition(.numericText())
                    Text("km/h")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.62))
                }
                .frame(width: 76, height: 62)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(aboveLimit ? Color.red.opacity(0.8) : Color.black.opacity(0.08), lineWidth: aboveLimit ? 2 : 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .accessibilityHidden(true)
            }

            if let alert = nextRoadAlert {
                HStack(spacing: 9) {
                    roadAlertSymbol(alert)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(alert.distanceText(from: routeDistance))
                            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NavigationGlassSurface(radius: 15))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(alert.title), \(alert.distanceText(from: routeDistance))")
            } else if let message = navigationStore.state.speedLimitMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if current == nil {
                Label(navigationStore.state.location == nil
                      ? "Prędkość niedostępna"
                      : (fresh ? "Odczyt prędkości niedostępny" : "Brak świeżego odczytu GPS"),
                      systemImage: "location.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 230, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    var nextNavigationRoadSafetyAlert: RoadSafetyAlert? {
        let routeDistance = navigationStore.state.progress?.traveledDistance ?? 0
        return navigationStore.state.roadSafetyAlerts
            .filter { alert in
                guard alert.type.isTrafficSign || alert.type.isEnforcement || alert.type == .speedLimitChange,
                      let distance = alert.distanceAlongRoute else { return false }
                return distance >= routeDistance && distance <= routeDistance + 2_000
            }
            .min { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
    }

    var hasUpcomingRoadSafetyWarning: Bool {
        let routeDistance = navigationStore.state.progress?.traveledDistance ?? 0
        return navigationStore.state.roadSafetyAlerts.contains { alert in
            guard let distance = alert.distanceAlongRoute else { return false }
            return distance >= routeDistance && distance <= routeDistance + 2_000
        }
    }

    @ViewBuilder
    private func roadAlertSymbol(_ alert: RoadSafetyAlert) -> some View {
        switch alert.type {
        case .stopSign:
            Text("STOP")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.red, in: RoadStopSignShape())
                .overlay(RoadStopSignShape().stroke(.white, lineWidth: 1.5).padding(3))
        case .speedLimitSign:
            Text(alert.signCode?.hasSuffix("B-34") == true
                 ? "END" : (alert.speedLimitKph.map(String.init) ?? "?"))
                .font(.system(size: alert.speedLimitKph == nil ? 9 : 13, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
                .frame(width: 38, height: 38)
                .background(.white, in: Circle())
                .overlay(Circle().strokeBorder(.red, lineWidth: 3))
        default:
            Image(systemName: alert.type.symbolName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(alert.type.isEnforcement ? Color.white : Color.orange)
                .frame(width: 36, height: 36)
                .background(
                    alert.type.isEnforcement ? Color.accentColor : Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    func errorNotice(_ message: String) -> some View {
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

    func circleSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 48, height: 48)
            .modifier(NavigationGlassSurface(radius: 24, interactive: true))
    }

    func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
    }

    func presentSearch() {
        selectingRouteOriginInSearch = false
        appRouter.present(.search)
    }

    func presentNearby(_ category: NearbyPlaceCategory, nearDestination: Bool = false) {
        placeStore.nearbyRequest = NearbySearchRequest(category: category, nearDestination: nearDestination)
    }

    func presentNearbyAfterMenuDismissal(_ category: NearbyPlaceCategory, nearDestination: Bool = false) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            presentNearby(category, nearDestination: nearDestination)
        }
    }

    func selectDestination(_ destination: Destination, recordSearch: Bool = true) {
        appRouter.dismiss(.search)
        if recordSearch { placeStore.recordSearch(destination) }
        navigationStore.selectDestination(destination)
        Task { await navigationStore.planRoute() }
    }

    func selectMapCoordinate(_ coordinate: Coordinate) {
        let destination = Destination(name: "Wybrany punkt", coordinate: coordinate)
        selectDestination(destination, recordSearch: false)
        Task {
            guard let address = await GUGiKAddressProvider().reverseGeocode(coordinate),
                  let current = navigationStore.state.destination,
                  current.id == destination.id else { return }
            navigationStore.state.destination = Destination(id: current.id, name: current.name,
                                                   coordinate: current.coordinate, address: address)
        }
    }

    func presentMapPlaces(_ places: [SearchResult]) {
        mapPlaceEstimateTask?.cancel()
        guard !places.isEmpty else { return }
        if places.count == 1, let place = places.first {
            presentMapPlace(place)
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                selectedMapPlaceDetent = .medium
                placeStore.selectedMapPlaces = places
            }
        }
    }

    func presentMapPlace(_ result: SearchResult) {
        mapPlaceEstimateTask?.cancel()
        let origin = navigationStore.state.location?.coordinate
        let navigationActive = isNavigating
        let mode = navigationStore.state.transportMode
        let canRequestETA = origin != nil && mode != .transit && mode != .parkRide
        var selected = result
        selected.travelEstimateStatus = canRequestETA ? .calculating : .unavailable

        if navigationActive {
            if let origin, let route = navigationStore.state.route?.coordinates,
               let currentProjection = MapMatcher.project(origin, onto: route) {
                let futureRoute = Array(route.dropFirst(currentProjection.segment))
                selected.detourDistance = MapMatcher.project(result.destination.coordinate, onto: futureRoute)?.distanceFromRoute
            }
        } else if let origin {
            selected.straightDistance = origin.distance(to: result.destination.coordinate)
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            selectedMapPlaceDetent = .medium
            placeStore.selectedMapPlaces = [selected]
        }

        guard canRequestETA, let origin else { return }
        let requestID = selected.id
        let preferences = navigationStore.state.routingPreferences
        let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ??
                           "https://valhalla1.openstreetmap.de")!
        let activeWaypoint = navigationStore.state.waypoints.first
        let activeDestination = navigationStore.state.destination
        let activeNavigationTarget = navigationStore.state.navigationTarget?.coordinate
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
                        guard placeStore.selectedMapPlaces.first?.id == requestID else { return }
                        updated.travelEstimateStatus = .unavailable
                        placeStore.selectedMapPlaces = [updated]
                        return
                    }
                    let rows = try await provider.searchMatrix(
                        sources: [origin, destinationCoordinate],
                        targets: [destinationCoordinate, routeTarget],
                        mode: mode, preferences: preferences)
                    guard rows.count == 2, rows.allSatisfy({ $0.count == 2 }),
                          placeStore.selectedMapPlaces.first?.id == requestID else { return }
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
                    guard placeStore.selectedMapPlaces.first?.id == requestID,
                          let cell = rows.first?.first else { return }
                    updated.travelTime = cell.time
                    updated.travelDistance = cell.distance.map { $0 * 1_000 }
                    updated.travelEstimateStatus = cell.time == nil ? .unavailable : .notRequested
                } else {
                    updated.travelEstimateStatus = .unavailable
                }
                guard !Task.isCancelled else { return }
                placeStore.selectedMapPlaces = [updated]
            } catch {
                guard !Task.isCancelled, placeStore.selectedMapPlaces.first?.id == requestID else { return }
                var updated = placeStore.selectedMapPlaces[0]
                updated.travelEstimateStatus = .unavailable
                guard !Task.isCancelled else { return }
                placeStore.selectedMapPlaces = [updated]
            }
        }
    }

    func replayTrip(_ trip: TripRecord) {
        appRouter.dismiss(.history)
        navigationStore.state.waypoints = trip.waypoints
        Task { await navigationStore.previewNewTrip(trip.destination) }
    }

    func saveCurrentPlace(as kind: PlaceKind) {
        guard let destination = navigationStore.state.destination else { return }
        let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        placeStore.add(destination, kind: kind, customName: name.isEmpty ? nil : name)
        favoriteName = ""
        isSavingPlace = false
    }

    func toggleDestinationFavorite() {
        guard let destination = navigationStore.state.destination else { return }
        if isDestinationFavorite {
            showFavoriteRemovalConfirmation = true
            return
        }
        guard placeStore.add(destination, kind: .favorite) else { return }
        animateFavoritePulse()
    }

    func animateFavoritePulse() {
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

    func removeFavorite(for destination: Destination) -> Bool {
        guard let place = placeStore.places.first(where: {
            $0.kind == .favorite && $0.destination.coordinate == destination.coordinate
        }) else { return false }
        placeStore.removePlace(place.id)
        return !placeStore.places.contains { $0.id == place.id }
    }

    func renameFavorite(for destination: Destination, to name: String) -> Bool {
        guard let place = placeStore.places.first(where: {
            $0.kind == .favorite && $0.destination.coordinate == destination.coordinate
        }) else { return false }
        return placeStore.updatePlace(place.id, customName: name)
    }

    func distance(_ meters: Double) -> String {
        guard meters >= 1000 else { return "\(Int(meters)) m" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let kilometers = formatter.string(from: NSNumber(value: meters / 1000)) ?? String(meters / 1000)
        return "\(kilometers) km"
    }

    func time(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(seconds / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(totalMinutes) min" }
        guard minutes > 0 else { return "\(hours) godz." }
        return "\(hours) godz. \(minutes) min"
    }

    func arrivalTime(_ seconds: TimeInterval) -> String {
        (navigationStore.state.estimatedArrival ?? Date().addingTimeInterval(max(0, seconds)))
            .formatted(date: .omitted, time: .shortened)
    }

    func timeAllowingZero(_ seconds: TimeInterval) -> String {
        guard seconds > 30 else { return "0 min" }
        return time(seconds)
    }

    func delayLabel(_ seconds: TimeInterval) -> String {
        guard abs(seconds) >= 60 else { return "Na czas" }
        let sign = seconds > 0 ? "+" : "−"
        return sign + time(abs(seconds))
    }
}

private struct RoadStopSignShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = min(rect.width, rect.height) * 0.29
        let points = [
            CGPoint(x: rect.minX + cut, y: rect.minY),
            CGPoint(x: rect.maxX - cut, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY + cut),
            CGPoint(x: rect.maxX, y: rect.maxY - cut),
            CGPoint(x: rect.maxX - cut, y: rect.maxY),
            CGPoint(x: rect.minX + cut, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY - cut),
            CGPoint(x: rect.minX, y: rect.minY + cut)
        ]
        return Path { path in
            path.addLines(points)
            path.closeSubpath()
        }
    }
}
