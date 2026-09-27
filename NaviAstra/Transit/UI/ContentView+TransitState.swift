import SwiftUI

extension ContentView {
    var selectedTransitSheet: TransitSheetSelection? {
        get { transitStore.selectedSheet }
        nonmutating set { transitStore.selectedSheet = newValue }
    }

    var selectedTransitStopID: String? {
        get { transitStore.selectedStopID }
        nonmutating set { transitStore.selectedStopID = newValue }
    }

    var selectedTransitRouteID: String? {
        get { transitStore.selectedRouteID }
        nonmutating set { transitStore.selectedRouteID = newValue }
    }

    var selectedTransitTripID: String? {
        get { transitStore.selectedTripID }
        nonmutating set { transitStore.selectedTripID = newValue }
    }

    var selectedTransitTripStopIDs: Set<String> {
        get { transitStore.selectedTripStopIDs }
        nonmutating set { transitStore.selectedTripStopIDs = newValue }
    }

    var selectedTransitLine: TransitLineDetails? {
        get { transitStore.selectedLine }
        nonmutating set { transitStore.selectedLine = newValue }
    }

    var selectedTransitTripCoordinates: [Coordinate] {
        get { transitStore.selectedTripCoordinates }
        nonmutating set { transitStore.selectedTripCoordinates = newValue }
    }

    var liveTransitTripDetails: TransitTripDetails? {
        get { transitStore.liveTripDetails }
        nonmutating set { transitStore.liveTripDetails = newValue }
    }
}
