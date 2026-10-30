import Foundation

extension NavigationSession {
    func flowDistanceRange(on route: NavigationRoute,
                                   flow: TrafficFlow) -> (start: Double, end: Double)? {
        if projectedFlowRouteID != route.id || projectedFlowUpdatedAt != flow.updatedAt ||
            projectedFlowCoordinates != flow.coordinates {
            let distances = flow.coordinates.compactMap { coordinate -> Double? in
                guard let projection = routeProgressTracker.projectRoadCoordinate(
                    route: route, coordinate: coordinate),
                      projection.distanceFromRoute <= RouteTrafficMonitor.routeMatchToleranceMeters else {
                    return nil
                }
                return projection.alongRoute
            }
            projectedFlowRouteID = route.id
            projectedFlowUpdatedAt = flow.updatedAt
            projectedFlowCoordinates = flow.coordinates
            projectedFlowDistanceRange = distances.min().flatMap { start in
                distances.max().map { (start: start, end: $0) }
            }
        }
        return projectedFlowDistanceRange
    }

    func chargingStopDistances(on route: NavigationRoute) -> [Double?] {
        let coordinates = route.chargingStops.map { stop in
            state.waypointNavigationTargets[stop.destination.id]?.coordinate ?? stop.destination.coordinate
        }
        if projectedChargingRouteID != route.id || projectedChargingCoordinates != coordinates {
            projectedChargingRouteID = route.id
            projectedChargingCoordinates = coordinates
            projectedChargingDistances = coordinates.map { coordinate in
                MapMatcher.project(coordinate, onto: route.coordinates)?.alongRoute
            }
        }
        return projectedChargingDistances
    }

