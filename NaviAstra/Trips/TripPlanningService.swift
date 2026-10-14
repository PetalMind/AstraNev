import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class TripPlanningService {
    static let shared = TripPlanningService()
    private(set) var trips: [PlannedTrip] = []
    private(set) var refreshingIDs: Set<UUID> = []
    var errorMessage: String?
    var reminderMessage: String?
    var requestedTripID: UUID?
    private let fileURL: URL
    private var canWrite = true
    private let scheduler = TripReminderScheduler()
    private var scheduling = false
    private var scheduleAgain = false

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviAstra", isDirectory: true)
        fileURL = directory.appendingPathComponent("planned-trips.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                trips = try JSONDecoder().decode([PlannedTrip].self, from: Data(contentsOf: fileURL))
            }
        } catch {
            canWrite = false
            errorMessage = "Nie udało się wczytać planowanych podróży. Zapis wstrzymany, aby zachować dane: \(error.localizedDescription)"
        }
    }

    var upcomingTrips: [PlannedTrip] {
        trips.filter { !$0.occurrences(after: Date()).isEmpty }.sorted {
            ($0.occurrences(after: Date()).first ?? .distantFuture) < ($1.occurrences(after: Date()).first ?? .distantFuture)
        }
    }

    @discardableResult func save(_ trip: PlannedTrip) -> Bool {
        var updated = trips
        if let index = updated.firstIndex(where: { $0.id == trip.id }) { updated[index] = trip }
        else { updated.append(trip) }
        return persist(updated)
    }

    func delete(_ id: UUID) {
        if persist(trips.filter { $0.id != id }) { Task { await reschedule() } }
    }

    func complete(_ id: UUID, occurrence: Date) {
        guard var trip = trips.first(where: { $0.id == id }) else { return }
        trip.completedOccurrence = occurrence
        trip.estimate = nil
        if save(trip) { Task { await refreshUpcoming(force: true) } }
    }

    private func persist(_ updated: [PlannedTrip]) -> Bool {
        guard canWrite else { return false }
        do {
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            trips = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Nie udało się zapisać podróży: \(error.localizedDescription)"
            return false
        }
    }

    func enableReminders() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            reminderMessage = granted ? nil : "Powiadomienia są wyłączone. Możesz włączyć je w ustawieniach systemu."
        } catch { reminderMessage = error.localizedDescription }
        await reschedule()
    }

    func refreshUpcoming(force: Bool = false) async {
        for trip in upcomingTrips {
            guard !Task.isCancelled else { return }
            let occurrence = trip.occurrences(after: Date()).first
            let age = trip.estimate.map { Date().timeIntervalSince($0.updatedAt) } ?? .infinity
            let near = (trip.departure(for: occurrence ?? .distantFuture) ?? .distantFuture).timeIntervalSinceNow < 3_600
            if force || trip.estimate?.occurrence != occurrence || age > (near ? 300 : 3_600) {
                await refresh(trip.id)
            }
        }
        await reschedule()
    }

    func refresh(_ id: UUID) async {
        guard !refreshingIDs.contains(id), let original = trips.first(where: { $0.id == id }),
              let occurrence = original.occurrences(after: Date()).first else { return }
        refreshingIDs.insert(id)
        defer { refreshingIDs.remove(id) }
        var updated = original
        do {
            let (route, matched) = try await calculate(original, occurrence: occurrence)
            try Task.checkCancellation()
            guard route.expectedTravelTime.isFinite, route.expectedTravelTime > 0 else { throw RoutingError.invalidResponse }
            let proposedDeparture = original.timing == .departure ? occurrence
                : occurrence.addingTimeInterval(-route.expectedTravelTime - Double(original.bufferMinutes + original.stopMinutes) * 60)
            var duration = route.expectedTravelTime
            var currentTraffic = false
            var trafficNote: String?
            if original.transportMode == .car, proposedDeparture.timeIntervalSinceNow < 3_600 {
                let result = try await measuredTravelTime(route)
                duration = result.duration
                currentTraffic = result.measured
                trafficNote = result.note
            }
            updated.estimate = original.makeEstimate(for: occurrence, route: route, travelSeconds: duration,
                currentTraffic: currentTraffic, matched: matched, trafficNote: trafficNote)
            updated.refreshError = nil
        } catch is CancellationError { return }
        catch { updated.refreshError = "Nie udało się odświeżyć trasy: \(error.localizedDescription)" }
        // A route response must not resurrect a deleted or edited plan.
        guard trips.first(where: { $0.id == id }) == original else { return }
        if save(updated) { await reschedule() }
    }

    func calculate(_ trip: PlannedTrip, occurrence: Date, now: Bool = false) async throws -> (NavigationRoute, Bool) {
        let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "")
            ?? URL(string: "https://valhalla1.openstreetmap.de")!
        let session = NavigationSession(dependencies: .live(routeEndpoint: endpoint, trafficAPIKey: nil,
            transitProvider: TransitousRouteProvider(), transitDataProvider: TransitousTransitDataProvider()))
        session.plannedTripCalculation = true
        session.state.transportMode = trip.transportMode
        session.state.routingPreferences = trip.preferences
        session.state.routeOrigin = RoutePoint(trip.origin, source: .savedPlace)
        session.state.waypoints = trip.waypoints
        session.state.journeyTimeMode = now ? .now : (trip.timing == .arrival ? .arriveBy : .departAt)
        session.state.journeyTargetTime = trip.timing == .arrival
            ? occurrence.addingTimeInterval(-Double(trip.bufferMinutes + trip.stopMinutes) * 60) : occurrence
        if trip.transportMode == .parkRide && trip.timing == .arrival && !now {
            // Existing P+R supports departure time only; do not manufacture an arrival timetable.
            throw TripPlanningError.message("P+R obsługuje planowanie godziny wyjazdu. Wybierz Wyjazd lub inny środek transportu.")
        }
        if (trip.transportMode == .transit || trip.transportMode == .parkRide), !trip.waypoints.isEmpty {
            throw TripPlanningError.message("Postoje pośrednie są obsługiwane dla auta, roweru i podróży pieszych.")
        }
        await RoadRoutingContext.$allowsPersonalization.withValue(false) { await session.preview(trip.destination) }
        try Task.checkCancellation()
        guard session.state.status == .routePreview else {
            throw TripPlanningError.message(session.state.errorMessage ?? "Trasa jest niedostępna.")
        }
        let selected = trip.preferredOption(in: session.state.routeOptions)
        guard let route = selected.route else { throw RoutingError.invalidResponse }
        return (route, selected.matched)
    }

    private func measuredTravelTime(_ route: NavigationRoute) async throws -> (duration: Double, measured: Bool, note: String?) {
        guard let provider = TrafficProviderFactory.tomTom.make(apiKey: TrafficCredential.read()) else {
            return (route.expectedTravelTime, false, "Brak skonfigurowanej usługi ruchu. Użyto czasu silnika tras.")
        }
        let geometry = RouteProgressGeometry(route)
        let queries = RouteTrafficMonitor.flowQueries(for: route, from: 0, through: geometry.length,
            budget: .init(maximumRequests: 24))
        async let flowRequest = provider.routeFlowSamples(at: queries)
        var incidents: [TrafficIncident] = []
        var incidentAvailable = false
        var note: String?
        do {
            incidents = try await provider.incidents(in: RouteTrafficMonitor.queryBoxes(
                for: route.coordinates, from: 0, through: geometry.length))
            incidentAvailable = true
        } catch {
            note = "Dane o zdarzeniach niedostępne; czas oparto na dostępnych pomiarach i silniku tras."
        }
        let samples = await flowRequest
        try Task.checkCancellation()
        let segments = RouteTrafficMonitor.coloredSegments(on: route, from: 0, through: geometry.length,
            queries: queries, samples: samples, geometry: geometry)
        let traffic = TrafficSnapshot(flow: nil, incidents: incidents, routeFlowSegments: segments,
            updatedAt: Date(), partialError: note, incidentDataAvailable: incidentAvailable)
        let duration = RoadRouteETA.estimate(route, from: 0, traffic: traffic)
        guard duration.isFinite else {
            throw TripPlanningError.message("Dostępne pomiary wskazują zamknięcie na trasie. Otwórz plan i wybierz inną trasę.")
        }
        let measured = !segments.isEmpty || incidents.contains {
            RouteTrafficMonitor.incidentProjection($0, geometry: geometry, route: route) != nil
        }
        if !measured { note = "Brak bieżących pomiarów na trasie. Użyto czasu silnika tras." }
        return (duration, measured, note)
    }

    func reschedule() async {
        if scheduling { scheduleAgain = true; return }
        scheduling = true
        defer { scheduling = false }
        repeat {
            scheduleAgain = false
            do { reminderMessage = try await scheduler.replace(trips: trips) }
            catch { reminderMessage = "Nie udało się ustawić przypomnień: \(error.localizedDescription)" }
        } while scheduleAgain && !Task.isCancelled
    }
}

