import Foundation

extension NavigationSession {
    func previewNewTrip(_ destination: Destination) async {
        applyConfiguredDefaultTransportMode()
        await preview(destination)
    }

    func preview(_ destination: Destination) async {
        requestGeneration += 1
        let generation = requestGeneration
        let mode = state.transportMode
        let transitCancellationToken = mode == .transit || mode == .parkRide
            ? TransitPlanningCancellationToken() : nil
        transitPlanningCancellationToken = transitCancellationToken
        defer {
            if let transitCancellationToken,
               self.transitPlanningCancellationToken === transitCancellationToken {
                self.transitPlanningCancellationToken = nil
            }
        }
        guard let origin = await resolvedRouteOriginCoordinate(for: mode),
              generation == requestGeneration else {
            guard generation == requestGeneration else { return }
            state.status = .error
            state.errorMessage = "Czekam na dokładną pozycję GPS."
            return
        }
        let requestedJourneyTimeMode = state.journeyTimeMode
        let requestedJourneyTime = state.journeyTargetTime
        state.destination = destination
        state.navigationTarget = nil
        state.parkRideCarTarget = nil
        state.evChargingStops = []
        state.status = .routeCalculating
        refreshEnergyPolicy()
        state.route = nil
        state.routeOptions = []
        state.laterTransitRoutes = []
        state.isLoadingLaterTransitRoutes = false
        state.didSearchLaterTransitRoutes = false
        laterTransitRequestGeneration += 1
        state.transitPlanningPhase = nil
        state.progress = nil
        state.transitProgress = nil
        routeProgressTracker.invalidateGeometries()
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        state.errorMessage = nil
        // The destination camera stays in place until route geometry is available.
        do {
            let accessTargets = await resolveAccessTargets(for: destination, mode: state.transportMode)
            guard generation == requestGeneration else { return }
            state.navigationTarget = accessTargets.navigation
            state.parkRideCarTarget = accessTargets.parkRideCar
            let routeDestination = accessTargets.navigation?.coordinate ?? destination.coordinate
            let routes: [NavigationRoute]
            if state.transportMode == .transit {
                let onProgress: TransitPlanningProgressHandler = { [weak self] phase in
                    guard let self, self.requestGeneration == generation else { return }
                    self.state.transitPlanningPhase = phase
                }
                if requestedJourneyTimeMode == .arriveBy {
                    routes = try await transitProvider.calculateRoutesArrivingBy(
                        from: origin, to: routeDestination, deadline: requestedJourneyTime,
                        onProgress: onProgress,
                        shouldContinue: { [weak self] in
                            self?.requestGeneration == generation
                        },
                        cancellationToken: transitCancellationToken)
                    onProvisionalTransitRoutes(routes, generation: generation)
                } else {
                    let departure = requestedJourneyTimeMode == .departAt ? requestedJourneyTime : Date()
                    routes = try await transitProvider.calculateRoutes(
                        from: origin, to: routeDestination, departingAt: departure,
                        onProgress: onProgress,
                        onProvisionalRoutes: { [weak self] routes in
                            self?.onProvisionalTransitRoutes(routes, generation: generation)
                        },
                        cancellationToken: transitCancellationToken)
                }
            } else if state.transportMode == .parkRide {
                let departure = requestedJourneyTimeMode == .departAt ? requestedJourneyTime : Date()
                routes = try await calculateParkRideRoutes(from: origin, to: routeDestination,
                                                            departingAt: departure,
                                                            cancellationToken: transitCancellationToken)
            } else {
                routes = try await calculateRoutes(from: origin, to: routeDestination)
            }
            guard generation == requestGeneration else { return }
            guard let firstRoute = routes.first else { throw RoutingError.invalidResponse }
            state.route = firstRoute
            state.routeOptions = routes
            state.status = .routePreview
            refreshEnergyPolicy()
            state.cameraState = .routeOverview
            state.transitPlanningPhase = nil
            if state.transportMode == .transit { lastTransitPlanRefresh = Date() }
            updateProgress()
            updateCameraIntent()
#if os(macOS)
            revealRoute()
#else
            // MapLibre replaces the full route shape when its reveal progress changes.
            // Draw it once on iOS instead of rebuilding an increasingly large shape every frame.
            state.routeRevealProgress = 1
#endif
            invalidateTraffic()
            if state.transportMode == .car { refreshTraffic(force: true) }
            if usesRoadVoiceGuidance { loadRoadData(for: firstRoute) }
        } catch {
            guard generation == requestGeneration else { return }
            state.route = nil
            state.routeOptions = []
            state.transitPlanningPhase = nil
            state.status = .error
            state.errorMessage = error.localizedDescription
        }
    }

    var routeOriginCoordinate: Coordinate? {
        if let origin = state.routeOrigin, !origin.isCurrentLocation { return origin.coordinate }
        return state.location?.coordinate
    }

    func resolvedRouteOriginCoordinate(for mode: TransportMode) async -> Coordinate? {
        guard let origin = state.routeOrigin, !origin.isCurrentLocation else {
            return state.location?.coordinate
        }
        guard origin.poi != nil else { return origin.coordinate }
        let destination = origin.destination
        return await POIAccessResolver.shared.resolve(for: destination, mode: mode)?.coordinate
            ?? origin.coordinate
    }

    private func onProvisionalTransitRoutes(_ routes: [NavigationRoute], generation: Int) {
        guard requestGeneration == generation, let firstRoute = routes.first else { return }
        state.route = firstRoute
        state.routeOptions = routes
        state.status = .routePreview
        state.transitPlanningPhase = nil
        state.cameraState = .routeOverview
        lastTransitPlanRefresh = Date()
        updateProgress()
        updateCameraIntent()
#if os(macOS)
        revealRoute()
#else
        state.routeRevealProgress = 1
#endif
    }

}
