import CoreLocation
import Foundation

@MainActor
final class NavigationSession {
    let state = NavigationState()
    var plannedTripCalculation = false
    var selectedVehicleID: (() -> UUID?)?
    lazy var mapCameraController = MapCameraController(
        state: state,
        routeMatchProvider: { [weak self] in self?.previousRouteMatch },
        routeGeometryProvider: { [weak self] route in
            guard let self else { return RouteProgressGeometry(route) }
            return self.routeProgressTracker.cameraGeometry(for: route)
        },
        refreshTransitVehicles: { [weak self] in self?.refreshTransitVehicles(near: $0) })
    let rerouteController = RerouteController()
    let locationManager = LocationManager()
    let energyPolicyEngine = EnergyPolicyEngine()
    let voice: VoiceGuidanceEngine
    var usesJourneyVoiceGuidance: Bool {
        state.transportMode == .transit
    }
    var usesRoadVoiceGuidance: Bool {
        state.transportMode == .car
    }
    private var filter = LocationFilter()
    var offRouteDetector = OffRouteDetector()
    var previousRouteMatch: (routeID: UUID, projection: RouteProjection, timestamp: Date)?
    var routeProgressTracker = RouteProgressTracker()
    private var lastAcceptedFix = Date.distantPast
    private var locationStartedAt = Date.distantPast
    private var gpsWatchdog: Task<Void, Never>?
    var appIsForeground = true
    var arrivalDetector = ArrivalDetector()
    let liveActivity = NavigationLiveActivityManager()
    private var didStartLocation = false
    var navigationTransitionTask: Task<Void, Never>?
    var routeProvider: RouteProvider
    var transitProvider: TransitRouteProvider
    let transitDataProvider: TransitDataProviding
    var transitPlanningCancellationToken: TransitPlanningCancellationToken?
    var transitRefreshCancellationToken: TransitPlanningCancellationToken?
    var laterTransitPlanningCancellationToken: TransitPlanningCancellationToken?
    var roadPlanningCancellationToken: TransitPlanningCancellationToken?
    var roadRerouteCancellationToken: TransitPlanningCancellationToken?
    var trafficComparisonInFlight = false
    var lastTrafficComparison = Date.distantPast
    var trafficComparisonTask: Task<Void, Never>?
    var trafficCandidateCancellationToken: TransitPlanningCancellationToken?
    var lastTrafficCandidateRefresh = Date.distantPast
    var roadETAPaceTracker = RoadETAPaceTracker()
    var knownRoadClosures: [String: ConfirmedRoadClosure] = [:]
    var evBatteryEstimate: EVBatteryEstimate?
    var requestGeneration = 0 {
        didSet {
            roadPlanningCancellationToken?.cancel()
            roadRerouteCancellationToken?.cancel()
            transitPlanningCancellationToken?.cancel()
            transitRefreshCancellationToken?.cancel()
            laterTransitPlanningCancellationToken?.cancel()
        }
    }
    var laterTransitRequestGeneration = 0 {
        didSet { laterTransitPlanningCancellationToken?.cancel() }
    }
    var nearbySearchID = UUID()
    var trafficGeneration = 0
    var trafficRouteSelectionGeneration = 0
    private var speedLimitGeneration = 0
    private var speedLimitTask: Task<Void, Never>?
    private var nearbySpeedLimitTask: Task<Void, Never>?
    private var nearbySpeedLimitSnapshot: RoadDataSnapshot?
    private var nearbySpeedLimitCenter: Coordinate?
    private var speedLimitBufferGeometry: RouteProgressGeometry?
    private var speedLimitBufferEndDistance: Double?
    private var speedLimitBufferRouteID: UUID?
    private var nearbySpeedLimitFailures = 0
    private var lastNearbySpeedLimitFetch = Date.distantPast
    private var roadDataTask: Task<Void, Never>?
    private var roadDataGeneration = 0
    var lastTrafficFetch = Date.distantPast
    private var lastSpeedLimitFetch = Date.distantPast
    private var speedLimitObservationLocation: Coordinate?
    private var speedLimitReading: SpeedLimitReading?
    private var speedLimitReadingDate = Date.distantPast
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
    var routeTrafficColorSegments: [RouteTrafficSegment] = []
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
    var onTripCheckpoint: ((TripRecord) -> Void)?
    var onHistoryMaintenance: (() -> Void)?
    private var lastTripCheckpointAt = Date.distantPast
    var learningOriginalRoute: NavigationRoute?
    var learningContext: DrivingPreferenceContext?
    var learningCosting = "auto"
    var learningAllowsDeviations = true
    var learningTrafficCheckedAt: Date?
    var learningRecordingGeneration: Int?
    var learningOfferedRoutes: [NavigationRoute] = []
    var learningSelectedRouteID: UUID?
    var learningExplicitlySelectedRouteID: UUID?
    var learningSelectedAgainstAlternative = false

