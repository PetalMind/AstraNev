import SwiftUI
import MapKit
import Charts

private enum HistoryPeriod: String, CaseIterable, Identifiable {
    case all = "Cała historia", week = "7 dni", month = "30 dni", year = "365 dni"
    var id: Self { self }
    var days: Int? {
        switch self {
        case .all: nil
        case .week: 7
        case .month: 30
        case .year: 365
        }
    }
}

struct RouteHistoryView: View {
    let store: PlaceStore
    let onPlanTrip: (TripRecord) -> Void
    let onSearch: (Destination) -> Void
    let onFavorite: (Destination) -> Void
    let onClose: () -> Void
    var completedOnly = false
    var embeddedInNavigation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: HistoryPeriod = .all
    @State private var mode: TransportMode?
    @State private var tab = 0

    private var trips: [TripRecord] {
        let cutoff = period.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        return store.trips.filter { trip in
            (cutoff.map { trip.startedAt >= $0 } ?? true) && (mode == nil || trip.transportMode == mode)
                && (!completedOnly || trip.arrived)
        }
    }

    private func isSaved(_ destination: Destination) -> Bool {
        store.places.contains { $0.destination.coordinate == destination.coordinate }
    }

    var body: some View {
        if embeddedInNavigation {
            historyContent
        } else {
            NavigationStack { historyContent }
        }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Picker("Widok historii", selection: $tab) {
                    Text("Trasy").tag(0)
                    Text("Mapa aktywności").tag(1)
                    if !completedOnly { Text("Wyszukiwania").tag(2) }
                }
                .pickerStyle(.segmented)
                if tab != 2 { filters }
            }
            .padding(14)
            .modifier(NavigationGlassSurface(radius: 24))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if tab == 0 {
                tripsList
            } else if tab == 1 {
                TripHeatmapView(trips: trips)
            } else {
                searchesList
            }
        }
        .environment(\.locale, TripHistoryFormat.locale)
        .background { TripHistoryBackground() }
        .navigationTitle(completedOnly ? "Historia przejazdów" : "Historia podróży")
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
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
    }

    @ViewBuilder
    private var filters: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) { periodFilter; transportFilter }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { periodFilter; transportFilter }
                VStack(alignment: .leading, spacing: 10) { periodFilter; transportFilter }
            }
        }
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
        List {
            if trips.isEmpty {
                ContentUnavailableView(completedOnly ? "Brak ukończonych przejazdów" : "Brak podróży", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text(completedOnly
                        ? "Po dotarciu do celu przejazd pojawi się tutaj wraz z dostępną oceną prowadzenia. Możesz też zmienić filtry."
                        : "Zakończone i przerwane nawigacje pojawią się tutaj. Możesz też zmienić filtry."))
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Podsumowanie", systemImage: "chart.bar.xaxis")
                            .font(.headline).foregroundStyle(Color.naviTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                        HistoryStatistics(trips: trips, compact: true)
                    }
                    .padding(18)
                    .modifier(NavigationGlassSurface(radius: 24))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                }
                Section {
                    ForEach(trips) { trip in
                        NavigationLink {
                            TripHistoryDetail(trip: trip, onPlan: { onPlanTrip(trip) })
                        } label: {
                            TripHistoryRow(trip: trip, showsUnavailableScore: completedOnly)
                        }
                        .padding(16)
                        .modifier(NavigationGlassSurface(radius: 22, interactive: true))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .contextMenu {
                            Button("Wyznacz trasę ponownie", systemImage: "arrow.triangle.turn.up.right.diamond") { onPlanTrip(trip) }
                            Button(isSaved(trip.destination) ? "Zapisano w Ulubionych" : "Zapisz cel do ulubionych", systemImage: "heart") {
                                onFavorite(trip.destination)
                            }
                            .disabled(isSaved(trip.destination))
                            Button("Usuń podróż", systemImage: "trash", role: .destructive) { store.removeTrip(trip.id) }
                        }
                        .swipeActions {
                            Button("Usuń", role: .destructive) { store.removeTrip(trip.id) }
                        }
                    }
                } header: {
                    Label("Przebyte trasy", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.headline).foregroundStyle(Color.naviTextPrimary)
                        .textCase(nil)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }
                Section {
                    Label {
                        Text("Dane i ślady GPS są zapisywane lokalnie na urządzeniu podczas aktywnej nawigacji. Starsze wpisy mogą nie mieć śladu GPS ani rodzaju transportu.")
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
    }

    private var searchesList: some View {
        List {
            if store.searches.isEmpty {
                ContentUnavailableView("Brak wyszukiwań", systemImage: "magnifyingglass",
                                       description: Text("Ostatnio wybrane miejsca pojawią się tutaj."))
            }
            ForEach(store.searches) { item in
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
                    Button("Zapisz do ulubionych", systemImage: isSaved(item.destination) ? "checkmark" : "heart") {
                        onFavorite(item.destination)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isSaved(item.destination))
                    Button("Usuń wyszukiwanie", systemImage: "trash", role: .destructive) { store.removeSearch(item.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct TripHistoryRow: View {
    let trip: TripRecord
    let showsUnavailableScore: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: trip.transportMode?.symbol ?? "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
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
            HStack(spacing: 6) {
                Image(systemName: trip.arrived ? "flag.checkered" : "stop.circle")
                Text(trip.arrived ? "Dojechano" : "Przerwano")
                Text("·")
                Text(trip.trace.isEmpty ? "Brak śladu GPS" : "Zapis GPS")
            }
            .font(.caption).foregroundStyle(Color.naviTextSecondary)
            if let score = trip.drivingScore {
                DrivingScoreHistoryLabel(score: score)
            } else if showsUnavailableScore && trip.transportMode == .car {
                Label("Ocena niedostępna · za mało danych", systemImage: "steeringwheel")
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
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 125), alignment: .leading)]
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
    }
}

private struct TripHeatmapView: View {
    let trips: [TripRecord]
    @State private var cells: [TripHeatCell] = []
    private var recordedCount: Int { trips.filter { !$0.trace.isEmpty }.count }
    private var maximumVisits: Int { cells.map(\.visits).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recordedCount == 0 {
                ContentUnavailableView("Brak danych do mapy aktywności", systemImage: "map",
                    description: Text("Mapa aktywności powstaje ze śladów GPS nowych podróży. Starsze statystyki nie zawierają przebiegu trasy."))
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
        .task(id: trips.map(\.id)) { cells = TripHeatmap.cells(for: trips) }
    }

    private func heatColor(_ visits: Int) -> Color {
        let strength = maximumVisits > 1 ? Double(visits - 1) / Double(maximumVisits - 1) : 0
        return Color(hue: 0.15 * (1 - strength), saturation: 0.95, brightness: 0.95)
    }
}

struct TripHistoryDetail: View {
    let trip: TripRecord
    let onPlan: () -> Void
    private let segments: [TripTraceSegment]
    private let speedSamples: [HistorySpeedSample]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var elapsed: Double = 0
    @State private var playing = false
    @State private var playbackRate = 5.0

    init(trip: TripRecord, onPlan: @escaping () -> Void) {
        self.trip = trip
        self.onPlan = onPlan
        segments = trip.traceSegments
        var segment = 0
        speedSamples = trip.trace.enumerated().compactMap { index, point in
            if point.startsSegment { segment += 1 }
            guard let speed = point.speedKph else {
                segment += 1
                return nil
            }
            return HistorySpeedSample(id: index, timestamp: point.timestamp, speed: speed, segment: segment)
        }
    }

    private var currentPoint: TripTracePoint? { trip.tracePoint(at: elapsed) }
    private var duration: Double { max(1, trip.duration) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(trip.destination.name).font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(TripHistoryFormat.date(trip.startedAt))
                        .foregroundStyle(Color.naviTextSecondary)
                    Label(trip.transportMode?.title ?? "Rodzaj transportu nie zapisany",
                          systemImage: trip.transportMode?.symbol ?? "map")
                    Label(trip.arrived ? "Dotarto do celu" : "Przerwano podróż",
                          systemImage: trip.arrived ? "flag.checkered" : "stop.circle")
                        .foregroundStyle(Color.naviTextSecondary)
                }
                .font(.subheadline)

                if trip.transportMode == .car || trip.drivingScore != nil {
                    DrivingScoreSummaryCard(trip: trip)
                }

                HistoryDetailSection(title: "Podsumowanie przejazdu", symbol: "chart.bar") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 125), alignment: .leading)],
                              alignment: .leading, spacing: 18) {
                        HistoryMetric(title: "Dystans", value: TripHistoryFormat.distance(trip.distanceMeters), symbol: "point.topleft.down.to.point.bottomright.curvepath")
                        HistoryMetric(title: "Czas podróży", value: TripHistoryFormat.duration(trip.duration), symbol: "clock")
                        HistoryMetric(title: "Czas w ruchu", value: TripHistoryFormat.duration(trip.movingSeconds), symbol: "figure.walk")
                        HistoryMetric(title: "Postoje", value: TripHistoryFormat.duration(trip.stoppedSeconds), symbol: "pause.circle")
                        HistoryMetric(title: "Średnia w ruchu", value: trip.movingSeconds > 0 ? "\(Int(trip.averageSpeedKph.rounded())) km/h" : "Brak danych", symbol: "speedometer")
                        HistoryMetric(title: "Maks. prędkość", value: trip.maximumSpeedKph.map { "\(Int($0.rounded())) km/h" } ?? "Brak danych", symbol: "speedometer")
                        HistoryMetric(title: "Przeliczenia", value: "\(trip.rerouteCount)", symbol: "arrow.triangle.branch")
                    }
                    if let delay = trip.delaySeconds {
                        Divider()
                        Label("Względem planu: \(delay >= 0 ? "później" : "wcześniej") o \(TripHistoryFormat.duration(abs(delay)))",
                              systemImage: "clock.arrow.circlepath")
                            .font(.subheadline).foregroundStyle(Color.naviTextSecondary)
                    }
                }

                HistoryDetailSection(title: "Przebieg trasy", symbol: "map") {
                    if trip.trace.isEmpty {
                        ContentUnavailableView("Brak śladu GPS", systemImage: "map",
                            description: Text("Ten przejazd ma zapisane statystyki, ale nie ma przebiegu do odtworzenia."))
                    } else {
                        traceMap
                        playbackControls
                    }
                }
                if !speedSamples.isEmpty {
                    HistoryDetailSection(title: "Prędkość w czasie", symbol: "waveform.path") { speedChart }
                }
                Button(action: onPlan) {
                    Label("Wyznacz trasę ponownie", systemImage: "arrow.triangle.turn.up.right.diamond")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Text("Ponowne wyznaczenie korzysta z zapisanych punktów pośrednich i aktualnych ustawień planowania. Odtwarzanie pokazuje zapis GPS; pozycje między pomiarami są interpolowane, a przerwy w sygnale pozostają lukami. Czas poza ruchem i dystans zależą od dostępności pomiarów GPS.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .environment(\.locale, TripHistoryFormat.locale)
        .background { TripHistoryBackground() }
        .navigationTitle("Szczegóły podróży")
        .task(id: playing) {
            guard playing else { return }
            var previousTick = Date()
            while !Task.isCancelled && playing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                let now = Date()
                elapsed = min(duration, elapsed + now.timeIntervalSince(previousTick) * playbackRate)
                previousTick = now
                if elapsed >= duration { playing = false }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playing = false } }
        .onDisappear { playing = false }
    }

    private var traceMap: some View {
        Map {
            ForEach(segments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(Color.accentColor, lineWidth: 4)
            }
            if let first = trip.trace.first {
                Marker("Start GPS", systemImage: "flag", coordinate: first.coordinate.cl).tint(.green)
            }
            if let last = trip.trace.last {
                Marker("Koniec GPS", systemImage: "flag.checkered", coordinate: last.coordinate.cl).tint(.orange)
            }
            if let point = currentPoint {
                Annotation("Pozycja w odtworzeniu", coordinate: point.coordinate.cl) {
                    Circle().fill(Color.accentColor).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(radius: 3)
                }
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var playbackControls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    playbackActions
                    Spacer(minLength: 8)
                    playbackTime
                }
                VStack(alignment: .leading, spacing: 10) {
                    playbackActions
                    playbackTime
                }
            }
            Slider(value: $elapsed, in: 0...duration, onEditingChanged: { editing in
                if editing { playing = false }
            })
            .accessibilityLabel("Pozycja na osi czasu podróży")
            HStack {
                Text(TripHistoryFormat.duration(elapsed))
                Spacer()
                Text(TripHistoryFormat.duration(trip.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Color.naviTextSecondary)
            Text(currentPoint?.speedKph.map { "\(Int($0.rounded())) km/h" }
                 ?? (currentPoint == nil ? "Luka w zapisie GPS" : "Prędkość niedostępna"))
                .font(.caption.monospacedDigit()).foregroundStyle(Color.naviTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var playbackActions: some View {
        HStack(spacing: 12) {
            Button(playing ? "Pauza" : "Odtwórz", systemImage: playing ? "pause.fill" : "play.fill") {
                if elapsed >= duration { elapsed = 0 }
                playing.toggle()
            }
            .buttonStyle(.bordered)
            Picker("Tempo", selection: $playbackRate) {
                Text("1×").tag(1.0)
                Text("5×").tag(5.0)
                Text("20×").tag(20.0)
                Text("100×").tag(100.0)
            }
            .pickerStyle(.menu)
        }
    }

    private var playbackTime: some View {
        Text(TripHistoryFormat.time(trip.startedAt.addingTimeInterval(elapsed)))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Color.naviTextSecondary)
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prędkość GPS · km/h").font(.caption).foregroundStyle(Color.naviTextSecondary)
            Chart {
                ForEach(speedSamples) { sample in
                    LineMark(x: .value("Czas", sample.timestamp), y: .value("km/h", sample.speed),
                             series: .value("Odcinek GPS", sample.segment))
                        .foregroundStyle(Color.accentColor)
                }
                RuleMark(x: .value("Odtwarzanie", trip.startedAt.addingTimeInterval(elapsed)))
                    .foregroundStyle(Color.secondary.opacity(0.3))
            }
            .chartXScale(domain: trip.startedAt...max(trip.endedAt, trip.startedAt.addingTimeInterval(1)))
            .frame(height: 160)
            Text("Wykres obejmuje pomiary z dostępną, wiarygodną prędkością GPS.")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
        }
    }
}

private struct HistoryDetailSection<Content: View>: View {
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
        .modifier(NavigationGlassSurface(radius: 24))
    }
}

/// Use the navigation palette and shared glass surfaces throughout the archive.
private struct TripHistoryBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let base = Color(naviHex: colorScheme == .dark
            ? NaviAstraColorPalette.navigationSurface : NaviAstraColorPalette.surfaceDay)
        base
            .overlay {
                LinearGradient(colors: [Color.accentColor.opacity(0.12), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

private struct HistorySpeedSample: Identifiable {
    let id: Int
    let timestamp: Date
    let speed: Double
    let segment: Int
}
