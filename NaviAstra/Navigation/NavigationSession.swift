import CoreLocation
import Foundation

@MainActor
final class NavigationSession {
    let state = NavigationState()
    lazy var mapCameraController = MapCameraController(
        state: state,
        routeMatchProvider: { [weak self] in self?.previousRouteMatch },
        refreshTransitVehicles: { [weak self] in self?.refreshTransitVehicles(near: $0) })
    let rerouteController = RerouteController()
    let locationManager = LocationManager()
    let energyPolicyEngine = EnergyPolicyEngine()
    let voice: VoiceGuidanceEngine
    var usesJourneyVoiceGuidance: Bool {
        state.transportMode == .transit || state.transportMode == .parkRide
    }
    var usesRoadVoiceGuidance: Bool {
        state.transportMode == .car || state.transportMode == .parkRide
    }
    private var filter = LocationFilter()
    var offRouteDetector = OffRouteDetector()
    var previousRouteMatch: (routeID: UUID, projection: RouteProjection, timestamp: Date)?
    var routeProgressTracker = RouteProgressTracker()
    private var lastAcceptedFix = Date.distantPast
    private var locationStartedAt = Date.distantPast
    private var gpsWatchdog: Task<Void, Never>?
    private var appIsForeground = true
    private var didStartLocation = false
    var navigationTransitionTask: Task<Void, Never>?
    var routeProvider: RouteProvider
    var transitProvider: TransitRouteProviding
    var requestGeneration = 0
    var laterTransitRequestGeneration = 0
    var nearbySearchID = UUID()
    var trafficGeneration = 0
    private var speedLimitGeneration = 0
    private var roadDataGeneration = 0
    var lastTrafficFetch = Date.distantPast
    private var lastSpeedLimitFetch = Date.distantPast
    var lastTransitVehiclesFetch = Date.distantPast
    private var lastTransitProgressRefresh = Date.distantPast
    var lastTransitPlanRefresh = Date.distantPast
    var transitPlanRefreshInFlight = false
    var lastTransitProgressLegIndex: Int?
    var transitVehiclesRequestInFlight = false
    var transitVehiclesGeneration = 0
    var insideTransitCoverage = false
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
    let trafficProviderFactory: TrafficProviderFactory
    var transitTripDetails: TransitTripDetails?
    var transitTripDetailsID: String?
    var transitRideTrackingID: String?
    var confirmedTransitTripID: String?
    var transitRideMotionEvidence = 0
    var lastTransitRideDistance = 0.0
    var tripSession: TripSession?
    var onTripFinished: ((TripRecord) -> Void)?

