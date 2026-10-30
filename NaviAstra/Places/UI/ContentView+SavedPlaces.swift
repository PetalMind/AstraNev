import SwiftUI

extension ContentView {
    var favoritesSheet: some View {
        NavigationStack {
            SavedPlacesListView(
                places: placeStore.places,
                estimates: quickETAEstimates,
                isCalculating: quickETAInFlight,
                onSelect: { place in
                    appRouter.dismiss(.favorites)
                    selectDestination(place.navigationDestination, recordSearch: false)
                },
                onEdit: { editingSavedPlace = $0 },
                onTogglePin: { place in
                    placeStore.updatePlace(place.id, customName: place.customName,
                                           isPinned: !place.isPinned)
                },
                onRemove: { place in
                    placePendingRemoval = place
                    showPlaceRemovalConfirmation = true
                },
                onSearch: beginFavoriteSearch)
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

    var historySheet: some View {
        RouteHistoryView(store: placeStore, onPlanTrip: replayTrip, onSearch: { destination in
            appRouter.dismiss(.history)
            Task { await navigationStore.previewNewTrip(destination) }
        }, onFavorite: { destination in
            addFavoriteWithFeedback(destination)
        }, onClose: {
            appRouter.dismiss(.history)
        }, energyStore: energyStore)
        .overlay(alignment: .top) {
            FavoriteFeedbackOverlay(feedback: $favoriteFeedback)
                .padding(.top, 48)
        }
    }

}