    init(dependencies: NavigationSessionDependencies) {
        routeProvider = dependencies.routeProvider
        transitProvider = dependencies.transitProvider
        transitDataProvider = dependencies.transitDataProvider
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
            guard self.appIsForeground else { return }
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
        guard !didStartLocation else { return }
        didStartLocation = true
        locationStartedAt = Date()
        locationManager.prepareAuthorization()
        if let provider = routeProvider as? ValhallaRouteProvider {
            DrivingLearningEngine.shared.processPending(endpoint: provider.endpoint)
        }
        refreshEnergyPolicy()
    }

    func setAppIsForeground(_ isForeground: Bool) {
        guard appIsForeground != isForeground else { return }
        appIsForeground = isForeground
        if !isForeground {
            checkpointTrip(force: true)
            mapCameraController.cancelNavigationCameraTasks()
            mapCameraController.cancelManeuverTransition()
            mapCameraController.cancelRouteReveal()
            navigationTransitionTask?.cancel()
            state.routeRevealProgress = 1
            if state.cameraState == .startingNavigation || state.cameraState == .leavingManeuver {
                state.cameraState = .followNavigation
            }
        }
        refreshEnergyPolicy()
        if isForeground {
            onHistoryMaintenance?()
            if state.status == .navigating || state.status == .rerouting {
                updateNavigationCameraState(force: true)
            }
            updateCameraIntent()
        }
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
        locationManager.apply(policy.location, appIsForeground: appIsForeground)

        let isNavigationActive = state.status == .navigating || state.status == .rerouting
        if isNavigationActive, gpsWatchdog == nil {
            gpsWatchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    guard self.state.status == .navigating || self.state.status == .rerouting else { return }
                    self.checkGPS()
                    self.checkpointTrip()
                    self.updateLiveActivity()
                    self.refreshTraffic()
                    if self.appIsForeground, self.state.transportMode == .walking {
                        self.updateCameraIntent()
                    }
                    if self.usesJourneyVoiceGuidance,
                       Date().timeIntervalSince(self.lastTransitProgressRefresh) >= 10 {
                        self.lastTransitProgressRefresh = Date()
                        self.updateProgress()
                    }
                    if self.appIsForeground, self.energyPolicyEngine.currentPolicy.transitRefreshInterval != nil,
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
            guard appIsForeground else { return }
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
        let previous = state.routingPreferences
        let estimatedPercent = tripSession.flatMap { trip in
            evBatteryEstimate?.batteryPercent(at: trip.distanceMeters)
        }
        state.routingPreferences = preferences
        if tripSession != nil {
            if previous.evBatteryPercent != preferences.evBatteryPercent {
                evBatteryEstimate = state.transportMode == .car
                    ? EVBatteryEstimate(fullRangeMeters: preferences.evRangeKilometers * 1_000,
                        batteryPercent: Double(preferences.evBatteryPercent),
                        tripDistance: tripSession?.distanceMeters ?? 0) : nil
            } else if previous.evRangeKilometers != preferences.evRangeKilometers {
                if let estimatedPercent {
                    evBatteryEstimate = EVBatteryEstimate(fullRangeMeters: preferences.evRangeKilometers * 1_000,
                        batteryPercent: estimatedPercent, tripDistance: tripSession?.distanceMeters ?? 0)
                }
            }
            if preferences.evPlanningEnabled, evBatteryEstimate == nil { resetEVBatteryEstimate() }
            // Disabling planning does not replenish the battery. Distance keeps
            // accumulating against the last confirmed observation while hidden.
            publishEVBatteryEstimate()
        }
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: "routingPreferences")
        }
        if state.status == .routePreview, let destination = state.destination { await preview(destination) }
    }
    func selectTransportMode(_ mode: TransportMode) async {
        guard state.status != .navigating && state.status != .rerouting else { return }
        state.transportMode = mode
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
    }

    func setJourneyTimeMode(_ mode: JourneyTimeMode) {
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
              state.route?.id != route.id,
              let selectedRoute = state.routeOptions.first(where: { $0.id == route.id }) else { return }
        laterTransitRequestGeneration += 1
        state.isLoadingLaterTransitRoutes = false
        state.laterTransitRoutes = []
        state.didSearchLaterTransitRoutes = false
        state.route = selectedRoute
        learningExplicitlySelectedRouteID = selectedRoute.id
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
              let route = state.route,
              (!usesJourneyVoiceGuidance || route.journey != nil) else { return }
        // A new start must never replace an uncommitted recording.
        if tripSession != nil { finishTrip(arrived: false, reason: .replaced) }
        if !usesJourneyVoiceGuidance, state.journeyTimeMode != .now, let destination = state.destination {
            state.journeyTimeMode = .now
            Task {
                await preview(destination)
                guard state.status == .routePreview, state.destination?.id == destination.id else { return }
                begin()
            }
            return
        }
        arrivalDetector.reset()
        state.arrivalLocation = nil
        rerouteController.beginNavigation()
        roadETAPaceTracker = RoadETAPaceTracker()
        knownRoadClosures.removeAll()
        lastTrafficCandidateRefresh = .distantPast
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
        locationManager.setHeadingUpdatesEnabled(appIsForeground && state.transportMode == .walking)
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
        let cameraTransitionDelay = state.transportMode == .transit
            ? 400 : 450
        navigationTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(cameraTransitionDelay))
            guard !Task.isCancelled, let self else { return }
            // Traffic I/O must not wait for the route projection. On long routes
            // the projection can take noticeably longer than the camera delay.
            if self.state.transportMode == .car {
                self.refreshTraffic(force: true, forceRouteRefresh: !hasFreshRouteTraffic)
            }
            await self.mapCameraController.waitForNavigationCameraUpdate()
            guard !Task.isCancelled, self.state.status == .navigating else { return }
            self.updateNavigationCameraState()
        }
        if let destination = state.destination, let route = state.route {
            tripSession = TripSession(destination: destination, waypoints: state.waypoints,
                                      originalExpectedTravelTime: route.expectedTravelTime,
                                      startedAt: Date(), lastLocation: state.location,
                                      tracksDriving: state.transportMode == .car,
                                      transportMode: state.transportMode,
                                      vehicleID: state.transportMode == .car ? selectedVehicleID?() : nil)
            resetEVBatteryEstimate()
            let learningEnabled = state.transportMode == .car && DrivingLearningEngine.shared.settings.enabled
                && state.waypoints.isEmpty && route.chargingStops.isEmpty
            learningOfferedRoutes = learningEnabled ? Array(state.routeOptions.filter { $0.chargingStops.isEmpty }.prefix(5)) : []
            learningOriginalRoute = learningEnabled ? learningOfferedRoutes.first ?? route : nil
            learningSelectedRouteID = learningEnabled ? route.id : nil
            learningSelectedAgainstAlternative = learningExplicitlySelectedRouteID == route.id
                && learningOfferedRoutes.count > 1 && learningOfferedRoutes.first?.id != route.id
            learningRecordingGeneration = DrivingLearningEngine.shared.recordingGeneration
            learningContext = DrivingPreferenceContext(date: Date(),
                trafficLevel: DrivingPreferenceContext.measuredTrafficLevel(state.traffic))
            learningCosting = state.routingPreferences.advanced.costing(for: state.transportMode)
            learningAllowsDeviations = true
            learningTrafficCheckedAt = nil
        }
        invalidateSpeedLimit(preservingRoadBuffer: true)
        if usesRoadVoiceGuidance, let location = state.location {
            refreshSpeedLimit(for: location, force: true)
        }
        updateProgress()
        updateLiveActivity()
        recordRouteQuality()
        checkpointTrip(force: true)
    }
    func stop() {
        guard state.status != .idle else { return }
        arrivalDetector.reset()
        liveActivity.end()
        state.arrivalLocation = nil
        finishTrip(arrived: state.status == .arrived)
        rerouteController.stop()
        requestGeneration += 1
        laterTransitRequestGeneration += 1
        invalidateTraffic()
        invalidateSpeedLimit()
        voice.reset()
        state.route = nil; state.routeOptions = []; state.progress = nil; state.destination = nil
        state.navigationTarget = nil
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
        state.pendingWaypointIDs = []
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
        let navigationLocation = NavigationLocation(coordinate: coordinate, speed: raw.speed, course: raw.course,
                                                    accuracy: raw.horizontalAccuracy, timestamp: raw.timestamp,
                                                    speedAccuracy: raw.speedAccuracy,
                                                    courseAccuracy: raw.courseAccuracy)
        state.location = navigationLocation
        if state.routeOrigin == nil || state.routeOrigin?.isCurrentLocation == true {
            state.routeOrigin = RoutePoint(
                Destination(name: "Twoja lokalizacja", coordinate: coordinate),
                source: .currentLocation)
        }
        state.cameraLocation = state.location
        lastAcceptedFix = raw.timestamp
        state.weakGPS = false
        state.gpsQuality = raw.horizontalAccuracy <= 10 ? .excellent : (raw.horizontalAccuracy <= 35 ? .good : .weak)
        tripSession?.record(navigationLocation,
                            speedLimitKph: state.transportMode == .car
                                ? drivingSpeedLimit(at: navigationLocation) : nil)
        publishEVBatteryEstimate()
        checkpointTrip()
        if learningAllowsDeviations, let original = learningOriginalRoute,
           let traffic = state.traffic, traffic.updatedAt != learningTrafficCheckedAt,
           abs(Date().timeIntervalSince(traffic.updatedAt)) <= 120 {
            learningTrafficCheckedAt = traffic.updatedAt
            let geometry = RouteProgressGeometry(original)
            if traffic.incidents.contains(where: { incident in
               incident.affectsRouting && (incident.isRoadClosure || (incident.delaySeconds ?? 0) >= 120)
                   && RouteTrafficMonitor.incidentProjection(incident, geometry: geometry, route: original) != nil
            }) {
                learningAllowsDeviations = false
            }
        }
        updateProgress()
        recordRouteQuality()
        if appIsForeground, state.transportMode == .walking,
           (state.status == .navigating || state.status == .rerouting) {
            mapCameraController.updateWalkingCamera(location: state.cameraLocation,
                                                    deviceHeading: state.deviceHeading)
        }
        if state.status == .idle || state.status == .destinationPreview || state.status == .routeCalculating {
            updateCameraIntent()
        }
        if state.status == .navigating || state.status == .rerouting {
            if appIsForeground, state.cameraState != .startingNavigation { updateNavigationCameraState() }
            if state.transportMode == .car {
                refreshSpeedLimit(for: state.location!)
            }
        }
        refreshEnergyPolicy()
        if state.transportMode == .car { refreshTraffic() }
    }
    func invalidateTraffic() {
        trafficComparisonTask?.cancel()
        trafficComparisonTask = nil
        trafficCandidateCancellationToken?.cancel()
        trafficCandidateCancellationToken = nil
        trafficGeneration += 1
        trafficComparisonInFlight = false
        lastTrafficComparison = .distantPast
        trafficRouteSelectionGeneration += 1
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
        routeTrafficColorSegments = []
        routeTrafficFlowUpdatedAt = nil
        state.traffic = nil
    }
    func invalidateSpeedLimit(preservingRoadBuffer: Bool = false) {
        speedLimitGeneration += 1
        speedLimitTask?.cancel()
        speedLimitTask = nil
        let wasFetchingBuffer = nearbySpeedLimitTask != nil
        nearbySpeedLimitTask?.cancel()
        nearbySpeedLimitTask = nil
        if !preservingRoadBuffer {
            nearbySpeedLimitSnapshot = nil
            nearbySpeedLimitCenter = nil
            speedLimitBufferGeometry = nil
            speedLimitBufferEndDistance = nil
            speedLimitBufferRouteID = nil
            nearbySpeedLimitFailures = 0
        }
        if !preservingRoadBuffer || wasFetchingBuffer { lastNearbySpeedLimitFetch = .distantPast }
        speedLimitRequestInFlight = false
        lastSpeedLimitFetch = .distantPast
        state.speedLimitKph = nil
        state.speedLimitSource = nil
        state.speedLimitMessage = nil
        speedLimitObservationLocation = nil
        speedLimitReading = nil
        speedLimitReadingDate = .distantPast
    }
    func refreshSpeedLimit(for location: NavigationLocation, force: Bool = false) {
        refreshNearbySpeedLimits(for: location)
        if let speed = MapDisplayPriorityEngine.passedSpeedLimit(in: state) {
            state.speedLimitKph = speed
            state.speedLimitSource = .explicitSign
            state.speedLimitMessage = nil
            speedLimitObservationLocation = location.coordinate
            return
        }
        if state.speedLimitSource == .explicitSign {
            state.speedLimitKph = nil
            state.speedLimitSource = nil
            speedLimitObservationLocation = nil
        }
        if let snapshot = activeSpeedLimitSnapshot(at: location) {
            if let result = snapshot.speedLimit(at: location) {
                state.speedLimitKph = result.speedKph
                state.speedLimitSource = result.source
                state.speedLimitMessage = nil
                speedLimitObservationLocation = location.coordinate
                return
            }
            if snapshot.shouldSuppressRoutingFallback(at: location) {
                state.speedLimitKph = nil
                state.speedLimitSource = nil
                state.speedLimitMessage = "Nie można ustalić aktywnego limitu z danych warunkowych."
                speedLimitObservationLocation = nil
                return
            }
        }
        if let observation = speedLimitObservationLocation,
           !(state.speedLimitSource == .routingProvider && speedLimitReading?.road.isEmpty == false
                ? routingSpeedLimitMatches(location)
                : observation.distance(to: location.coordinate) <= 75) {
            state.speedLimitKph = nil
            state.speedLimitSource = nil
            speedLimitObservationLocation = nil
        }
        guard !speedLimitRequestInFlight,
              force || Date().timeIntervalSince(lastSpeedLimitFetch) >= (state.speedLimitKph == nil ? 3 : 10) else { return }
        speedLimitRequestInFlight = true
        lastSpeedLimitFetch = Date()
        let generation = speedLimitGeneration
        let provider = speedLimitProvider
        speedLimitTask = Task(priority: .userInitiated) {
            defer { if generation == speedLimitGeneration { speedLimitRequestInFlight = false } }
            do {
                let value = try await provider.limit(at: location.coordinate, heading: location.course)
                guard generation == speedLimitGeneration, state.status == .navigating || state.status == .rerouting else { return }
                guard let currentLocation = state.location else { return }
                if MapDisplayPriorityEngine.passedSpeedLimit(in: state) != nil {
                    refreshSpeedLimit(for: currentLocation)
                    return
                }
                // OSM may have become available while locate was in flight.
                if let snapshot = activeSpeedLimitSnapshot(at: currentLocation),
                   snapshot.speedLimit(at: currentLocation) != nil || snapshot.shouldSuppressRoutingFallback(at: currentLocation) {
                    refreshSpeedLimit(for: currentLocation)
                    return
                }
                let onReturnedRoad = value.map { $0.road.count > 1 ? $0.matches(currentLocation) : nil } ?? nil
                let stillNearby = currentLocation.coordinate.distance(to: location.coordinate) <= max(30, min(80, currentLocation.accuracy))
                guard onReturnedRoad ?? stillNearby else {
                    lastSpeedLimitFetch = .distantPast
                    return
                }
                state.speedLimitKph = value?.speedKph
                state.speedLimitSource = value == nil ? nil : .routingProvider
                state.speedLimitMessage = value == nil ? "Brak limitu w danych drogi." : nil
                speedLimitObservationLocation = value == nil ? nil : currentLocation.coordinate
                speedLimitReading = value
                speedLimitReadingDate = .now
            } catch {
                guard generation == speedLimitGeneration else { return }
                if let current = state.location, let snapshot = activeSpeedLimitSnapshot(at: current),
                   snapshot.speedLimit(at: current) != nil || snapshot.shouldSuppressRoutingFallback(at: current) { return }
                state.speedLimitKph = nil
                state.speedLimitSource = nil
                state.speedLimitMessage = "Limit niedostępny: \(error.localizedDescription)"
                speedLimitObservationLocation = nil
            }
        }
    }

    private func drivingSpeedLimit(at location: NavigationLocation) -> Int? {
        if let speed = MapDisplayPriorityEngine.passedSpeedLimit(in: state) { return speed }
        if let snapshot = activeSpeedLimitSnapshot(at: location) {
            if let result = snapshot.speedLimit(at: location) { return result.speedKph }
            if snapshot.shouldSuppressRoutingFallback(at: location) { return nil }
        }
        guard let speedLimit = state.speedLimitKph,
              let observationLocation = speedLimitObservationLocation else { return nil }
        if state.speedLimitSource == .routingProvider,
           speedLimitReading?.road.isEmpty == false {
            return routingSpeedLimitMatches(location) ? speedLimit : nil
        }
        guard observationLocation.distance(to: location.coordinate) <= 75 else { return nil }
        return speedLimit
    }

    private func routingSpeedLimitMatches(_ location: NavigationLocation) -> Bool {
        Date().timeIntervalSince(speedLimitReadingDate) <= 15 && speedLimitReading?.matches(location) == true
    }

    private func activeSpeedLimitSnapshot(at location: NavigationLocation) -> RoadDataSnapshot? {
        if let nearby = nearbySpeedLimitSnapshot,
           Date().timeIntervalSince(nearby.fetchedAt) < 86_400,
           speedLimitBufferRouteID == state.route?.id {
            // Prefer fresh local rules, including unresolved conditional limits.
            if nearby.speedLimit(at: location) != nil || nearby.shouldSuppressRoutingFallback(at: location) {
                return nearby
            }
        }
        return roadDataSnapshot
    }

    private func refreshNearbySpeedLimits(for location: NavigationLocation) {
        guard nearbySpeedLimitTask == nil, let route = state.route else { return }
        let elapsed = Date().timeIntervalSince(lastNearbySpeedLimitFetch)
        let retryInterval = 15 * pow(2, Double(min(nearbySpeedLimitFailures, 3)))
        let moved = nearbySpeedLimitCenter.map { $0.distance(to: location.coordinate) >= 600 } ?? true
        let speed = max(0, location.speed)
        let reserve = max(1_500, speed * 90)
        let projection = speedLimitBufferGeometry?.project(location.coordinate, within: 120)
        let remaining = speedLimitBufferEndDistance.flatMap { end in projection.map { end - $0.alongRoute } }
        let needsMoreRoad = remaining.map { $0 <= reserve &&
            (speedLimitBufferGeometry?.length ?? 0) > (speedLimitBufferEndDistance ?? 0) + 10 } ?? moved
        guard elapsed >= retryInterval,
              nearbySpeedLimitSnapshot == nil || needsMoreRoad || elapsed >= 180 || nearbySpeedLimitFailures > 0 else { return }
        lastNearbySpeedLimitFetch = .now
        let generation = speedLimitGeneration
        let routeID = route.id
        let routeCoordinates = route.coordinates
        let cachedGeometry = speedLimitBufferRouteID == routeID ? speedLimitBufferGeometry : nil
        let provider = roadDataProvider
        nearbySpeedLimitTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer { if generation == self.speedLimitGeneration { self.nearbySpeedLimitTask = nil } }
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    let geometry = cachedGeometry ?? RouteProgressGeometry(coordinates: routeCoordinates)
                    let projection = geometry.project(location.coordinate, within: 120)
                    let lookAhead = max(4_000, min(12_000, speed * 240 + 1_000))
                    let end = projection.map { min(geometry.length, $0.alongRoute + lookAhead) }
                    let corridor = projection.flatMap { point in
                        end.map { geometry.corridor(from: max(0, point.alongRoute - 200), through: $0) }
                    } ?? []
                    return (geometry, end, corridor)
                }
                let (geometry, end, corridor) = await preparation.value
                try Task.checkCancellation()
                let snapshot = try await provider.loadSpeedLimits(near: location.coordinate, along: corridor)
                guard !Task.isCancelled, generation == self.speedLimitGeneration,
                      self.state.route?.id == routeID,
                      self.state.status == .routePreview || self.state.status == .navigating || self.state.status == .rerouting else { return }
                self.nearbySpeedLimitSnapshot = snapshot
                self.nearbySpeedLimitCenter = location.coordinate
                self.speedLimitBufferGeometry = geometry
                self.speedLimitBufferEndDistance = end
                self.speedLimitBufferRouteID = routeID
                self.nearbySpeedLimitFailures = 0
                if self.state.status == .navigating || self.state.status == .rerouting,
                   let current = self.state.location { self.refreshSpeedLimit(for: current) }
            } catch {
                // Locate continues independently; retry the small OSM request on a later fix.
                guard !Task.isCancelled, generation == self.speedLimitGeneration else { return }
                self.nearbySpeedLimitFailures += 1
            }
        }
    }

    func loadRoadData(for route: NavigationRoute, isRetry: Bool = false) {
        guard usesRoadVoiceGuidance else { return }
        let roadCoordinates = route.coordinates
        guard roadCoordinates.count > 1 else { return }
        roadDataTask?.cancel()
        roadDataGeneration &+= 1
        let generation = roadDataGeneration
        let routeID = route.id
        let provider = roadDataProvider
        if !isRetry {
            roadDataSnapshot = nil
            state.roadSafetyAlerts = []
            state.roadAlertRoadSegments = nil
            state.roadSafetyStatus = .loading
            state.lastPassedRoadZoneID = nil
            state.roadZoneNotice = nil
            state.roadZoneNoticeExpiresAt = nil
            invalidateSpeedLimit()
        }
        if let location = state.location,
           state.status == .routePreview || state.status == .navigating || state.status == .rerouting {
            refreshNearbySpeedLimits(for: location)
        }
        roadDataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await provider.load(for: roadCoordinates)
                guard !Task.isCancelled, generation == self.roadDataGeneration,
                      self.state.route?.id == routeID,
                      self.usesRoadVoiceGuidance else { return }
                self.roadDataSnapshot = snapshot
                self.state.roadSafetyAlerts = snapshot.matchedAlerts(on: roadCoordinates)
                self.state.roadAlertRoadSegments = snapshot.roadSegments ?? snapshot.speedSegments
                self.state.roadSafetyStatus = snapshot.unavailableSources.flatMap { sources in
                    sources.isEmpty ? nil : .partial("Niedostępne źródło: " + sources.joined(separator: ", "))
                } ?? .available
                self.updateProgress()
                if let location = self.state.location,
                   self.state.status == .navigating || self.state.status == .rerouting,
                   self.state.transportMode == .car {
                    self.refreshSpeedLimit(for: location, force: true)
                }
                if snapshot.unavailableSources?.isEmpty == false {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled, generation == self.roadDataGeneration,
                          self.state.route?.id == routeID, self.usesRoadVoiceGuidance else { return }
                    self.loadRoadData(for: route, isRetry: true)
                }
            } catch {
                guard !Task.isCancelled, generation == self.roadDataGeneration,
                      self.state.route?.id == routeID,
                      self.usesRoadVoiceGuidance else { return }
                self.roadDataSnapshot = nil
                self.state.roadSafetyAlerts = []
                self.state.roadAlertRoadSegments = nil
                self.state.roadSafetyStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    func resetRoadSafetyData() {
        roadDataTask?.cancel()
        roadDataTask = nil
        roadDataGeneration &+= 1
        roadDataSnapshot = nil
        state.roadSafetyAlerts = []
        state.roadAlertRoadSegments = nil
        state.roadSafetyStatus = .idle
        state.lastPassedRoadZoneID = nil
        state.roadZoneNotice = nil
        state.roadZoneNoticeExpiresAt = nil
        invalidateSpeedLimit()
    }
    func checkpointTrip(force: Bool = false) {
        guard let session = tripSession else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastTripCheckpointAt) >= 15 else { return }
        lastTripCheckpointAt = now
        onTripCheckpoint?(session.record(endedAt: now, arrived: false, terminationReason: nil))
    }

    func finishTrip(arrived: Bool, reason: TripTerminationReason? = nil) {
        guard let session = tripSession else { return }
        tripSession = nil
        evBatteryEstimate = nil
        publishEVBatteryEstimate()
        roadETAPaceTracker = RoadETAPaceTracker()
        knownRoadClosures.removeAll()
        lastTrafficCandidateRefresh = .distantPast
        lastTripCheckpointAt = .distantPast
        let record = session.record(endedAt: Date(), arrived: arrived,
                                    terminationReason: reason ?? (arrived ? .completed : .userStopped))
        state.lastTrip = record
        onTripFinished?(record)
        DrivingLearningEngine.shared.enqueue(record, proposed: learningOriginalRoute, costing: learningCosting,
            context: learningContext ?? DrivingPreferenceContext(date: record.startedAt),
            allowAutomaticDeviations: learningAllowsDeviations,
            recordingGeneration: learningRecordingGeneration, offeredRoutes: learningOfferedRoutes,
            selectedRouteID: learningSelectedRouteID, selectedAgainstAlternative: learningSelectedAgainstAlternative)
        learningOriginalRoute = nil
        learningContext = nil
        learningRecordingGeneration = nil
        learningOfferedRoutes = []
        learningSelectedRouteID = nil
        learningExplicitlySelectedRouteID = nil
        learningSelectedAgainstAlternative = false
        if let provider = routeProvider as? ValhallaRouteProvider {
            DrivingLearningEngine.shared.processPending(endpoint: provider.endpoint)
        }
    }


}

