import SwiftUI
import MapKit
import Charts

private enum HistoryTab: String, CaseIterable, Identifiable {
    case trips = "Trasy", activity = "Mapa aktywności", searches = "Wyszukiwania"
    var id: Self { self }
}

private enum HistoryPeriod: String, CaseIterable, Identifiable {
    case all = "Cała historia", week = "7 dni", month = "30 dni", year = "365 dni", custom = "Własny zakres"
    var id: Self { self }
    var days: Int? {
        switch self {
        case .all, .custom: nil
        case .week: 7
        case .month: 30
        case .year: 365
        }
    }
}

private enum HistoryStatus: String, CaseIterable, Identifiable {
    case all = "Wszystkie", completed = "Ukończone", interrupted = "Przerwane"
    var id: Self { self }
}

private enum HistoryVehicleFilter: Hashable {
    case all, unassigned, vehicle(UUID)
}

private struct HistoryDay: Identifiable {
    let date: Date
    let trips: [TripRecord]
    var id: Date { date }
}

struct RouteHistoryView: View {
    let store: PlaceStore
    let onPlanTrip: (TripRecord) -> Void
    let onSearch: (Destination) -> Void
    let onFavorite: (Destination) -> Void
    let onClose: () -> Void
    var energyStore: EnergyStore? = nil
    var embeddedInNavigation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var period: HistoryPeriod = .all
    @State private var mode: TransportMode?
    @State private var status: HistoryStatus = .all
    @State private var vehicleFilter: HistoryVehicleFilter = .all
    @State private var searchText = ""
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var pendingRemoval: TripRecord?
    @State private var tab: HistoryTab = .trips
    @State private var showsFilters = false

