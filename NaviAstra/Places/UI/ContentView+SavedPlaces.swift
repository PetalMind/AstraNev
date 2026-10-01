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
                        Text(quickETAEstimates[place.id.uuidString].map { TravelDurationFormatter.string(minutes: $0.minutes) } ?? "— min")
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
        RouteHistoryView(store: placeStore, onPlanTrip: replayTrip, onSearch: { destination in
            appRouter.dismiss(.history)
            Task { await navigationStore.previewNewTrip(destination) }
        }, onFavorite: { destination in
            addFavoriteWithFeedback(destination)
        }, onClose: {
            appRouter.dismiss(.history)
        })
        .overlay(alignment: .top) {
            FavoriteFeedbackOverlay(feedback: $favoriteFeedback)
                .padding(.top, 48)
        }
    }

}
