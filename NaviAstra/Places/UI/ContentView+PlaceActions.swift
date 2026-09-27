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

    var recentPlaceShortcuts: [PlaceShortcut] {
        var candidates: [(date: Date, shortcut: PlaceShortcut)] = []
        for search in placeStore.searches {
            candidates.append((search.searchedAt, PlaceShortcut(
                id: "recent-\(search.id.uuidString)",
                title: search.destination.name,
                symbol: "clock.arrow.circlepath",
                destination: search.destination,
                isRecent: true
            )))
        }

        for trip in placeStore.trips {
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
        let speed = fresh ? navigationStore.state.location?.speed : nil
        let current = speed.flatMap { $0 >= 0 ? Int(($0 * 3.6).rounded()) : nil }
        let limit = fresh ? navigationStore.state.speedLimitKph : nil
        let aboveLimit = speedWarningsEnabled && (current.map { value in limit.map { value > $0 + 5 } ?? false } ?? false)
        let routeDistance = navigationStore.state.progress?.traveledDistance ?? 0
        let nextRoadAlert = navigationStore.state.roadSafetyAlerts
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
                        Text(navigationStore.state.speedLimitSource.map { "\($0.shortTitle) · km/h" } ?? "km/h")
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
                } else if let message = navigationStore.state.speedLimitMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if case .loading = navigationStore.state.roadSafetyStatus {
                    Label("Pobieranie ostrzeżeń drogowych…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if case .unavailable = navigationStore.state.roadSafetyStatus {
                    Label("Ostrzeżenia drogowe niedostępne", systemImage: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if case .available = navigationStore.state.roadSafetyStatus {
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
            placeStore.selectedMapPlaces = places
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
        placeStore.selectedMapPlaces = [selected]

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