    func updateProgress(reuseJourneyMatch: Bool = false) {
        defer { updateLiveActivity() }
        let journeyProgress = updateJourneyVoiceProgress(reuseExistingMatch: reuseJourneyMatch)
        if state.transportMode == .transit,
           let route = state.route, let journey = route.journey {
            state.routeMatch = nil
            state.mapMatchingResult = nil
            state.laneGuidance = nil
            state.guidanceQuality = nil
            state.routeReliability = nil
            state.etaConfidence = nil
            let isActive = state.status == .navigating || state.status == .rerouting
            let transitProgress = journeyProgress

            let progressFraction = transitProgress?.routeFraction ??
                (isActive
                    ? max(0, min(1, 1 - journey.arrival.timeIntervalSinceNow / max(1, route.expectedTravelTime)))
                    : 0)
            let geometryProgress = routeProgressTracker.displayedGeometryProgress(
                routeID: route.id,
                candidate: progressFraction,
                canAdvance: isActive,
                isNavigationActive: isActive)
            let scheduledArrival = journey.arrival
            var estimatedArrival = scheduledArrival
            if let tripID = transitTripDetailsID,
               let leg = journey.legs.first(where: { $0.tripID == tripID }),
               let alightingStop = leg.transitStops.last,
               let liveStop = (transitTripDetails?.pastStops ?? [])
                    .first(where: { $0.stopID == alightingStop.stopID }) ??
                    (transitTripDetails?.nextStops ?? []).first(where: { $0.stopID == alightingStop.stopID }) {
                estimatedArrival = scheduledArrival.addingTimeInterval(
                    liveStop.arrival.timeIntervalSince(alightingStop.arrival))
            }
            let remainingTime = isActive
                ? max(0, estimatedArrival.timeIntervalSinceNow)
                : route.expectedTravelTime
            state.progress = RouteProgress(traveledDistance: route.distance * progressFraction,
                                           remainingDistance: route.distance * (1 - progressFraction),
                                           remainingTime: remainingTime,
                                           distanceToNextManeuver: .infinity,
                                           nextManeuver: nil,
                                           geometryProgress: geometryProgress,
                                           geometryRouteID: route.id)
            state.estimatedArrival = isActive ? estimatedArrival : Date().addingTimeInterval(remainingTime)

            let destinationCoordinate = state.destination.map { destinationRouteCoordinate(for: $0) }
                ?? route.coordinates.last
            if isActive, let destinationCoordinate, let location = state.location,
               arrivalDetector.observe(location, destinationDistance: location.coordinate.distance(to: destinationCoordinate),
                                       remainingDistance: state.progress?.remainingDistance ?? .infinity) {
                arriveAtDestination()
                return
            }
            if isActive, let transitProgress {
                updateTransitVoice(for: transitProgress, journey: journey)
            }
            return
        }
        guard let route = state.route, let location = state.location else {
            state.routeMatch = nil
            state.mapMatchingResult = nil
            state.laneGuidance = nil
            state.guidanceQuality = nil
            state.routeReliability = nil
            state.etaConfidence = nil
            return
        }
        let previousMatch = previousRouteMatch?.routeID == route.id ? previousRouteMatch : nil
        guard let measurement = routeProgressTracker.measureRoadProgress(
            route: route,
            location: location,
            previousMatch: previousMatch?.projection,
            previousTimestamp: previousMatch?.timestamp) else {
            state.routeMatch = nil
            state.mapMatchingResult = nil
            state.laneGuidance = nil
            state.guidanceQuality = nil
            state.routeReliability = nil
            state.etaConfidence = nil
            return
        }
        let projection = measurement.projection
        let routeMatch = measurement.matchedRoute
        state.mapMatchingResult = measurement.matching
        if (routeMatch?.confidence ?? 0) >= 0.25, measurement.matching?.ambiguous != true {
            previousRouteMatch = (route.id, projection, location.timestamp)
        }
        state.routeMatch = NavigationRouteMatch(
            routeID: route.id,
            locationTimestamp: location.timestamp,
            match: routeMatch ?? RouteMatch(projection: projection, confidence: 0),
            isAmbiguous: measurement.matching?.ambiguous ?? true)
        if MapDisplayPriorityEngine.canPresentRouteAlerts(state),
           let zone = state.roadSafetyAlerts.last(where: {
               $0.type == .trafficZoneSign && ($0.distanceAlongRoute ?? .infinity) <= projection.alongRoute
           }), state.lastPassedRoadZoneID != zone.id {
            state.lastPassedRoadZoneID = zone.id
            if projection.alongRoute - (zone.distanceAlongRoute ?? 0) <= 40 {
                state.roadZoneNotice = zone
                state.roadZoneNoticeExpiresAt = .now.addingTimeInterval(3)
            }
        }
        let fraction = measurement.fraction
        let geometryProgress = routeProgressTracker.displayedGeometryProgress(
            routeID: route.id,
            candidate: measurement.geometryFraction,
            canAdvance: measurement.canAdvanceGeometryProgress,
            isNavigationActive: state.status == .navigating || state.status == .rerouting)
        let next = measurement.nextManeuver
        let maneuverDistance = measurement.distanceToNextManeuver
        state.laneGuidance = next.flatMap { LaneGuidanceEngine.guidance(for: $0) }
        let followingDistance: Double? = next.flatMap { current in
            guard let index = route.maneuvers.firstIndex(where: { $0.id == current.id }),
                  route.maneuvers.indices.contains(index + 1) else { return nil }
            return routeProgressTracker.cameraGeometry(for: route).distance(
                from: current.shapeIndex, through: route.maneuvers[index + 1].shapeIndex)
        }
        state.guidanceQuality = next.map { GuidanceQualityEngine.evaluate(maneuver: $0,
            followingDistance: followingDistance, speed: location.speed, mode: state.transportMode) }
        if state.transportMode == .car {
            let reliability = RouteReliability.evaluate(route: route, from: measurement.etaProgressDistance,
                through: measurement.etaProgressDistance + RouteTrafficMonitor.lookAheadDistance(for: route, progress: state.progress),
                traffic: state.traffic, geometry: routeProgressTracker.cameraGeometry(for: route))
            state.routeReliability = reliability
            state.etaConfidence = ETAConfidence.evaluate(reliability, gpsConfidence: routeMatch?.confidence)
        }

        let remainingDistance = route.distance * (1 - fraction)
        let paceMultiplier = roadETAPaceTracker.observe(route: route,
            distance: measurement.etaProgressDistance, location: location,
            reliable: (routeMatch?.confidence ?? 0) >= 0.5 && measurement.matching?.ambiguous != true,
            isNavigating: state.status == .navigating)
        let estimate = routeProgressTracker.estimateRoadETA(route: route, from: measurement.etaProgressDistance,
                                            traffic: state.traffic, paceMultiplier: paceMultiplier)
        // A closure triggers rerouting separately; retain a finite display while it is calculated.
        let remainingTime = estimate.isFinite ? estimate : routeProgressTracker.estimateRoadETA(
            route: route, from: measurement.etaProgressDistance, traffic: nil, paceMultiplier: paceMultiplier)
        state.progress = RouteProgress(traveledDistance: route.distance * fraction,
                                       remainingDistance: remainingDistance,
                                       remainingTime: max(0, remainingTime),
                                       distanceToNextManeuver: max(0, maneuverDistance), nextManeuver: next,
                                       geometryProgress: geometryProgress,
                                       geometryRouteID: route.id)
        if state.status == .routePreview, state.journeyTimeMode == .arriveBy {
            state.estimatedArrival = state.journeyTargetTime
        } else if state.status == .routePreview, state.journeyTimeMode == .departAt {
            state.estimatedArrival = state.journeyTargetTime.addingTimeInterval(route.expectedTravelTime)
        } else {
            state.estimatedArrival = Date().addingTimeInterval(max(0, remainingTime))
        }
        guard state.status == .navigating || state.status == .rerouting else { return }
        guard abs(location.timestamp.timeIntervalSinceNow) <= 10 else {
            arrivalDetector.reset()
            return
        }
        guard let targetCoordinate = state.destination.map({ destinationRouteCoordinate(for: $0) })
                ?? route.coordinates.last else { return }
        var destinationDistance = location.coordinate.distance(to: targetCoordinate)
        let isCarArrival = state.transportMode == .car
        if isCarArrival, let destination = state.destination {
            // Accept the place itself as well as its selected access point.
            destinationDistance = min(destinationDistance,
                                      location.coordinate.distance(to: destination.coordinate))
        }
        // Keep intermediate stops mandatory, but do not require the car to
        // follow the planned final approach to recognize arrival.
        let requiresRouteCompletion = !isCarArrival || !unvisitedStops(from: location.coordinate).isEmpty
        if arrivalDetector.observe(location, destinationDistance: destinationDistance,
                                   remainingDistance: requiresRouteCompletion
                                       ? state.progress?.remainingDistance ?? .infinity : nil,
                                   destinationRadius: isCarArrival ? 100 : 50) {
            arriveAtDestination()
            return
        }
        if let next, state.voiceEnabled,
           (routeMatch?.confidence ?? 0) >= 0.25, measurement.matching?.ambiguous != true {
            let maneuverCoordinate = route.coordinates.indices.contains(next.shapeIndex)
                ? route.coordinates[next.shapeIndex] : nil
            voice.announce(next, coordinate: maneuverCoordinate,
                           distance: max(0, maneuverDistance), speed: max(0, location.speed),
                           quality: state.guidanceQuality, lanes: state.laneGuidance)
        }
        if state.voiceEnabled, MapDisplayPriorityEngine.canPresentRouteAlerts(state) {
            for alert in MapDisplayPriorityEngine.upcomingAlerts(in: state) {
                guard let alongRoute = alert.distanceAlongRoute else { continue }
                let distance = alongRoute - projection.alongRoute
                if distance >= 0 && distance <= 1_200 {
                    voice.announce(alert, distance: distance)
                }
            }
            if let snapshot = state.traffic,
               Date().timeIntervalSince(snapshot.updatedAt) <= 180 {
                for incident in SafetyAlertEngine.alerts(in: snapshot.incidents) {
                    guard let distance = distanceToTrafficIncident(incident, on: route,
                                                                  after: projection.alongRoute),
                          distance >= 0, distance <= 1_200 else { continue }
                    voice.announce(incident, distance: distance)
                }
            }
        }
        let hasSustainedDeparture = offRouteDetector.shouldRequestReroute(
            location: location,
            route: route,
            projection: routeMatch?.projection ?? projection,
            matchConfidence: routeMatch?.confidence ?? 0)
        state.deviationState = offRouteDetector.deviationState
        if hasSustainedDeparture,
           Date().timeIntervalSince(rerouteController.lastReroute) > 20,
           state.status != .rerouting {
            rerouteController.recordRerouteRequest()
            resetOffRouteEvidence()
            Task { await reroute(from: location.coordinate) }
        }
    }

