import SwiftUI
import EventKit

struct PlannedTripsView: View {
    @Bindable var service: TripPlanningService
    let places: [Destination]
    let currentOrigin: Destination?
    let onOpen: (PlannedTrip) -> Void
    let onHistory: () -> Void
    let onClose: () -> Void
    @State private var selection = 0
    @State private var path: [UUID] = []
    @State private var editing: PlannedTrip?
    @State private var creating = false
    @State private var removing: PlannedTrip?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Picker("Podróże", selection: $selection) {
                    Text("Zaplanowane").tag(0)
                    Text("Regularne").tag(1)
                }.pickerStyle(.segmented)
                Button("Zaplanuj nową trasę", systemImage: "plus") { creating = true }
                Button("Ostatnie podróże", systemImage: "clock.arrow.circlepath", action: onHistory)
                if let message = service.errorMessage { Text(message).foregroundStyle(.red) }
                if let message = service.reminderMessage { Text(message).foregroundStyle(.secondary) }
                let visible = service.upcomingTrips.filter { selection == 0 || $0.repeatRule != .never }
                if visible.isEmpty {
                    ContentUnavailableView("Brak zaplanowanych podróży", systemImage: "calendar",
                        description: Text("Zapisz trasę na później lub ustaw regularne wyjazdy."))
                }
                ForEach(visible) { trip in
                    NavigationLink(value: trip.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(trip.displayTitle, systemImage: trip.transportMode.symbol).font(.headline)
                            Text("\(trip.origin.name) → \(trip.destination.name)").font(.subheadline)
                            if let occurrence = trip.occurrences(after: Date()).first {
                                Text(PolishRegionalFormat.dateTime(occurrence, dateStyle: .abbreviated, timeZone: trip.calendar.timeZone)).font(.subheadline)
                                if let departure = trip.departure(for: occurrence) {
                                    Text("Wyjazd około \(PolishRegionalFormat.time(departure, timeZone: trip.calendar.timeZone))")
                                        .foregroundStyle(.secondary)
                                } else { Text("Czas trasy niedostępny").foregroundStyle(.secondary) }
                            }
                            if trip.repeatRule != .never { Text(trip.repeatRule.title).font(.caption).foregroundStyle(.secondary) }
                            if trip.refreshError != nil { Label("Trasa wymaga odświeżenia", systemImage: "exclamationmark.triangle").font(.caption) }
                        }.padding(.vertical, 5)
                    }
                    .swipeActions {
                        Button("Usuń", role: .destructive) { removing = trip }
                        Button("Edytuj") { editing = trip }.tint(.accentColor)
                    }
                }
                if selection == 0 {
                    let past = service.trips.filter { $0.occurrences(after: Date()).isEmpty }
                        .sorted { $0.targetDate > $1.targetDate }
                    if !past.isEmpty {
                        Section("Poprzednie plany") {
                            ForEach(past) { trip in
                                NavigationLink(trip.displayTitle, value: trip.id)
                            }
                        }
                    }
                }
                Section {
                    Text("Plany są przechowywane na tym urządzeniu. Przypomnienia korzystają z ostatniego przeliczenia. Ruch odświeżamy podczas używania aplikacji i gdy system pozwoli na pracę w tle.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Podróże")
            .navigationDestination(for: UUID.self) { detail($0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zamknij", action: onClose) }
                ToolbarItem(placement: .primaryAction) {
                    Button("Odśwież", systemImage: "arrow.clockwise") { Task { await service.refreshUpcoming(force: true) } }
                        .disabled(!service.refreshingIDs.isEmpty)
                }
            }
            .sheet(isPresented: $creating) {
                PlannedTripEditor(service: service, seed: nil, places: places, currentOrigin: currentOrigin)
            }
            .sheet(item: $editing) { trip in
                PlannedTripEditor(service: service, seed: trip, places: places, currentOrigin: currentOrigin)
            }
            .confirmationDialog("Usunąć zaplanowaną podróż i jej przypomnienia?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Usuń", role: .destructive) { if let removing { service.delete(removing.id) }; removing = nil }
            }
            .task {
                openRequestedTrip()
                await service.refreshUpcoming()
            }
            .onChange(of: service.requestedTripID) { _, id in
                if id != nil { openRequestedTrip() }
            }
            .refreshable { await service.refreshUpcoming(force: true) }
        }
    }

    private func openRequestedTrip() {
        guard let id = service.requestedTripID else { return }
        service.requestedTripID = nil
        if service.trips.contains(where: { $0.id == id }) { path = [id] }
        else { service.errorMessage = "Ta zaplanowana podróż została usunięta." }
    }

    @ViewBuilder private func detail(_ id: UUID) -> some View {
        if let trip = service.trips.first(where: { $0.id == id }) {
            List {
                Section("Trasa") {
                    LabeledContent("Start", value: trip.origin.name)
                    LabeledContent("Cel", value: trip.destination.name)
                    ForEach(trip.waypoints) { stop in Label(stop.name, systemImage: "mappin") }
                    LabeledContent("Transport", value: trip.transportMode.title)
                    LabeledContent("Wariant", value: trip.preferredRoute.isEmpty ? trip.preferences.advanced.effectiveRoutePreference.title : "Wybrany wcześniej")
                }
                if let occurrence = trip.occurrences(after: Date()).first {
                    Section("Termin") {
                        Text(PolishRegionalFormat.dateTime(occurrence, dateStyle: .complete, timeZone: trip.calendar.timeZone))
                        LabeledContent(trip.timing.title, value: PolishRegionalFormat.dateTime(occurrence, dateStyle: .omitted, timeZone: trip.calendar.timeZone))
                        if let departure = trip.departure(for: occurrence) {
                            LabeledContent("Wyjazd około", value: PolishRegionalFormat.time(departure, timeZone: trip.calendar.timeZone))
                            if departure < Date() { Text("Zalecana godzina wyjazdu już minęła.").foregroundStyle(.orange) }
                        }
                        LabeledContent("Strefa czasowa", value: trip.timeZoneIdentifier)
                        LabeledContent("Powtarzanie", value: trip.repeatRule.title)
                    }
                    if let estimate = trip.estimate {
                        Section("Ostatnie przeliczenie") {
                            LabeledContent("Czas trasy", value: TravelDurationFormatter.string(minutes: Int(ceil(estimate.travelSeconds / 60))))
                            LabeledContent("Dystans", value: String(format: "%.1f km", locale: PolishRegionalFormat.locale, estimate.distanceMeters / 1_000))
                            LabeledContent("Przyjazd około", value: PolishRegionalFormat.dateTime(estimate.arrival, dateStyle: .abbreviated, timeZone: trip.calendar.timeZone))
                            Text("Obliczono \(PolishRegionalFormat.dateTime(estimate.updatedAt, dateStyle: .abbreviated, timeZone: trip.calendar.timeZone))").font(.footnote)
                            Text(estimate.currentTraffic ? "Uwzględniono dostępne pomiary ruchu. Pozostałe odcinki według silnika tras." : "Szacunek silnika tras; bez bieżących pomiarów ruchu.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let note = estimate.trafficNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
                            if !estimate.preferredRouteMatched { Text("Wybrany wcześniej wariant nie jest dostępny. Użyto aktualnej rekomendacji silnika tras.").foregroundStyle(.orange) }
                        }
                    }
                    if let message = trip.refreshError { Text(message).foregroundStyle(.red) }
                    Button("Pomiń ten termin", systemImage: "checkmark") { service.complete(trip.id, occurrence: occurrence) }
                } else {
                    Section("Termin") {
                        Text(PolishRegionalFormat.dateTime(trip.targetDate, dateStyle: .complete, timeZone: trip.calendar.timeZone))
                        Text(trip.completedOccurrence != nil ? "Termin wykorzystany lub pominięty" : "Termin minął")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Edytuj", systemImage: "pencil") { editing = trip }
                    Button("Przelicz teraz", systemImage: "arrow.clockwise") { Task { await service.refresh(trip.id) } }
                        .disabled(service.refreshingIDs.contains(trip.id) || trip.occurrences(after: Date()).isEmpty)
                    Button("Rozpocznij teraz", systemImage: "location.fill") { onOpen(trip) }
                    Button("Usuń podróż", role: .destructive) { removing = trip }
                }
            }.navigationTitle(trip.displayTitle)
        } else { ContentUnavailableView("Podróż nie jest dostępna", systemImage: "calendar") }
    }
}

struct PlannedTripEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var service: TripPlanningService
    let seed: PlannedTrip?
    let places: [Destination]
    let currentOrigin: Destination?
    @State private var title: String
    @State private var origin: Destination?
    @State private var destination: Destination?
    @State private var waypoints: [Destination]
    @State private var mode: TransportMode
    @State private var preferences: RoutingPreferences
    @State private var timing: PlannedTrip.Timing
    @State private var targetDate: Date
    @State private var bufferMinutes: Int
    @State private var stopMinutes: Int
    @State private var repeatRule: PlannedTrip.RepeatRule
    @State private var weekdays: Set<Int>
    @State private var reminders: Set<Int>
    @State private var keepPreferred: Bool
    @State private var picker: PlaceField?
    @State private var searchQuery = ""
    @State private var saving = false
    @State private var message: String?
    private enum PlaceField: String, Identifiable { case origin, destination, waypoint; var id: Self { self } }

    init(service: TripPlanningService, seed: PlannedTrip?, places: [Destination], currentOrigin: Destination?) {
        self.service = service; self.seed = seed; self.places = places; self.currentOrigin = currentOrigin
        _title = State(initialValue: seed?.title ?? "")
        _origin = State(initialValue: seed?.origin ?? currentOrigin)
        _destination = State(initialValue: seed?.destination)
        _waypoints = State(initialValue: seed?.waypoints ?? [])
        _mode = State(initialValue: seed?.transportMode ?? .configuredDefault)
        var initialPreferences = seed?.preferences ?? RoutingPreferences()
        initialPreferences.advanced.routePreference = initialPreferences.advanced.effectiveRoutePreference
        _preferences = State(initialValue: initialPreferences)
        _timing = State(initialValue: seed?.timing ?? .departure)
        _targetDate = State(initialValue: seed.map { $0.occurrences(after: Date()).first ?? max($0.targetDate, Date().addingTimeInterval(60)) } ?? Date().addingTimeInterval(3_600))
        _bufferMinutes = State(initialValue: seed?.bufferMinutes ?? 15)
        _stopMinutes = State(initialValue: seed?.stopMinutes ?? 0)
        _repeatRule = State(initialValue: seed?.repeatRule ?? .never)
        _weekdays = State(initialValue: seed?.weekdays ?? [2, 3, 4, 5, 6])
        _reminders = State(initialValue: seed?.reminderMinutes ?? [15, 0])
        _keepPreferred = State(initialValue: !(seed?.preferredRoute.isEmpty ?? true))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trasa") {
                    TextField("Nazwa podróży (opcjonalnie)", text: $title)
                    Button("Start: \(origin?.name ?? "Wybierz miejsce")") { searchQuery = ""; picker = .origin }
                    Button("Cel: \(destination?.name ?? "Wybierz miejsce")") { searchQuery = ""; picker = .destination }
                    Picker("Transport", selection: $mode) { ForEach(TransportMode.allCases) { Text($0.title).tag($0) } }
                    NavigationLink("Zaplanuj dojazd z kalendarza") {
                        TripCalendarPicker { eventTitle, date, location, coordinate in
                            title = eventTitle; targetDate = date; timing = .arrival
                            if let coordinate { destination = Destination(name: eventTitle, coordinate: coordinate, address: location) }
                            else { searchQuery = location; picker = .destination }
                        }
                    }
                }
                Section("Termin") {
                    Picker("Godzina", selection: $timing) {
                        Text("Wyjazd").tag(PlannedTrip.Timing.departure)
                        Text("Przyjazd do").tag(PlannedTrip.Timing.arrival)
                    }.pickerStyle(.segmented)
                    DatePicker("Data i godzina", selection: $targetDate, in: Date().addingTimeInterval(60)...)
                        .environment(\.locale, PolishRegionalFormat.locale)
                        .environment(\.timeZone, TimeZone(identifier: seed?.timeZoneIdentifier ?? TimeZone.current.identifier) ?? .current)
                    if timing == .arrival { Stepper("Bufor: \(bufferMinutes) min", value: $bufferMinutes, in: 0...180, step: 5) }
                    Picker("Powtarzaj", selection: $repeatRule) { ForEach(PlannedTrip.RepeatRule.allCases) { Text($0.title).tag($0) } }
                    if repeatRule == .custom {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                            Toggle(PolishRegionalFormat.weekday(day), isOn: Binding(
                                get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
                        }
                    }
                }
                if mode == .car || mode == .walking || mode == .bicycle {
                    Section("Postoje") {
                        ForEach(waypoints) { Text($0.name) }
                            .onDelete { waypoints.remove(atOffsets: $0) }
                            .onMove { waypoints.move(fromOffsets: $0, toOffset: $1) }
                        Button("Dodaj postój", systemImage: "plus") { searchQuery = ""; picker = .waypoint }
                        if !waypoints.isEmpty { Stepper("Łączny czas postojów: \(stopMinutes) min", value: $stopMinutes, in: 0...360, step: 5) }
                    }
                }
                Section("Preferencje trasy") {
                    Picker("Wariant", selection: $preferences.advanced.routePreference) {
                        ForEach(RoutePreference.allCases) { Text($0.title).tag($0) }
                    }
                    if !(seed?.preferredRoute.isEmpty ?? true) { Toggle("Zachowaj wybrany wcześniej wariant", isOn: $keepPreferred) }
                    if mode == .car {
                        Toggle("Unikaj opłat", isOn: $preferences.avoidTolls)
                        Toggle("Unikaj autostrad", isOn: $preferences.avoidHighways)
                    }
                    Toggle("Unikaj promów", isOn: $preferences.avoidFerries)
                    Toggle("Unikaj dróg nieutwardzonych", isOn: $preferences.avoidUnpaved)
                    Text("Profil pojazdu i pozostałe ustawienia zapisujemy z planowanej trasy.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Przypomnienia") {
                    ForEach([1_440, 60, 15, 0], id: \.self) { minutes in
                        Toggle(minutes == 1_440 ? "Dzień wcześniej" : minutes == 0 ? "W chwili wyjazdu" : "\(minutes) min przed wyjazdem", isOn: Binding(
                            get: { reminders.contains(minutes) }, set: { if $0 { reminders.insert(minutes) } else { reminders.remove(minutes) } }))
                    }
                    Text("Terminy przypomnień obliczamy z ostatnio dostępnej trasy. Bieżący ruch nie jest prognozą korków na przyszłe dni.").font(.footnote).foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.red) }
                if saving { ProgressView("Zapisuję i przeliczam trasę…") }
            }
            .navigationTitle("Zaplanuj na później")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Zapisz") { Task { await save() } }.disabled(saving || origin == nil || destination == nil || (repeatRule == .custom && weekdays.isEmpty)) }
            }
            .sheet(item: $picker) { field in
                TripPlacePicker(places: places, currentOrigin: currentOrigin, initialQuery: searchQuery) { chosen in
                    switch field {
                    case .origin: origin = chosen
                    case .destination: destination = chosen
                    case .waypoint: waypoints.append(chosen)
                    }
                }
            }
            .onChange(of: origin) { _, _ in keepPreferred = false }
            .onChange(of: destination) { _, _ in keepPreferred = false }
            .onChange(of: waypoints) { _, _ in keepPreferred = false }
            .onChange(of: mode) { _, mode in
                keepPreferred = false
                if mode == .transit { waypoints = []; stopMinutes = 0 }
            }
        }.interactiveDismissDisabled(saving)
    }

    private func save() async {
        guard let origin, let destination else { return }
        guard targetDate > Date() else { message = "Wybierz przyszłą datę i godzinę podróży."; return }
        saving = true
        defer { saving = false }
        var trip = seed ?? PlannedTrip(origin: origin, destination: destination, transportMode: mode, preferences: preferences, targetDate: targetDate)
        trip.title = title; trip.origin = origin; trip.destination = destination
        trip.transportMode = mode; trip.preferences = preferences
        trip.preferences.advanced.shortest = preferences.advanced.routePreference == .shortest
        trip.waypoints = waypoints; trip.timing = timing; trip.targetDate = targetDate
        trip.bufferMinutes = bufferMinutes; trip.stopMinutes = waypoints.isEmpty ? 0 : stopMinutes
        trip.repeatRule = repeatRule; trip.weekdays = weekdays; trip.reminderMinutes = reminders
        trip.preferredRoute = keepPreferred ? seed?.preferredRoute ?? [] : []
        trip.estimate = nil; trip.refreshError = nil; trip.completedOccurrence = nil
        guard service.save(trip) else { message = service.errorMessage; return }
        await service.refresh(trip.id)
        if !reminders.isEmpty { await service.enableReminders() }
        else { await service.reschedule() }
        BackgroundMaintenance.schedule()
        dismiss()
    }
}

