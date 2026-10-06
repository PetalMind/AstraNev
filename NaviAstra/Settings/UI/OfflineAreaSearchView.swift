#if os(iOS)
import MapKit
import SwiftUI

struct OfflineAreaSearchView: View {
    let bounds: OfflineMapBounds?
    let onSelect: (Destination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searched = false
    @State private var isSearching = false
    @State private var error: String?
    @State private var search: MKLocalSearch?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Miasto, adres lub miejsce", text: $query)
                            .submitLabel(.search).onSubmit { performSearch() }
                        Button("Szukaj", systemImage: "magnifyingglass") { performSearch() }
                            .labelStyle(.iconOnly)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: { Text("Wyszukiwanie miejsc wymaga internetu.") }
                if isSearching { ProgressView("Wyszukiwanie") }
                if let error { Text(error).foregroundStyle(.red) }
                if searched && !isSearching && results.isEmpty && error == nil {
                    Text("Nie znaleziono miejsc. Dopisz miejscowość lub zmień zapytanie.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                    Button {
                        let coordinate = item.location.coordinate
                        onSelect(Destination(name: item.name ?? query,
                            coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? query).foregroundStyle(.primary)
                            if let address = item.address?.fullAddress {
                                Text(address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Znajdź obszar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Zamknij") { dismiss() } } }
        }
        .onChange(of: query) { _, _ in
            cancelSearch()
            results = []
            error = nil
            searched = false
        }
        .onDisappear { cancelSearch() }
    }

    private func cancelSearch() {
        generation = UUID()
        task?.cancel()
        search?.cancel()
        task = nil
        search = nil
        isSearching = false
    }

    private func performSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancelSearch()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let bounds, bounds.isValid {
            request.region = MKCoordinateRegion(center: bounds.center.cl,
                span: MKCoordinateSpan(latitudeDelta: bounds.north - bounds.south, longitudeDelta: bounds.east - bounds.west))
        }
        let operation = MKLocalSearch(request: request)
        search = operation
        let requestGeneration = generation
        isSearching = true
        error = nil
        results = []
        task = Task { @MainActor in
            do {
                let response = try await operation.start()
                guard !Task.isCancelled, generation == requestGeneration else { return }
                results = response.mapItems
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                self.error = SearchError.classify(error).localizedDescription
            }
            searched = true
            isSearching = false
            search = nil
            task = nil
        }
    }
}
#endif