    func updateJourneyVoiceProgress(reuseExistingMatch: Bool = false) -> TransitNavigationProgress? {
        guard usesJourneyVoiceGuidance,
              let route = state.route, let journey = route.journey else {
            state.transitProgress = nil
            return nil
        }
        let isActive = state.status == .navigating || state.status == .rerouting
        let tracked: TransitNavigationProgress?
        if reuseExistingMatch {
            tracked = state.transitProgress
        } else {
            tracked = state.location.flatMap {
                routeProgressTracker.transitProgress(
                    route: route,
                    at: $0.coordinate,
                    accuracy: $0.accuracy,
                    previousLegIndex: lastTransitProgressLegIndex)
            }
        }
        if let tracked { lastTransitProgressLegIndex = tracked.legIndex }
        if let projection = tracked?.routeProjection, let location = state.location {
            previousRouteMatch = (route.id, projection, location.timestamp)
        } else {
            previousRouteMatch = nil
        }
        var progress = tracked
        if var matched = progress, journey.legs.indices.contains(matched.legIndex) {
            let leg = journey.legs[matched.legIndex]
            if leg.mode.uppercased() == "WALK" {
                resetTransitRideConfirmation()
            } else if isActive, let location = state.location {
                let isOnVehicle = confirmTransitRide(progress: matched, leg: leg, location: location)
                if isOnVehicle, let tripID = leg.tripID,
                   let vehicle = currentTransitVehicle(for: tripID),
                   let vehicleProgress = routeProgressTracker.transitProgress(
                    route: route,
                    at: vehicle.coordinate,
                    accuracy: 80,
                    previousLegIndex: matched.legIndex),
                   vehicleProgress.legIndex == matched.legIndex {
                    matched = vehicleProgress
                }
                matched.isOnVehicle = isOnVehicle
                progress = matched
            }
        }
        state.transitProgress = progress
        return progress
    }

