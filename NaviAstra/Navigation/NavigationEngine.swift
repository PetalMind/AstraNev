import CoreLocation
import Foundation

@MainActor
final class NavigationEngine {
    let state = NavigationState()
    let locationManager = LocationManager()
    let voice: VoiceGuidanceEngine
    let walkingCameraController = WalkingCameraController()
    var usesJourneyVoiceGuidance: Bool {
        state.transportMode == .transit || state.transportMode == .parkRide
    }
    var usesRoadVoiceGuidance: Bool {
        state.transportMode == .car || state.transportMode == .parkRide
    }
    private var filter = LocationFilter()
    var offRouteSince: Date?
    var previousRouteMatch: (routeID: UUID, projection: RouteProjection, timestamp: Date)?
    var routeProgressTracker = RouteProgressTracker()
    private var lastAcceptedFix = Date.distantPast
    private var locationStartedAt = Date.distantPast
    private var gpsWatchdog: Task<Void, Never>?
    var revealTask: Task<Void, Never>?
    private var navigationTransitionTask: Task<Void, Never>?
    var navigationCameraProjectionTask: Task<RouteProjection?, Never>?
    var navigationCameraUpdateTask: Task<Void, Never>?
    var maneuverTransitionTask: Task<Void, Never>?
    var cameraManeuverID: Int?
    var lastReroute = Date.distantPast
    var rerouteGeneration = 0
    var automaticClosureRerouteTask: Task<Void, Never>?
    var routeProvider: RouteProvider
    var transitProvider: LodzTransitRouteProvider
    private var requestGeneration = 0
    private var laterTransitRequestGeneration = 0
    var trafficGeneration = 0
    private var speedLimitGeneration = 0
    private var roadDataGeneration = 0
    var lastTrafficFetch = Date.distantPast
    private var lastSpeedLimitFetch = Date.distantPast
    var lastTransitVehiclesFetch = Date.distantPast
    private var lastTransitProgressRefresh = Date.distantPast
    private var lastTransitPlanRefresh = Date.distantPast
    private var transitPlanRefreshInFlight = false
    var lastTransitProgressLegIndex: Int?
    var transitVehiclesRequestInFlight = false
    var transitVehiclesGeneration = 0
    var insideTransitCoverage = false
    var autoReroutedClosures: Set<String> = []
    var automaticClosureRetryAfter: [String: Date] = [:]
    var trafficProjectionRouteID: UUID?
    var trafficProjectionUpdatedAt: Date?
    var projectedTrafficIncidents: [(alongRoute: Double, delaySeconds: Int?)] = []
    var trafficRequestInFlight = false
    var routeTrafficRequestInFlight = false
    var lastRouteTrafficFetch = Date.distantPast
    var lastRouteFlowFetch = Date.distantPast
    var routeFlowRouteID: UUID?
    var projectedFlowRouteID: UUID?
    var projectedFlowUpdatedAt: Date?
    var projectedFlowCoordinates: [Coordinate] = []
    var projectedFlowDistanceRange: (start: Double, end: Double)?
    var projectedChargingRouteID: UUID?
    var projectedChargingCoordinates: [Coordinate] = []
    var projectedChargingDistances: [Double?] = []
    var latestNearbyTrafficSnapshot: TrafficSnapshot?
    var routeTrafficIncidents: [TrafficIncident] = []
    var routeTrafficDataAvailable = false
    var routeTrafficUpdatedAt: Date?
    var routeTrafficFlowSegments: [RouteTrafficSegment] = []
    var routeTrafficFlowUpdatedAt: Date?
    private var speedLimitRequestInFlight = false
    private var speedLimitProvider: SpeedLimitProvider
    private let roadDataProvider: RoadDataProvider
    private var roadDataSnapshot: RoadDataSnapshot?
    var trafficProvider: TrafficProvider?
    var transitTripDetails: TransitTripDetails?
    var transitTripDetailsID: String?
    var transitRideTrackingID: String?
    var confirmedTransitTripID: String?
    var transitRideMotionEvidence = 0
    var lastTransitRideDistance = 0.0
    var tripSession: TripSession?
    var onTripFinished: ((TripRecord) -> Void)?

