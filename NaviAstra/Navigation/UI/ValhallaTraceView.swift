import SwiftUI
import MapKit
import Charts
import UniformTypeIdentifiers

struct ValhallaTraceView: View {
    let endpoint: URL
    let preferences: RoutingPreferences
    var trips: [TripRecord] = []
    var initialTrace: [[Coordinate]] = []
    var initialMode: TransportMode = .car
    @State private var segments: [[Coordinate]] = []
    @State private var mode: TransportMode = .car
    @State private var routes: [NavigationRoute] = []
    @State private var elevations: [RouteElevationSample] = []
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var busy = false
    @State private var error: String?
    @State private var sourceName = ""
    @State private var task: Task<Void, Never>?

    private var pointCount: Int { segments.reduce(0) { $0 + $1.count } }
    private var elevationChartPoints: [TraceHeightPoint] {
        var part = 0
        return elevations.enumerated().compactMap { index, sample in
            guard let height = sample.heightMeters else { part += 1; return nil }
            return TraceHeightPoint(id: index, distance: sample.distanceMeters, height: height, part: part)
        }
    }
    private var traceTrips: [TripRecord] { trips.filter { !$0.trace.isEmpty && $0.transportMode != .transit && $0.transportMode != .parkRide } }

    var body: some View {
        Form {
            Section("Ślad do analizy") {
                Button("Importuj GPX", systemImage: "square.and.arrow.down") { showsImporter = true }
                if !traceTrips.isEmpty {
                    Menu("Wybierz przejazd z historii") {
                        ForEach(traceTrips) { trip in
                            Button("\(trip.destination.name) · \(TripHistoryFormat.date(trip.startedAt))") {
                                use(trip.valhallaTraceSegments, name: trip.destination.name)
                                mode = trip.transportMode ?? .car
                            }
                        }
                    }
                }
                Picker("Profil dopasowania", selection: $mode) {
                    Text(preferences.advanced.vehicle.title).tag(TransportMode.car)
                    Text("Pieszo").tag(TransportMode.walking)
                    Text("Rower").tag(TransportMode.bicycle)
                }
                if !segments.isEmpty {
                    Text("\(sourceName) · \(pointCount) punktów · \(segments.count) części")
                        .font(.caption)
                    if segments.contains(where: { $0.count > 1_000 }) {
                        Text("Długie części są próbkowane do 1000 punktów dla serwera. Oryginalny zapis pozostaje zachowany.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Dopasuj do dróg i pobierz instrukcje", systemImage: "point.topleft.down.curvedto.point.bottomright.up") { match() }
                    Button("Pobierz profil wysokości śladu", systemImage: "mountain.2") { loadHeights() }
                }
                Text("Po wybraniu analizy punkty śladu są wysyłane do wybranego serwera tras. Dopasowanie jest interpretacją punktów przez jego sieć dróg. Nie zastępuje pomiaru GPS. Analiza śladu nie stosuje obszarów omijanych ani przyszłej godziny podróży.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(busy)
            if busy { ProgressView("Analiza śladu…") }
            if let error { Text(error).foregroundStyle(.orange) }
            if !segments.isEmpty {
                Section("Przebieg śladu") { traceMap }
            }
            if !routes.isEmpty {
                Section("Dopasowane odcinki") {
                    Button("Eksportuj dopasowany GPX", systemImage: "square.and.arrow.up") { showsExporter = true }
                    ForEach(routes) { route in
                        DisclosureGroup("\(TripHistoryFormat.distance(route.distance)) · szacowany czas \(TripHistoryFormat.duration(route.expectedTravelTime))") {
                            ForEach(Array(route.maneuvers.enumerated()), id: \.offset) { _, maneuver in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(maneuver.instruction)
                                    ManeuverInformationView(maneuver: maneuver)
                                }
                            }
                            RouteInformationView(route: route)
                        }
                    }
                }
            }
            if !elevations.isEmpty {
                Section("Profil wysokości terenu") {
                    if elevationChartPoints.count > 1 {
                        Chart(elevationChartPoints) { point in
                            LineMark(x: .value("Dystans (km)", point.distance / 1000),
                                     y: .value("Wysokość (m)", point.height), series: .value("Część", point.part))
                        }.chartYAxisLabel("m n.p.m.").chartXAxisLabel("km").frame(height: 200)
                    } else { Text("Serwer nie udostępnił wystarczającej liczby próbek wysokości.") }
                    Text("Profil dotyczy terenu. Luki w śladzie lub danych wysokości nie są łączone; mosty i tunele mogą mieć inny przebieg wysokości.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Analiza śladu GPS")
        .onAppear { if segments.isEmpty && !initialTrace.isEmpty {
            use(initialTrace, name: "Zapisany ślad")
            mode = initialMode == .transit || initialMode == .parkRide ? .car : initialMode
        } }
        .onChange(of: mode) { _, _ in routes = []; error = nil }
        .onDisappear { task?.cancel(); busy = false }
        .fileImporter(isPresented: $showsImporter,
            allowedContentTypes: [.naviastraGPX, .xml], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 10_000_000 else { throw ValhallaFeatureError.message("Plik GPX może mieć maksymalnie 10 MB.") }
                let imported = try GPXTraceParser.read(Data(contentsOf: url))
                use(imported, name: url.lastPathComponent)
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $showsExporter, document: MatchedTraceDocument(routes: routes),
            contentType: .naviastraGPX, defaultFilename: "NaviAstra-dopasowany-slad") { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
    }

    private var traceMap: some View {
        Map {
            ForEach(segments.indices, id: \.self) { index in
                MapPolyline(coordinates: segments[index].map(\.cl)).stroke(.gray.opacity(0.6), lineWidth: 3)
            }
            ForEach(routes) { route in
                MapPolyline(coordinates: route.coordinates.map(\.cl)).stroke(Color.accentColor, lineWidth: 4)
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .frame(height: 350)
        .overlay(alignment: .bottomLeading) {
            Text("Szary: GPS · Kolor: dopasowane drogi")
                .font(.caption2).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
        }
    }

    private func use(_ value: [[Coordinate]], name: String) {
        task?.cancel(); segments = value.filter { $0.count > 1 }; sourceName = name
        routes = []; elevations = []; error = nil
    }
    private func match() {
        task?.cancel(); busy = true; error = nil; routes = []
        let input = segments, selectedMode = mode
        task = Task {
            defer { busy = false }
            do {
                let result = try await ValhallaServices(endpoint: endpoint).matchTrace(input, mode: selectedMode, preferences: preferences)
                try Task.checkCancellation(); routes = result
            } catch is CancellationError { } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func loadHeights() {
        task?.cancel(); busy = true; error = nil; elevations = []
        let input = segments
        task = Task {
            defer { busy = false }
            do {
                var result: [RouteElevationSample] = []
                var offset = 0.0
                for segment in input {
                    let samples = try await ValhallaServices(endpoint: endpoint).heights(ValhallaServices.sample(segment, limit: 1_000))
                    try Task.checkCancellation()
                    if !result.isEmpty {
                        // A one millimetre offset keeps chart IDs unique at the break boundary.
                        result.append(RouteElevationSample(distanceMeters: offset + 0.001, heightMeters: nil))
                        offset += 0.002
                    }
                    result += samples.map { RouteElevationSample(distanceMeters: offset + $0.distanceMeters, heightMeters: $0.heightMeters) }
                    offset += samples.last?.distanceMeters ?? 0
                }
                elevations = result
            } catch is CancellationError { } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private struct TraceHeightPoint: Identifiable {
        var id: Int
        var distance: Double
        var height: Double
        var part: Int
    }
}

extension TripRecord {
    var valhallaTraceSegments: [[Coordinate]] {
        var parts: [[Coordinate]] = []
        for point in trace {
            if point.startsSegment || parts.isEmpty { parts.append([]) }
            parts[parts.count - 1].append(point.coordinate)
        }
        return parts.filter { $0.count > 1 }
    }
}