    init(dependencies: NavigationSessionDependencies) {
        routeProvider = dependencies.routeProvider
        transitProvider = dependencies.transitProvider
        speedLimitProvider = dependencies.speedLimitProvider
        roadDataProvider = dependencies.roadDataProvider
        trafficProvider = dependencies.trafficProvider
        trafficProviderFactory = dependencies.trafficProviderFactory
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
            self.mapCameraController.updateWalkingCamera(
                location: self.state.cameraLocation ?? self.state.location,
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
            self.refreshEnergyPolicy()
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
        didStartLocation = true
        locationStartedAt = Date()
        locationManager.prepareAuthorization()
        refreshEnergyPolicy()
    }

    func setAppIsForeground(_ isForeground: Bool) {
        guard appIsForeground != isForeground else { return }
        appIsForeground = isForeground
        refreshEnergyPolicy()
    }

    func refreshEnergyPolicy() {
        let previousPolicy = energyPolicyEngine.currentPolicy
        let policy = energyPolicyEngine.update(
            navigationStatus: state.status,
            transportMode: state.transportMode,
            appIsForeground: appIsForeground,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            speedMetersPerSecond: state.location?.speed)
        guard didStartLocation else { return }
        if previousPolicy.location != policy.location { locationStartedAt = Date() }
        locationManager.apply(policy.location)

        let isNavigationActive = state.status == .navigating || state.status == .rerouting
        if isNavigationActive, gpsWatchdog == nil {
            gpsWatchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    guard self.state.status == .navigating || self.state.status == .rerouting else { return }
                    self.checkGPS()
                    if self.state.transportMode == .walking {
                        self.updateCameraIntent()
                    }
                    if self.usesJourneyVoiceGuidance,
                       Date().timeIntervalSince(self.lastTransitProgressRefresh) >= 10 {
                        self.lastTransitProgressRefresh = Date()
                        self.updateProgress()
                    }
                    if self.energyPolicyEngine.currentPolicy.transitRefreshInterval != nil,
                       let coordinate = self.state.location?.coordinate {
                        self.refreshTransitVehicles(near: coordinate)
                    }
                }
            }
        } else if !isNavigationActive, let gpsWatchdog {
            gpsWatchdog.cancel()
            self.gpsWatchdog = nil
        }
    }

    func resetOffRouteEvidence() {
        offRouteDetector.reset()
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

    func updateRoutingDependencies(_ dependencies: NavigationRoutingDependencies) {
        routeProvider = dependencies.routeProvider
        transitProvider = dependencies.transitProvider
        speedLimitProvider = dependencies.speedLimitProvider
        invalidateSpeedLimit()
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

    func applyConfiguredDefaultTransportMode() {
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
        guard state.status == .routePreview,
              state.transitPlanningPhase != .enrichingGeometry,
              let route = state.route,
              (!usesJourneyVoiceGuidance || route.journey != nil) else { return }
        rerouteController.beginNavigation()
        resetOffRouteEvidence()
        mapCameraController.cancelNavigationCameraTasks()
        mapCameraController.cancelRouteReveal()
        state.routeRevealProgress = 1
        voice.reset()
        resetTransitRideConfirmation()
        mapCameraController.setCurrentManeuver(state.progress?.nextManeuver?.id)
        mapCameraController.cancelManeuverTransition()
        routeProgressTracker.resetDisplayedGeometryProgress()
        if var progress = state.progress {
            progress.geometryProgress = 0
            progress.geometryRouteID = route.id
            state.progress = progress
        }
        state.status = .navigating
        state.cameraState = .startingNavigation
        refreshEnergyPolicy()
        mapCameraController.resetWalkingCamera()
        locationManager.setHeadingUpdatesEnabled(state.transportMode == .walking)
        if state.transportMode == .walking {
            mapCameraController.updateWalkingCamera(location: state.location,
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
        let hasFreshRouteTraffic = state.transportMode == .car && routeTrafficDataAvailable
            && Date().timeIntervalSince(routeTrafficUpdatedAt ?? .distantPast) <= 120
        navigationTransitionTask?.cancel()
        let cameraTransitionDelay = state.transportMode == .transit || state.transportMode == .parkRide
            ? 400 : 450
        navigationTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(cameraTransitionDelay))
            guard !Task.isCancelled, let self else { return }
            await self.mapCameraController.waitForNavigationCameraUpdate()
            guard !Task.isCancelled, self.state.status == .navigating else { return }
            self.updateNavigationCameraState()
            if self.state.transportMode == .car {
                self.refreshTraffic(force: true, forceRouteRefresh: !hasFreshRouteTraffic)
            }
        }
        if let destination = state.destination, let route = state.route {
            tripSession = TripSession(destination: destination, waypoints: state.waypoints,
                                      originalExpectedTravelTime: route.expectedTravelTime,
                                      startedAt: Date(), lastLocation: state.location)
        }
        invalidateSpeedLimit()
    }
    func stop() {
        guard state.status != .idle else { return }
        finishTrip(arrived: state.status == .arrived)
        rerouteController.stop()
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
        mapCameraController.resetWalkingCamera()
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
        mapCameraController.setCurrentManeuver(nil)
        mapCameraController.cancelRouteReveal()
        navigationTransitionTask?.cancel()
        mapCameraController.cancelNavigationCameraTasks()
        mapCameraController.cancelManeuverTransition()
        state.status = .idle; state.cameraState = .browse
        refreshEnergyPolicy()
        updateCameraIntent()
        state.traffic = nil
        resetOffRouteEvidence()
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
            mapCameraController.updateWalkingCamera(location: state.cameraLocation,
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
        refreshEnergyPolicy()
        if state.transportMode == .car || state.transportMode == .parkRide { refreshTraffic() }
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

    func resetRoadSafetyData() {
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
