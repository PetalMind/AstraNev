import SwiftUI
import MapKit

struct ValhallaToolsView: View {
    let endpoint: URL?
    let origin: Coordinate?
    let navigation: NavigationStore
    let trips: [TripRecord]
    @State private var selectedPoint: Coordinate?
    @State private var height: Double?
    @State private var heightLoaded = false
    @State private var status: ValhallaServerStatus?
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?

    private var point: Coordinate? { selectedPoint ?? origin }

    var body: some View {
        Form {
            Section("Punkt na mapie") {
                ValhallaPointMap(origin: point) { selectedPoint = $0; height = nil; heightLoaded = false }
                    .frame(height: 240)
                if let point {
                    Text("\(point.latitude.formatted(.number.precision(.fractionLength(5)))), \(point.longitude.formatted(.number.precision(.fractionLength(5))))")
                        .font(.caption.monospacedDigit())
                    Button("Pobierz wysokość punktu", systemImage: "mountain.2") { loadHeight(point) }
                        .disabled(busy)
                } else { Text("Wskaż punkt na mapie lub poczekaj na lokalizację GPS.").font(.caption) }
                if heightLoaded {
                    Text(height.map { "Wysokość terenu: \(Int($0.rounded())) m n.p.m." } ?? "Brak danych wysokości dla tego punktu.")
                }
            }
            if let endpoint {
                Section("Analiza i planowanie") {
                    NavigationLink("Zasięg czasu lub odległości") {
                        ValhallaReachabilityView(endpoint: endpoint, origin: point, navigation: navigation)
                    }
                    NavigationLink("Obszary omijane") {
                        ValhallaAvoidAreasView(navigation: navigation, origin: point)
                    }
                    NavigationLink("Dopasuj ślad GPS lub GPX do dróg") {
                        ValhallaTraceView(endpoint: endpoint, preferences: navigation.state.routingPreferences, trips: trips)
                    }
                    NavigationLink("Profile i preferencje tras") { ValhallaPreferencesView(navigation: navigation) }
                }
            }
            Section("Możliwości serwera") {
                Button("Sprawdź serwer", systemImage: "network") { loadStatus() }.disabled(busy || endpoint == nil)
                if let status {
                    LabeledContent("Wersja", value: status.version ?? "Brak danych")
                    if let date = status.modifiedAt { LabeledContent("Aktualizacja plików routingu", value: TripHistoryFormat.date(date)) }
                    LabeledContent("Dane ruchu na żywo", value: availability(status.liveTraffic))
                    LabeledContent("Strefy czasowe", value: availability(status.timeZones))
                    LabeledContent("Dane dróg", value: availability(status.hasTiles))
                    if let changeset = status.changeset { LabeledContent("Zbiór danych OSM", value: changeset) }
                    if let actions = status.actions { Text("Dostępne usługi: " + actions.joined(separator: ", ")).font(.caption) }
                    Text("Brak potwierdzenia ruchu w statusie oznacza stan nieznany. Aktualizacja plików routingu nie jest datą wszystkich danych OSM. Informacje o ruchu dla odcinków pojawią się w szczegółach trasy, jeśli serwer je udostępni. Komunikacja publiczna w aplikacji nadal korzysta z Transitous.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView("Pobieranie danych…") }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle("Narzędzia tras")
        .onDisappear { task?.cancel(); busy = false }
    }

    private func availability(_ flag: Bool?) -> String { flag.map { $0 ? "Dostępne" : "Niedostępne" } ?? "Serwer nie potwierdził" }
    private func loadHeight(_ point: Coordinate) {
        guard let endpoint else { error = "Nieprawidłowy adres serwera tras."; return }
        task?.cancel(); busy = true; error = nil; heightLoaded = false
        task = Task {
            defer { busy = false }
            do {
                let samples = try await ValhallaServices(endpoint: endpoint).heights([point], resample: false)
                try Task.checkCancellation(); height = samples.first?.heightMeters; heightLoaded = true
            } catch is CancellationError { } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func loadStatus() {
        guard let endpoint else { return }
        task?.cancel(); busy = true; error = nil; status = nil
        task = Task {
            defer { busy = false }
            do { let result = try await ValhallaServices(endpoint: endpoint).status(); try Task.checkCancellation(); status = result }
            catch is CancellationError { } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct ValhallaPointMap: View {
    let origin: Coordinate?
    let onSelect: (Coordinate) -> Void
    @State private var position: MapCameraPosition = .automatic
    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let origin { Marker("Wybrany punkt", coordinate: origin.cl) }
            }
            .onTapGesture { location in
                if let value = proxy.convert(location, from: .local) {
                    onSelect(Coordinate(latitude: value.latitude, longitude: value.longitude))
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
        }
        .onAppear {
            if let origin { position = .region(MKCoordinateRegion(center: origin.cl,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))) }
        }
    }
}

extension ValhallaContour {
    var polygon: MKPolygon {
        let interiors = rings.dropFirst().map { MKPolygon(coordinates: $0.map(\.cl), count: $0.count) }
        let exterior = rings.first ?? []
        return MKPolygon(coordinates: exterior.map(\.cl), count: exterior.count, interiorPolygons: interiors)
    }
}

struct ValhallaReachabilityView: View {
    let endpoint: URL
    let origin: Coordinate?
    let navigation: NavigationStore
    @State private var mode: TransportMode = .walking
    @State private var distance = false
    @State private var limit = 20
    @State private var contours: [ValhallaContour] = []
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Zasięg od wybranego punktu") {
                Picker("Transport", selection: $mode) {
                    Text("Pieszo").tag(TransportMode.walking)
                    Text("Rower").tag(TransportMode.bicycle)
                    Text(navigation.state.routingPreferences.advanced.vehicle.title).tag(TransportMode.car)
                }
                Picker("Rodzaj zasięgu", selection: $distance) { Text("Czas").tag(false); Text("Odległość").tag(true) }
                Stepper("Zasięg: \(limit) \(distance ? "km" : "min")", value: $limit, in: 1...120)
                Button("Pokaż zasięg", systemImage: "map") { calculate() }.disabled(origin == nil || busy)
                if origin == nil { Text("Wróć i wskaż punkt na mapie.").font(.caption) }
                Text("Obszar uwzględnia profil i preferencje trasy oraz zapisane obszary omijane. Zasięg czasu jest szacowany dla wyjazdu teraz.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(busy)
            if busy { ProgressView("Obliczanie zasięgu…") }
            if let error { Text(error).foregroundStyle(.orange) }
            if !contours.isEmpty {
                Section("Obszar dostępności") {
                    Map {
                        ForEach(contours) { contour in
                            MapPolygon(contour.polygon).foregroundStyle(Color.accentColor.opacity(0.25))
                                .stroke(Color.accentColor, lineWidth: 2)
                        }
                        if let origin { Marker("Start", coordinate: origin.cl) }
                    }
                    .mapControls { MapCompass(); MapScaleView() }
                    .frame(height: 400)
                }
            }
        }
        .navigationTitle("Zasięg podróży")
        .onChange(of: mode) { _, _ in contours = []; error = nil }
        .onChange(of: distance) { _, _ in contours = []; error = nil }
        .onChange(of: limit) { _, _ in contours = []; error = nil }
        .onDisappear { task?.cancel(); busy = false }
    }
    private func calculate() {
        guard let origin else { return }
        task?.cancel(); busy = true; error = nil; contours = []
        let preferences = navigation.state.routingPreferences
        task = Task {
            defer { busy = false }
            do {
                let result = try await ValhallaServices(endpoint: endpoint).contours(at: origin, mode: mode,
                    preferences: preferences, value: limit, distance: distance)
                try Task.checkCancellation(); contours = result
            } catch is CancellationError { } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct ValhallaAvoidAreasView: View {
    let navigation: NavigationStore
    let origin: Coordinate?
    @State private var vertices: [Coordinate] = []
    @State private var name = ""
    @State private var error: String?
    @State private var position: MapCameraPosition = .automatic
    @State private var saving = false
    private var areas: [ValhallaAvoidArea] { navigation.state.routingPreferences.advanced.avoidAreas }

    var body: some View {
        Form {
            Section("Zaznacz obszar do pominięcia") {
                Text("Dotknij kolejnych narożników na mapie. Zapisz wielokąt z 3–32 punktami; jego boki nie mogą się przecinać.")
                    .font(.caption).foregroundStyle(.secondary)
                MapReader { proxy in
                    Map(position: $position) {
                        ForEach(areas) { area in
                            MapPolygon(coordinates: area.vertices.map(\.cl)).foregroundStyle(.red.opacity(0.15)).stroke(.red, lineWidth: 1)
                        }
                        if vertices.count > 2 {
                            MapPolygon(coordinates: vertices.map(\.cl)).foregroundStyle(.orange.opacity(0.25)).stroke(.orange, lineWidth: 2)
                        } else if vertices.count > 1 { MapPolyline(coordinates: vertices.map(\.cl)).stroke(.orange, lineWidth: 2) }
                        ForEach(vertices.indices, id: \.self) { index in
                            Marker("\(index + 1)", coordinate: vertices[index].cl).tint(.orange)
                        }
                    }
                    .onTapGesture { location in
                        guard !saving, vertices.count < 32, let point = proxy.convert(location, from: .local) else { return }
                        vertices.append(Coordinate(latitude: point.latitude, longitude: point.longitude)); error = nil
                    }
                }
                .frame(height: 350)
                TextField("Nazwa obszaru", text: $name)
                HStack {
                    Button("Cofnij punkt") { if !vertices.isEmpty { vertices.removeLast() } }.disabled(vertices.isEmpty)
                    Button("Wyczyść") { vertices = []; error = nil }.disabled(vertices.isEmpty)
                }
                Button("Zapisz obszar (\(vertices.count) punktów)") { save() }
                    .disabled(vertices.count < 3 || areas.count >= 8)
                if let error { Text(error).foregroundStyle(.orange) }
            }.disabled(saving)
            Section("Zapisane obszary (\(areas.count)/8)") {
                ForEach(areas) { area in
                    HStack {
                        Text(area.name)
                        Spacer()
                        Button("Usuń", role: .destructive) {
                            var preferences = navigation.state.routingPreferences
                            preferences.advanced.avoidAreas.removeAll { $0.id == area.id }
                            saving = true
                            Task { await navigation.updateRoutingPreferences(preferences); saving = false }
                        }
                    }
                }
                Text("Obszary obowiązują przy wyznaczaniu i przeliczaniu tras. Jeśli obejmą start, cel lub jedyny przejazd, serwer może nie znaleźć trasy.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(saving)
        }
        .navigationTitle("Obszary omijane")
        .onAppear {
            if let origin { position = .region(MKCoordinateRegion(center: origin.cl,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))) }
        }
    }
    private func save() {
        let area = ValhallaAvoidArea(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Obszar \(areas.count + 1)" : name, vertices: vertices)
        guard area.isValid else { error = "Obszar jest pusty lub jego boki się przecinają. Popraw zaznaczenie."; return }
        var preferences = navigation.state.routingPreferences
        preferences.advanced.avoidAreas.append(area)
        vertices = []; name = ""; error = nil; saving = true
        Task { await navigation.updateRoutingPreferences(preferences); saving = false }
    }
}
