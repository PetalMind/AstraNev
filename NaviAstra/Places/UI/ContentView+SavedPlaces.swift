import SwiftUI

extension ContentView {
    var favoritesSheet: some View {
        NavigationStack {
            List {
                if localData.places.isEmpty {
                    ContentUnavailableView("Brak zapisanych miejsc",
                                           systemImage: "heart",
                                           description: Text("Dodaj Dom, Pracę albo ulubiony adres z wyszukiwarki."))
                }

                let quickPlaces = [PlaceKind.home, .work].compactMap { kind in
                    localData.places.first(where: { $0.kind == kind })
                }
                if !quickPlaces.isEmpty {
                    Section("Szybkie miejsca") {
                        ForEach(quickPlaces) { place in
                            favoritePlaceRow(place)
                        }
                    }
                }

                let pinnedFavorites = localData.places.filter { $0.kind == .favorite && $0.isPinned }
                if !pinnedFavorites.isEmpty {
                    Section("Przypięte ulubione") {
                        ForEach(pinnedFavorites) { place in
                            favoritePlaceRow(place)
                        }
                    }
                }

                let otherFavorites = localData.places.filter { $0.kind == .favorite && !$0.isPinned }
                if !otherFavorites.isEmpty {
                    Section("Pozostałe ulubione") {
                        ForEach(otherFavorites) { place in
                            favoritePlaceRow(place)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Ulubione miejsca")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { appRouter.dismiss(.favorites) }
                }
            }
            .sheet(item: $editingSavedPlace) { place in
                SavedPlaceEditorSheet(place: place) { name, icon, isPinned in
                    localData.updatePlace(place.id, customName: name, icon: icon, isPinned: isPinned)
                } onRemove: {
                    localData.removePlace(place.id)
                }
            }
            .confirmationDialog("Usunąć to miejsce z Ulubionych?",
                                isPresented: $showPlaceRemovalConfirmation,
                                titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    if let placePendingRemoval { localData.removePlace(placePendingRemoval.id) }
                    placePendingRemoval = nil
                }
                Button("Anuluj", role: .cancel) { placePendingRemoval = nil }
            } message: {
                Text(placePendingRemoval?.displayName ?? "")
            }
        }
    }

    private func favoritePlaceRow(_ place: SavedPlace) -> some View {
        HStack(spacing: 12) {
            Button {
                appRouter.dismiss(.favorites)
                selectDestination(place.navigationDestination, recordSearch: false)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: place.icon.symbol)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.displayName).foregroundStyle(.primary)
                        Text(place.sourceContactIdentifier != nil
                             ? "Z Kontaktów · \(place.destination.address ?? place.kind.title)"
                             : (place.destination.address ?? place.kind.title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let estimate = quickETAEstimates[place.id.uuidString] {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(estimate.minutes) min")
                            Text(distance(estimate.distanceMeters))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingSavedPlace = place
            } label: {
                Image(systemName: "pencil")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edytuj nazwę miejsca \(place.displayName)")

            Menu {
                if place.kind == .favorite {
                    Button(place.isPinned ? "Odepnij od wyszukiwarki" : "Przypnij pod wyszukiwarką",
                           systemImage: place.isPinned ? "pin.slash" : "pin") {
                        localData.updatePlace(place.id, customName: place.customName,
                                              isPinned: !place.isPinned)
                    }
                }
                Button("Usuń", systemImage: "trash", role: .destructive) {
                    placePendingRemoval = place
                    showPlaceRemovalConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Opcje miejsca \(place.displayName)")
        }
    }

    var historySheet: some View {
        NavigationStack {
            List {
                if localData.trips.isEmpty && localData.searches.isEmpty {
                    ContentUnavailableView("Brak zakończonych podróży",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Wyszukane miejsca i zakończone podróże pojawią się tutaj."))
                }

                if !localData.searches.isEmpty {
                    Section("Ostatnie wyszukiwania") {
                        ForEach(localData.searches) { item in
                            HStack(spacing: 10) {
                                Button {
                                    appRouter.dismiss(.history)
                                    Task { await engine.previewNewTrip(item.destination) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.destination.name).foregroundStyle(.primary)
                                        Text(item.searchedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button("Zapisz do ulubionych", systemImage: "heart") {
                                    localData.add(item.destination)
                                }
                                .labelStyle(.iconOnly)
                                Button("Usuń wyszukiwanie", systemImage: "trash", role: .destructive) {
                                    localData.removeSearch(item.id)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                }

                if !localData.trips.isEmpty {
                    Section("Przebyte trasy") {
                        ForEach(localData.trips) { trip in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(trip.destination.name).font(.headline)
                                    Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.secondary)
                                    Text("\(distance(trip.distanceMeters)) · \(time(trip.duration)) · średnio \(Int(trip.averageSpeedKph.rounded())) km/h")
                                        .font(.caption)
                                    Text("\(trip.arrived ? "Dojechano" : "Przerwano") · postoje \(timeAllowingZero(trip.stoppedSeconds)) · przeliczenia \(trip.rerouteCount)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button("Wyznacz tę trasę ponownie", systemImage: "arrow.triangle.turn.up.right.diamond") {
                                    replayTrip(trip)
                                }
                                .labelStyle(.iconOnly)
                                Button("Zapisz cel do ulubionych", systemImage: "heart") {
                                    localData.add(trip.destination)
                                }
                                .labelStyle(.iconOnly)
                                Button("Usuń podróż", systemImage: "trash", role: .destructive) {
                                    localData.removeTrip(trip.id)
                                }
                                .labelStyle(.iconOnly)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Historia podróży")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { appRouter.dismiss(.history) }
                }
            }
        }
    }

}
