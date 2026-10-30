#if os(iOS)
import Foundation
import EventKit
import Observation

struct IOSTripCalendarEvent: Identifiable {
    let id: String
    let title: String
    let date: Date
    let location: String
    let coordinate: Coordinate?
}

@MainActor @Observable
final class IOSTripCalendarModel {
    private(set) var events: [IOSTripCalendarEvent] = []
    private(set) var message: String?
    private(set) var loading = true
    @ObservationIgnored private let store = EKEventStore()

    func load() async {
        loading = true
        message = nil
        defer { loading = false }
        do {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                store.requestFullAccessToEvents { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard !Task.isCancelled else { return }
            guard granted else {
                message = "Brak dostępu do kalendarza. Możesz zaplanować trasę, wpisując adres."
                return
            }
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start
            events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { !$0.isAllDay && $0.startDate > start && ($0.structuredLocation?.geoLocation != nil || !($0.location ?? "").isEmpty) }
                .sorted { $0.startDate < $1.startDate }.map { event in
                    IOSTripCalendarEvent(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)-\(event.startDate.timeIntervalSinceReferenceDate)", title: event.title ?? "Wydarzenie",
                        date: event.startDate, location: event.location ?? "",
                        coordinate: event.structuredLocation?.geoLocation.map {
                            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                        })
                }
            if events.isEmpty { message = "Brak wydarzeń z godziną i adresem w najbliższych 30 dniach." }
        } catch {
            guard !Task.isCancelled else { return }
            message = "Nie udało się wczytać kalendarza. Możesz wpisać adres ręcznie."
        }
    }
}
#endif
