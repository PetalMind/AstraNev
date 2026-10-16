#if os(iOS)
import SwiftUI
import EventKit

struct IOSTripPlaceSearch: View {
    @Bindable var draft: IOSPlannedTripDraft
    let places: [SavedPlace]
    let recentPlaces: [Destination]
    let onBack: () -> Void
    let onMap: () -> Void
    let onSelect: (Destination, IOSTripPointRole) -> Void
    @FocusState private var focused: Bool
    @State private var scope = 0
    @State private var results: [SearchResult] = []
    @State private var stops: [TransitStop] = []
    @State private var loading = false
    @State private var completed = false
    @State private var errorMessage: String?
    @State private var requestID = UUID()
    @State private var submittedRevision = 0
    private var query: String { draft.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var localMatches: [Destination] {
        guard !query.isEmpty, scope == 0 else { return [] }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: PolishRegionalFormat.locale)
        var matches: [Destination] = []
        for place in places.map(\.navigationDestination) + recentPlaces {
            let text = (place.name + " " + (place.address ?? "")).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: PolishRegionalFormat.locale)
            if text.contains(needle), !matches.contains(where: { $0.coordinate.distance(to: place.coordinate) < 5 }) { matches.append(place) }
        }
        return Array(matches.prefix(6))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Wróć do szkicu")
                    Text(draft.selectedRole.title).font(.title2.weight(.semibold))
                    Spacer()
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.accentColor)
                    TextField(scope == 0 ? "Wpisz adres lub nazwę miejsca" : "Wpisz nazwę przystanku", text: $draft.searchQuery)
                        .focused($focused).submitLabel(.search).autocorrectionDisabled()
                        .onSubmit { submittedRevision += 1 }
                    if !draft.searchQuery.isEmpty {
                        Button { draft.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 40, height: 40) }
                            .accessibilityLabel("Wyczyść adres")
                    }
                }.padding(.horizontal, 14).frame(minHeight: 52).modifier(NavigationGlassSurface(radius: 16, interactive: true))
                Button(action: onMap) {
                    Label("Wybierz na mapie", systemImage: "mappin.and.ellipse").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                }.buttonStyle(.bordered)
                if draft.mode == .transit {
                    Picker("Wyszukaj", selection: $scope) { Text("Adresy i miejsca").tag(0); Text("Przystanki").tag(1) }.pickerStyle(.segmented)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let message = draft.message { Text(message).foregroundStyle(.red).font(.subheadline) }
                    if query.isEmpty {
                        if let current = draft.currentOrigin {
                            sectionTitle("Bieżące miejsce")
                            locationRow(current, symbol: "location.fill", subtitle: "Zapisz ten punkt jako miejsce podróży")
                        }
                        if !places.isEmpty {
                            sectionTitle("Zapisane miejsca")
                            ForEach(places) { place in locationRow(place.navigationDestination, symbol: place.icon.symbol, subtitle: place.destination.address ?? place.kind.title) }
                        }
                        if !recentPlaces.isEmpty {
                            sectionTitle("Ostatnie miejsca")
                            ForEach(Array(recentPlaces.prefix(10).enumerated()), id: \.offset) { _, place in
                                locationRow(place, symbol: "clock.arrow.circlepath", subtitle: place.address)
                            }
                        }
                        if places.isEmpty && recentPlaces.isEmpty && draft.currentOrigin == nil {
                            Text("Wpisz miejscowość i adres albo wybierz punkt na mapie. Lokalizacja GPS nie jest potrzebna do zapisania wybranego miejsca.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else if scope == 0 {
                        if !localMatches.isEmpty {
                            sectionTitle("Zapisane i ostatnie miejsca")
                            ForEach(localMatches) { place in locationRow(place, symbol: "star", subtitle: place.address) }
                        }
                        ForEach(results.filter { result in !localMatches.contains(where: { $0.coordinate.distance(to: result.destination.coordinate) < 5 }) }) { result in locationRow(result.navigationDestination, symbol: result.isPOI ? "mappin" : "building.2", subtitle: result.destination.address ?? [result.street, result.houseNumber, result.city].compactMap { $0 }.joined(separator: " ")) }
                    } else {
                        ForEach(stops) { stop in
                            locationRow(Destination(name: stop.name, coordinate: stop.coordinate, address: stop.address),
                                symbol: "tram.fill", subtitle: stop.address)
                        }
                    }
                    if loading { ProgressView(results.isEmpty && stops.isEmpty ? "Szukam miejsc…" : "Uzupełniam wyniki…").font(.subheadline) }
                    if let errorMessage {
                        Text(errorMessage).font(.subheadline).foregroundStyle(.red)
                        Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { submittedRevision += 1 }
                    } else if completed && !loading && results.isEmpty && stops.isEmpty && localMatches.isEmpty {
                        Text("Nie znaleziono miejsca. Dopisz miejscowość lub numer budynku albo wybierz punkt na mapie.").font(.subheadline).foregroundStyle(.secondary)
                    } else if !query.isEmpty && query.count < 2 && localMatches.isEmpty {
                        Text("Wpisz co najmniej dwa znaki.").font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }.scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: 620).frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .task(id: query + String(scope) + String(submittedRevision)) { await search() }
    }

    private func sectionTitle(_ title: String) -> some View { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
    private func locationRow(_ place: Destination, symbol: String, subtitle: String?) -> some View {
        Button { focused = false; onSelect(place, draft.selectedRole) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("Wybierz").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }.padding(12).frame(minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(.plain).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }

    private func search() async {
        let id = UUID(); requestID = id
        results = []; stops = []; completed = false; errorMessage = nil; loading = false
        guard query.count >= 2 else { return }
        let requestedQuery = query
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            if scope == 1 {
                let found = await draft.session.transitDataProvider.search(requestedQuery,
                    near: draft.origin?.coordinate ?? draft.mapState.searchMapCenter)
                guard !Task.isCancelled, requestID == id else { return }
                stops = found.stops
            } else {
                let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "")
                    ?? URL(string: "https://valhalla1.openstreetmap.de")!
                let context = SearchContext(origin: draft.origin?.coordinate ?? draft.currentOrigin?.coordinate,
                    area: draft.mapState.searchMapCenter, route: draft.mapState.route?.coordinates ?? [],
                    mode: draft.mode, preferences: draft.preferences,
                    localDestinations: places.map(\.navigationDestination) + recentPlaces)
                let found = try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint)).search(requestedQuery,
                    context: context, includeUUGFallback: submittedRevision > 0,
                    onUpdate: { partial in
                        guard !Task.isCancelled, requestID == id else { return }
                        results = partial
                    })
                guard !Task.isCancelled, requestID == id else { return }
                results = found
            }
            completed = true; loading = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestID == id else { return }
            loading = false
            switch SearchError.classify(error) {
            case .offline: errorMessage = "Brak internetu. Możesz wybrać zapisane miejsce lub punkt na mapie."
            case .timeout: errorMessage = "Wyszukiwanie trwa zbyt długo. Spróbuj ponownie lub wybierz punkt na mapie."
            case .locationRequired: errorMessage = "Dopisz miejscowość albo ustaw obszar na mapie."
            default: errorMessage = "Nie udało się wyszukać adresu. Spróbuj ponownie lub wybierz punkt na mapie."
            }
        }
    }
}

