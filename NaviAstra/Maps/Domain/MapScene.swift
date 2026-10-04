import Foundation

struct MapSceneTransitData {
    let vehicles: [TransitVehicle]
    let stops: [TransitStop]
    let selectedStopID: String?
    let selectedRouteID: String?
    let selectedTripID: String?
    let selectedTripStopIDs: Set<String>
    let activeStopID: String?
    let alightingStopID: String?
    let lineCoordinates: [Coordinate]
    let lineColor: UInt32?
}

struct MapSceneCommands {
    let onSearchSelect: (Destination) -> Void
    let onPlaceSelect: ([SearchResult]) -> Void
    let onTransitStopSelect: (TransitStop) -> Void
    let onTransitVehicleSelect: (TransitVehicle) -> Void
    let onParkedCarSelect: () -> Void
    let onRouteSelect: (UUID) -> Void
    let onCyclingPathsStatus: (OSMCyclingPathsStatus) -> Void
    let onRoadPOIStatus: (MapRoadPOIStatus) -> Void
    let onTransitViewportChange: (TransitMapViewport) -> Void
    let onMapPan: () -> Void
    let onLongPress: (Coordinate) -> Void
}

struct MapScene {
    let navigationState: NavigationState
    let energyPolicy: EnergyPolicy
    let transit: MapSceneTransitData
    let parkedCar: ParkedCar?
    let settings: MapSettings
    let isSearchPresented: Bool
    let routePreviewExpanded: Bool
    let isBottomSheetDragging: Bool
    let viewportPadding: CameraPadding
    let commands: MapSceneCommands
    var weather = WeatherVisualConfiguration()
    var weatherSamples: [RouteWeatherSample] = []
    var selectedPlace: SearchResult? = nil

    var placeMarkers: [SearchResult] {
        let showsOnlyRouteEndpoints = navigationState.destination != nil && navigationState.status != .idle
        var results = showsOnlyRouteEndpoints ? [] : Array(navigationState.searchResults.prefix(8))
        if let selectedPlace {
            let identity = selectedPlace.placeIdentity.cacheKey
            if let index = results.firstIndex(where: { $0.placeIdentity.cacheKey == identity }) {
                results[index] = selectedPlace
            } else {
                results.append(selectedPlace)
            }
        }
        return results
    }
}