    init(dependencies: NavigationEngineDependencies) {
        routeProvider = dependencies.routeProvider
        transitProvider = dependencies.transitProvider
        speedLimitProvider = dependencies.speedLimitProvider
        roadDataProvider = dependencies.roadDataProvider
        trafficProvider = dependencies.trafficProvider
        voice = dependencies.voiceGuidance
        state.transportMode = TransportMode.configuredDefault
        voice.updatePreferences(state.voicePreferences)
        if trafficProvider != nil {
            state.trafficStatus = .updating
        }
        updateTrafficTileURLTemplates()
        locationManager.onLocation = { [weak self] in self?.receive($0) }
        locationManager.onHeading = { [weak self] heading in
            guard let self, heading.headingAccuracy >= 0, heading.headingAccuracy <= 45 else { return }
            let direction = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
            guard direction.isFinite, (0...360).contains(direction) else { return }
            guard self.state.transportMode == .walking,
                  (self.state.status == .navigating || self.state.status == .rerouting) else { return }
            self.state.deviceHeading = direction
            self.walkingCameraController.update(location: self.state.cameraLocation ?? self.state.location,
                                                deviceHeading: direction, isNewLocationFix: false)
            self.updateCameraIntent()
        }
        locationManager.onAuthorization = { [weak self] authorization in
            guard let self else { return }
            self.state.transitBackgroundLocationAvailable = authorization == .authorizedAlways &&
                self.locationManager.backgroundLocationModeEnabled
            if authorization == .denied || authorization == .restricted {
                self.state.errorMessage = "Włącz dostęp do lokalizacji w ustawieniach urządzenia."
            } else {
#if os(iOS)
                if self.usesJourneyVoiceGuidance,
                   self.state.status == .navigating,
                   !self.locationManager.backgroundLocationModeEnabled {
                    self.state.errorMessage = "Aplikacja nie ma skonfigurowanego śledzenia lokalizacji w tle."
                } else if self.usesJourneyVoiceGuidance,
                          self.state.status == .navigating,
                          authorization != .authorizedAlways {
                    self.state.errorMessage = "Dostęp Zawsze pozwala prowadzić w podróży z odcinkiem komunikacji i odtwarzać ostrzeżenia przy zablokowanym ekranie."
                } else {
                    self.state.errorMessage = nil
                }
#else
                self.state.errorMessage = nil
#endif
            }
        }
        locationManager.onFailure = { [weak self] _ in
            guard self?.state.location == nil else { return }
            self?.state.gpsQuality = .noSignal
        }
        if let data = UserDefaults.standard.data(forKey: "routingPreferences"),
           let preferences = try? JSONDecoder().decode(RoutingPreferences.self, from: data) {
            state.routingPreferences = preferences
        }
    }
    func startLocation() {
        locationStartedAt = Date()
        locationManager.start()
        guard gpsWatchdog == nil else { return }
        gpsWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.checkGPS()
                if self.state.transportMode == .walking,
                   (self.state.status == .navigating || self.state.status == .rerouting) {
                    self.updateCameraIntent()
                }
                if self.usesJourneyVoiceGuidance,
                   (self.state.status == .navigating || self.state.status == .rerouting),
                   Date().timeIntervalSince(self.lastTransitProgressRefresh) >= 10 {
                    self.lastTransitProgressRefresh = Date()
                    self.updateProgress()
                }
                if let coordinate = self.state.location?.coordinate {
                    self.refreshTransitVehicles(near: coordinate)
                }
            }
        }
    }

    private func checkGPS() {
        guard let location = state.location else {
            if Date().timeIntervalSince(locationStartedAt) > 10 { state.gpsQuality = .noSignal }
            return
        }
        let age = Date().timeIntervalSince(lastAcceptedFix)
        if age > 30 {
            state.gpsQuality = .noSignal
            state.weakGPS = true
        } else if age > 5 {
            state.gpsQuality = .predicted
        }
        guard age > 5 else { return }
        state.weakGPS = true
        if state.status == .navigating || state.status == .rerouting {
            state.cameraLocation = CameraPlanner.predictedLocation(from: location, elapsed: age, route: state.route)
            updateNavigationCameraState()
        }
    }

    func updateProvider(_ provider: RouteProvider) {
        routeProvider = provider
        if let valhalla = provider as? ValhallaRouteProvider {
            transitProvider = LodzTransitRouteProvider(walkingRoutingEndpoint: valhalla.endpoint)
            speedLimitProvider = ValhallaSpeedLimitProvider(endpoint: valhalla.endpoint)
            invalidateSpeedLimit()
        }
    }
    func updateRoutingPreferences(_ preferences: RoutingPreferences) async {
        state.routingPreferences = preferences
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: "routingPreferences")
        }
        if state.status == .routePreview, let destination = state.destination { await preview(destination) }
    }
    func selectTransportMode(_ mode: TransportMode) async {
        guard state.status != .navigating && state.status != .rerouting else { return }
        state.transportMode = mode
        if mode != .transit && mode != .parkRide {
            state.journeyTimeMode = .now
        } else if mode == .parkRide && state.journeyTimeMode == .arriveBy {
            state.journeyTimeMode = .now
        }
        if mode != .transit { state.transitPlanningPhase = nil }
        if mode != .car { resetRoadSafetyData() }
        state.transitProgress = nil
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        if state.status == .destinationPreview { return }
        if let destination = state.destination { await preview(destination) }
    }

    private func applyConfiguredDefaultTransportMode() {
        let mode = TransportMode.configuredDefault
        state.transportMode = mode
        if mode != .transit && mode != .parkRide {
            state.journeyTimeMode = .now
        } else if mode == .parkRide && state.journeyTimeMode == .arriveBy {
            state.journeyTimeMode = .now
        }
    }

    func setJourneyTimeMode(_ mode: JourneyTimeMode) {
        guard mode != .arriveBy || state.transportMode == .transit else { return }
        state.journeyTimeMode = mode
        let now = Date()
        if mode == .now {
            state.journeyTargetTime = now
        } else if state.journeyTargetTime < now.addingTimeInterval(60) {
            state.journeyTargetTime = now.addingTimeInterval(3_600)
        }
        laterTransitRequestGeneration += 1
        state.isLoadingLaterTransitRoutes = false
        state.laterTransitRoutes = []
        state.didSearchLaterTransitRoutes = false
    }

    func setJourneyTargetTime(_ date: Date) {
        state.journeyTargetTime = date
        laterTransitRequestGeneration += 1
        state.isLoadingLaterTransitRoutes = false
        state.laterTransitRoutes = []
        state.didSearchLaterTransitRoutes = false
    }

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
    func estimatedCarRouteEstimate(to destination: Destination) async -> PlaceRouteEstimate? {
        guard let origin = state.location?.coordinate else { return nil }
        let target: Coordinate
        if destination.poi != nil {
            target = await POIAccessResolver.shared.resolve(for: destination, mode: .car)?.coordinate
                ?? destination.coordinate
        } else {
            target = destination.coordinate
        }
        do {
            if let provider = routeProvider as? AdvancedRouteProvider {
                let routes = try await provider.calculateRoutes(
                    from: origin, to: target, through: [], mode: .car,
                    preferences: state.routingPreferences, avoiding: [])
                guard let route = routes.first else { return nil }
                return PlaceRouteEstimate(minutes: max(1, Int(ceil(route.expectedTravelTime / 60))),
                                          distanceMeters: route.distance)
            }
            let routes = try await routeProvider.calculateRoutes(from: origin, to: target, mode: .car)
            guard let route = routes.first else { return nil }
            return PlaceRouteEstimate(minutes: max(1, Int(ceil(route.expectedTravelTime / 60))),
                                      distanceMeters: route.distance)
        } catch {
            return nil
        }
    }

    func selectDestination(_ destination: Destination, applyConfiguredMode: Bool = true) {
        let isEndingActiveTrip = state.status == .navigating || state.status == .rerouting
        if isEndingActiveTrip {
            finishTrip(arrived: false)
            voice.reset()
            locationManager.stopBackgroundNavigationUpdates()
            locationManager.setHeadingUpdatesEnabled(false)
            walkingCameraController.reset()
            state.deviceHeading = nil
        }
        invalidateAutomaticClosureReroute()
        rerouteGeneration &+= 1
        autoReroutedClosures.removeAll()
        automaticClosureRetryAfter.removeAll()
        requestGeneration += 1
        navigationTransitionTask?.cancel()
        navigationCameraProjectionTask?.cancel()
        navigationCameraUpdateTask?.cancel()
        if applyConfiguredMode { applyConfiguredDefaultTransportMode() }
        state.destination = destination
        state.navigationTarget = nil
        state.parkRideCarTarget = nil
        state.waypoints = []
        state.evChargingStops = []
        state.waypointNavigationTargets = [:]
        state.status = .destinationPreview
        state.cameraState = .destinationPreview
        updateCameraIntent()
        state.route = nil
        state.routeOptions = []
        state.transitPlanningPhase = nil
        resetRoadSafetyData()
        state.progress = nil
        state.transitProgress = nil
        state.routeMatch = nil
        previousRouteMatch = nil
        offRouteSince = nil
        routeProgressTracker.invalidateGeometries()
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        state.errorMessage = nil
        invalidateTraffic()
    }

    func setRouteOrigin(_ point: RoutePoint?) async {
        if let point {
            state.routeOrigin = point
        } else if let location = state.location {
            state.routeOrigin = RoutePoint(
                Destination(name: "Twoja lokalizacja", coordinate: location.coordinate),
                source: .currentLocation)
        } else {
            state.routeOrigin = nil
        }
        guard let destination = state.destination,
              state.status != .navigating, state.status != .rerouting else { return }
        await preview(destination)
    }

    func swapRoutePoints() async {
        guard let destination = state.destination,
              let previousOrigin = state.routeOrigin ?? state.location.map({
                  RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: $0.coordinate),
                             source: .currentLocation)
              }) else { return }
        let reversedWaypoints = Array(state.waypoints.reversed())
        let replacementOrigin = RoutePoint(destination, source: destination.poi == nil ? .search : .poi)
        state.routeOrigin = replacementOrigin
        selectDestination(previousOrigin.destination, applyConfiguredMode: false)
        state.routeOrigin = replacementOrigin
        state.waypoints = reversedWaypoints
        await preview(previousOrigin.destination)
    }

    func planRoute() async {
        guard let destination = state.destination else { return }
        guard routeOriginCoordinate != nil else {
            state.errorMessage = "Czekam na dokładną pozycję GPS."
            return
        }
        await preview(destination)
    }

    func addWaypoint(_ destination: Destination) async {
        guard state.transportMode == .car || state.transportMode == .walking || state.transportMode == .bicycle else {
            state.errorMessage = "Przystanki pośrednie są dostępne dla tras samochodowych, pieszych i rowerowych."
            return
        }
        guard state.waypoints.count < 8 else {
            state.errorMessage = "Możesz dodać maksymalnie 8 przystanków pośrednich."
            return
        }
        guard !state.waypoints.contains(where: { $0.coordinate == destination.coordinate }) else { return }
        let isActiveTrip = state.status == .navigating || state.status == .rerouting
        if isActiveTrip {
            state.waypoints.insert(destination, at: 0)
            tripSession?.waypoints.insert(destination, at: 0)
            if let origin = state.location?.coordinate { await reroute(from: origin) }
            return
        }

        state.waypoints.append(destination)
        if let final = state.destination { await preview(final) }
    }

    func removeWaypoint(_ id: UUID) async {
        state.waypoints.removeAll { $0.id == id }
        state.evChargingStops = []
        if let final = state.destination { await preview(final) }
    }

    func moveWaypoint(_ id: UUID, by offset: Int) async {
        guard let index = state.waypoints.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard state.waypoints.indices.contains(target) else { return }
        await reorderWaypoint(id, to: target)
    }

    func reorderWaypoint(_ id: UUID, to targetIndex: Int) async {
        guard let sourceIndex = state.waypoints.firstIndex(where: { $0.id == id }) else { return }
        let boundedTarget = min(max(0, targetIndex), state.waypoints.count - 1)
        guard sourceIndex != boundedTarget else { return }
        let waypoint = state.waypoints.remove(at: sourceIndex)
        state.waypoints.insert(waypoint, at: boundedTarget)
        state.evChargingStops = []
        if let final = state.destination { await preview(final) }
    }

    func optimizeWaypoints() async {
        guard state.waypoints.count >= 2, let destination = state.destination,
              let origin = await resolvedRouteOriginCoordinate(for: state.transportMode) else { return }
        guard state.transportMode == .car || state.transportMode == .walking || state.transportMode == .bicycle else {
            state.errorMessage = "Optymalizacja przystanków jest dostępna dla tras samochodowych, pieszych i rowerowych."
            return
        }
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            state.errorMessage = "Wybrany serwer nie obsługuje optymalizacji przystanków."
            return
        }
        do {
            let target = destinationRouteCoordinate(for: destination)
            let routedWaypoints = await routedDestinations(state.waypoints, mode: state.transportMode)
            let order = try await provider.optimizedWaypointOrder(from: origin, to: target,
                                                                 waypoints: routedWaypoints, mode: state.transportMode,
                                                                 preferences: state.routingPreferences)
            guard order.count == state.waypoints.count,
                  order.allSatisfy({ $0 >= 0 && $0 < state.waypoints.count }) else { throw RoutingError.invalidResponse }
            state.waypoints = order.map { state.waypoints[$0] }
            await preview(destination)
        } catch {
            state.errorMessage = "Nie udało się zoptymalizować kolejności: \(error.localizedDescription)"
        }
    }

    private var nearbySearchID = UUID()

    func searchNearbyPlaces(_ category: NearbyPlaceCategory, nearDestination: Bool = false,
                            searchRadius: Double = 5_000, resultLimit: Int = 25) async {
        let searchID = UUID()
        nearbySearchID = searchID
        state.nearbySuggestions = []
        let destination = state.destination
        guard !nearDestination || destination != nil else {
            state.nearbyStatus = .unavailable("Najpierw wybierz cel podróży.")
            return
        }
        let current = state.location?.coordinate
        let isNavigating = state.status == .navigating || state.status == .rerouting
        let nearestSearch = !nearDestination && !isNavigating
        var coordinates = state.route?.coordinates ?? []
        if isNavigating && !nearDestination {
            guard let current, let projection = MapMatcher.project(current, onto: coordinates) else {
                state.nearbyStatus = .unavailable("Czekam na pozycję GPS na aktywnej trasie.")
                return
            }
            coordinates = [projection.coordinate] + Array(coordinates.dropFirst(projection.segment + 1))
        }
        guard nearDestination || nearestSearch || coordinates.count > 1 else {
            state.nearbyStatus = .unavailable("Najpierw wyznacz trasę, aby znaleźć miejsca po drodze.")
            return
        }
        guard !nearestSearch || current != nil else {
            state.nearbyStatus = .unavailable("Poczekaj na ustalenie pozycji GPS i spróbuj ponownie.")
            return
        }
        let preferences = state.routingPreferences
        let pendingStopDestinations = current.map { unvisitedStops(from: $0) } ?? []
        state.nearbyStatus = .searching
        do {
            let candidates: [NearbyPlaceCandidate]
            if nearDestination, let destination {
                candidates = try await NearbyPlaceSearchProvider().search(
                    category, around: destination.coordinate, radius: 2_000, resultLimit: resultLimit)
            } else if nearestSearch, let current {
                candidates = try await NearbyPlaceSearchProvider().search(
                    category, around: current, radius: searchRadius, resultLimit: resultLimit)
            } else {
                candidates = try await OpenStreetMapNearbyPlaceProvider()
                    .search(category, along: coordinates, radius: 1_500)
            }
            try Task.checkCancellation()
            guard nearbySearchID == searchID else { return }
            state.nearbySuggestions = candidates.enumerated().map { index, candidate in
                RouteStopSuggestion(candidate: candidate,
                                    estimateStatus: nearestSearch && index < 8 ? .calculating : .unavailable)
            }
            state.nearbyStatus = .available
            if nearestSearch {
                guard let current, !candidates.isEmpty else { return }
                await estimateNearbyTravel(for: Array(candidates.prefix(8)), from: current,
                                           preferences: state.routingPreferences, searchID: searchID)
                return
            }
            guard !nearestSearch, !candidates.isEmpty, let destination, let current, state.transportMode == .car,
                  let provider = routeProvider as? AdvancedRouteProvider else { return }
            let destinationCoordinate = destinationRouteCoordinate(for: destination)
            let pendingStops = await routedDestinations(pendingStopDestinations, mode: .car).map(\.coordinate)
            let selected = Array(candidates.prefix(8))
            for index in selected.indices { state.nearbySuggestions[index].estimateStatus = .calculating }
            let resolvedSelected = await POIAccessResolver.shared.resolveMany(
                for: selected.map(\.destination), mode: .car)
            try Task.checkCancellation()
            guard nearbySearchID == searchID else { return }
            let routedSelected: [(selectedIndex: Int, candidate: NearbyPlaceCandidate, coordinate: Coordinate)] =
                selected.indices.compactMap { index in
                    if selected[index].destination.poi != nil {
                        return (index, selected[index], resolvedSelected[index]?.coordinate
                                ?? selected[index].destination.coordinate)
                    }
                    return (index, selected[index], selected[index].destination.coordinate)
                }
            guard !routedSelected.isEmpty else { return }
            do {
                if pendingStops.isEmpty, let matrix = provider as? ValhallaRouteProvider {
                    let targets = routedSelected.map { $0.coordinate }
                    async let outbound = matrix.searchMatrix(sources: [current], targets: targets + [destinationCoordinate],
                                                              mode: .car, preferences: preferences)
                    async let onward = matrix.searchMatrix(sources: targets, targets: [destinationCoordinate],
                                                           mode: .car, preferences: preferences)
                    let (first, second) = try await (outbound, onward)
                    try Task.checkCancellation()
                    guard nearbySearchID == searchID else { return }
                    if let baseline = first[0][targets.count].time {
                        for (rowIndex, routed) in routedSelected.enumerated() {
                            if let arrival = first[0][rowIndex].time,
                               let continuation = second[rowIndex][0].time {
                                state.nearbySuggestions[routed.selectedIndex].detourSeconds =
                                    max(0, arrival + continuation - baseline)
                            }
                        }
                    }
                } else {
                    let baseline = try await provider.calculateRoutes(from: current, to: destinationCoordinate,
                        through: pendingStops, mode: .car, preferences: preferences, avoiding: []).first?.expectedTravelTime
                    if let baseline {
                        // Limit server load while letting independent estimates complete together.
                        for start in stride(from: 0, to: routedSelected.count, by: 3) {
                            try Task.checkCancellation()
                            guard nearbySearchID == searchID else { return }
                            await withTaskGroup(of: (Int, Double?).self) { group in
                            for index in start..<min(start + 3, routedSelected.count) {
                                    let routed = routedSelected[index]
                                    group.addTask { @MainActor in
                                        do {
                                            let first = try await provider.calculateRoutes(from: current,
                                                to: routed.coordinate, through: nearDestination ? pendingStops : [],
                                                mode: .car, preferences: preferences, avoiding: []).first
                                            let second = nearDestination ? 0 : try await provider.calculateRoutes(
                                                from: routed.coordinate, to: destinationCoordinate,
                                                through: pendingStops, mode: .car, preferences: preferences, avoiding: []).first?.expectedTravelTime
                                            guard let first, let second else { return (index, nil) }
                                            return (index, max(0, first.expectedTravelTime + second - baseline))
                                        } catch { return (index, nil) }
                                    }
                                }
                                for await (index, detour) in group {
                                    guard nearbySearchID == searchID, !Task.isCancelled else { continue }
                                    let selectedIndex = routedSelected[index].selectedIndex
                                    state.nearbySuggestions[selectedIndex].detourSeconds = detour
                                    state.nearbySuggestions[selectedIndex].estimateStatus =
                                        detour == nil ? .unavailable : .notRequested
                                }
                            }
                        }
                    }
                }
            } catch {
                // A routing failure must never discard places already found.
            }
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
            for index in state.nearbySuggestions.indices {
                state.nearbySuggestions[index].estimateStatus = state.nearbySuggestions[index].detourSeconds == nil ? .unavailable : .notRequested
            }
            state.nearbySuggestions.sort { lhs, rhs in
                switch (lhs.detourSeconds, rhs.detourSeconds) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.candidate.distanceFromRoute < rhs.candidate.distanceFromRoute
                }
            }
        } catch {
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
            state.nearbyStatus = .unavailable(error.localizedDescription)
        }
    }

    func estimateNearbyTravel(for candidateID: String) async {
        guard let origin = state.location?.coordinate,
              let suggestion = state.nearbySuggestions.first(where: { $0.id == candidateID }),
              (suggestion.travelTime == nil || suggestion.travelDistance == nil) else { return }
        await estimateNearbyTravel(for: [suggestion.candidate], from: origin,
                                   preferences: state.routingPreferences, searchID: nearbySearchID)
    }

    private func estimateNearbyTravel(for candidates: [NearbyPlaceCandidate], from origin: Coordinate,
                                      preferences: RoutingPreferences, searchID: UUID) async {
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            for index in state.nearbySuggestions.indices {
                state.nearbySuggestions[index].estimateStatus = .unavailable
            }
            return
        }
        for candidate in candidates {
            guard let index = state.nearbySuggestions.firstIndex(where: { $0.id == candidate.id }) else { continue }
            state.nearbySuggestions[index].estimateStatus = .calculating
        }
        do {
            let poiIndexes = candidates.indices.filter { candidates[$0].destination.poi != nil }
            let poiDestinations = poiIndexes.map { candidates[$0].destination }
            let resolvedPOIs = await POIAccessResolver.shared.resolveMany(for: poiDestinations, mode: .car)
            try Task.checkCancellation()
            guard nearbySearchID == searchID else { return }
            var poiCoordinates: [Int: Coordinate] = [:]
            for (offset, index) in poiIndexes.enumerated() {
                poiCoordinates[index] = resolvedPOIs[offset]?.coordinate
                    ?? candidates[index].destination.coordinate
            }
            let routedCandidates: [(index: Int, candidate: NearbyPlaceCandidate, coordinate: Coordinate)] =
                candidates.indices.compactMap { index in
                    if candidates[index].destination.poi != nil {
                        return (index, candidates[index], poiCoordinates[index]
                                ?? candidates[index].destination.coordinate)
                    }
                    return (index, candidates[index], candidates[index].destination.coordinate)
                }
            guard !routedCandidates.isEmpty else { return }
            if let matrix = routeProvider as? ValhallaRouteProvider {
                let rows = try await matrix.searchMatrix(sources: [origin],
                    targets: routedCandidates.map { $0.coordinate }, mode: .car,
                    preferences: preferences)
                try Task.checkCancellation()
                guard nearbySearchID == searchID else { return }
                for (rowIndex, routed) in routedCandidates.enumerated() {
                    let estimate = rows[0][rowIndex]
                    guard let suggestionIndex = state.nearbySuggestions.firstIndex(where: { $0.id == routed.candidate.id }) else { continue }
                    state.nearbySuggestions[suggestionIndex].travelTime = estimate.time
                    state.nearbySuggestions[suggestionIndex].travelDistance = estimate.distance.map { $0 * 1_000 }
                }
            } else {
                for start in stride(from: 0, to: routedCandidates.count, by: 3) {
                    try Task.checkCancellation()
                    guard nearbySearchID == searchID else { return }
                    await withTaskGroup(of: (Int, TimeInterval?, Double?).self) { group in
                        for index in start..<min(start + 3, routedCandidates.count) {
                            let routed = routedCandidates[index]
                            group.addTask { @MainActor in
                                do {
                                    let route = try await provider.calculateRoutes(from: origin,
                                        to: routed.coordinate, through: [], mode: .car,
                                        preferences: preferences, avoiding: []).first
                                    return (index, route?.expectedTravelTime, route?.distance)
                                } catch {
                                    return (index, nil, nil)
                                }
                            }
                        }
                        for await (index, travelTime, travelDistance) in group {
                            guard nearbySearchID == searchID, !Task.isCancelled else { continue }
                            guard let suggestionIndex = state.nearbySuggestions.firstIndex(where: {
                                $0.id == routedCandidates[index].candidate.id
                            }) else { continue }
                            state.nearbySuggestions[suggestionIndex].travelTime = travelTime
                            state.nearbySuggestions[suggestionIndex].travelDistance = travelDistance
                        }
                    }
                }
            }
        } catch {
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
        }
        guard nearbySearchID == searchID, !Task.isCancelled else { return }
        for candidate in candidates {
            guard let index = state.nearbySuggestions.firstIndex(where: { $0.id == candidate.id }) else { continue }
            let suggestion = state.nearbySuggestions[index]
            state.nearbySuggestions[index].estimateStatus = suggestion.travelTime != nil && suggestion.travelDistance != nil
                ? .notRequested : .unavailable
        }
    }

    func selectNearbyPlace(_ destination: Destination, asFinalParking: Bool) async {
        let active = state.status == .navigating || state.status == .rerouting
        if !active && !asFinalParking {
            state.waypoints = []
            state.evChargingStops = []
            state.waypointNavigationTargets = [:]
            await preview(destination)
            return
        }
        if asFinalParking {
            if active, let location = state.location?.coordinate {
                let previousDestinationID = state.destination?.id
                let targets = await resolveAccessTargets(for: destination, mode: state.transportMode)
                guard (state.status == .navigating || state.status == .rerouting),
                      state.destination?.id == previousDestinationID else { return }
                state.destination = destination
                state.navigationTarget = targets.navigation
                state.parkRideCarTarget = targets.parkRideCar
                state.evChargingStops = []
                state.waypointNavigationTargets = [:]
                tripSession?.destination = destination
                await reroute(from: location)
            } else {
                state.evChargingStops = []
                state.waypointNavigationTargets = [:]
                await preview(destination)
            }
            return
        }
        if active, let location = state.location?.coordinate {
            state.waypoints.insert(destination, at: 0)
            tripSession?.waypoints.insert(destination, at: 0)
            await reroute(from: location)
        } else {
            await preview(destination)
        }
    }

    func previewNewTrip(_ destination: Destination) async {
        applyConfiguredDefaultTransportMode()
        await preview(destination)
    }

    func preview(_ destination: Destination) async {
        requestGeneration += 1
        let generation = requestGeneration
        let mode = state.transportMode
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
                    let deadline = requestedJourneyTime
                    var lowerDeparture = deadline.addingTimeInterval(-18 * 60 * 60)
                    var upperDeparture = deadline
                    var bestRoutes: [NavigationRoute] = []
                    for _ in 0..<10 {
                        guard generation == requestGeneration else { throw CancellationError() }
                        let interval = upperDeparture.timeIntervalSince(lowerDeparture)
                        guard interval > 60 else { break }
                        let departure = lowerDeparture.addingTimeInterval(interval / 2)
                        do {
                            let candidates = try await transitProvider.calculateRoutes(
                                from: origin, to: routeDestination, departingAt: departure,
                                onProgress: onProgress)
                            let eligible = candidates.filter { ($0.journey?.arrival ?? .distantFuture) <= deadline }
                                .sorted {
                                    let firstDeparture = $0.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantPast
                                    let secondDeparture = $1.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantPast
                                    if firstDeparture != secondDeparture { return firstDeparture > secondDeparture }
                                    return ($0.journey?.arrival ?? .distantFuture) < ($1.journey?.arrival ?? .distantFuture)
                                }
                            if let latest = eligible.first {
                                let latestDeparture = latest.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantPast
                                let previousBestDeparture = bestRoutes.first?.journey?.legs
                                    .first(where: { $0.mode != "WALK" })?.departure ?? .distantPast
                                let latestArrival = latest.journey?.arrival ?? .distantFuture
                                let previousBestArrival = bestRoutes.first?.journey?.arrival ?? .distantFuture
                                if latestDeparture > previousBestDeparture
                                    || (latestDeparture == previousBestDeparture && latestArrival < previousBestArrival) {
                                    bestRoutes = eligible
                                }
                                lowerDeparture = departure
                            } else {
                                upperDeparture = departure
                            }
                        } catch TransitRoutingError.noJourney {
                            upperDeparture = departure
                        }
                    }
                    guard !bestRoutes.isEmpty else { throw TransitRoutingError.noJourneyBeforeArrivalDeadline }
                    routes = bestRoutes
                    onProvisionalTransitRoutes(routes, generation: generation)
                } else {
                    let departure = requestedJourneyTimeMode == .departAt ? requestedJourneyTime : Date()
                    routes = try await transitProvider.calculateRoutes(
                        from: origin, to: routeDestination, departingAt: departure,
                        onProgress: onProgress,
                        onProvisionalRoutes: { [weak self] routes in
                            self?.onProvisionalTransitRoutes(routes, generation: generation)
                        })
                }
            } else if state.transportMode == .parkRide {
                let departure = requestedJourneyTimeMode == .departAt ? requestedJourneyTime : Date()
                routes = try await calculateParkRideRoutes(from: origin, to: routeDestination,
                                                            departingAt: departure)
            } else {
                routes = try await calculateRoutes(from: origin, to: routeDestination)
            }
            guard generation == requestGeneration else { return }
            guard let firstRoute = routes.first else { throw RoutingError.invalidResponse }
            state.route = firstRoute
            state.routeOptions = routes
            state.status = .routePreview
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

    private var routeOriginCoordinate: Coordinate? {
        if let origin = state.routeOrigin, !origin.isCurrentLocation { return origin.coordinate }
        return state.location?.coordinate
    }

    private func resolvedRouteOriginCoordinate(for mode: TransportMode) async -> Coordinate? {
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
        state.transitPlanningPhase = .enrichingGeometry
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

    func select(_ route: NavigationRoute) {
        guard state.status == .routePreview,
              state.transitPlanningPhase != .enrichingGeometry,
              state.route?.id != route.id,
              let selectedRoute = state.routeOptions.first(where: { $0.id == route.id }) else { return }
        laterTransitRequestGeneration += 1
        state.isLoadingLaterTransitRoutes = false
        state.laterTransitRoutes = []
        state.didSearchLaterTransitRoutes = false
        state.route = selectedRoute
        state.evChargingStops = selectedRoute.chargingStops.map(\.destination)
        if usesRoadVoiceGuidance { loadRoadData(for: selectedRoute) }
        state.transitProgress = nil
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        updateCameraIntent()
        invalidateTraffic()
        updateProgress()
        if state.transportMode == .car { refreshTraffic(force: true) }
    }
    func setVoiceEnabled(_ enabled: Bool) {
        var preferences = state.voicePreferences
        preferences.isEnabled = enabled
        setVoicePreferences(preferences)
    }
    func setVoicePreferences(_ preferences: VoiceGuidancePreferences) {
        state.voicePreferences = preferences
        voice.updatePreferences(preferences)
    }
    func begin() {
        guard state.transitPlanningPhase != .enrichingGeometry,
              let route = state.route,
              (!usesJourneyVoiceGuidance || route.journey != nil) else { return }
        invalidateAutomaticClosureReroute()
        rerouteGeneration &+= 1
        autoReroutedClosures.removeAll()
        automaticClosureRetryAfter.removeAll()
        offRouteSince = nil
        lastReroute = .distantPast
        navigationCameraProjectionTask?.cancel()
        navigationCameraUpdateTask?.cancel()
        revealTask?.cancel()
        state.routeRevealProgress = 1
        voice.reset()
        resetTransitRideConfirmation()
        cameraManeuverID = state.progress?.nextManeuver?.id
        maneuverTransitionTask?.cancel()
        routeProgressTracker.resetDisplayedGeometryProgress()
        if var progress = state.progress {
            progress.geometryProgress = 0
            progress.geometryRouteID = route.id
            state.progress = progress
        }
        state.status = .navigating
        state.cameraState = .startingNavigation
        walkingCameraController.reset()
        locationManager.setHeadingUpdatesEnabled(state.transportMode == .walking)
        if state.transportMode == .walking {
            walkingCameraController.update(location: state.location,
                                           deviceHeading: state.deviceHeading)
        }
        if usesJourneyVoiceGuidance {
            state.transitBackgroundLocationAvailable = locationManager.requestTransitBackgroundAuthorization()
            if !locationManager.backgroundLocationModeEnabled {
                state.errorMessage = "Aplikacja nie ma skonfigurowanego śledzenia lokalizacji w tle."
            }
        }
        if usesJourneyVoiceGuidance { updateProgress(reuseJourneyMatch: true) }
        prepareNavigationCamera(for: route)
        navigationTransitionTask?.cancel()
        navigationTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self else { return }
            await self.navigationCameraUpdateTask?.value
            guard !Task.isCancelled, self.state.status == .navigating else { return }
            self.updateNavigationCameraState()
        }
        if let destination = state.destination, let route = state.route {
            tripSession = TripSession(destination: destination, waypoints: state.waypoints,
                                      originalExpectedTravelTime: route.expectedTravelTime,
                                      startedAt: Date(), lastLocation: state.location)
        }
        invalidateSpeedLimit()
        if state.transportMode == .car {
            let hasFreshRouteTraffic = routeTrafficDataAvailable
                && Date().timeIntervalSince(routeTrafficUpdatedAt ?? .distantPast) <= 120
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.state.status == .navigating,
                      self.state.route?.id == route.id else { return }
                // Start traffic work after the navigation UI has had a chance to render.
                // Reuse the preview's fresh corridor response when it is still current.
                self.refreshTraffic(force: true, forceRouteRefresh: !hasFreshRouteTraffic)
            }
        }
    }
    func stop() {
        finishTrip(arrived: state.status == .arrived)
        invalidateAutomaticClosureReroute()
        rerouteGeneration &+= 1
        autoReroutedClosures.removeAll()
        automaticClosureRetryAfter.removeAll()
        requestGeneration += 1
        laterTransitRequestGeneration += 1
        invalidateTraffic()
        invalidateSpeedLimit()
        voice.reset()
        state.route = nil; state.routeOptions = []; state.progress = nil; state.destination = nil
        state.navigationTarget = nil; state.parkRideCarTarget = nil
        state.laterTransitRoutes = []
        state.isLoadingLaterTransitRoutes = false
        state.didSearchLaterTransitRoutes = false
        state.transitPlanningPhase = nil
        resetRoadSafetyData()
        state.transitProgress = nil
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        locationManager.stopBackgroundNavigationUpdates()
        locationManager.setHeadingUpdatesEnabled(false)
        walkingCameraController.reset()
        state.deviceHeading = nil
        state.routeOriginMapSelectionActive = false
        state.routeOrigin = state.location.map {
            RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: $0.coordinate),
                       source: .currentLocation)
        }
        state.waypoints = []
        state.evChargingStops = []
        state.waypointNavigationTargets = [:]
        state.weakGPS = false
        state.gpsQuality = .noSignal
        cameraManeuverID = nil
        revealTask?.cancel()
        navigationTransitionTask?.cancel()
        navigationCameraProjectionTask?.cancel()
        navigationCameraUpdateTask?.cancel()
        maneuverTransitionTask?.cancel()
        state.status = .idle; state.cameraState = .browse
        updateCameraIntent()
        state.traffic = nil
        offRouteSince = nil
        previousRouteMatch = nil
        routeProgressTracker.invalidateTransitGeometry()
        state.routeMatch = nil
        routeProgressTracker.invalidateRoadGeometry()
        projectedFlowRouteID = nil
        projectedFlowUpdatedAt = nil
        projectedFlowCoordinates = []
        projectedFlowDistanceRange = nil
        projectedChargingRouteID = nil
        projectedChargingCoordinates = []
        projectedChargingDistances = []
        routeProgressTracker.resetDisplayedGeometryProgress()
        refreshTraffic(force: true)
        
    }
    private func receive(_ raw: CLLocation) {
        guard filter.accept(raw, mode: state.transportMode) else { return }
        let coordinate = Coordinate(latitude: raw.coordinate.latitude, longitude: raw.coordinate.longitude)
        state.location = NavigationLocation(coordinate: coordinate, speed: raw.speed, course: raw.course,
                                            accuracy: raw.horizontalAccuracy, timestamp: raw.timestamp,
                                            speedAccuracy: raw.speedAccuracy,
                                            courseAccuracy: raw.courseAccuracy)
        if state.routeOrigin == nil || state.routeOrigin?.isCurrentLocation == true {
            state.routeOrigin = RoutePoint(
                Destination(name: "Twoja lokalizacja", coordinate: coordinate),
                source: .currentLocation)
        }
        state.cameraLocation = state.location
        lastAcceptedFix = raw.timestamp
        state.weakGPS = false
        state.gpsQuality = raw.horizontalAccuracy <= 10 ? .excellent : (raw.horizontalAccuracy <= 35 ? .good : .weak)
        tripSession?.record(state.location!)
        updateProgress()
        if state.transportMode == .walking,
           (state.status == .navigating || state.status == .rerouting) {
            walkingCameraController.update(location: state.cameraLocation,
                                           deviceHeading: state.deviceHeading)
        }
        if state.status == .idle || state.status == .destinationPreview || state.status == .routeCalculating {
            updateCameraIntent()
        }
        if state.status == .navigating || state.status == .rerouting {
            if state.cameraState != .startingNavigation { updateNavigationCameraState() }
            if state.transportMode == .car ||
                (state.transportMode == .parkRide && state.transitProgress?.legIndex == 0) {
                refreshSpeedLimit(for: state.location!)
            }
        }
        if state.transportMode == .car { refreshTraffic() }
    }
    func invalidateTraffic() {
        trafficGeneration += 1
        trafficRequestInFlight = false
        routeTrafficRequestInFlight = false
        lastTrafficFetch = .distantPast
        lastRouteTrafficFetch = .distantPast
        lastRouteFlowFetch = .distantPast
        routeFlowRouteID = nil
        latestNearbyTrafficSnapshot = nil
        routeTrafficIncidents = []
        routeTrafficDataAvailable = false
        routeTrafficUpdatedAt = nil
        routeTrafficFlowSegments = []
        routeTrafficFlowUpdatedAt = nil
        state.traffic = nil
    }
    func invalidateSpeedLimit() {
        speedLimitGeneration += 1
        speedLimitRequestInFlight = false
        lastSpeedLimitFetch = .distantPast
        state.speedLimitKph = nil
        state.speedLimitSource = nil
        state.speedLimitMessage = nil
    }
    func refreshSpeedLimit(for location: NavigationLocation, force: Bool = false) {
        if let snapshot = roadDataSnapshot {
            if let result = snapshot.speedLimit(at: location) {
                state.speedLimitKph = result.speedKph
                state.speedLimitSource = result.source
                state.speedLimitMessage = nil
                return
            }
            if snapshot.shouldSuppressRoutingFallback(at: location) {
                state.speedLimitKph = nil
                state.speedLimitSource = nil
                state.speedLimitMessage = "Nie można ustalić aktywnego limitu z danych warunkowych."
                return
            }
            state.speedLimitKph = nil
            state.speedLimitSource = nil
            state.speedLimitMessage = "Limit OSM nie pasuje do bieżącej drogi; sprawdzam dane trasy."
        }
        guard !speedLimitRequestInFlight,
              force || Date().timeIntervalSince(lastSpeedLimitFetch) >= 10 else { return }
        speedLimitRequestInFlight = true
        lastSpeedLimitFetch = Date()
        let generation = speedLimitGeneration
        let provider = speedLimitProvider
        Task {
            defer { if generation == speedLimitGeneration { speedLimitRequestInFlight = false } }
            do {
                let value = try await provider.limit(at: location.coordinate, heading: location.course)
                guard generation == speedLimitGeneration, state.status == .navigating || state.status == .rerouting else { return }
                guard let currentLocation = state.location,
                      currentLocation.coordinate.distance(to: location.coordinate) <= max(30, min(80, currentLocation.accuracy)) else {
                    lastSpeedLimitFetch = .distantPast
                    return
                }
                state.speedLimitKph = value
                state.speedLimitSource = value == nil ? nil : .routingProvider
                state.speedLimitMessage = value == nil ? "Brak limitu w danych drogi." : nil
            } catch {
                guard generation == speedLimitGeneration else { return }
                state.speedLimitKph = nil
                state.speedLimitSource = nil
                state.speedLimitMessage = "Limit niedostępny: \(error.localizedDescription)"
            }
        }
    }

    func loadRoadData(for route: NavigationRoute) {
        guard usesRoadVoiceGuidance else { return }
        let roadCoordinates: [Coordinate]
        if state.transportMode == .parkRide {
            roadCoordinates = route.journey?.legs.first(where: { $0.mode.uppercased() == "CAR" })?.coordinates ?? []
        } else {
            roadCoordinates = route.coordinates
        }
        guard roadCoordinates.count > 1 else { return }
        roadDataGeneration &+= 1
        let generation = roadDataGeneration
        let routeID = route.id
        let provider = roadDataProvider
        roadDataSnapshot = nil
        state.roadSafetyAlerts = []
        state.roadSafetyStatus = .loading
        invalidateSpeedLimit()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await provider.load(for: roadCoordinates)
                guard generation == self.roadDataGeneration,
                      self.state.route?.id == routeID,
                      self.usesRoadVoiceGuidance else { return }
                self.invalidateSpeedLimit()
                self.roadDataSnapshot = snapshot
                self.state.roadSafetyAlerts = snapshot.matchedAlerts(on: roadCoordinates)
                self.state.roadSafetyStatus = .available
                self.updateProgress()
                if let location = self.state.location,
                   self.state.status == .navigating || self.state.status == .rerouting,
                   self.state.transportMode == .car ||
                    (self.state.transportMode == .parkRide && self.state.transitProgress?.legIndex == 0) {
                    self.refreshSpeedLimit(for: location, force: true)
                }
            } catch {
                guard generation == self.roadDataGeneration,
                      self.state.route?.id == routeID,
                      self.usesRoadVoiceGuidance else { return }
                self.roadDataSnapshot = nil
                self.state.roadSafetyAlerts = []
                self.state.roadSafetyStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    private func resetRoadSafetyData() {
        roadDataGeneration &+= 1
        roadDataSnapshot = nil
        state.roadSafetyAlerts = []
        state.roadSafetyStatus = .idle
        invalidateSpeedLimit()
    }
    func finishTrip(arrived: Bool) {
        guard let session = tripSession else { return }
        tripSession = nil
        let record = TripRecord(destination: session.destination, waypoints: session.waypoints,
                                startedAt: session.startedAt,
                                endedAt: Date(), distanceMeters: session.distanceMeters,
                                movingSeconds: session.movingSeconds, rerouteCount: session.rerouteCount, arrived: arrived,
                                originalExpectedTravelTime: session.originalExpectedTravelTime)
        state.lastTrip = record
        onTripFinished?(record)
    }


}

private extension ArraySlice where Element == Coordinate {
    func adjacentDistance() -> Double { zip(self, dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
}


struct TripSession {
    var destination: Destination
    var waypoints: [Destination]
    let originalExpectedTravelTime: TimeInterval
    let startedAt: Date
    var lastLocation: NavigationLocation?
    var distanceMeters = 0.0
    var movingSeconds: TimeInterval = 0
    var rerouteCount = 0

    mutating func record(_ location: NavigationLocation) {
        defer { lastLocation = location }
        guard let previous = lastLocation else { return }
        let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
        guard seconds > 0, seconds <= 30 else { return }
        let distance = previous.coordinate.distance(to: location.coordinate)
        guard distance <= max(30, seconds * 60) else { return }
        if location.speed >= 0.5 {
            movingSeconds += seconds
            distanceMeters += distance
        }
    }
}