enum TripPlanningError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

/// One delegate handles foreground delivery and cold-launch notification actions.
final class TripNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = TripNotificationDelegate()
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "planned-trip", actions: [
            UNNotificationAction(identifier: "open-trip", title: "Otwórz trasę", options: [.foreground])
        ], intentIdentifiers: [])])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let value = response.notification.request.content.userInfo["tripID"] as? String,
              let id = UUID(uuidString: value) else { completionHandler(); return }
        Task { @MainActor in
            TripPlanningService.shared.requestedTripID = id
            completionHandler()
        }
    }
}

@MainActor struct TripReminderScheduler {
    private let prefix = "naviastra.trip."
    func replace(trips: [PlannedTrip]) async throws -> String? {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let settings = await center.notificationSettings()
        let own = pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
        let delivered = await center.deliveredNotifications()
        let validIDs = Set(trips.map { $0.id.uuidString })
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.identifier.hasPrefix(prefix) && !validIDs.contains($0.request.content.userInfo["tripID"] as? String ?? "")
        }.map { $0.request.identifier })
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: own)
            return trips.contains(where: { !$0.reminderMinutes.isEmpty }) ? "Powiadomienia są wyłączone. Plan pozostaje zapisany." : nil
        }
        let requests = requests(for: trips, now: Date())
        // Reserve room for unrelated application reminders, schedule nearest ones first.
        let available = max(0, 60 - pending.filter { !$0.identifier.hasPrefix(prefix) }.count)
        let scheduled = Array(requests.sorted(by: { $0.0 < $1.0 }).prefix(available))
        let retained = Set(scheduled.map { $0.1.identifier })
        center.removePendingNotificationRequests(withIdentifiers: own.filter { !retained.contains($0) })
        for (_, request) in scheduled {
            try Task.checkCancellation()
            try await center.add(request)
        }
        return requests.count > available ? "Ustawiono najbliższe przypomnienia. Kolejne uzupełnimy po otwarciu aplikacji lub odświeżeniu w tle." : nil
    }
    func requests(for trips: [PlannedTrip], now: Date) -> [(Date, UNNotificationRequest)] {
        var requests: [(Date, UNNotificationRequest)] = []
        for trip in trips where !trip.reminderMinutes.isEmpty {
            for occurrence in trip.occurrences(after: now) {
                guard let departure = trip.departure(for: occurrence) else { continue }
                for minutes in trip.reminderMinutes.sorted() {
                    let date = departure.addingTimeInterval(-Double(minutes) * 60)
                    guard date > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = minutes == 0 ? "Czas wyjechać · \(trip.displayTitle)" : "Podróż · \(trip.displayTitle)"
                    content.body = "\(trip.origin.name) → \(trip.destination.name). Wyjazd około \(PolishRegionalFormat.time(departure, timeZone: trip.calendar.timeZone))."
                    if let estimate = trip.estimate {
                        content.body += " Czas trasy: \(TravelDurationFormatter.string(minutes: Int(ceil(estimate.travelSeconds / 60)))). Obliczono \(PolishRegionalFormat.dateTime(estimate.updatedAt, timeZone: trip.calendar.timeZone))."
                    }
                    if trip.refreshError != nil { content.body += " Odświeżenie trasy niedostępne." }
                    content.sound = .default
                    content.categoryIdentifier = "planned-trip"
                    content.userInfo = ["tripID": trip.id.uuidString]
                    let trigger = UNCalendarNotificationTrigger(dateMatching: trip.calendar.dateComponents(
                        [.timeZone, .year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
                    let id = "\(prefix)\(trip.id.uuidString).\(Int(occurrence.timeIntervalSince1970)).\(minutes)"
                    requests.append((date, UNNotificationRequest(identifier: id, content: content, trigger: trigger)))
                }
            }
        }
        return requests
    }

}