    func arriveAtDestination() {
        guard state.status == .navigating || state.status == .rerouting else { return }
        arrivalDetector.reset()
        rerouteController.stop()
        requestGeneration += 1
        invalidateTraffic()
        navigationTransitionTask?.cancel()
        mapCameraController.cancelNavigationCameraTasks()
        mapCameraController.cancelManeuverTransition()
        liveActivity.end()
        state.arrivalLocation = state.location
        state.status = .arrived
        refreshEnergyPolicy()
        state.cameraState = .arrived
        locationManager.setHeadingUpdatesEnabled(false)
        state.deviceHeading = nil
        updateCameraIntent()
        locationManager.stopBackgroundNavigationUpdates()
        if state.voiceEnabled {
            voice.announceArrival(destination: state.destination, transportMode: state.transportMode)
        }
        finishTrip(arrived: true)
    }

    func distanceToTrafficIncident(_ incident: TrafficIncident,
                                           on route: NavigationRoute,
                                           after traveledDistance: Double) -> Double? {
        if let observedAt = incident.observedAt, Date().timeIntervalSince(observedAt) > 120 { return nil }
        guard let projection = RouteTrafficMonitor.incidentProjection(
            incident, geometry: RouteProgressGeometry(route), route: route) else { return nil }
        return projection.alongRoute - traveledDistance
    }