struct IOSTripCalendarEvent: Identifiable {
    let id: String
    let title: String
    let date: Date
    let location: String
    let coordinate: Coordinate?
}

struct IOSTripCalendarSelection: View {
    let onBack: () -> Void
    let onSelect: (IOSTripCalendarEvent) -> Void
    @State private var store = EKEventStore()
    @State private var events: [IOSTripCalendarEvent] = []
    @State private var message: String?
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Wróć do szkicu")
                Text("Dojazd na wydarzenie").font(.title2.weight(.semibold))
            }.padding(.horizontal, 8)
            List {
                if loading { ProgressView("Wczytuję wydarzenia…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                ForEach(events) { event in
                    Button { onSelect(event) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title).font(.headline)
                            Text(PolishRegionalFormat.dateTime(event.date)).font(.subheadline)
                            Text(event.location).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }
        }.task {
            defer { loading = false }
            do {
                let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                    store.requestFullAccessToEvents { granted, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                    }
                }
                guard granted else { message = "Brak dostępu do kalendarza. Możesz zaplanować trasę, wpisując adres."; return }
                let start = Date(), end = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
                events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                    .filter { !$0.isAllDay && $0.startDate > start && ($0.structuredLocation?.geoLocation != nil || !($0.location ?? "").isEmpty) }
                    .sorted { $0.startDate < $1.startDate }.map { event in
                        IOSTripCalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Wydarzenie",
                            date: event.startDate, location: event.location ?? "",
                            coordinate: event.structuredLocation?.geoLocation.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
                    }
                if events.isEmpty { message = "Brak wydarzeń z godziną i adresem w najbliższych 30 dniach." }
            } catch { message = "Nie udało się wczytać kalendarza. Możesz wpisać adres ręcznie." }
        }
    }
}
#endif
