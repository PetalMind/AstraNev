#if os(iOS)
import SwiftUI
import MapLibre

struct OfflineMapsView: View {
    let location: Coordinate?
    let destination: Destination?
    var savedPlaces: [SavedPlace] = []
    var route: [Coordinate] = []
    @State private var store = OfflineMapStore.shared
    @State private var routingStore = OfflineRoutingStore.shared
    @State private var name = ""
    @State private var useDestination = false
    @State private var radius = 5.0
    @State private var maximumZoom = 14.0
    @State private var pendingRemoval: OfflineMapRegion?
    @State private var useMapSelection = true
    @State private var selectedBounds: OfflineMapBounds?
    @State private var isSelectingArea = false

    private var center: Coordinate? { useDestination ? destination?.coordinate : location }
    private var downloadBounds: OfflineMapBounds? {
        useMapSelection ? selectedBounds : center.map { OfflineMapBounds.around($0, radiusKilometers: radius) }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    OfflineRoutingView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Dane drogowe i trasy offline", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        Text(routingStore.activePack?.name ?? "Pobierz dane potrzebne do wyznaczania tras")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Mapa i dane drogowe są osobnymi paczkami. Aby wyznaczać trasy bez internetu, pobierz również dane drogowe dla całego przebiegu trasy.")
            }
            Section {
                TextField("Nazwa obszaru", text: $name)
                Picker("Wybór obszaru", selection: $useMapSelection) {
                    Text("Na mapie").tag(true)
                    Text("Wokół miejsca").tag(false)
                }.pickerStyle(.segmented)
                if useMapSelection {
                    Button {
                        isSelectingArea = true
                    } label: {
                        Label(selectedBounds == nil ? "Wybierz obszar na mapie" : "Zmień obszar na mapie", systemImage: "viewfinder")
                    }
                    if let selectedBounds {
                        Text(selectedBounds.dimensions).font(.subheadline)
                        Text(String(format: "%.4f; %.4f — %.4f; %.4f", locale: PolishRegionalFormat.locale, selectedBounds.south,
                                    selectedBounds.west, selectedBounds.north, selectedBounds.east))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if destination != nil {
                        Picker("Środek obszaru", selection: $useDestination) {
                            Text("Moja pozycja").tag(false)
                            Text("Cel podróży").tag(true)
                        }
                    }
                    if let center {
                        Text(String(format: "%.4f; %.4f", locale: PolishRegionalFormat.locale,
                                    center.latitude, center.longitude))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Brak pozycji. Wybierz cel podróży albo poczekaj na ustalenie lokalizacji.")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Zasięg wokół miejsca", selection: $radius) {
                        ForEach([2.0, 5, 10, 20], id: \.self) { value in
                            Text("\(Int(value)) km").tag(value)
                        }
                    }
                }
                Picker("Szczegółowość", selection: $maximumZoom) {
                    Text("Podstawowa").tag(12.0)
                    Text("Ulice").tag(14.0)
                    Text("Budynki i miejsca").tag(16.0)
                }
                Button {
                    guard let bounds = downloadBounds else { return }
                    store.download(name: name, bounds: bounds, maximumZoom: maximumZoom)
                } label: {
                    if store.isCreating { ProgressView("Przygotowanie pobierania") }
                    else { Label("Pobierz mapę", systemImage: "arrow.down.circle") }
                }
                .disabled(downloadBounds?.isValid != true || store.isCreating || store.isLoading)
            } header: { Text("Nowy obszar") } footer: {
                Text("W trybie mapy pobierany jest prostokąt wewnątrz ramki, a wokół miejsca — kwadrat obejmujący wskazany zasięg. Większy obszar i większa szczegółowość wymagają więcej miejsca i transferu. Pobieranie jest wstrzymywane po przejściu aplikacji do tła. Możesz je wznowić po powrocie.")
            }
            if let error = store.error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section("Pobrane obszary") {
                if store.isLoading { ProgressView("Odczytywanie map") }
                else if store.regions.isEmpty { Text("Nie pobrano jeszcze żadnej mapy.").foregroundStyle(.secondary) }
                ForEach(store.regions) { region in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(region.name).font(.headline)
                        Text(region.status).foregroundStyle(region.error == nil ? Color.secondary : .red)
                        Text("\(region.bounds.dimensions) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: region.bytes), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                        if region.state == .active {
                            if let progress = region.progress { ProgressView(value: progress) }
                            else { ProgressView() }
                        }
                        if region.state != .complete {
                            Text(region.exactResourceCount
                                 ? "Zasoby: \(region.downloadedResources) / \(region.expectedResources)"
                                 : "Pobrane zasoby: \(region.downloadedResources)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = region.error { Text(error).font(.caption).foregroundStyle(.red) }
                        HStack {
                            if region.state == .active || region.state == .inactive {
                                Button(region.state == .active ? "Wstrzymaj" : "Wznów") { store.toggleDownload(region.id) }
                                    .buttonStyle(.bordered)
                            }
                            Spacer()
                            Button("Usuń", role: .destructive) { pendingRemoval = region }
                                .buttonStyle(.bordered)
                        }.disabled(store.deletingIDs.contains(region.id))
                    }.padding(.vertical, 5)
                }
            }
            Section {
                Text("Pobrana mapa jest używana automatycznie na zapisanym obszarze i w pobranym zakresie przybliżeń. Poza nimi mogą brakować szczegółów. Trasy drogowe można wyznaczać offline po pobraniu odpowiedniej paczki danych drogowych. Wyszukiwanie miejsc, komunikacja publiczna oraz aktualne dane ruchu i pogody wymagają internetu.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mapy offline")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isSelectingArea) {
            OfflineAreaPickerView(initialBounds: selectedBounds ?? center.map {
                OfflineMapBounds.around($0, radiusKilometers: radius)
            }, location: location, destination: destination, savedPlaces: savedPlaces, route: route) {
                selectedBounds = $0
                useMapSelection = true
            }
        }
        .onAppear {
            if location == nil, destination != nil { useDestination = true }
            store.refresh()
        }
        .alert("Usunąć pobraną mapę?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { region in
            Button("Usuń", role: .destructive) {
                store.remove(region.id)
                pendingRemoval = nil
            }
            Button("Anuluj", role: .cancel) { pendingRemoval = nil }
        } message: { region in Text(region.name) }
    }
}
#endif
