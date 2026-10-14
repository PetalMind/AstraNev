#if os(iOS)
import SwiftUI

struct IOSPlannedTripsView: View {
    @Bindable var service: TripPlanningService
    let focusTripID: UUID?
    let navigationIsActive: Bool
    let onCreate: () -> Void
    let onEdit: (PlannedTrip) -> Void
    let onStart: (PlannedTrip) -> Void
    let onHistory: () -> Void
    let onClose: () -> Void
    @State private var tab = 0
    @State private var path: [UUID] = []
    @State private var removing: PlannedTrip?
    @State private var skipping: PlannedTrip?
    private var regularTrips: [PlannedTrip] { service.trips.filter { $0.repeatRule != .never }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending } }
    private var groupedTrips: [(day: Date, trips: [PlannedTrip])] {
        let trips = service.upcomingTrips
        let groups = Dictionary(grouping: trips) { Calendar.current.startOfDay(for: $0.occurrences(after: Date()).first ?? $0.targetDate) }
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Picker("Podróże", selection: $tab) { Text("Zaplanowane").tag(0); Text("Regularne").tag(1) }.pickerStyle(.segmented)
                    if service.errorMessage != nil { notice("Nie udało się odczytać lub zapisać planów na urządzeniu. Zachowaliśmy dotychczasowe dane.", symbol: "exclamationmark.triangle") }
                    if let message = service.reminderMessage { notice(IOSTripUserMessage.reminders(message), symbol: "bell.badge") }
                    if tab == 0 {
                        ForEach(groupedTrips, id: \.day) { group in
                            Text(dayTitle(group.day)).font(.headline)
                            ForEach(group.trips) { trip in tripCard(trip, regular: false) }
                        }
                        if groupedTrips.isEmpty { emptyState }
                        let past = service.trips.filter { $0.occurrences(after: Date()).isEmpty }.sorted { $0.targetDate > $1.targetDate }
                        if !past.isEmpty {
                            DisclosureGroup("Poprzednie plany") {
                                VStack(spacing: 10) { ForEach(past) { trip in tripCard(trip, regular: false) } }.padding(.top, 10)
                            }.font(.subheadline.weight(.semibold))
                        }
                    } else {
                        ForEach(regularTrips) { trip in tripCard(trip, regular: true) }
                        if regularTrips.isEmpty { emptyState }
                    }
                    Button("Ostatnie podróże", systemImage: "clock.arrow.circlepath", action: onHistory)
                        .frame(minHeight: 44).font(.subheadline.weight(.semibold))
                    Text("Plany pozostają na tym urządzeniu. Przypomnienia korzystają z ostatnio obliczonej trasy.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }.background(Color(.systemGroupedBackground))
            .navigationTitle("Podróże").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zamknij", action: onClose) }
                ToolbarItem(placement: .primaryAction) { Button(action: onCreate) { Image(systemName: "plus") }.accessibilityLabel("Zaplanuj nową podróż") }
            }
            .navigationDestination(for: UUID.self) { detail($0) }
            .refreshable { await service.refreshUpcoming(force: true) }
            .task {
                if let id = service.requestedTripID ?? focusTripID { open(id); service.requestedTripID = nil }
                await service.refreshUpcoming()
            }
            .onChange(of: service.requestedTripID) { _, id in if let id { open(id); service.requestedTripID = nil } }
            .confirmationDialog("Usunąć plan i jego przypomnienia?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Usuń plan", role: .destructive) { if let removing { service.delete(removing.id) }; removing = nil; path = [] }
            }
            .confirmationDialog("Pominąć najbliższy termin tej podróży?", isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } })) {
                Button("Pomiń termin") {
                    if let skipping, let occurrence = skipping.occurrences(after: Date()).first { service.complete(skipping.id, occurrence: occurrence) }
                    skipping = nil
                }
            }
        }.environment(\.locale, PolishRegionalFormat.locale)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.plus").font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text(tab == 0 ? "Zaplanuj następną podróż" : "Brak regularnych podróży").font(.headline)
            Text("Wybierz miejsca na mapie lub wpisz adres, sprawdź trasę i ustaw termin.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Zaplanuj podróż", action: onCreate).buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity).padding(24).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private func tripCard(_ trip: PlannedTrip, regular: Bool) -> some View {
        NavigationLink(value: trip.id) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(trip.displayTitle, systemImage: trip.transportMode.symbol).font(.headline)
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(trip.origin.name) → \(trip.destination.name)").font(.subheadline).foregroundStyle(.secondary)
                if regular {
                    Text(scheduleTitle(trip)).font(.subheadline.weight(.semibold))
                    Text("\(trip.timing.title) \(PolishRegionalFormat.time(trip.targetDate, timeZone: trip.calendar.timeZone))").font(.title3.weight(.semibold))
                } else if let occurrence = trip.occurrences(after: Date()).first {
                    HStack(alignment: .firstTextBaseline) {
                        Text(trip.timing.title).font(.subheadline)
                        Text(PolishRegionalFormat.time(occurrence, timeZone: trip.calendar.timeZone)).font(.title2.weight(.bold))
                    }
                    if trip.timing == .arrival, let departure = trip.departure(for: occurrence) {
                        Text("Wyjazd około \(PolishRegionalFormat.time(departure, timeZone: trip.calendar.timeZone))").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    if trip.repeatRule != .never { Text(scheduleTitle(trip)).font(.caption).foregroundStyle(.secondary) }
                } else { Text("Termin minął lub został wykorzystany").font(.caption).foregroundStyle(.secondary) }
                if service.refreshingIDs.contains(trip.id) { ProgressView("Odświeżam trasę…").font(.caption) }
                else if trip.refreshError != nil { Label("Trasa wymaga odświeżenia", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                else if let estimate = trip.estimate {
                    Text("\(TravelDurationFormatter.string(minutes: Int(ceil(estimate.travelSeconds / 60)))) · obliczono \(PolishRegionalFormat.dateTime(estimate.updatedAt, timeZone: trip.calendar.timeZone))")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("Czas trasy nie został jeszcze obliczony").font(.caption).foregroundStyle(.secondary) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Edytuj na mapie", systemImage: "map") { onEdit(trip) }
                Button("Usuń plan", systemImage: "trash", role: .destructive) { removing = trip }
            }
    }

    @ViewBuilder private func detail(_ id: UUID) -> some View {
        if let trip = service.trips.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(trip.displayTitle).font(.title2.weight(.bold))
                        if let occurrence = trip.occurrences(after: Date()).first {
                            Text(trip.timing.title).font(.subheadline).foregroundStyle(.secondary)
                            Text(PolishRegionalFormat.dateTime(occurrence, dateStyle: .complete, timeZone: trip.calendar.timeZone)).font(.headline)
                            if let departure = trip.departure(for: occurrence) {
                                Text("Wyjazd około \(PolishRegionalFormat.time(departure, timeZone: trip.calendar.timeZone))").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }
                        } else { Text("Termin minął lub został wykorzystany. Możesz zaplanować tę trasę ponownie.").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Label(trip.origin.name, systemImage: "a.circle.fill")
                        ForEach(Array(trip.waypoints.enumerated()), id: \.element.id) { index, stop in Label(stop.name, systemImage: "\(index + 1).circle") }
                        Label(trip.destination.name, systemImage: "flag.fill")
                        Button("Podgląd i edycja na mapie", systemImage: "map") { onEdit(trip) }.frame(minHeight: 44)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    if let estimate = trip.estimate {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ostatnie przeliczenie").font(.headline)
                            Text("\(TravelDurationFormatter.string(minutes: Int(ceil(estimate.travelSeconds / 60)))) · \(String(format: "%.1f km", locale: PolishRegionalFormat.locale, estimate.distanceMeters / 1_000))")
                            Text("Przyjazd około \(PolishRegionalFormat.dateTime(estimate.arrival, timeZone: trip.calendar.timeZone))")
                            Text("Obliczono \(PolishRegionalFormat.dateTime(estimate.updatedAt, timeZone: trip.calendar.timeZone))").font(.footnote).foregroundStyle(.secondary)
                            if !estimate.preferredRouteMatched { Text("Poprzedni wariant jest niedostępny. Użyto aktualnej rekomendacji.").font(.footnote).foregroundStyle(.orange) }
                        }
                    }
                    if trip.refreshError != nil { notice("Nie udało się odświeżyć trasy. Zapisany plan pozostaje dostępny.", symbol: "exclamationmark.triangle") }
                    Button("Odśwież czas przejazdu", systemImage: "arrow.clockwise") { Task { await service.refresh(trip.id) } }
                        .disabled(service.refreshingIDs.contains(trip.id) || trip.occurrences(after: Date()).isEmpty)
                    DisclosureGroup("Przypomnienia i ustawienia planu") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Transport", value: trip.transportMode.title)
                            LabeledContent("Powtarzanie", value: scheduleTitle(trip))
                            LabeledContent("Bufor", value: "\(trip.bufferMinutes) min")
                            if !trip.waypoints.isEmpty { LabeledContent("Czas postojów", value: "\(trip.stopMinutes) min") }
                            Text(trip.reminderMinutes.isEmpty ? "Przypomnienia wyłączone" : "Przypomnienia: " + trip.reminderMinutes.sorted(by: >).map { $0 == 0 ? "w chwili wyjazdu" : $0 == 1_440 ? "dzień wcześniej" : "\($0) min wcześniej" }.joined(separator: ", "))
                            if trip.timeZoneIdentifier != TimeZone.current.identifier { LabeledContent("Strefa czasowa", value: trip.timeZoneIdentifier) }
                        }.font(.subheadline).padding(.top, 10)
                    }
                    if trip.occurrences(after: Date()).first != nil { Button("Pomiń najbliższy termin", systemImage: "calendar.badge.minus") { skipping = trip } }
                    Button("Usuń plan", systemImage: "trash", role: .destructive) { removing = trip }
                    if navigationIsActive { Text("Zakończ bieżącą nawigację, aby rozpocząć następną podróż.").font(.footnote).foregroundStyle(.secondary) }
                }.padding(16)
            }.background(Color(.systemGroupedBackground)).navigationTitle("Zaplanowana podróż").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Button { onStart(trip) } label: { Label("Rozpocznij z bieżącego miejsca", systemImage: "location.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 46) }
                        .buttonStyle(.borderedProminent).disabled(navigationIsActive).padding(16).background(.regularMaterial)
                }
        } else { ContentUnavailableView("Plan nie jest dostępny", systemImage: "calendar") }
    }
    private func notice(_ text: String, symbol: String) -> some View { Label(text, systemImage: symbol).font(.footnote).foregroundStyle(.secondary) }
    private func open(_ id: UUID) { if service.trips.contains(where: { $0.id == id }) { path = [id] } }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Dzisiaj" }
        if Calendar.current.isDateInTomorrow(day) { return "Jutro" }
        return PolishRegionalFormat.dateTime(day, dateStyle: .complete, timeStyle: .omitted)
    }
    private func scheduleTitle(_ trip: PlannedTrip) -> String {
        if trip.repeatRule == .custom { return [2, 3, 4, 5, 6, 7, 1].filter { trip.weekdays.contains($0) }.map { String(PolishRegionalFormat.weekday($0).prefix(3)) }.joined(separator: ", ") }
        if trip.repeatRule == .weekly { return "Co tydzień · " + PolishRegionalFormat.weekday(trip.calendar.component(.weekday, from: trip.targetDate)) }
        return trip.repeatRule.title
    }
}

enum IOSTripUserMessage {
    static func reminders(_ message: String) -> String {
        if message.hasPrefix("Powiadomienia są wyłączone") || message.hasPrefix("Ustawiono najbliższe przypomnienia") { return message }
        return "Nie udało się ustawić części przypomnień. Plan jest zapisany; sprawdź powiadomienia w ustawieniach systemu."
    }
}
#endif
