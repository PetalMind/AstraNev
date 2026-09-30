import SwiftUI

extension ContentView {
    var favoritesSheet: some View {
        NavigationStack {
            List {
                if placeStore.places.isEmpty {
                    VStack(spacing: 14) {
                        ContentUnavailableView("Brak zapisanych miejsc",
                                               systemImage: "heart",
                                               description: Text("Dodaj Dom, Pracę albo ulubiony adres z wyszukiwarki."))
                        Button("Wyszukaj miejsce", systemImage: "magnifyingglass",
                               action: beginFavoriteSearch)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 230)
                    .listRowSeparator(.hidden)
                }

                let quickPlaces = [PlaceKind.home, .work].compactMap { kind in
                    placeStore.places.first(where: { $0.kind == kind })
                }
                if !quickPlaces.isEmpty {
                    Section("Szybkie miejsca") {
                        ForEach(quickPlaces) { place in
                            favoritePlaceRow(place)
                        }
                    }
                }

                let pinnedFavorites = placeStore.places.filter { $0.kind == .favorite && $0.isPinned }
                if !pinnedFavorites.isEmpty {
                    Section("Przypięte ulubione") {
                        ForEach(pinnedFavorites) { place in
                            favoritePlaceRow(place)
                        }
                    }
                }

                let otherFavorites = placeStore.places.filter { $0.kind == .favorite && !$0.isPinned }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { appRouter.dismiss(.favorites) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Dodaj", systemImage: "plus", action: beginFavoriteSearch)
                }
            }
            .task { await refreshQuickDestinationETAs() }
            .sheet(item: $editingSavedPlace) { place in
                SavedPlaceEditorSheet(place: place) { name, icon, isPinned in
                    placeStore.updatePlace(place.id, customName: name, icon: icon, isPinned: isPinned)
                } onRemove: {
                    placeStore.removePlace(place.id)
                }
            }
            .confirmationDialog("Usunąć to miejsce z Ulubionych?",
                                isPresented: $showPlaceRemovalConfirmation,
                                titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    if let placePendingRemoval { placeStore.removePlace(placePendingRemoval.id) }
                    placePendingRemoval = nil
                }
                Button("Anuluj", role: .cancel) { placePendingRemoval = nil }
            } message: {
                Text(placePendingRemoval?.displayName ?? "")
            }
        }
    }

    func beginFavoriteSearch() {
        guard appRouter.sheet == .favorites else {
            appRouter.present(.search)
            return
        }
        openSearchAfterFavoritesDismiss = true
        appRouter.dismiss(.favorites)
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
                        Text(place.displayName).foregroundStyle(Color.naviTextPrimary)
                        Text(place.sourceContactIdentifier != nil
                             ? "Z Kontaktów · \(place.destination.address ?? place.kind.title)"
                             : (place.destination.address ?? place.kind.title))
                            .font(.caption)
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(quickETAEstimates[place.id.uuidString].map { "\($0.minutes) min" } ?? "— min")
                        Text(quickETAKilometers(quickETAEstimates[place.id.uuidString]?.distanceMeters))
                            .font(.caption2)
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
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
                        placeStore.updatePlace(place.id, customName: place.customName,
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
                if placeStore.trips.isEmpty && placeStore.searches.isEmpty {
                    ContentUnavailableView("Brak zakończonych podróży",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Wyszukane miejsca i zakończone podróże pojawią się tutaj."))
                }

                if !placeStore.searches.isEmpty {
                    Section("Ostatnie wyszukiwania") {
                        ForEach(placeStore.searches) { item in
                            let isSaved = isFavoriteDestination(item.destination)
                            HStack(spacing: 10) {
                                Button {
                                    appRouter.dismiss(.history)
                                    Task { await navigationStore.previewNewTrip(item.destination) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.destination.name).foregroundStyle(Color.naviTextPrimary)
                                        Text(item.searchedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button(isSaved ? "Zapisano w Ulubionych" : "Zapisz do ulubionych",
                                       systemImage: isSaved ? "checkmark" : "heart") {
                                    if !isSaved { addFavoriteWithFeedback(item.destination) }
                                }
                                .labelStyle(.iconOnly)
                                .disabled(isSaved)
                                Button("Usuń wyszukiwanie", systemImage: "trash", role: .destructive) {
                                    placeStore.removeSearch(item.id)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                }

                if !placeStore.trips.isEmpty {
                    Section("Przebyte trasy") {
                        ForEach(placeStore.trips) { trip in
                            let isSaved = isFavoriteDestination(trip.destination)
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(trip.destination.name).font(.headline)
                                    Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(Color.naviTextSecondary)
                                    Text("\(distance(trip.distanceMeters)) · \(time(trip.duration)) · średnio \(Int(trip.averageSpeedKph.rounded())) km/h")
                                        .font(.caption)
                                    if let score = trip.drivingScore {
                                        Text("Driving Score \(score.score)/100 · \(score.headline)")
                                            .font(.caption.weight(.semibold))
                                    }
                                    Text("\(trip.arrived ? "Dojechano" : "Przerwano") · postoje \(timeAllowingZero(trip.stoppedSeconds)) · przeliczenia \(trip.rerouteCount)")
                                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                                }
                                Spacer(minLength: 4)
                                Button("Wyznacz tę trasę ponownie", systemImage: "arrow.triangle.turn.up.right.diamond") {
                                    replayTrip(trip)
                                }
                                .labelStyle(.iconOnly)
                                Button(isSaved ? "Zapisano w Ulubionych" : "Zapisz cel do ulubionych",
                                       systemImage: isSaved ? "checkmark" : "heart") {
                                    if !isSaved { addFavoriteWithFeedback(trip.destination) }
                                }
                                .labelStyle(.iconOnly)
                                .disabled(isSaved)
                                Button("Usuń podróż", systemImage: "trash", role: .destructive) {
                                    placeStore.removeTrip(trip.id)
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
        .overlay(alignment: .top) {
            FavoriteFeedbackOverlay(feedback: $favoriteFeedback)
                .padding(.top, 48)
        }
    }

}
