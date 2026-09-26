import SwiftUI

extension ContentView {
    var searchSheet: some View {
        DestinationSearchSheet(
            engine: engine,
            searchStore: searchStore,
            selectingRouteOrigin: selectingRouteOriginInSearch,
            places: localData.places,
            recentDestinations: recentDestinations,
            recentSearches: localData.searches,
            quickEstimates: quickETAEstimates,
            pointSelectionHint: pointSelectionHint,
            onRemoveFavorite: { removeFavorite(for: $0) },
            onRenameFavorite: { renameFavorite(for: $0, to: $1) },
            onRefreshContactPlace: { contactReference, destination in
                localData.updateContactPlace(contactReference, destination: destination)
            },
            onSavePlaceAs: { destination, kind, contactIdentifier in
                localData.add(destination, kind: kind, sourceContactIdentifier: contactIdentifier)
            },
            onSaveCurrentLocation: { kind in
                guard let coordinate = engine.state.location?.coordinate else { return false }
                let address = await GUGiKAddressProvider().reverseGeocode(coordinate)
                let destination = Destination(name: kind.title, coordinate: coordinate, address: address)
                return localData.add(destination, kind: kind)
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
                    localData.recordSearch(destination)
                    Task {
                        await engine.addWaypoint(destination)
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
        if let center = engine.state.searchMapCenter ?? engine.state.location?.coordinate,
           center.distance(to: stop.coordinate) > 700 {
            engine.focusMap(on: stop.coordinate)
        }
        selectedTransitStopID = stop.id
        selectedTransitRouteID = nil
        selectedTransitTripID = nil
        selectedTransitTripStopIDs = []
        selectedTransitLine = nil
        selectedTransitTripCoordinates = []
        selectedTransitSheet = .stop(stop)
    }

    func openTransitVehicle(_ vehicle: TransitVehicle) {
        selectedTransitStopID = nil
        selectedTransitRouteID = vehicle.routeID
        selectedTransitTripID = vehicle.tripID
        selectedTransitTripStopIDs = []
        selectedTransitTripCoordinates = []
        selectedTransitSheet = .vehicle(vehicle)
        Task {
            let provider = LodzTransitRouteProvider()
            async let line = provider.lineDetails(for: vehicle.routeID)
            async let trip = provider.vehicleDetails(id: vehicle.id)
            let (lineDetails, tripDetails) = await (line, trip)
            selectedTransitLine = lineDetails
            if let tripDetails {
                selectedTransitTripStopIDs = Set((tripDetails.pastStops + tripDetails.nextStops).map(\.stopID)
                    + (tripDetails.currentStopID.map { [$0] } ?? []))
            } else {
                selectedTransitTripStopIDs = []
            }
            selectedTransitTripCoordinates = tripDetails?.coordinates ?? []
        }
    }

    private func openTransitLine(_ line: TransitLineSearchResult) {
        selectedTransitStopID = nil
        selectedTransitRouteID = line.id
        selectedTransitTripID = nil
        selectedTransitTripStopIDs = []
        selectedTransitLine = nil
        selectedTransitTripCoordinates = []
        Task {
            guard let details = await LodzTransitRouteProvider().lineDetails(for: line.id) else { return }
            selectedTransitLine = details
            if let center = engine.state.searchMapCenter ?? engine.state.location?.coordinate,
               let midpoint = details.coordinates.dropFirst(details.coordinates.count / 2).first,
               center.distance(to: midpoint) > 2_000 {
                engine.focusMap(on: midpoint, zoom: 12.8)
            }
            selectedTransitSheet = .line(details)
        }
    }

    func openTransitDeparture(_ departure: TransitDeparture) {
        selectedTransitStopID = departure.stopID
        selectedTransitRouteID = departure.routeID
        selectedTransitTripID = departure.tripID
        selectedTransitTripStopIDs = []
        selectedTransitTripCoordinates = []
        selectedTransitSheet = .departure(departure)
        Task {
            let provider = LodzTransitRouteProvider()
            async let line = provider.lineDetails(for: departure.routeID)
            async let trip = provider.tripDetails(for: departure)
            let (lineDetails, tripDetails) = await (line, trip)
            selectedTransitLine = lineDetails
            if let tripDetails {
                selectedTransitTripStopIDs = Set((tripDetails.pastStops + tripDetails.nextStops).map(\.stopID)
                    + (tripDetails.currentStopID.map { [$0] } ?? []))
            } else {
                selectedTransitTripStopIDs = []
            }
            selectedTransitTripCoordinates = tripDetails?.coordinates ?? []
        }
        selectedTransitSheet = .departure(departure)
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