private struct TripPlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    let places: [Destination]
    let currentOrigin: Destination?
    let initialQuery: String
    let onSelect: (Destination) -> Void
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Szukam…") }
                if let error { Text(error).foregroundStyle(.red) }
                if query.isEmpty {
                    if let currentOrigin { Button("Bieżąca lokalizacja (zapisz ten punkt)") { choose(currentOrigin) } }
                    ForEach(places) { place in Button(place.name) { choose(place) } }
                } else {
                    ForEach(results) { result in
                        Button { choose(result.navigationDestination) } label: {
                            VStack(alignment: .leading) {
                                Text(result.destination.name)
                                if let address = result.destination.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if !loading && error == nil && results.isEmpty { Text("Brak wyników. Dopisz miejscowość lub adres.") }
                }
            }
            .navigationTitle("Wybierz miejsce")
            .searchable(text: $query, prompt: "Miejsce, adres lub postój")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Zamknij") { dismiss() } } }
            .onAppear { query = initialQuery }
            .task(id: query) {
                results = []; error = nil; loading = false
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
                loading = true
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "") ?? URL(string: "https://valhalla1.openstreetmap.de")!
                    let found = try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint)).search(query,
                        context: SearchContext(origin: currentOrigin?.coordinate, localDestinations: places))
                    try Task.checkCancellation()
                    results = found; loading = false
                } catch is CancellationError { }
                catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
            }
        }
    }
    private func choose(_ destination: Destination) { onSelect(destination); dismiss() }
}