    func upcomingTrafficDelay(on route: NavigationRoute, after distance: Double) -> Double {
        guard let traffic = state.traffic else { return 0 }
        if trafficProjectionRouteID != route.id || trafficProjectionUpdatedAt != traffic.updatedAt {
            trafficProjectionRouteID = route.id
            trafficProjectionUpdatedAt = traffic.updatedAt
            projectedTrafficIncidents = traffic.incidents.compactMap { incident in
                let coordinates = [incident.coordinate] + incident.geometry
                let projections = coordinates.compactMap {
                    routeProgressTracker.projectRoadCoordinate(route: route, coordinate: $0)
                }.filter {
                    $0.distanceFromRoute <= RouteTrafficMonitor.routeMatchToleranceMeters
                }
                guard let projection = projections.min(by: {
                    $0.distanceFromRoute < $1.distanceFromRoute
                }) else { return nil }
                return (alongRoute: projection.alongRoute, delaySeconds: incident.routingDelaySeconds)
            }
        }
        let delay = projectedTrafficIncidents.reduce(0.0) { total, incident in
            guard incident.alongRoute > distance + 40 else { return total }
            return total + Double(max(0, incident.delaySeconds ?? 0))
        }
        return min(1_800, delay)
    }

    func confirmTransitRide(progress: TransitNavigationProgress, leg: JourneyLeg,
                                    location: NavigationLocation) -> Bool {
        guard leg.mode.uppercased() != "WALK", let tripID = leg.tripID else { return false }
        if transitRideTrackingID != tripID {
            transitRideTrackingID = tripID
            confirmedTransitTripID = nil
            transitRideMotionEvidence = 0
            lastTransitRideDistance = 0
        }

        let hasMovedPastBoardingStop = progress.legDistance >= 120
        if hasMovedPastBoardingStop, let vehicle = currentTransitVehicle(for: tripID),
           Date().timeIntervalSince(location.timestamp) <= 30,
           location.speed >= 1.5,
           location.coordinate.distance(to: vehicle.coordinate) <= max(250, location.accuracy * 2) {
            confirmedTransitTripID = tripID
        }

        let isMovingForward = progress.legDistance >= lastTransitRideDistance + 5
        if hasMovedPastBoardingStop, isMovingForward, location.speed >= 4 {
            transitRideMotionEvidence += 1
        } else if confirmedTransitTripID != tripID {
            transitRideMotionEvidence = 0
        }
        if transitRideMotionEvidence >= 2 { confirmedTransitTripID = tripID }
        lastTransitRideDistance = max(lastTransitRideDistance, progress.legDistance)
        return confirmedTransitTripID == tripID
    }

    func currentTransitVehicle(for tripID: String) -> TransitVehicle? {
        let now = Date()
        if transitTripDetailsID == tripID, let vehicle = transitTripDetails?.vehicle,
           (-60...120).contains(now.timeIntervalSince(vehicle.updatedAt)) {
            return vehicle
        }
        return state.transitVehicles.first {
            $0.tripID == tripID && (-60...120).contains(now.timeIntervalSince($0.updatedAt))
        }
    }

