#if os(iOS)
import Foundation

/// Reads the live navigation state. Queries never change the route or replay a
/// cached announcement, which may already refer to a junction behind the user.
@MainActor
final class VoiceNavigationActions {
    private let navigationStore: NavigationStore
    private let placeStore: PlaceStore

    init(navigationStore: NavigationStore, placeStore: PlaceStore) {
        self.navigationStore = navigationStore
        self.placeStore = placeStore
    }

    func answer(_ query: VoiceQuery) -> String {
        Self.answer(query, state: navigationStore.state, now: .now)
    }

    func savedDestination(named name: String) -> Destination? {
        let normalized = QueryClassifier.normalize(name)
        let kind: PlaceKind? = switch normalized {
        case "dom", "domu", "do domu": .home
        case "praca", "pracy", "do pracy": .work
        default: nil
        }
        let matches = placeStore.places.filter {
            if let kind { return $0.kind == kind }
            return QueryClassifier.normalize($0.displayName) == normalized
        }
        // A duplicate saved label needs the same disambiguation as a search.
        return matches.count == 1 ? matches.first?.navigationDestination : nil
    }

    func searchDestinations(_ query: String) async throws -> [Destination] {
        if let saved = savedDestination(named: query) { return [saved] }
        let state = navigationStore.state
        var remainingRoute: [Coordinate] = []
        if state.status == .navigating, let route = state.route,
           let origin = state.location?.coordinate,
           let projection = MapMatcher.project(origin, onto: route.coordinates) {
            remainingRoute = [projection.coordinate] + Array(route.coordinates.dropFirst(projection.segment + 1))
        }
        let context = SearchContext(
            origin: state.location?.coordinate ?? state.searchMapCenter,
            route: remainingRoute,
            routeTarget: state.navigationTarget?.coordinate ?? state.destination?.coordinate,
            mode: state.transportMode, preferences: state.routingPreferences,
            localDestinations: placeStore.places.map(\.navigationDestination)
                + placeStore.searches.map(\.destination))
        let address = UserDefaults.standard.string(forKey: "routingServer") ?? ""
        let endpoint = URL(string: address) ?? URL(string: "https://valhalla1.openstreetmap.de")!
        let results = try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint))
            .search(query, context: context)
        try Task.checkCancellation()
        return Array(results.prefix(5)).map(\.navigationDestination)
    }

    func findStops(_ category: NearbyPlaceCategory, nearDestination: Bool) async -> [RouteStopSuggestion] {
        let routeID = navigationStore.state.route?.id
        let destinationID = navigationStore.state.destination?.id
        await navigationStore.searchNearbyPlaces(category, nearDestination: nearDestination,
                                                resultLimit: 12)
        guard !Task.isCancelled,
              navigationStore.state.route?.id == routeID,
              navigationStore.state.destination?.id == destinationID else { return [] }
        return navigationStore.state.nearbySuggestions.filter { $0.candidate.category == category }
    }

    func describeStop(_ stop: RouteStopSuggestion) -> String {
        let name = stop.candidate.destination.name
        if let detour = stop.detourSeconds, detour.isFinite, detour >= 0 {
            if detour < 60 { return "\(name). Dodatkowy czas jazdy: mniej niż minuta." }
            return "\(name). Dodatkowy czas jazdy: około \(Self.duration(detour))."
        }
        if let travel = stop.travelTime, travel.isFinite, travel >= 0 {
            return "\(name). Dojazd zajmie około \(Self.duration(travel)). Nie znam dodatkowego czasu całej trasy."
        }
        return "\(name). Dodatkowy czas jazdy jest niedostępny."
    }

    static func answer(_ query: VoiceQuery, state: NavigationState, now: Date) -> String {
        if state.status == .arrived { return "Cel podróży został osiągnięty." }
        if state.status == .rerouting || state.status == .routeCalculating {
            return "Trwa przeliczanie trasy. Zapytaj ponownie za chwilę."
        }
        guard state.status == .navigating, let route = state.route else {
            return "Najpierw rozpocznij nawigację, aby zapytać o bieżącą podróż."
        }
        guard let location = state.location,
              (-5...15).contains(now.timeIntervalSince(location.timestamp)),
              location.accuracy.isFinite, (0...100).contains(location.accuracy),
              !state.weakGPS, (state.gpsQuality == .good || state.gpsQuality == .excellent) else {
            return "Czekam na dokładną, aktualną pozycję GPS. Zapytaj ponownie za chwilę."
        }
        guard let progress = state.progress, progress.geometryRouteID == route.id else {
            return "Aktualizuję postęp na nowej trasie. Zapytaj ponownie za chwilę."
        }
        if route.journey == nil {
            guard let match = state.routeMatch, match.routeID == route.id,
                  match.locationTimestamp == location.timestamp, !match.isAmbiguous,
                  match.match.confidence >= 0.5, state.deviationState == .onRoute else {
                return "Nie mogę jeszcze dokładnie dopasować pozycji do trasy. Zapytaj ponownie za chwilę."
            }
        }
        switch query {
        case .arrival:
            guard state.etaConfidence?.level != .blocked else {
                return "Na trasie jest zamknięcie. Czas dojazdu wymaga przeliczenia."
            }
            guard let arrival = state.estimatedArrival, arrival >= now,
                  progress.remainingTime.isFinite, progress.remainingTime >= 0 else {
                return "Aktualny czas dojazdu jest niedostępny."
            }
            let prefix = route.journey.map { $0.realtimeFreshness != .live } == true
                ? "Według rozkładu dotrzesz" : "Szacowany przyjazd"
            let clock = Calendar.current.isDate(arrival, inSameDayAs: now)
                ? "o " + PolishRegionalFormat.time(arrival)
                : PolishRegionalFormat.dateTime(arrival)
            return "\(prefix) \(clock). Pozostało około \(duration(progress.remainingTime))."
        case .remaining:
            guard progress.remainingDistance.isFinite, progress.remainingDistance >= 0,
                  progress.remainingTime.isFinite, progress.remainingTime >= 0 else {
                return "Aktualna odległość do celu jest niedostępna."
            }
            return "Do celu pozostało około \(distance(progress.remainingDistance)) i \(duration(progress.remainingTime))."
        case .maneuver:
            if route.journey != nil { return transitAnswer(.transitLine, state: state, route: route) }
            return maneuverAnswer(progress)
        case .lanes:
            guard let maneuver = progress.nextManeuver,
                  let lanes = LaneGuidanceEngine.guidance(for: maneuver) else {
                return "Nie mam danych o pasach dla najbliższego manewru."
            }
            let selected = lanes.selectedIndices.filter { lanes.lanes.indices.contains($0) }
            guard !selected.isEmpty else { return "Nie mam danych o pasach dla najbliższego manewru." }
            if selected.count == lanes.lanes.count { return "Możesz skorzystać z dowolnego pasa wskazanego dla tego manewru." }
            let numbers = selected.map { number($0 + 1) }.joined(separator: ", ")
            return selected.count == 1
                ? "Wybierz pas numer \(numbers), licząc od lewej."
                : "Możesz wybrać pasy o numerach: \(numbers), licząc od lewej."
        case .roundabout:
            guard let maneuver = progress.nextManeuver, maneuver.kind.isRoundabout else {
                return "Najbliższy manewr nie dotyczy ronda. " + maneuverAnswer(progress)
            }
            guard let count = maneuver.roundabout?.exitCount, count > 0 else {
                return "Nie mam potwierdzonego numeru zjazdu z tego ronda."
            }
            return "Na rondzie wybierz zjazd numer \(number(count))."
        case .traffic:
            return trafficAnswer(state: state, route: route, now: now)
        case .transitAlighting, .transitTransfer, .transitLine:
            return transitAnswer(query, state: state, route: route)
        }
    }

    private static func maneuverAnswer(_ progress: RouteProgress) -> String {
        guard let maneuver = progress.nextManeuver,
              progress.distanceToNextManeuver.isFinite, progress.distanceToNextManeuver >= 0 else {
            return "Nie mam teraz kolejnego manewru do odczytania."
        }
        let prefix = progress.distanceToNextManeuver < 35
            ? "" : "Za około \(distance(progress.distanceToNextManeuver)): "
        return prefix + maneuver.spokenInstruction
    }

    private static func transitAnswer(_ query: VoiceQuery, state: NavigationState,
                                      route: NavigationRoute) -> String {
        guard let journey = route.journey, let progress = state.transitProgress,
              journey.legs.indices.contains(progress.legIndex) else {
            return "Nie mam aktywnego odcinka podróży komunikacją miejską."
        }
        let leg = journey.legs[progress.legIndex]
        let walking = leg.mode.uppercased() == "WALK"
        let following = journey.legs.dropFirst(progress.legIndex + 1).first {
            $0.mode.uppercased() != "WALK"
        }
        switch query {
        case .transitAlighting:
            guard !walking, progress.isOnVehicle else {
                return walking ? "Teraz idziesz pieszo do: \(leg.to)."
                    : "Nie mam jeszcze potwierdzenia jazdy pojazdem. Planowany przystanek wysiadania: \(leg.to)."
            }
            guard let stops = progress.stopsUntilAlighting, stops >= 0 else {
                return "Planowany przystanek wysiadania: \(leg.to). Liczba pozostałych przystanków jest niedostępna."
            }
            if stops == 0 { return "Przystanek docelowy tego odcinka: \(leg.to)." }
            if stops == 1 { return "Wysiądź na następnym przystanku: \(leg.to)." }
            return "Przystanek wysiadania: \(leg.to). Liczba pozostałych przystanków: \(number(stops))."
        case .transitTransfer:
            guard let following else { return "Na pozostałej trasie nie ma kolejnej przesiadki." }
            return "\(walking ? "Podejdź" : "Po wysiadaniu na \(leg.to) przejdź") do przystanku \(following.from). "
                + lineDescription(following)
        default:
            if walking {
                return "Idź do: \(leg.to). " + (following.map(lineDescription) ?? "To ostatni odcinek dojścia do celu.")
            }
            let next = following.map { " Następnie: " + lineDescription($0) }
                ?? " To ostatnia linia w tej podróży."
            return "Bieżący odcinek: " + lineDescription(leg) + next
        }
    }

    private static func lineDescription(_ leg: JourneyLeg) -> String {
        let line = leg.line.flatMap { $0.isEmpty ? nil : $0 }
        let prefix = line.map { "Linia \($0)" } ?? "Połączenie komunikacji miejskiej"
        return "\(prefix), kierunek \(leg.direction ?? leg.to). Wysiadanie: \(leg.to)."
    }

    private static func trafficAnswer(state: NavigationState, route: NavigationRoute, now: Date) -> String {
        guard let snapshot = state.traffic,
              (-5...180).contains(now.timeIntervalSince(snapshot.updatedAt)),
              let routeMatch = state.routeMatch, routeMatch.routeID == route.id else {
            return "Nie mam aktualnych informacji o ruchu na Twojej trasie."
        }
        let start = routeMatch.match.projection.alongRoute
        let geometry = RouteProgressGeometry(route)
        let fresh = snapshot.routeFlowSegments.filter {
            $0.routeID == route.id && $0.endDistance > start && $0.startDistance < geometry.length &&
                (-5...180).contains(now.timeIntervalSince($0.measuredAt ?? snapshot.updatedAt))
        }
        if fresh.contains(where: \.isRoadClosure) {
            return "Przed Tobą zgłoszono zamknięcie drogi na trasie."
        }
        let jams = snapshot.incidents.filter {
            guard $0.category == .jam, $0.isActive(at: now),
                  (-5...180).contains(now.timeIntervalSince($0.sourceUpdatedAt ?? snapshot.updatedAt)),
                  let projection = RouteTrafficMonitor.incidentProjection($0, geometry: geometry, route: route, at: now) else { return false }
            return projection.alongRoute >= start
        }
        let slowdown = fresh.contains { segment in
            guard let speed = segment.currentSpeedKph, let freeSpeed = segment.freeFlowSpeedKph,
                  speed.isFinite, freeSpeed.isFinite, speed >= 0, freeSpeed > 0 else { return false }
            return speed / freeSpeed < 0.65
        }
        if slowdown || !jams.isEmpty {
            return "Na trasie przed Tobą są spowolnienia. Dane obejmują tylko monitorowane odcinki."
        }
        guard fresh.contains(where: { $0.currentSpeedKph != nil }) else {
            return "Nie mam wystarczających pomiarów, aby ocenić korki na Twojej trasie."
        }
        return "Na odcinkach z aktualnymi pomiarami przed Tobą nie widać większych spowolnień. Pozostałe odcinki mogą nie być monitorowane."
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "nieznany czas" }
        if seconds < 60 { return "mniej niż minuta" }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = PolishRegionalFormat.locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: (seconds / 60).rounded(.up) * 60) ?? "nieznany czas"
    }

    static func distance(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "nieznana odległość" }
        let formatter = MeasurementFormatter()
        formatter.locale = PolishRegionalFormat.locale
        formatter.unitStyle = .long
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.locale = PolishRegionalFormat.locale
        formatter.numberFormatter.maximumFractionDigits = meters >= 1_000 ? 1 : 0
        let value = meters >= 1_000 ? meters / 1_000 : (meters / 10).rounded() * 10
        return formatter.string(from: Measurement(value: value, unit: meters >= 1_000 ? UnitLength.kilometers : .meters))
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(PolishRegionalFormat.locale))
    }
}
#endif