private struct TripCalendarPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String, Date, String, Coordinate?) -> Void
    @State private var events: [EKEvent] = []
    @State private var message: String?
    @State private var loading = true
    @State private var store = EKEventStore()

    var body: some View {
        List {
            if loading { ProgressView("Wczytuję wydarzenia…") }
            if let message { Text(message).foregroundStyle(.secondary) }
            ForEach(events, id: \.eventIdentifier) { event in
                Button {
                    let coordinate = event.structuredLocation?.geoLocation.map {
                        Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                    }
                    onSelect(event.title ?? "Wydarzenie", event.startDate, event.location ?? "", coordinate)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(event.title ?? "Wydarzenie")
                        Text(PolishRegionalFormat.dateTime(event.startDate)).font(.subheadline)
                        Text(event.location ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Dojazd na wydarzenie")
        .task {
            defer { loading = false }
            do {
                let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                    store.requestFullAccessToEvents { granted, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: granted) }
                    }
                }
                guard granted else { message = "Brak dostępu do kalendarza. Dostęp możesz włączyć w ustawieniach systemu."; return }
                let start = Date()
                let end = Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start
                events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                    .filter { !$0.isAllDay && $0.startDate > start && ($0.structuredLocation?.geoLocation != nil || !($0.location ?? "").isEmpty) }
                    .sorted { $0.startDate < $1.startDate }
                if events.isEmpty { message = "Brak wydarzeń z godziną i lokalizacją w najbliższych 30 dniach." }
            } catch { message = error.localizedDescription }
        }
    }
}
