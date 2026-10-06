#if os(iOS)
import SwiftUI

struct OfflineAreaPickerView: View {
    let location: Coordinate?
    let destination: Destination?
    let savedPlaces: [SavedPlace]
    let route: [Coordinate]
    let onChoose: (OfflineMapBounds) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraRequest: OfflineAreaCameraRequest
    @State private var selection: OfflineMapBounds?
    @State private var isSearching = false

    init(initialBounds: OfflineMapBounds?, location: Coordinate?, destination: Destination?,
         savedPlaces: [SavedPlace], route: [Coordinate], onChoose: @escaping (OfflineMapBounds) -> Void) {
        self.location = location
        self.destination = destination
        self.savedPlaces = savedPlaces
        self.route = route
        self.onChoose = onChoose
        let fallback = OfflineMapBounds.around(Coordinate(latitude: 52.2297, longitude: 21.0122), radiusKilometers: 5)
        let nearby = (location ?? destination?.coordinate).map { OfflineMapBounds.around($0, radiusKilometers: 5) }
        let initial = initialBounds.flatMap { $0.isValid ? $0 : nil }
            ?? nearby.flatMap { $0.isValid ? $0 : nil } ?? fallback
        _cameraRequest = State(initialValue: OfflineAreaCameraRequest(bounds: initial))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Przesuwaj i przybliżaj mapę. Pobierzesz teren wewnątrz ramki. Przytrzymaj mapę, aby wskazać miejsce pinezką.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("Szukaj", systemImage: "magnifyingglass") { isSearching = true }
                        if let location {
                            Button("Moja pozycja", systemImage: "location") { focus(on: location) }
                        }
                        if let destination {
                            Button("Cel", systemImage: "flag") { focus(on: destination.coordinate) }
                        }
                        if let bounds = OfflineMapBounds.enclosing(route) {
                            Button("Trasa", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                                focus(on: bounds)
                            }
                        }
                        if !savedPlaces.isEmpty {
                            Menu {
                                ForEach(savedPlaces) { place in
                                    Button(place.displayName) { focus(on: place.destination.coordinate) }
                                }
                            } label: { Label("Zapisane miejsca", systemImage: "star") }
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }
                ZStack {
                    OfflineAreaMap(cameraRequest: cameraRequest, route: route) { selection = $0 }
                    OfflineAreaSelectionMask()
                }
                .frame(minHeight: 180)
                .layoutPriority(1)
                VStack(spacing: 8) {
                    if let selection {
                        Text(selection.dimensions).font(.headline)
                        Text("Około \(selection.approximateAreaSquareKilometers.formatted(.number.precision(.fractionLength(0)))) km²")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Dopasuj ramkę do obszaru między 85°S a 85°N, bez przekraczania południka 180°.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        guard let selection else { return }
                        onChoose(selection)
                        dismiss()
                    } label: {
                        Text("Użyj tego obszaru").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil)
                }.padding(.horizontal).padding(.bottom, 8)
            }
            .navigationTitle("Obszar do pobrania")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } } }
            .sheet(isPresented: $isSearching) {
                OfflineAreaSearchView(bounds: selection) { focus(on: $0.coordinate) }
            }
        }
    }

    private func focus(on coordinate: Coordinate) {
        focus(on: OfflineMapBounds.around(coordinate, radiusKilometers: 5))
    }

    private func focus(on bounds: OfflineMapBounds) {
        guard bounds.isValid else { return }
        selection = nil
        cameraRequest = OfflineAreaCameraRequest(bounds: bounds)
    }
}
#endif
