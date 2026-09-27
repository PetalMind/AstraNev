import SwiftUI

extension ContentView {
    var searchSheet: some View {
        DestinationSearchSheet(
            navigationStore: navigationStore,
            searchStore: searchStore,
            selectingRouteOrigin: selectingRouteOriginInSearch,
            places: placeStore.places,
            recentDestinations: recentDestinations,
            recentSearches: placeStore.searches,
            quickEstimates: quickETAEstimates,
            pointSelectionHint: pointSelectionHint,
            onRemoveFavorite: { removeFavorite(for: $0) },
            onRenameFavorite: { renameFavorite(for: $0, to: $1) },
            onRefreshContactPlace: { contactReference, destination in
                placeStore.updateContactPlace(contactReference, destination: destination)
            },
            onSavePlaceAs: { destination, kind, contactIdentifier in
                placeStore.add(destination, kind: kind, sourceContactIdentifier: contactIdentifier)
            },
            onSaveCurrentLocation: { kind in
                guard let coordinate = navigationStore.state.location?.coordinate else { return false }
                let address = await GUGiKAddressProvider().reverseGeocode(coordinate)
                let destination = Destination(name: kind.title, coordinate: coordinate, address: address)
                return placeStore.add(destination, kind: kind)
            },
            onChooseOnMap: { kind in beginSavedPlaceMapSelection(as: kind) },
            onSelectTransitStop: { stop in
                appRouter.dismiss(.search)
                openTransitStop(stop)
            },
            onSelectTransitLine: { line in
                appRouter.dismiss(.search)
                openTransitLine(line)
            },
            onSelectDestination: { destination, asStop in
                if selectingRouteOriginInSearch {
                    guard !asStop else { return }
                    applyRouteOrigin(destination, source: destination.poi == nil ? .search : .poi)
                } else if addingWaypoint || asStop {
                    placeStore.recordSearch(destination)
                    Task {
                        await navigationStore.addWaypoint(destination)
                    }
                    addingWaypoint = false
                    appRouter.dismiss(.search)
                } else {
                    selectDestination(destination)
                }
            }
        )
    }

    func openTransitStop(_ stop: TransitStop) {
        if let center = navigationStore.state.searchMapCenter ?? navigationStore.state.location?.coordinate,
           center.distance(to: stop.coordinate) > 700 {
            navigationStore.focusMap(on: stop.coordinate)
        }
        transitStore.open(stop)
    }

    func openTransitVehicle(_ vehicle: TransitVehicle) {
        Task { await transitStore.open(vehicle) }
    }

    private func openTransitLine(_ line: TransitLineSearchResult) {
        Task {
            guard let details = await transitStore.open(line) else { return }
            if let center = navigationStore.state.searchMapCenter ?? navigationStore.state.location?.coordinate,
               let midpoint = details.coordinates.dropFirst(details.coordinates.count / 2).first,
               center.distance(to: midpoint) > 2_000 {
                navigationStore.focusMap(on: midpoint, zoom: 12.8)
            }
        }
    }

    func openTransitDeparture(_ departure: TransitDeparture) {
        Task { await transitStore.open(departure) }
    }

    private func destinationRow(_ destination: Destination, subtitle: String?, symbol: String) -> some View {
        Button {
            selectDestination(destination)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}
