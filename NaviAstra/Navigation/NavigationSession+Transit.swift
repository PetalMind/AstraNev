import Foundation

extension NavigationSession {
    func loadLaterTransitConnections(after departure: Date) async {
        guard state.status == .routePreview,
              state.transportMode == .transit,
              let destination = state.destination,
              let origin = state.location?.coordinate else { return }
        let expectedRouteID = state.route?.id
        let expectedDestinationID = destination.id
        let generation = requestGeneration
        laterTransitRequestGeneration += 1
        let laterGeneration = laterTransitRequestGeneration
        state.isLoadingLaterTransitRoutes = true
        state.laterTransitRoutes = []
        state.didSearchLaterTransitRoutes = false
        defer {
            if laterGeneration == laterTransitRequestGeneration {
                state.isLoadingLaterTransitRoutes = false
            }
        }

        do {
            let routeTarget = destinationRouteCoordinate(for: destination)
            let routes = try await transitProvider.calculateRoutes(
                from: origin,
                to: routeTarget,
                departingAt: departure.addingTimeInterval(1))
            guard generation == requestGeneration,
                  laterGeneration == laterTransitRequestGeneration,
                  state.status == .routePreview,
                  state.destination?.id == expectedDestinationID,
                  state.route?.id == expectedRouteID else { return }
            state.laterTransitRoutes = routes.filter { route in
                (route.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantPast) > departure
            }.sorted {
                let firstDeparture = $0.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantFuture
                let secondDeparture = $1.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantFuture
                return firstDeparture < secondDeparture
            }
            state.didSearchLaterTransitRoutes = true
        } catch {
            guard generation == requestGeneration,
                  laterGeneration == laterTransitRequestGeneration,
                  state.destination?.id == expectedDestinationID,
                  state.route?.id == expectedRouteID else { return }
            state.errorMessage = error.localizedDescription
            state.laterTransitRoutes = []
            state.didSearchLaterTransitRoutes = true
        }
    }

    func selectLaterTransitConnection(_ route: NavigationRoute) {
        guard state.status == .routePreview,
              state.laterTransitRoutes.contains(where: { $0.id == route.id }) else { return }
        state.route = route
        state.routeOptions = [route]
        state.journeyTimeMode = .departAt
        state.journeyTargetTime = route.journey?.departure ?? Date()
        laterTransitRequestGeneration += 1
        state.isLoadingLaterTransitRoutes = false
        state.laterTransitRoutes = []
        state.didSearchLaterTransitRoutes = false
        state.transitPlanningPhase = nil
        state.transitProgress = nil
        updateCameraIntent()
        invalidateTraffic()
        updateProgress()
    }

    func updateTransitTripDetails(_ details: TransitTripDetails?, tripID: String?) {
        transitTripDetails = details
        transitTripDetailsID = tripID
        guard state.transportMode == .transit else { return }
        updateProgress()
    }

    func refreshTransitRouteIfNeeded() async {
        guard state.transportMode == .transit,
              (state.status == .routePreview || state.status == .navigating),
              state.transitPlanningPhase == nil,
              !transitPlanRefreshInFlight,
              Date().timeIntervalSince(lastTransitPlanRefresh) >= 45,
              let destination = state.destination,
              let origin = state.location?.coordinate else { return }

        // Keep an explicitly selected future departure or arrival deadline stable in preview.
        guard state.status != .routePreview || state.journeyTimeMode == .now else { return }

        if state.status == .navigating {
            guard state.transitProgress?.isOnVehicle != true else { return }
            if let route = state.route,
               let journey = route.journey,
               let legIndex = state.transitProgress?.legIndex,
               journey.legs.indices.contains(legIndex),
               journey.legs[legIndex].mode.uppercased() != "WALK",
               (state.location?.speed ?? 0) >= 2.5 {
                return
            }
        }

        transitPlanRefreshInFlight = true
        lastTransitPlanRefresh = Date()
        defer { transitPlanRefreshInFlight = false }

        let expectedStatus = state.status
        let expectedDestinationID = destination.id
        let expectedRouteID = state.route?.id
        let previousRoute = state.route
        let previousOptions = state.routeOptions
        do {
            let routeTarget = destinationRouteCoordinate(for: destination)
            let routes = try await transitProvider.calculateRoutes(from: origin, to: routeTarget,
                                                                    departingAt: Date())
            guard !Task.isCancelled,
                  state.transportMode == .transit,
                  state.status == expectedStatus,
                  state.destination?.id == expectedDestinationID,
                  state.route?.id == expectedRouteID,
                  !routes.isEmpty else { return }

            var refreshedRoutes = routes
            for index in refreshedRoutes.indices {
                guard let previous = previousOptions.first(where: {
                    transitRouteSignature($0) == transitRouteSignature(refreshedRoutes[index])
                }), previous.coordinates == refreshedRoutes[index].coordinates else { continue }
                preserveTransitRouteIdentity(from: previous, in: &refreshedRoutes[index])
            }

            let selectedIndex: Int
            if let previousRoute,
               let matchingIndex = refreshedRoutes.firstIndex(where: {
                   transitRouteSignature($0) == transitRouteSignature(previousRoute)
               }) {
                selectedIndex = matchingIndex
            } else {
                selectedIndex = refreshedRoutes.startIndex
            }
            let selectedRoute = refreshedRoutes[selectedIndex]
            state.routeOptions = refreshedRoutes
            state.route = selectedRoute
            routeProgressTracker.invalidateTransitGeometry()
            updateProgress()
            if state.cameraState == .routeOverview { updateCameraIntent() }
        } catch {
            // Keep the current route when the live feed or route service has a temporary failure.
        }
    }

    private func transitRouteSignature(_ route: NavigationRoute) -> String {
        route.journey?.legs.filter { $0.mode.uppercased() != "WALK" }
            .map { leg in
                let first = leg.transitStops.first?.sequence ?? 0
                let last = leg.transitStops.last?.sequence ?? 0
                return "\(leg.tripID ?? "")|\(leg.serviceDate ?? "")|\(leg.routeID ?? "")|\(first)-\(last)"
            }
            .joined(separator: ";") ?? ""
    }

    private func preserveTransitRouteIdentity(from previous: NavigationRoute,
                                             in refreshed: inout NavigationRoute) {
        refreshed.id = previous.id
        guard var refreshedJourney = refreshed.journey,
              let previousJourney = previous.journey else { return }
        for index in refreshedJourney.legs.indices where previousJourney.legs.indices.contains(index) {
            let oldLeg = previousJourney.legs[index]
            let newLeg = refreshedJourney.legs[index]
            if oldLeg.mode == newLeg.mode && oldLeg.from == newLeg.from && oldLeg.to == newLeg.to {
                refreshedJourney.legs[index].id = oldLeg.id
            }
        }
        refreshed.journey = refreshedJourney
    }
}
