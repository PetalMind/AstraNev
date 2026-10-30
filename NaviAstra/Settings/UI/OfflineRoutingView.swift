#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct OfflineRoutingView: View {
    @Bindable private var store = OfflineRoutingStore.shared
    @State private var showImporter = false
    @State private var customURL = ""
    @State private var customName = ""
    @State private var motorVehiclesOnly = false
    @State private var pendingRemoval: OfflineRoutingPack?
    private var downloadURL: URL? {
        guard let url = URL(string: customURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    var body: some View {
        Form {
            Section {
                if let pack = store.activePack {
                    Label(pack.name, systemImage: "checkmark.circle.fill")
                    Text(pack.motorVehiclesOnly ? "Trasy dla pojazdów silnikowych" : "Profile tras zgodnie z zawartością paczki")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Brak aktywnej paczki drogowej").foregroundStyle(.secondary)
                }
                Toggle("Wyznaczaj trasy na urządzeniu", isOn: $store.preferOffline)
                    .disabled(store.activePack == nil && !store.preferOffline)
            } header: { Text("Trasowanie offline") } footer: {
                Text("Bez internetu aplikacja korzysta automatycznie z aktywnej paczki. Włącz przełącznik, aby używać jej także przy dostępnym połączeniu. Cała trasa musi mieścić się w jednej paczce, łącznie z objazdami. Dane drogowe są pobierane osobno od mapy.")
            }
            if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            if store.isInstalling {
                Section("Pobieranie lub przygotowanie danych") {
                    Text(store.transferName)
                    if let progress = store.progress { ProgressView(value: progress) }
                    else { ProgressView() }
                    if store.downloadedBytes > 0 {
                        Text(OfflineStorageFormat.bytes(store.downloadedBytes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Anuluj", role: .cancel) { store.cancelTransfer() }
                }
            }
            Section {
                NavigationLink("Pobierz dane dla regionu") { catalogView }
                Button("Importuj paczkę .tar", systemImage: "square.and.arrow.down") { showImporter = true }
                Toggle("Importowana paczka tylko dla pojazdów", isOn: $motorVehiclesOnly)
            } header: { Text("Dodaj dane drogowe") } footer: {
                Text("Importuj nieskompresowane archiwum Valhalla zgodne z silnikiem 3.6.x. Polska nie jest dostępna w obecnym publicznym katalogu; możesz użyć własnej paczki lub adresu od dostawcy.")
            }.disabled(store.isInstalling)
            Section("Pobierz z adresu") {
                TextField("Nazwa regionu", text: $customName)
                TextField("https://…/tiles.tar", text: $customURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Pobierz paczkę") {
                    guard let url = downloadURL else { return }
                    let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.download(url: url, name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                                   motorVehiclesOnly: motorVehiclesOnly)
                }.disabled(downloadURL == nil || store.isInstalling)
            }
            Section("Zapisane paczki") {
                if store.packs.isEmpty {
                    ContentUnavailableView("Brak danych drogowych", systemImage: "shippingbox",
                        description: Text("Pobierz region lub zaimportuj paczkę, aby wyznaczać trasy bez internetu."))
                }
                ForEach(store.packs) { pack in
                    OfflineRoutingPackRow(pack: pack, isActive: store.activeID == pack.id,
                        isRemoving: store.removingIDs.contains(pack.id),
                        onActivate: { store.activeID = pack.id }, onRemove: { pendingRemoval = pack })
                }
            }

            Section("Źródła danych i licencje") {
                Link("Valhalla Mobile · silnik i licencja", destination: URL(string: "https://github.com/Rallista/valhalla-mobile")!)
                Link("Librescoot · katalog paczek i zasady danych", destination: URL(string: "https://github.com/librescoot/valhalla-tiles")!)
                Link("© Autorzy OpenStreetMap · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.locale, PolishRegionalFormat.locale)
        .navigationTitle("Dane drogowe offline")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.archive, .data]) { result in
            switch result {
            case .success(let url): store.importArchive(url, motorVehiclesOnly: motorVehiclesOnly)
            case .failure(let error):
                Logger(subsystem: "NaviAstra", category: "OfflineImport")
                    .error("Nie udało się wybrać pliku: \(error.localizedDescription, privacy: .private)")
                store.error = "Nie udało się otworzyć wybranej paczki. Sprawdź dostęp do pliku i spróbuj ponownie."
            }
        }
        .alert("Usunąć dane drogowe?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { pack in
            Button("Usuń", role: .destructive) { store.remove(pack); pendingRemoval = nil }
            Button("Anuluj", role: .cancel) { pendingRemoval = nil }
        } message: { pack in Text(pack.name) }
    }

    private var catalogView: some View {
        List {
            Section {
                Text("Paczki dla pojazdów silnikowych z publicznego katalogu Librescoot. Nie obsługują tras pieszych i rowerowych. Dostępność ogranicza się do wymienionych regionów; nie zawierają mapy do wyświetlania.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.isLoadingCatalog { ProgressView("Odczytywanie katalogu") }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                if !store.isLoadingCatalog && store.catalog.isEmpty {
                    Button("Wczytaj katalog ponownie") { Task { await store.loadCatalog() } }
                }
                ForEach(store.catalog) { download in
                    Button {
                        store.download(url: download.browserDownloadURL, name: download.title,
                            motorVehiclesOnly: true, expectedSHA256: download.sha256)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(download.title)
                            Text(OfflineStorageFormat.bytes(download.size))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(store.isInstalling)
                }
            }
            if store.isInstalling {
                Section {
                    Text("Pobieranie: \(store.transferName)")
                    if let progress = store.progress { ProgressView(value: progress) } else { ProgressView() }
                    Button("Anuluj", role: .cancel) { store.cancelTransfer() }
                }
            }
        }
        .navigationTitle("Paczki drogowe")
        .task { await store.loadCatalog() }
    }
}
#endif
