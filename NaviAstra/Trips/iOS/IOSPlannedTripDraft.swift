#if os(iOS)
import Foundation
import Observation
import OSLog

struct IOSPlannedTripPresentation: Identifiable {
    let id = UUID()
    var seed: PlannedTrip?
    var draft: IOSPlannedTripDraft? = nil
}

enum IOSTripPointRole: Equatable {
    case origin, destination, waypoint, replaceWaypoint(UUID)
    var title: String {
        switch self {
        case .origin: "Punkt startowy"
        case .destination: "Cel podróży"
        case .waypoint, .replaceWaypoint: "Punkt pośredni"
        }
    }
    var confirmation: String {
        switch self {
        case .origin: "Użyj jako start"
        case .destination: "Użyj jako cel"
        case .waypoint: "Dodaj punkt"
        case .replaceWaypoint: "Zmień punkt"
        }
    }
}

@MainActor @Observable
final class IOSPlannedTripDraft {
    var title: String
    var origin: Destination?
    var destination: Destination?
    var waypoints: [Destination]
    var mode: TransportMode
    var preferences: RoutingPreferences
    var timing: PlannedTrip.Timing
    var targetDate: Date
    var bufferMinutes: Int
    var stopMinutes: Int
    var repeatRule: PlannedTrip.RepeatRule
    var weekdays: Set<Int>
    var reminders: Set<Int>
    var preferredRoute: [Coordinate]
    let timeZone: TimeZone
    let currentOrigin: Destination?
    let session: NavigationSession
    var mapState: NavigationState { session.state }
    var selectedRole: IOSTripPointRole = .destination
    var searchQuery = ""
    var mapCandidate: Destination?
    var geocoding = false
    var calculating = false
    var saving = false
    var message: String?
    var routeMessage: String?
    var savedTrip: PlannedTrip?
    private(set) var calculatedKey: String?
    private(set) var previewCalculatedAt: Date?
    private var preferredRouteMatched = true
    private var initialEditKey = ""
    private let id: UUID
    private let createdAt: Date
    private var generation = 0
    private var mapPlaceAnchor: Destination?
    @ObservationIgnored private var geocodingTask: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "NaviAstra", category: "TripEditor")

    init(seed originalSeed: PlannedTrip?, currentOrigin: Destination?, initialCenter: Coordinate?, preferences: RoutingPreferences) {
        var seed = originalSeed
        if var normalizedSeed = seed {
            normalizedSeed.targetDate = normalizedSeed.calendar.dateInterval(of: .minute, for: normalizedSeed.targetDate)?.start ?? normalizedSeed.targetDate
            seed = normalizedSeed
        }
        self.currentOrigin = currentOrigin
        id = seed?.id ?? UUID(); createdAt = seed?.createdAt ?? Date()
        title = seed?.title ?? ""; origin = seed?.origin ?? currentOrigin; destination = seed?.destination
        waypoints = seed?.waypoints ?? []; mode = seed?.transportMode ?? .configuredDefault
        var initialPreferences = seed?.preferences ?? preferences
        initialPreferences.advanced.routePreference = initialPreferences.advanced.effectiveRoutePreference
        self.preferences = initialPreferences
        timing = seed?.timing ?? .departure
        targetDate = seed?.occurrences(after: Date()).first ?? max(seed?.targetDate ?? .distantPast, Date().addingTimeInterval(3_600))
        bufferMinutes = seed?.bufferMinutes ?? 15; stopMinutes = seed?.stopMinutes ?? 0
        repeatRule = seed?.repeatRule ?? .never; weekdays = seed?.weekdays ?? [2, 3, 4, 5, 6]
        reminders = seed?.reminderMinutes ?? [15, 0]; preferredRoute = seed?.preferredRoute ?? []
        timeZone = TimeZone(identifier: seed?.timeZoneIdentifier ?? "") ?? .current
        let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "")
            ?? URL(string: "https://valhalla1.openstreetmap.de")!
        session = NavigationSession(dependencies: .live(routeEndpoint: endpoint, trafficAPIKey: nil,
            transitProvider: TransitousRouteProvider(), transitDataProvider: TransitousTransitDataProvider()))
        session.plannedTripCalculation = true
        if let center = seed?.origin.coordinate ?? initialCenter ?? currentOrigin?.coordinate { focus(center) }
        targetDate = normalizedTargetDate
        initialEditKey = editKey
    }

    var normalizedTargetDate: Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.dateInterval(of: .minute, for: targetDate)?.start ?? targetDate
    }
    var allowsWaypoints: Bool { mode == .car || mode == .walking || mode == .bicycle }
    var validationMessage: String? {
        if origin == nil { return "Wybierz punkt startowy na mapie lub wpisz jego adres." }
        if destination == nil { return "Wybierz cel podróży na mapie lub wpisz jego adres." }
        if normalizedTargetDate <= Date() { return "Wybierz przyszłą datę i godzinę." }
        if mode == .parkRide && timing == .arrival { return "P+R obsługuje godzinę wyjazdu. Wybierz „Wyjazd”." }
        if !allowsWaypoints && !waypoints.isEmpty { return "Ten transport nie obsługuje punktów pośrednich. Punkty pozostają w szkicu — możesz zmienić transport lub je usunąć." }
        if waypoints.count > 8 { return "Możesz zapisać maksymalnie 8 punktów pośrednich." }
        if repeatRule == .custom && weekdays.isEmpty { return "Wybierz przynajmniej jeden dzień powtarzania." }
        return nil
    }
    var plan: PlannedTrip? {
        guard let origin, let destination else { return nil }
        var plan = PlannedTrip(id: id, title: title, origin: origin, destination: destination,
            waypoints: waypoints, transportMode: mode, preferences: preferences, timing: timing,
            targetDate: normalizedTargetDate, timeZoneIdentifier: timeZone.identifier,
            bufferMinutes: bufferMinutes, stopMinutes: waypoints.isEmpty ? 0 : stopMinutes,
            repeatRule: repeatRule, weekdays: weekdays, reminderMinutes: reminders,
            preferredRoute: preferredRoute, createdAt: createdAt)
        plan.preferences.advanced.shortest = preferences.advanced.effectiveRoutePreference == .shortest
        return plan
    }
    var previewKey: String {
        guard var plan else { return "incomplete" }
        plan.title = ""; plan.reminderMinutes = []; plan.preferredRoute = []
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(plan)).flatMap { String(data: $0, encoding: .utf8) } ?? "incomplete"
    }
    var hasPreview: Bool {
        guard calculatedKey == previewKey, validationMessage == nil, !calculating,
              let route = mapState.route else { return false }
        return route.expectedTravelTime.isFinite && route.expectedTravelTime > 0 && route.distance.isFinite && route.distance >= 0
    }
    var hasChanges: Bool { editKey != initialEditKey }
    private var editKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let pointData = (try? encoder.encode([origin, destination] + waypoints.map { Optional($0) })) ?? Data()
        let preferenceData = (try? encoder.encode(preferences)) ?? Data()
        let parts = [previewKey, pointData.base64EncodedString(), preferenceData.base64EncodedString(), title,
            reminders.sorted().map(String.init).joined(separator: ","), String(targetDate.timeIntervalSince1970),
            mode.rawValue, timing.rawValue, String(bufferMinutes), String(stopMinutes), repeatRule.rawValue,
            weekdays.sorted().map(String.init).joined(separator: ",")]
        return parts.joined(separator: "|")
    }
    var estimate: PlannedTrip.Estimate? {
        guard hasPreview, let plan, let route = mapState.route,
              let occurrence = plan.occurrences(after: Date()).first else { return nil }
        return plan.makeEstimate(for: occurrence, route: route, travelSeconds: route.expectedTravelTime,
            currentTraffic: false, matched: preferredRouteMatched, updatedAt: previewCalculatedAt ?? createdAt)
    }

    func calculatePreview() async {
        generation += 1
        let request = generation, key = previewKey
        session.requestGeneration += 1
        calculatedKey = nil; routeMessage = nil
        mapState.route = nil; mapState.routeOptions = []
        guard validationMessage == nil, let plan, let occurrence = plan.occurrences(after: Date()).first else { calculating = false; return }
        calculating = true
        defer { if request == generation { calculating = false } }
        do {
            try await Task.sleep(for: .milliseconds(450))
            try Task.checkCancellation()
            mapState.transportMode = mode; mapState.routingPreferences = plan.preferences
            mapState.routeOrigin = RoutePoint(plan.origin, source: .savedPlace)
            mapState.waypoints = plan.waypoints
            mapState.journeyTimeMode = timing == .arrival ? .arriveBy : .departAt
            mapState.journeyTargetTime = timing == .arrival
                ? occurrence.addingTimeInterval(-Double(bufferMinutes + plan.stopMinutes) * 60) : occurrence
            await RoadRoutingContext.$allowsPersonalization.withValue(false) { await session.preview(plan.destination) }
            try Task.checkCancellation()
            guard request == generation, key == previewKey else { return }
            guard mapState.status == .routePreview, !mapState.routeOptions.isEmpty else {
                routeMessage = "Nie udało się obliczyć trasy. Sprawdź połączenie i wybrane punkty, a potem spróbuj ponownie."
                Self.logger.error("Preview failed: \(self.mapState.errorMessage ?? "unknown", privacy: .private)")
                mapState.route = nil; mapState.routeOptions = []; return
            }
            let selected = plan.preferredOption(in: mapState.routeOptions)
            if let route = selected.route { select(route, remember: false) }
            preferredRouteMatched = selected.matched
            if !selected.matched { routeMessage = "Poprzedni wariant jest niedostępny. Pokazujemy aktualne trasy." }
            calculatedKey = key; previewCalculatedAt = Date()
        } catch is CancellationError { }
        catch {
            guard request == generation else { return }
            routeMessage = "Nie udało się obliczyć trasy. Spróbuj ponownie."
            Self.logger.error("Preview failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func select(_ route: NavigationRoute, remember: Bool = true) {
        guard mapState.routeOptions.contains(where: { $0.id == route.id }) else { return }
        mapState.route = route; mapState.progress = nil
        mapState.evChargingStops = route.chargingStops.map(\.destination)
        session.mapCameraController.showRouteOverview()
        if remember {
            preferredRoute = PlannedTrip.fingerprint(route); calculatedKey = previewKey
            preferredRouteMatched = true; routeMessage = nil
            if previewCalculatedAt == nil { previewCalculatedAt = Date() }
        }
    }

    func choose(_ destination: Destination, for role: IOSTripPointRole) -> Bool {
        message = nil
        switch role {
        case .origin: origin = destination
        case .destination: self.destination = destination
        case .waypoint, .replaceWaypoint:
            guard allowsWaypoints else { message = "Punkty pośrednie są dostępne dla auta, roweru i podróży pieszych."; return false }
            guard !waypoints.contains(where: { stop in
                if case let .replaceWaypoint(id) = role, stop.id == id { return false }
                return stop.coordinate.distance(to: destination.coordinate) < 5
            }) else { message = "To miejsce jest już punktem pośrednim."; return false }
            if case let .replaceWaypoint(id) = role, let index = waypoints.firstIndex(where: { $0.id == id }) {
                var replacement = destination; replacement.id = id; waypoints[index] = replacement
            } else {
                guard waypoints.count < 8 else { message = "Możesz dodać maksymalnie 8 punktów pośrednich."; return false }
                waypoints.append(destination)
            }
        }
        preferredRoute = []; focus(destination.coordinate)
        return true
    }

    func point(for role: IOSTripPointRole) -> Destination? {
        switch role {
        case .origin: origin
        case .destination: destination
        case .waypoint: nil
        case let .replaceWaypoint(id): waypoints.first(where: { $0.id == id })
        }
    }

    func focus(_ coordinate: Coordinate) {
        mapState.cameraCommandID &+= 1
        mapState.cameraState = .browse
        mapState.cameraIntent = CameraIntent(target: coordinate, zoom: 15.5, pitch: 0, bearing: 0,
            padding: CameraPadding(top: 0, left: 0, bottom: 0, right: 0))
    }

    func resetMapSelection() {
        geocodingTask?.cancel(); mapPlaceAnchor = nil; mapCandidate = nil; geocoding = false
    }
    func selectMapPlace(_ destination: Destination) {
        geocodingTask?.cancel(); geocoding = false
        mapPlaceAnchor = destination; mapCandidate = destination
        focus(destination.coordinate)
    }
    func mapGestureStarted() { mapPlaceAnchor = nil }

    func updateMapCandidate(_ coordinate: Coordinate) {
        if let anchor = mapPlaceAnchor { mapCandidate = anchor; return }
        if let candidate = mapCandidate, candidate.coordinate.distance(to: coordinate) < 1 { return }
        geocodingTask?.cancel(); geocoding = true
        mapCandidate = Destination(name: "Wybrany punkt", coordinate: coordinate)
        geocodingTask = Task {
            do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            let address = await GUGiKAddressProvider().reverseGeocode(coordinate)
            guard !Task.isCancelled, mapCandidate?.coordinate == coordinate else { return }
            mapCandidate = Destination(name: address?.components(separatedBy: ",").first ?? "Wybrany punkt",
                coordinate: coordinate, address: address)
            geocoding = false
        }
    }

    func save(to service: TripPlanningService, withoutRoute: Bool) async -> Bool {
        guard !saving, validationMessage == nil, var plan else { message = validationMessage; return false }
        guard withoutRoute || hasPreview else { message = "Najpierw sprawdź obliczoną trasę."; return false }
        saving = true
        cancelCalculation()
        defer { saving = false }
        plan.estimate = estimate
        if hasPreview, let route = mapState.route { plan.preferredRoute = Self.routeFingerprint(route) }
        guard service.save(plan) else { message = "Nie udało się zapisać planu na urządzeniu. Spróbuj ponownie."; return false }
        if !reminders.isEmpty { await service.enableReminders() } else { await service.reschedule() }
        savedTrip = plan
        BackgroundMaintenance.schedule()
        return true
    }

    private static func routeFingerprint(_ route: NavigationRoute) -> [Coordinate] { PlannedTrip.fingerprint(route) }
    func cancelCalculation() { generation += 1; session.requestGeneration += 1; calculating = false }
    func invalidatePreview() { cancelCalculation(); calculatedKey = nil }
    func cancel() { cancelCalculation(); geocodingTask?.cancel() }
}
#endif
