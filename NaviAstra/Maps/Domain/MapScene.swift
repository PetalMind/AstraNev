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
}