    func updateTransitVoice(for progress: TransitNavigationProgress, journey: Journey) {
        guard state.voiceEnabled, journey.legs.indices.contains(progress.legIndex) else { return }
        let leg = journey.legs[progress.legIndex]
        if leg.mode.uppercased() == "WALK" {
            let followingRide = journey.legs.dropFirst(progress.legIndex + 1).first {
                $0.mode.uppercased() != "WALK"
            }
            let instruction: String
            if let followingRide {
                instruction = "Idź do przystanku \(leg.to). Następnie wsiądź do linii \(followingRide.line ?? "MPK"), kierunek \(followingRide.to)."
            } else {
                instruction = "Idź pieszo do celu: \(leg.to)."
            }
            voice.announceTransit(instruction, key: "walk|\(journeyLegIdentity(leg))")
            return
        }

        guard progress.isOnVehicle,
              let remainingStops = progress.stopsUntilAlighting,
              let alightingStop = leg.transitStops.last else { return }
        let followingRide = journey.legs.dropFirst(progress.legIndex + 1).first {
            $0.mode.uppercased() != "WALK"
        }
        let transfer = followingRide.map {
            " Po wysiadaniu przesiądź się na linię \($0.line ?? "MPK") w kierunku \($0.to)."
        } ?? ""
        let tripID = leg.tripID ?? "leg-\(progress.legIndex)"
        if remainingStops == 2, voice.shouldAnnounceAlighting(remainingStops: remainingStops) {
            voice.announceTransit("Za dwa przystanki wysiądź na \(alightingStop.name).\(transfer)",
                                  key: "alight-2-\(tripID)-\(alightingStop.stopID)")
        } else if remainingStops == 1 {
            voice.announceTransit("Następny przystanek: \(alightingStop.name). Przygotuj się do wysiadania.\(transfer)",
                                  key: "alight-1-\(tripID)-\(alightingStop.stopID)", urgent: true)
        }
    }

    func journeyLegIdentity(_ leg: JourneyLeg) -> String {
        let from = leg.from.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let to = leg.to.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let endpoint = leg.coordinates.last.map {
            "\(Int(($0.latitude * 10_000).rounded()))-\(Int(($0.longitude * 10_000).rounded()))"
        } ?? "unknown"
        return "\(leg.mode.uppercased())|\(from)|\(to)|\(endpoint)"
    }

    func resetTransitRideConfirmation() {
        transitRideTrackingID = nil
        confirmedTransitTripID = nil
        transitRideMotionEvidence = 0
        lastTransitRideDistance = 0
    }
    func refreshTransitVehicles(near coordinate: Coordinate) {
        guard let refreshInterval = energyPolicyEngine.currentPolicy.transitRefreshInterval else { return }
        let provider = transitDataProvider
        let coverage = transitDataProvider.region
        guard coordinate.distance(to: coverage.coverageCenter) <= coverage.coverageRadiusMeters else {
            if insideTransitCoverage {
                insideTransitCoverage = false
                transitVehiclesGeneration &+= 1
                transitVehiclesRequestInFlight = false
                state.transitVehicles = []
                state.transitVehiclesUpdatedAt = nil
                state.transitStops = []
                state.nearbyTransitStop = nil
                state.nearbyTransitDepartures = []
            }
            return
        }
        insideTransitCoverage = true
        guard !transitVehiclesRequestInFlight,
              Date().timeIntervalSince(lastTransitVehiclesFetch) >= refreshInterval else { return }
        transitVehiclesRequestInFlight = true
        lastTransitVehiclesFetch = Date()
        transitVehiclesGeneration &+= 1
        let generation = transitVehiclesGeneration
        Task {
            let feed = await provider.vehiclePositions(near: coordinate)
            guard generation == transitVehiclesGeneration else { return }
            transitVehiclesRequestInFlight = false
            state.transitVehicles = feed.vehicles
            state.transitVehiclesUpdatedAt = feed.updatedAt
            state.transitStops = feed.stops
            state.nearbyTransitStop = feed.nearbyStop
            state.nearbyTransitDepartures = feed.nearbyDepartures
            if self.state.transportMode == .transit,
               self.state.status == .navigating || self.state.status == .rerouting {
                self.updateProgress()
            }
        }
    }
}
