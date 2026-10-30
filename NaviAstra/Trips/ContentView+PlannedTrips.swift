import SwiftUI

extension ContentView {
    private var tripPlaces: [Destination] { placeStore.places.map(\.navigationDestination) }
    private var tripCurrentOrigin: Destination? {
        guard let location = navigationStore.state.location, location.accuracy >= 0,
              location.accuracy <= 100, Date().timeIntervalSince(location.timestamp) < 120 else { return nil }
        return Destination(name: "Miejsce zapisania planu", coordinate: location.coordinate)
    }

    private var tripDraft: PlannedTrip? {
        guard let destination = navigationStore.state.destination,
              let origin = navigationStore.state.routePlan?.origin else { return nil }
        let state = navigationStore.state
        let date = state.journeyTimeMode == .now ? Date().addingTimeInterval(3_600) : max(state.journeyTargetTime, Date().addingTimeInterval(60))
        var trip = PlannedTrip(origin: origin.destination, destination: destination,
            waypoints: state.waypoints, transportMode: state.transportMode,
            preferences: state.routingPreferences,
            timing: state.journeyTimeMode == .arriveBy ? .arrival : .departure, targetDate: date)
        if let route = state.route { trip.preferredRoute = PlannedTrip.fingerprint(route) }
        return trip
    }

    var planTripButton: some View {
        Button("Zaplanuj na później", systemImage: "calendar.badge.plus") {
#if os(iOS)
            beginIOSPlanning(seed: tripDraft, returnToLibrary: false)
#else
            plannedTripDraft = tripDraft
            appRouter.present(.planTrip)
#endif
        }
        .disabled(navigationStore.state.routePlan == nil || isNavigating)
    }

    @ViewBuilder var planTripSheet: some View {
#if os(iOS)
        iosTripWorkspace(IOSPlannedTripPresentation(seed: plannedTripDraft))
#else
        PlannedTripEditor(service: tripPlanning, seed: plannedTripDraft, places: tripPlaces, currentOrigin: tripCurrentOrigin)
#endif
    }

    @ViewBuilder var plannedTripsSheet: some View {
#if os(iOS)
        IOSPlannedTripsView(service: tripPlanning, focusTripID: tripCoordinator.libraryFocusID,
            navigationIsActive: isNavigating,
            onCreate: { beginIOSPlanning(seed: nil, returnToLibrary: true) },
            onEdit: { beginIOSPlanning(seed: $0, returnToLibrary: true) },
            onStart: openPlannedTrip,
            onHistory: { appRouter.present(.history) },
            onClose: { tripCoordinator.libraryFocusID = nil; appRouter.dismiss(.plannedTrips) })
#else
        PlannedTripsView(service: tripPlanning, places: tripPlaces, currentOrigin: tripCurrentOrigin,
            onOpen: openPlannedTrip,
            onHistory: { appRouter.present(.history) },
            onClose: { appRouter.dismiss(.plannedTrips) })
#endif
    }

#if os(iOS)
    func beginIOSPlanning(seed: PlannedTrip?, returnToLibrary: Bool) {
        var presentation = IOSPlannedTripPresentation(seed: seed)
        presentation.draft = IOSPlannedTripDraft(seed: seed, currentOrigin: iosPlanningOrigin,
            initialCenter: navigationStore.state.searchMapCenter ?? navigationStore.state.location?.coordinate,
            preferences: navigationStore.state.routingPreferences)
        tripCoordinator.begin(presentation, returnToLibrary: returnToLibrary, router: appRouter)
    }

    func iosTripWorkspace(_ presentation: IOSPlannedTripPresentation) -> some View {
        IOSPlannedTripWorkspace(seed: presentation.seed, preparedDraft: presentation.draft, service: tripPlanning,
            places: placeStore.places, recentPlaces: placeStore.searches.map(\.destination) + recentDestinations,
            currentOrigin: iosPlanningOrigin,
            initialCenter: navigationStore.state.searchMapCenter ?? navigationStore.state.location?.coordinate,
            preferences: navigationStore.state.routingPreferences, mapSettings: navigationMapSettings,
            onRecordPlace: { placeStore.recordSearch($0) },
            onSaved: { trip in tripCoordinator.didSave(trip) })
    }

    private var iosPlanningOrigin: Destination? {
        tripCurrentOrigin.map { point in
            var point = point; point.name = "Bieżące miejsce"; return point
        }
    }

    func finishIOSPlanning() {
        tripCoordinator.finish(router: appRouter)
    }
#endif

    func openPlannedTrip(_ trip: PlannedTrip) {
        guard !isNavigating else {
            tripPlanning.errorMessage = "Zakończ bieżącą nawigację przed rozpoczęciem kolejnej podróży."
            return
        }
        appRouter.dismiss(.plannedTrips)
        navigationStore.stop()
        let state = navigationStore.state
        state.transportMode = trip.transportMode
        state.routingPreferences = trip.preferences
        state.routeOrigin = RoutePoint(trip.origin, source: .savedPlace)
        state.waypoints = trip.waypoints
        state.journeyTimeMode = .now
        state.journeyTargetTime = Date()
        navigationStore.selectDestination(trip.destination, applyConfiguredMode: false)
        state.routeOrigin = RoutePoint(trip.origin, source: .savedPlace)
        state.waypoints = trip.waypoints
        pendingPlannedTripID = trip.id
        pendingPlannedTripOccurrence = trip.occurrences(after: Date()).first
        Task {
            guard let location = await navigationStore.freshDepartureLocation(), location.accuracy >= 0,
                  location.accuracy <= 100, Date().timeIntervalSince(location.timestamp) < 60 else {
                state.errorMessage = "Do rozpoczęcia podróży potrzebna jest aktualna pozycja GPS."
                pendingPlannedTripID = nil
                pendingPlannedTripOccurrence = nil
                return
            }
            guard state.status == .destinationPreview, state.destination?.id == trip.destination.id else { return }
            state.routeOrigin = RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: location.coordinate), source: .mapSelection)
            await RoadRoutingContext.$allowsPersonalization.withValue(
                trip.preferences.advanced.effectiveRoutePreference == .personalized) {
                await navigationStore.planRoute()
            }
            guard state.status == .routePreview, state.destination?.id == trip.destination.id else {
                pendingPlannedTripID = nil
                pendingPlannedTripOccurrence = nil
                return
            }
            let preferred = trip.preferredOption(in: state.routeOptions)
            if let route = preferred.route { navigationStore.select(route) }
            if !preferred.matched {
                state.errorMessage = "Poprzedni wariant jest niedostępny. Wybrano aktualną rekomendację trasy."
            }
            navigationStore.begin()
        }
    }
}