    private var trips: [TripRecord] {
        let calendar = Calendar.current
        let cutoff = period.days.flatMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }
        let start = calendar.startOfDay(for: customStart)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd)) ?? customEnd
        return store.trips.filter { trip in
            trip.id != pendingRemoval?.id
                && (cutoff.map { trip.startedAt >= $0 } ?? true)
                && (period != .custom || (trip.startedAt >= start && trip.startedAt < end))
                && (mode == nil || trip.transportMode == mode)
                && (status == .all || (status == .completed ? trip.arrived : !trip.arrived))
                && matchesVehicle(trip) && matchesSearch(trip.destination)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private func days(for trips: [TripRecord]) -> [HistoryDay] {
        Dictionary(grouping: trips) { Calendar.current.startOfDay(for: $0.startedAt) }
            .map { HistoryDay(date: $0.key, trips: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private func matchesVehicle(_ trip: TripRecord) -> Bool {
        switch vehicleFilter {
        case .all: true
        case .unassigned: trip.transportMode == .car && trip.vehicleID == nil
        case .vehicle(let id): trip.vehicleID == id
        }
    }

    private func matchesSearch(_ destination: Destination) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [destination.name, destination.address ?? ""].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: TripHistoryFormat.locale) != nil
        }
    }

    private func isSaved(_ destination: Destination) -> Bool {
        store.places.contains { $0.kind == .favorite && $0.destination.coordinate == destination.coordinate }
    }

    var body: some View {
        Group {
            if embeddedInNavigation {
                historyContent
            } else {
                NavigationStack { historyContent }
            }
        }
        .environment(\.locale, TripHistoryFormat.locale)
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if dynamicTypeSize.isAccessibilitySize {
                    historyPicker.pickerStyle(.menu)
                } else {
                    historyPicker.pickerStyle(.segmented)
                }
                if tab != .searches {
                    DisclosureGroup(isExpanded: $showsFilters) {
                        filters.padding(.top, 8)
                    } label: {
                        Label(activeFilterCount == 0 ? "Filtry przejazdów" : "Filtry przejazdów: \(activeFilterCount)",
                              systemImage: "line.3.horizontal.decrease")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                }
            }
            .padding(14)
            #if os(iOS)
            .iosCardSurface(radius: 24)
            #else
            .modifier(NavigationGlassSurface(radius: 24))
            #endif
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if tab == .trips {
                tripsList
            } else if tab == .activity {
                TripHeatmapView(trips: trips)
            } else {
                searchesList
            }
        }
        .background { TripHistoryBackground() }
        .navigationTitle("Historia przejazdów")
        .searchable(text: $searchText, prompt: "Szukaj celu lub adresu")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !embeddedInNavigation {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij", action: onClose)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let pendingRemoval {
                    HStack(spacing: 12) {
                        Text("Ukryto przejazd do: \(pendingRemoval.destination.name)")
                            .font(.subheadline).lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Cofnij") { self.pendingRemoval = nil }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.regularMaterial)
                    .accessibilityElement(children: .contain)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
        }
        .task(id: pendingRemoval?.id) {
            guard let id = pendingRemoval?.id else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled, pendingRemoval?.id == id else { return }
            commitRemoval()
        }
        .onDisappear { commitRemoval() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { commitRemoval() } }
    }

    private var historyPicker: some View {
        Picker("Widok historii", selection: $tab) {
            ForEach(HistoryTab.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private var activeFilterCount: Int {
        [period != .all, mode != nil, status != .all, vehicleFilter != .all].filter { $0 }.count
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { periodFilter; transportFilter }
                VStack(alignment: .leading, spacing: 10) { periodFilter; transportFilter }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { statusFilter; vehiclePicker }
                VStack(alignment: .leading, spacing: 10) { statusFilter; vehiclePicker }
            }
            if period == .custom {
                DatePicker("Od", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                DatePicker("Do", selection: $customEnd, in: customStart..., displayedComponents: .date)
            }
        }
    }

    private var statusFilter: some View {
        Menu {
            Picker("Status przejazdu", selection: $status) {
                ForEach(HistoryStatus.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: { filterLabel(status.rawValue, symbol: "flag.checkered") }
            .accessibilityLabel("Status przejazdu")
            .accessibilityValue(status.rawValue)
    }

    private var vehicleFilterTitle: String {
        switch vehicleFilter {
        case .all: "Każdy pojazd"
        case .unassigned: "Nieprzypisane"
        case .vehicle(let id): energyStore?.vehicles.first { $0.id == id }?.name ?? "Usunięty pojazd"
        }
    }

    @ViewBuilder private var vehiclePicker: some View {
        if let energyStore {
            Menu {
                Picker("Pojazd", selection: $vehicleFilter) {
                    Text("Każdy pojazd").tag(HistoryVehicleFilter.all)
                    Text("Samochód bez przypisanego pojazdu").tag(HistoryVehicleFilter.unassigned)
                    ForEach(energyStore.vehicles) { vehicle in
                        Text(vehicle.name).tag(HistoryVehicleFilter.vehicle(vehicle.id))
                    }
                }
            } label: { filterLabel(vehicleFilterTitle, symbol: "car.side") }
                .accessibilityLabel("Pojazd")
                .accessibilityValue(vehicleFilterTitle)
        }
    }

    private func scheduleRemoval(_ trip: TripRecord) {
        commitRemoval()
        pendingRemoval = trip
    }

    private func commitRemoval() {
        guard let trip = pendingRemoval else { return }
        pendingRemoval = nil
        if store.removeTrip(trip.id) { HistoryHeatmapCache.clear() }
    }

    private var periodFilter: some View {
        Menu {
            Picker("Okres", selection: $period) {
                ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            filterLabel(period == .all ? "Cała historia" : period.rawValue, symbol: "calendar")
        }
        .accessibilityLabel("Okres")
        .accessibilityValue(period.rawValue)
    }

    private var transportFilter: some View {
        Menu {
            Picker("Środek transportu", selection: $mode) {
                Text("Każdy transport").tag(nil as TransportMode?)
                ForEach(TransportMode.allCases) { Text($0.title).tag(Optional($0)) }
            }
        } label: {
            filterLabel(mode?.title ?? "Każdy", symbol: mode?.symbol ?? "car.side")
        }
        .accessibilityLabel("Środek transportu")
        .accessibilityValue(mode?.title ?? "Każdy transport")
    }

    private func filterLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var tripsList: some View {
        let visibleTrips = trips
        let groupedDays = days(for: visibleTrips)
        return List {
            if visibleTrips.isEmpty {
                ContentUnavailableView(store.trips.isEmpty ? "Brak przejazdów" : "Brak pasujących przejazdów",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text(store.trips.isEmpty
                        ? "Ukończone i przerwane nawigacje pojawią się tutaj."
                        : "Zmień filtry lub wpisaną nazwę celu, aby zobaczyć pozostałe przejazdy."))
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Podsumowanie", systemImage: "chart.bar.xaxis")
                            .font(.headline).foregroundStyle(Color.naviTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                        HistoryStatistics(trips: visibleTrips, compact: true)
                        if let energyStore {
                            let vehicles = energyStore.vehicles.filter { vehicle in
                                visibleTrips.contains { $0.transportMode == .car && $0.vehicleID == vehicle.id }
                            }
                            ForEach(vehicles) { vehicle in
                                Divider()
                                EnergyConsumptionSummary(store: energyStore, vehicle: vehicle, trips: store.trips)
                            }
                            if !vehicles.isEmpty {
                                Text("Średnie spalanie obejmuje wszystkie dostępne pomiary pojazdu, niezależnie od filtra historii.")
                                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                            }
                        }
                    }
                    .padding(18)
                    #if os(iOS)
                    .iosCardSurface(radius: 24)
                    #else
                    .modifier(NavigationGlassSurface(radius: 24))
                    #endif
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                }
                ForEach(groupedDays) { day in
                    Section {
                        ForEach(day.trips) { trip in tripLink(trip) }
                    } header: {
                        Text(day.date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(TripHistoryFormat.locale)))
                            .font(.headline).foregroundStyle(Color.naviTextPrimary)
                            .textCase(nil)
                            .padding(.top, 8)
                            .padding(.bottom, 6)
                    }
                }
                Section {
                    Label {
                        Text("Dane i ślady GPS są zapisywane lokalnie podczas nawigacji. Ślady są przechowywane dla 300 najnowszych przejazdów z ostatnich 365 dni. Statystyki starszych przejazdów pozostają w historii.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private func tripLink(_ trip: TripRecord) -> some View {
        NavigationLink {
            TripHistoryDetail(trip: trip, onPlan: { onPlanTrip(trip) }, energyStore: energyStore, places: store)
        } label: {
            TripHistoryRow(trip: trip, energyStore: energyStore, allTrips: store.trips)
        }
        .padding(16)
        #if os(iOS)
        .iosCardSurface(radius: 22)
        #else
        .modifier(NavigationGlassSurface(radius: 22, interactive: true))
        #endif
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .contextMenu {
            Button("Wyznacz trasę ponownie", systemImage: "arrow.triangle.turn.up.right.diamond") { onPlanTrip(trip) }
            Button(isSaved(trip.destination) ? "Zapisano w Ulubionych" : "Zapisz cel do ulubionych", systemImage: "heart") {
                onFavorite(trip.destination)
            }
            .disabled(isSaved(trip.destination))
            Button("Usuń podróż", systemImage: "trash", role: .destructive) { scheduleRemoval(trip) }
        }
        .swipeActions {
            Button("Usuń", role: .destructive) { scheduleRemoval(trip) }
        }
    }

    private var searchesList: some View {
        let searches = store.searches.filter { matchesSearch($0.destination) }
        return List {
            if searches.isEmpty {
                ContentUnavailableView(store.searches.isEmpty ? "Brak wyszukiwań" : "Brak pasujących miejsc", systemImage: "magnifyingglass",
                                       description: Text(store.searches.isEmpty ? "Ostatnio wybrane miejsca pojawią się tutaj." : "Wpisz inną nazwę lub adres."))
            }
            ForEach(searches) { item in
                HStack {
                    Button { onSearch(item.destination) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.destination.name).foregroundStyle(Color.naviTextPrimary)
                            Text(TripHistoryFormat.date(item.searchedAt))
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button {
                        onFavorite(item.destination)
                    } label: {
                        Label("Zapisz do ulubionych", systemImage: isSaved(item.destination) ? "checkmark" : "heart")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSaved(item.destination))
                    Button(role: .destructive) { store.removeSearch(item.id) } label: {
                        Label("Usuń wyszukiwanie", systemImage: "trash")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

private struct TripHistoryRow: View {
    let trip: TripRecord
    let energyStore: EnergyStore?
    let allTrips: [TripRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                #if os(iOS)
                if trip.trace.contains(where: { !$0.startsSegment }) {
                    TripMapThumbnail(trip: trip)
                } else {
                Image(systemName: trip.transportMode?.symbol ?? "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                }
                #else
                Image(systemName: trip.transportMode?.symbol ?? "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                #endif
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.destination.name)
                        .font(.headline).foregroundStyle(Color.naviTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(TripHistoryFormat.date(trip.startedAt))
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { distanceLabel; durationLabel }
                VStack(alignment: .leading, spacing: 6) { distanceLabel; durationLabel }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Color.naviTextPrimary)
            if trip.transportMode == .car, let energyStore {
                if let estimate = energyStore.estimate(for: trip, trips: allTrips) {
                    EnergyUsageLabel(estimate: estimate, compact: true)
                } else {
                    Label(trip.vehicleID == nil ? "Przypisz pojazd, aby obliczyć zużycie paliwa"
                          : "Zużycie paliwa niedostępne · brak zamkniętego pomiaru lub dystansu", systemImage: "fuelpump")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: trip.arrived ? "flag.checkered" : "stop.circle")
                Text(trip.terminationDescription)
                Text("·")
                Text(trip.trace.isEmpty ? "Brak śladu GPS" : "Zapis GPS")
            }
            .font(.caption).foregroundStyle(Color.naviTextSecondary)
            if let score = trip.drivingScore {
                DrivingScoreHistoryLabel(score: score)
            } else if let reason = trip.scoreUnavailableReason, trip.transportMode == .car {
                Label("Ocena niedostępna · \(reason)", systemImage: "steeringwheel")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var distanceLabel: some View {
        Label(TripHistoryFormat.distance(trip.distanceMeters), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
    }

    private var durationLabel: some View {
        Label(TripHistoryFormat.duration(trip.duration), systemImage: "clock")
    }
}

private struct HistoryStatistics: View {
    let trips: [TripRecord]
    var compact = false
    private var distance: Double { trips.reduce(0) { $0 + $1.distanceMeters } }
    private var moving: Double { trips.reduce(0) { $0 + $1.movingSeconds } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                HistoryMetric(title: "Przejazdy", value: "\(trips.count)", symbol: "map")
                HistoryMetric(title: "Dystans", value: TripHistoryFormat.distance(distance), symbol: "point.topleft.down.to.point.bottomright.curvepath")
                HistoryMetric(title: "Czas podróży", value: TripHistoryFormat.duration(trips.reduce(0) { $0 + $1.duration }), symbol: "clock")
            }
            if compact {
                DisclosureGroup("Więcej statystyk") { additionalMetrics.padding(.top, 12) }
                    .font(.subheadline)
            } else {
                additionalMetrics
            }
        }
        .padding(.vertical, 8)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .leading)]
            : [GridItem(.adaptive(minimum: 125), alignment: .leading)]
    }

    private var additionalMetrics: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            HistoryMetric(title: "Czas w ruchu", value: TripHistoryFormat.duration(moving), symbol: "figure.walk")
            HistoryMetric(title: "Średnia w ruchu", value: moving > 0 ? "\(Int((distance / moving * 3.6).rounded())) km/h" : "Brak danych", symbol: "speedometer")
            HistoryMetric(title: "Dotarcie do celu", value: "\(trips.filter(\.arrived).count) z \(trips.count)", symbol: "flag.checkered")
        }
    }
}

private struct HistoryMetric: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(Color.naviTextSecondary)
                .labelStyle(.titleAndIcon)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Color.naviTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct TripHeatmapView: View {
    let trips: [TripRecord]
    @State private var cells: [TripHeatCell] = []
    @State private var loading = true
    private var recordedCount: Int { trips.filter { !$0.trace.isEmpty }.count }
    private var maximumVisits: Int { cells.map(\.visits).max() ?? 1 }
    private var cacheKey: String { trips.map { "\($0.id.uuidString):\($0.trace.count)" }.joined(separator: "|") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recordedCount == 0 {
                ContentUnavailableView("Brak danych do mapy aktywności", systemImage: "map",
                    description: Text("Dla wybranych przejazdów nie ma dostępnego śladu GPS. Powód znajdziesz w szczegółach przejazdu. Możesz też zmienić filtry."))
            } else if loading {
                ProgressView("Przygotowuję mapę aktywności…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map {
                    ForEach(cells) { cell in
                        MapCircle(center: cell.coordinate, radius: cell.radius * 1.4)
                            .foregroundStyle(heatColor(cell.visits).opacity(0.14))
                        MapCircle(center: cell.coordinate, radius: cell.radius)
                            .foregroundStyle(heatColor(cell.visits).opacity(0.5))
                    }
                }
                .mapControls { MapCompass(); MapScaleView() }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .id(trips.map(\.id))
                HStack {
                    Circle().fill(.yellow).frame(width: 12, height: 12)
                    Text("1 podróż")
                    Spacer()
                    Circle().fill(heatColor(maximumVisits)).frame(width: 12, height: 12)
                    Text(TripHistoryFormat.journeys(maximumVisits))
                }
                .font(.caption)
                Text("\(recordedCount) z \(trips.count) podróży ma ślad GPS. Kolor pokazuje liczbę podróży w danym obszarze; postoje nie zwiększają intensywności. Luki GPS są pomijane.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            }
        }
        .padding()
        .task(id: cacheKey) {
            let key = cacheKey
            if let cached = HistoryHeatmapCache.cells[key] {
                cells = cached
                loading = false
                return
            }
            loading = true
            let traces = trips.map(\.trace)
            let computation = Task.detached(priority: .userInitiated) { TripHeatmap.cells(for: traces) }
            let result = await withTaskCancellationHandler {
                await computation.value
            } onCancel: {
                computation.cancel()
            }
            guard !Task.isCancelled else { return }
            HistoryHeatmapCache.insert(result, for: key)
            cells = result
            loading = false
        }
    }

    private func heatColor(_ visits: Int) -> Color {
        let strength = maximumVisits > 1 ? Double(visits - 1) / Double(maximumVisits - 1) : 0
        return Color(hue: 0.15 * (1 - strength), saturation: 0.95, brightness: 0.95)
    }
}

@MainActor private enum HistoryHeatmapCache {
    static var cells: [String: [TripHeatCell]] = [:]
    private static var order: [String] = []

    static func insert(_ value: [TripHeatCell], for key: String) {
        if cells[key] == nil { order.append(key) }
        cells[key] = value
        while order.count > 8 { cells.removeValue(forKey: order.removeFirst()) }
    }

    static func clear() {
        cells.removeAll()
        order.removeAll()
    }
}

struct TripHistoryDetail: View {
    let energyStore: EnergyStore?
    let places: PlaceStore?
    let trip: TripRecord
    let onPlan: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rememberError: String?

    init(trip: TripRecord, onPlan: @escaping () -> Void, energyStore: EnergyStore? = nil, places: PlaceStore? = nil) {
        self.energyStore = energyStore
        self.places = places
        self.trip = trip
        self.onPlan = onPlan
    }

    private var currentTrip: TripRecord { places?.trips.first { $0.id == trip.id } ?? trip }
    private var metricColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .leading)]
            : [GridItem(.adaptive(minimum: 125), alignment: .leading)]
    }
    private var learningEndpoint: URL? {
        URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "https://valhalla1.openstreetmap.de")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(trip.destination.name).font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(TripHistoryFormat.date(trip.startedAt))
                        .foregroundStyle(Color.naviTextSecondary)
                    Label(trip.transportMode?.title ?? "Rodzaj transportu niedostępny",
                          systemImage: trip.transportMode?.symbol ?? "map")
                    Label(trip.terminationDescription,
                          systemImage: trip.arrived ? "flag.checkered" : "stop.circle")
                        .foregroundStyle(Color.naviTextSecondary)
                    if trip.transportMode == .car, trip.arrived, DrivingLearningEngine.shared.settings.enabled,
                       let endpoint = learningEndpoint {
                        if DrivingLearningEngine.shared.isRemembered(trip.id) {
                            Label("Trasa zapamiętana", systemImage: "heart.fill")
                                .foregroundStyle(Color.accentColor)
                        } else if let reason = DrivingLearningEngine.shared.historyRememberUnavailableReason(trip) {
                            Label(reason, systemImage: "info.circle")
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        } else {
                            Button("Zapamiętaj tę trasę", systemImage: "heart") {
                                let engine = DrivingLearningEngine.shared
                                rememberError = engine.rememberHistoricalTrip(trip, endpoint: endpoint)
                                    ? nil : (engine.message ?? "Nie udało się zapamiętać trasy. Spróbuj ponownie.")
                            }
                        }
                        if let rememberError {
                            Label(rememberError, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        }
                    }
                }
                .font(.subheadline)

                if trip.transportMode == .car, let energyStore, let places {
                    HistoryDetailSection(title: "Paliwo i koszt jazdy", symbol: "fuelpump") {
                        Picker("Pojazd tego przejazdu", selection: Binding(
                            get: { currentTrip.vehicleID },
                            set: { _ = places.assignVehicle($0, to: trip.id) })) {
                            Text("Nieprzypisany").tag(nil as UUID?)
                            ForEach(energyStore.vehicles) { Text($0.name).tag(Optional($0.id)) }
                        }
                        if let vehicle = energyStore.vehicles.first(where: { $0.id == currentTrip.vehicleID }) {
                            if let estimate = energyStore.estimate(for: currentTrip, trips: places.trips) {
                                EnergyCostLabel(estimate: estimate)
                                Text("Zużycie oszacowano z dystansu przejazdu i aktualnej średniej pojazdu ze wszystkich dostępnych pomiarów, także późniejszych tankowań. Koszt opiera się na ostatnich zapisanych cenach. To nie jest pomiar rzeczywistego spalania tej trasy.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                EnergyConsumptionSummary(store: energyStore, vehicle: vehicle, trips: places.trips)
                            }
                        } else { Text("Wybierz pojazd, aby obliczyć szacowane zużycie paliwa.").foregroundStyle(.secondary) }
                        if let error = places.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if trip.transportMode == .car || trip.drivingScore != nil {
                    DrivingScoreSummaryCard(trip: trip)
                }

                HistoryDetailSection(title: "Podsumowanie przejazdu", symbol: "chart.bar") {
                    LazyVGrid(columns: metricColumns,
                              alignment: .leading, spacing: 18) {
                        HistoryMetric(title: "Dystans", value: TripHistoryFormat.distance(trip.distanceMeters), symbol: "point.topleft.down.to.point.bottomright.curvepath")
                        HistoryMetric(title: "Czas podróży", value: TripHistoryFormat.duration(trip.duration), symbol: "clock")
                        HistoryMetric(title: "Czas w ruchu", value: TripHistoryFormat.duration(trip.movingSeconds), symbol: "figure.walk")
                        HistoryMetric(title: "Postoje", value: trip.measuredStoppedSeconds.map(TripHistoryFormat.duration) ?? "Brak danych", symbol: "pause.circle")
                        HistoryMetric(title: "Bez pomiaru", value: TripHistoryFormat.duration(trip.unknownSeconds), symbol: "antenna.radiowaves.left.and.right.slash")
                        HistoryMetric(title: "Pokrycie pomiarem", value: trip.measuredStoppedSeconds == nil ? "Niepełne dane"
                            : trip.recordingCoverage.formatted(.percent.precision(.fractionLength(0)).locale(TripHistoryFormat.locale)),
                            symbol: "checkmark.circle")
                        HistoryMetric(title: "Średnia w ruchu", value: trip.movingSeconds > 0 ? "\(Int(trip.averageSpeedKph.rounded())) km/h" : "Brak danych", symbol: "speedometer")
                        HistoryMetric(title: "Maks. prędkość", value: trip.maximumSpeedKph.map { "\(Int($0.rounded())) km/h" } ?? "Brak danych", symbol: "speedometer")
                        HistoryMetric(title: "Przeliczenia", value: "\(trip.rerouteCount)", symbol: "arrow.triangle.branch")
                    }
                    if trip.unknownSeconds > 0 {
                        Text(trip.measuredStoppedSeconds == nil
                            ? "W starszym zapisie nie rozdzielono postojów od braku pomiaru. Nie można określić pełnego pokrycia podróży danymi GPS."
                            : "Dystans obejmuje tylko wiarygodne pomiary. Czas bez danych GPS nie jest zaliczany do postojów.")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    }
                    if let delay = trip.delaySeconds {
                        Divider()
                        Label("Względem pierwotnego planu: \(delay >= 0 ? "później" : "wcześniej") o \(TripHistoryFormat.duration(abs(delay)))",
                              systemImage: "clock.arrow.circlepath")
                            .font(.subheadline).foregroundStyle(Color.naviTextSecondary)
                    }
                }

                TripHistoryPlaybackView(trip: trip)
                Button(action: onPlan) {
                    Label("Wyznacz trasę ponownie", systemImage: "arrow.triangle.turn.up.right.diamond")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Text("Ponowne wyznaczenie korzysta z zapisanego środka transportu i punktów pośrednich oraz aktualnych ustawień planowania. Przy starszych wpisach bez rodzaju transportu użyje ustawienia domyślnego. Odtwarzanie pokazuje zapis GPS. Między wiarygodnymi pomiarami pozycja jest przybliżona. Podczas luki znacznik pozostaje na ostatniej znanej pozycji, bez odtwarzania brakującego odcinka. Czas bez pomiaru nie jest postojem.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .environment(\.locale, TripHistoryFormat.locale)
        .background { TripHistoryBackground() }
        .navigationTitle("Szczegóły podróży")
    }
}

struct HistoryDetailSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.headline).foregroundStyle(Color.naviTextPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .iosCardSurface(radius: 24)
        #else
        .modifier(NavigationGlassSurface(radius: 24))
        #endif
    }
}

/// Keep reading surfaces calm while native controls provide navigation chrome.
private struct TripHistoryBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
            .accessibilityHidden(true)
        #else
        let base = Color(naviHex: colorScheme == .dark
            ? NaviAstraColorPalette.navigationSurface : NaviAstraColorPalette.surfaceDay)
        base
            .overlay {
                LinearGradient(colors: [Color.accentColor.opacity(0.12), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        #endif
    }
}
