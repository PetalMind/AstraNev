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
    @State private var period: HistoryPeriod = .all
    @State private var mode: TransportMode?
    @State private var tab = 0

    private var trips: [TripRecord] {
        let cutoff = period.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        return store.trips.filter { trip in
            (cutoff.map { trip.startedAt >= $0 } ?? true) && (mode == nil || trip.transportMode == mode)
        }
    }

    private func isSaved(_ destination: Destination) -> Bool {
        store.places.contains { $0.destination.coordinate == destination.coordinate }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Widok historii", selection: $tab) {
                    Text("Trasy").tag(0)
                    Text("Heatmapa").tag(1)
                    Text("Wyszukiwania").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                if tab != 2 {
                    HStack {
                        Picker("Okres", selection: $period) {
                            ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Transport", selection: $mode) {
                            Text("Każdy transport").tag(nil as TransportMode?)
                            ForEach(TransportMode.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                if tab == 0 {
                    tripsList
                } else if tab == 1 {
                    TripHeatmapView(trips: trips)
                } else {
                    searchesList
                }
            }
            .navigationTitle("Historia podróży")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij", action: onClose)
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
    }

    private var tripsList: some View {
        List {
            if trips.isEmpty {
                ContentUnavailableView("Brak podróży", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text("Zakończone i przerwane nawigacje pojawią się tutaj. Możesz też zmienić filtry."))
            } else {
                Section("Statystyki wybranego okresu") {
                    HistoryStatistics(trips: trips)
                }
                Section("Przebyte trasy") {
                    ForEach(trips) { trip in
                        NavigationLink {
                            TripHistoryDetail(trip: trip, onPlan: { onPlanTrip(trip) })
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Image(systemName: trip.transportMode?.symbol ?? "point.topleft.down.to.point.bottomright.curvepath")
                                        .foregroundStyle(Color.accentColor)
                                    Text(trip.destination.name).font(.headline)
                                }
                                Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                                Text("\(TripHistoryFormat.distance(trip.distanceMeters)) · \(TripHistoryFormat.duration(trip.duration))")
                                    .font(.subheadline.monospacedDigit())
                                Text("\(trip.arrived ? "Dojechano" : "Przerwano") · \(trip.trace.isEmpty ? "Brak śladu GPS" : "Zapisany przebieg GPS")")
                                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                                if let score = trip.drivingScore { DrivingScoreHistoryLabel(score: score) }
                            }
                            .padding(.vertical, 5)
                        }
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
                }
                Section {
                    Text("Dane i ślady GPS są zapisywane lokalnie na urządzeniu podczas aktywnej nawigacji. Starsze wpisy mogą nie mieć śladu GPS ani rodzaju transportu.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .listStyle(.plain)
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
                            Text(item.searchedAt.formatted(date: .abbreviated, time: .shortened))
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
    }
}

private struct HistoryStatistics: View {
    let trips: [TripRecord]
    private var distance: Double { trips.reduce(0) { $0 + $1.distanceMeters } }
    private var moving: Double { trips.reduce(0) { $0 + $1.movingSeconds } }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 18) {
            HistoryMetric(title: "Podróże", value: "\(trips.count)", symbol: "map")
            HistoryMetric(title: "Dystans", value: TripHistoryFormat.distance(distance), symbol: "point.topleft.down.to.point.bottomright.curvepath")
            HistoryMetric(title: "Czas podróży", value: TripHistoryFormat.duration(trips.reduce(0) { $0 + $1.duration }), symbol: "clock")
            HistoryMetric(title: "Czas w ruchu", value: TripHistoryFormat.duration(moving), symbol: "figure.walk")
            HistoryMetric(title: "Średnia w ruchu", value: moving > 0 ? "\(Int((distance / moving * 3.6).rounded())) km/h" : "Brak danych", symbol: "speedometer")
            HistoryMetric(title: "Dotarcie do celu", value: "\(trips.filter(\.arrived).count) z \(trips.count)", symbol: "flag.checkered")
        }
        .padding(.vertical, 8)
    }
}

private struct HistoryMetric: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(Color.naviTextSecondary)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(Color.naviTextPrimary)
        }
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
                ContentUnavailableView("Brak danych do heatmapy", systemImage: "map",
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
                    Text("\(maximumVisits) \(maximumVisits == 1 ? "podróż" : "podróży")")
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
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(trip.destination.name).font(.title2.bold())
                    Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("\(trip.transportMode?.title ?? "Rodzaj transportu nie zapisany") · \(trip.arrived ? "Dotarto do celu" : "Przerwano podróż")")
                }
                .font(.subheadline)

                if trip.trace.isEmpty {
                    ContentUnavailableView("Brak śladu GPS", systemImage: "map",
                        description: Text("Ta podróż ma zapisane statystyki, ale nie ma przebiegu do odtworzenia. Ślady będą zapisywane w nowych nawigacjach."))
                } else {
                    traceMap
                    playbackControls
                }

                HistoryStatistics(trips: [trip])
                HStack(alignment: .top, spacing: 24) {
                    HistoryMetric(title: "Postoje", value: TripHistoryFormat.duration(trip.stoppedSeconds), symbol: "pause.circle")
                    HistoryMetric(title: "Maks. prędkość", value: trip.maximumSpeedKph.map { "\(Int($0.rounded())) km/h" } ?? "Brak danych", symbol: "speedometer")
                    HistoryMetric(title: "Przeliczenia", value: "\(trip.rerouteCount)", symbol: "arrow.triangle.branch")
                }
                if let delay = trip.delaySeconds {
                    Text("Względem planu: \(delay >= 0 ? "później" : "wcześniej") o \(TripHistoryFormat.duration(abs(delay)))")
                        .font(.subheadline)
                }
                if !speedSamples.isEmpty { speedChart }
                if trip.transportMode == .car || trip.drivingScore != nil {
                    NavigationLink { DrivingScoreReport(trip: trip) } label: {
                        Label("Ocena prowadzenia", systemImage: "steeringwheel")
                    }
                }
                Button("Wyznacz trasę do tego celu ponownie", systemImage: "arrow.triangle.turn.up.right.diamond", action: onPlan)
                    .buttonStyle(.borderedProminent)
                Text("Ponowne wyznaczenie korzysta z zapisanych punktów pośrednich i aktualnych ustawień planowania. Odtwarzanie powyżej pokazuje zapis GPS; pozycje między pomiarami są interpolowane, a przerwy w sygnale pozostają lukami. Czas poza ruchem i dystans zależą od dostępności pomiarów GPS.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
            HStack {
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
                Spacer()
                Text(trip.startedAt.addingTimeInterval(elapsed), style: .time)
                    .font(.subheadline.monospacedDigit())
            }
            Slider(value: $elapsed, in: 0...duration, onEditingChanged: { editing in
                if editing { playing = false }
            })
            .accessibilityLabel("Pozycja na osi czasu podróży")
            HStack {
                Text(TripHistoryFormat.duration(elapsed))
                Spacer()
                Text(currentPoint?.speedKph.map { "\(Int($0.rounded())) km/h" }
                     ?? (currentPoint == nil ? "Luka w zapisie GPS" : "Prędkość niedostępna"))
                Spacer()
                Text(TripHistoryFormat.duration(trip.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Color.naviTextSecondary)
        }
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prędkość w czasie · km/h").font(.headline)
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

private struct HistorySpeedSample: Identifiable {
    let id: Int
    let timestamp: Date
    let speed: Double
    let segment: Int
}