private extension ArraySlice where Element == Coordinate {
    func adjacentDistance() -> Double { zip(self, dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
}


struct TripSession {
    let id = UUID()
    var destination: Destination
    var waypoints: [Destination]
    let originalExpectedTravelTime: TimeInterval
    let startedAt: Date
    let tracksDriving: Bool
    var lastLocation: NavigationLocation?
    var distanceMeters = 0.0
    var movingSeconds: TimeInterval = 0
    var measuredStoppedSeconds: TimeInterval = 0
    var distanceSamples: [TripDistanceSample] = []
    var rerouteCount = 0
    var drivingAnalyzer: DrivingBehaviorAnalyzer?
    var transportMode: TransportMode?
    var traceRecorder = TripTraceRecorder()
    var routeQuality = RouteQualityRecorder()
    var vehicleID: UUID?

    init(destination: Destination, waypoints: [Destination],
         originalExpectedTravelTime: TimeInterval, startedAt: Date,
         lastLocation: NavigationLocation?, tracksDriving: Bool,
         transportMode: TransportMode? = nil, vehicleID: UUID? = nil) {
        self.vehicleID = vehicleID
        self.destination = destination
        self.waypoints = waypoints
        self.originalExpectedTravelTime = originalExpectedTravelTime
        self.startedAt = startedAt
        self.lastLocation = lastLocation.flatMap {
            abs($0.timestamp.timeIntervalSince(startedAt)) <= 15 ? $0 : nil
        }
        self.tracksDriving = tracksDriving
        self.transportMode = transportMode
        drivingAnalyzer = tracksDriving ? DrivingBehaviorAnalyzer() : nil
        if let lastLocation, abs(lastLocation.timestamp.timeIntervalSince(startedAt)) <= 15 {
            traceRecorder.record(lastLocation)
        }
    }

    mutating func record(_ location: NavigationLocation, speedLimitKph: Int?) {
        guard location.timestamp >= startedAt,
              lastLocation.map({ location.timestamp > $0.timestamp }) ?? true else { return }
        traceRecorder.record(location)
        defer { lastLocation = location }

        if let previous = lastLocation {
            let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
            let measuredStart = max(startedAt, previous.timestamp)
            let measuredSeconds = location.timestamp.timeIntervalSince(measuredStart)
            if seconds > 0, seconds <= 30, measuredSeconds > 0,
               isReliableMovementFix(previous), isReliableMovementFix(location) {
                let distance = previous.coordinate.distance(to: location.coordinate)
                let maximumSpeed = min(60, transportMode?.maximumPlausibleSpeed ?? 60)
                if distance <= max(30, seconds * maximumSpeed) {
                    if previous.speed >= 0.5 || location.speed >= 0.5 {
                        let measuredDistance = distance * measuredSeconds / seconds
                        movingSeconds += measuredSeconds
                        distanceMeters += measuredDistance
                        distanceSamples.append(TripDistanceSample(startedAt: measuredStart,
                            endedAt: location.timestamp, distanceMeters: measuredDistance))
                    } else {
                        measuredStoppedSeconds += measuredSeconds
                    }
                }
            }
        }

        drivingAnalyzer?.process(DrivingSample(timestamp: location.timestamp,
                                               speedMetersPerSecond: location.speed,
                                               speedLimitKph: speedLimitKph,
                                               headingDegrees: location.course,
                                               horizontalAccuracy: location.accuracy,
                                               speedAccuracy: location.speedAccuracy,
                                               courseAccuracy: location.courseAccuracy))
    }

    var drivingScore: DrivingScore? {
        guard tracksDriving else { return nil }
        return drivingAnalyzer?.score(distanceMeters: distanceMeters, movingSeconds: movingSeconds)
    }

    func record(endedAt: Date, arrived: Bool, terminationReason: TripTerminationReason?) -> TripRecord {
        var recorder = traceRecorder
        recorder.finalize()
        var record = TripRecord(id: id, destination: destination, waypoints: waypoints,
                                startedAt: startedAt, endedAt: max(startedAt, endedAt),
                                distanceMeters: distanceMeters, movingSeconds: movingSeconds,
                                rerouteCount: rerouteCount, arrived: arrived,
                                originalExpectedTravelTime: originalExpectedTravelTime,
                                drivingScore: arrived ? drivingScore : nil, transportMode: transportMode,
                                trace: recorder.points, maximumSpeedKph: recorder.maximumSpeedKph,
                                vehicleID: vehicleID)
        record.measuredStoppedSeconds = measuredStoppedSeconds
        record.distanceSamples = distanceSamples
        record.routingQuality = routeQuality.measurement
        record.terminationReason = terminationReason
        if recorder.points.isEmpty { record.traceUnavailableReason = .noReliableLocations }
        return record
    }

    private func isReliableMovementFix(_ location: NavigationLocation) -> Bool {
        location.accuracy.isFinite && (0...50).contains(location.accuracy)
            && location.speed.isFinite && (0...(transportMode?.maximumPlausibleSpeed ?? 75)).contains(location.speed)
            && location.speedAccuracy.isFinite && (0...5).contains(location.speedAccuracy)
            && location.coordinate.latitude.isFinite && abs(location.coordinate.latitude) <= 90
            && location.coordinate.longitude.isFinite && abs(location.coordinate.longitude) <= 180
    }
}
