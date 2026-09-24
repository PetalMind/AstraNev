import AVFoundation
import CoreLocation
import Foundation
import Observation

@MainActor @Observable
final class NavigationState {
    var searchMapCenter: Coordinate?
    var searchResults: [SearchResult] = []
    var location: NavigationLocation?
    var cameraLocation: NavigationLocation?
    var route: NavigationRoute?
    var transportMode: TransportMode = .car
    // Keep provider order stable when the selected route changes.
    var routeOptions: [NavigationRoute] = []
    var alternatives: [NavigationRoute] {
        routeOptions.filter { $0.id != route?.id }
    }
    var destination: Destination?
    var waypoints: [Destination] = []
    var evChargingStops: [Destination] = []
    var routingPreferences = RoutingPreferences()
    var progress: RouteProgress?
    var transitProgress: TransitNavigationProgress?
    var status: NavigationStatus = .idle
    var cameraState: NavigationCameraState = .browse
    var cameraIntent: CameraIntent?
    var cameraCommandID = 0
    var routeRevealProgress = 1.0
    var weakGPS = false
    var gpsQuality: GPSQuality = .noSignal
    var estimatedArrival: Date?
    var lastTrip: TripRecord?
    var errorMessage: String?
    var voiceEnabled = true
    var speedLimitKph: Int?
    var speedLimitSource: SpeedLimitSource?
    var speedLimitMessage: String?
    var roadSafetyAlerts: [RoadSafetyAlert] = []
    var roadSafetyStatus: RoadSafetyStatus = .idle
    var traffic: TrafficSnapshot?
    var trafficStatus: TrafficStatus = .notConfigured
    var trafficLightTileURLTemplate: String?
    var trafficDarkTileURLTemplate: String?
    var trafficLightIncidentTileURLTemplate: String?
    var trafficDarkIncidentTileURLTemplate: String?
    var nearbySuggestions: [RouteStopSuggestion] = []
    var nearbyStatus: NearbySearchStatus = .idle
    var transitVehicles: [TransitVehicle] = []
    var transitVehiclesUpdatedAt: Date?
    var transitStops: [TransitStop] = []
    var nearbyTransitStop: TransitStop?
    var nearbyTransitDepartures: [TransitDeparture] = []
    var transitBackgroundLocationAvailable = false
}

enum TrafficStatus: Equatable {
    case notConfigured, updating, available, unavailable(String)
}

enum NearbySearchStatus: Equatable {
    case idle, searching, available, unavailable(String)
}

enum EVPlanningError: LocalizedError {
    case rangeNotConfigured, consumptionNotConfigured, chargersUnavailable
    var errorDescription: String? {
        switch self {
        case .rangeNotConfigured: "Wpisz szacowany zasięg EV w ustawieniach, aby uwzględnić postoje na ładowanie."
        case .consumptionNotConfigured: "Wpisz zużycie energii oraz maksymalną moc ładowania auta w ustawieniach EV."
        case .chargersUnavailable: "Nie znaleziono wystarczającej liczby publicznych ładowarek ze znanym złączem i mocą w danych OpenStreetMap."
        }
    }
}

@MainActor
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    var onFailure: ((Error) -> Void)?
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
    }
    func start() { manager.requestWhenInUseAuthorization(); manager.startUpdatingLocation() }
    func stop() { manager.stopUpdatingLocation() }

    var backgroundLocationModeEnabled: Bool {
#if os(iOS)
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
#else
        return false
#endif
    }

    func requestTransitBackgroundAuthorization() -> Bool {
#if os(iOS)
        guard backgroundLocationModeEnabled else { return false }
        if manager.authorizationStatus == .authorizedAlways {
            applyBackgroundLocationSettings(.authorizedAlways)
            return true
        }
        manager.requestAlwaysAuthorization()
#endif
        return false
    }

    func stopBackgroundNavigationUpdates() {
#if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
#endif
    }

    private func applyBackgroundLocationSettings(_ authorization: CLAuthorizationStatus) {
#if os(iOS)
        let enabled = authorization == .authorizedAlways && backgroundLocationModeEnabled
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = !enabled
#endif
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in self?.onLocation?(location) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.applyBackgroundLocationSettings(status)
            self?.onAuthorization?(status)
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.onFailure?(error) }
    }
}

struct LocationFilter {
    private var previous: CLLocation?
    private var mode: TransportMode?

    mutating func accept(_ location: CLLocation, mode newMode: TransportMode) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 70,
              abs(location.timestamp.timeIntervalSinceNow) < 15 else { return false }
        if mode != newMode {
            previous = nil
            mode = newMode
        }
        if let previous {
            let interval = location.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0 else { return false }
            if location.distance(from: previous) / interval > newMode.maximumPlausibleSpeed { return false }
        }
        previous = location
        return true
    }
}

private extension TransportMode {
    var maximumPlausibleSpeed: Double {
        switch self {
        case .walking: 10
        case .bicycle: 40
        case .car: 75
        case .transit: 90
        case .parkRide: 75
        }
    }
}

struct RouteProjection {
    let coordinate: Coordinate
    let distanceFromRoute: Double
    let alongRoute: Double
    let segment: Int
}

enum MapMatcher {
    static func project(_ location: Coordinate, onto route: [Coordinate]) -> RouteProjection? {
        guard route.count > 1 else { return nil }
        let metersPerLatitudeDegree = 110_574.0
        let metersPerLongitudeDegreeAtLocation = 111_320.0 * cos(location.latitude * .pi / 180)
        var bestCoordinate: Coordinate?
        var bestDistanceSquared = Double.infinity
        var bestAlongRoute = 0.0
        var bestSegment = 0
        var traveled = 0.0
        for index in 0..<(route.count - 1) {
            let a = route[index], b = route[index + 1]
            let longitudeDelta = b.longitude - a.longitude
            let latitudeDelta = b.latitude - a.latitude
            let dx = longitudeDelta * metersPerLongitudeDegreeAtLocation
            let dy = latitudeDelta * metersPerLatitudeDegree
            let px = (location.longitude - a.longitude) * metersPerLongitudeDegreeAtLocation
            let py = (location.latitude - a.latitude) * metersPerLatitudeDegree
            let segmentLengthSquared = dx * dx + dy * dy
            guard segmentLengthSquared > 0 else { continue }
            let segmentLength = sqrt(segmentLengthSquared)
            let fraction = max(0, min(1, (px * dx + py * dy) / segmentLengthSquared))
            let offsetX = px - fraction * dx
            let offsetY = py - fraction * dy
            let distanceSquared = offsetX * offsetX + offsetY * offsetY
            let projected = Coordinate(latitude: a.latitude + fraction * (b.latitude - a.latitude),
                                       longitude: a.longitude + fraction * (b.longitude - a.longitude))
            if distanceSquared < bestDistanceSquared {
                bestCoordinate = projected
                bestDistanceSquared = distanceSquared
                bestAlongRoute = traveled + fraction * segmentLength
                bestSegment = index
            }
            traveled += segmentLength
        }
        guard let bestCoordinate else { return nil }
        return RouteProjection(coordinate: bestCoordinate, distanceFromRoute: sqrt(bestDistanceSquared),
                               alongRoute: bestAlongRoute, segment: bestSegment)
    }

    static func match(_ location: NavigationLocation, onto route: [Coordinate],
                      previous: RouteProjection? = nil, previousTimestamp: Date? = nil) -> RouteMatch? {
        guard route.count > 1 else { return nil }
        var candidates: [(projection: RouteProjection, bearing: Double)] = []
        var traveled = 0.0
        let metersPerLatitudeDegree = 110_574.0
        let metersPerLongitudeDegree = 111_320.0 * cos(location.coordinate.latitude * .pi / 180)
        for index in 0..<(route.count - 1) {
            let start = route[index], end = route[index + 1]
            let dx = (end.longitude - start.longitude) * metersPerLongitudeDegree
            let dy = (end.latitude - start.latitude) * metersPerLatitudeDegree
            let segmentLengthSquared = dx * dx + dy * dy
            guard segmentLengthSquared > 0 else { continue }
            let segmentLength = sqrt(segmentLengthSquared)
            let px = (location.coordinate.longitude - start.longitude) * metersPerLongitudeDegree
            let py = (location.coordinate.latitude - start.latitude) * metersPerLatitudeDegree
            let fraction = max(0, min(1, (px * dx + py * dy) / segmentLengthSquared))
            let offsetX = px - fraction * dx
            let offsetY = py - fraction * dy
            let coordinate = Coordinate(
                latitude: start.latitude + fraction * (end.latitude - start.latitude),
                longitude: start.longitude + fraction * (end.longitude - start.longitude))
            let projection = RouteProjection(coordinate: coordinate,
                                             distanceFromRoute: hypot(offsetX, offsetY),
                                             alongRoute: traveled + fraction * segmentLength,
                                             segment: index)
            if projection.distanceFromRoute <= max(250, location.accuracy * 6) {
                let bearing = atan2(dx, dy) * 180 / .pi
                candidates.append((projection, (bearing + 360).truncatingRemainder(dividingBy: 360)))
            }
            traveled += segmentLength
        }
        guard !candidates.isEmpty else { return nil }
        let accuracy = max(8, location.accuracy)
        let elapsed = previousTimestamp.map { max(0, location.timestamp.timeIntervalSince($0)) } ?? 0
        let expectedProgress = previous.map { $0.alongRoute + max(0, location.speed) * elapsed }
        let scored = candidates.map { candidate -> (RouteProjection, Double) in
            let distanceScore = pow(candidate.projection.distanceFromRoute / accuracy, 2)
            var score = distanceScore
            if location.speed >= 1.5, location.course >= 0, location.course <= 360 {
                let difference = abs(location.course - candidate.bearing)
                let headingDifference = min(difference, 360 - difference)
                score += pow(headingDifference / 55, 2)
            }
            if let previous, let expectedProgress {
                let continuityScale = max(35, max(0, location.speed) * elapsed + accuracy * 2)
                score += pow((candidate.projection.alongRoute - expectedProgress) / continuityScale, 2) * 0.35
            }
            return (candidate.projection, score)
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }
        return RouteMatch(projection: best.0, confidence: exp(-0.5 * min(40, best.1)))
    }
}

struct RouteMatch {
    let projection: RouteProjection
    let confidence: Double
}

enum TransitRouteProgressCalculator {
    private struct LegMatch {
        let index: Int
        let projection: RouteProjection
        let length: Double
    }

    static func progress(route: NavigationRoute, at coordinate: Coordinate,
                         accuracy: Double, previousLegIndex: Int? = nil) -> TransitNavigationProgress? {
        guard let journey = route.journey, !journey.legs.isEmpty else { return nil }
        let lengths = journey.legs.map { leg in
            zip(leg.coordinates, leg.coordinates.dropFirst())
                .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        }
        let totalLength = lengths.reduce(0, +)
        guard totalLength > 0 else { return nil }

        let matches = journey.legs.indices.compactMap { index -> LegMatch? in
            let leg = journey.legs[index]
            guard lengths[index] > 0,
                  let projection = MapMatcher.project(coordinate, onto: leg.coordinates) else { return nil }
            return LegMatch(index: index, projection: projection, length: lengths[index])
        }
        guard let nearest = matches.min(by: {
            $0.projection.distanceFromRoute < $1.projection.distanceFromRoute
        }) else { return nil }
        let maximumMatchDistance = max(150, accuracy * 2)
        let previousMatch = previousLegIndex.flatMap { index in matches.first(where: { $0.index == index }) }
        let match = previousMatch.map {
            $0.projection.distanceFromRoute <= maximumMatchDistance &&
                $0.projection.distanceFromRoute <= nearest.projection.distanceFromRoute + 35
                ? $0 : nearest
        } ?? nearest
        guard match.projection.distanceFromRoute <= maximumMatchDistance else { return nil }

        let distanceBeforeLeg = lengths.prefix(match.index).reduce(0, +)
        let legDistance = min(match.length, max(0, match.projection.alongRoute))
        let routeFraction = min(1, max(0, (distanceBeforeLeg + legDistance) / totalLength))
        let leg = journey.legs[match.index]
        let orderedStops = leg.transitStops.sorted { $0.sequence < $1.sequence }
        let stopPositions = orderedStops.enumerated().compactMap { index, stop -> (Int, TransitJourneyStop, Double)? in
            guard let projection = MapMatcher.project(stop.coordinate, onto: leg.coordinates),
                  projection.distanceFromRoute <= 250 else { return nil }
            return (index, stop, projection.alongRoute)
        }
        let upcomingStops = stopPositions.filter { $0.0 > 0 && $0.2 >= legDistance - 60 }
        let nextStop = upcomingStops.first?.1

        return TransitNavigationProgress(
            legIndex: match.index,
            legFraction: min(1, max(0, legDistance / match.length)),
            routeFraction: routeFraction,
            legDistance: legDistance,
            distanceToLegEnd: max(0, match.length - legDistance),
            distanceFromRoute: match.projection.distanceFromRoute,
            nextStop: nextStop,
            distanceToNextStop: nextStop.map { coordinate.distance(to: $0.coordinate) },
            stopsUntilAlighting: leg.mode.uppercased() == "WALK" ? nil : upcomingStops.count)
    }
}

@MainActor
final class VoiceGuidanceEngine {
    private let synthesizer = AVSpeechSynthesizer()
    private var announced: Set<String> = []
    private var audioSessionConfigured = false
    private var speechGeneration = 0
    private var audioSessionOperationGeneration = 0
    private var audioSessionOperation: Task<Void, Never>?

    func reset() {
        speechGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        announced.removeAll()
#if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        enqueueAudioSessionOperation {
            _ = try? await audioSession.deactivate(options: .notifyOthersOnDeactivation)
        }
#endif
    }
    func announce(_ maneuver: Maneuver, distance: Double, speed: Double) {
        let early = max(200, min(1200, speed * 24))
        let stage: Int
        if distance <= 35 { stage = 2 }
        else if distance <= max(80, speed * 8) { stage = 1 }
        else if distance <= early { stage = 0 }
        else { return }
        let key = "\(maneuver.id):\(stage)"
        guard announced.insert(key).inserted else { return }
        let prefix = stage == 2 ? "" : "Za \(Int(distance / 50) * 50) metrów "
        let utterance = AVSpeechUtterance(string: prefix + maneuver.spokenInstruction)
        utterance.voice = AVSpeechSynthesisVoice(language: "pl-PL")
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speak(utterance)
    }

    func announceTransit(_ instruction: String, key: String) {
        guard announced.insert(key).inserted else { return }
        let utterance = AVSpeechUtterance(string: instruction)
        utterance.voice = AVSpeechSynthesisVoice(language: "pl-PL")
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speak(utterance)
    }

    func announce(_ alert: RoadSafetyAlert, distance: Double, routeID: UUID) {
        guard alert.type.isEnforcement || alert.type == .speedLimitChange else { return }
        let stage: Int
        if distance <= 40 { stage = 2 }
        else if distance <= 250 { stage = 1 }
        else if distance <= 1_200 { stage = 0 }
        else { return }
        let key = "road-\(routeID)-\(alert.id)-\(stage)"
        guard announced.insert(key).inserted else { return }
        let prefix = stage == 2 ? "" : "Za \(Int(distance / 50) * 50) metrów "
        let utterance = AVSpeechUtterance(string: prefix + alert.title)
        utterance.voice = AVSpeechSynthesisVoice(language: "pl-PL")
        speak(utterance)
    }

    private func speak(_ utterance: AVSpeechUtterance) {
#if os(iOS)
        speechGeneration &+= 1
        let generation = speechGeneration
        let audioSession = AVAudioSession.sharedInstance()
        enqueueAudioSessionOperation { [weak self] in
            guard let self else { return }
            do {
                if !self.audioSessionConfigured {
                    try await Task.detached(priority: .userInitiated) {
                        try AVAudioSession.sharedInstance().setCategory(
                            .playback, mode: .spokenAudio, options: [.duckOthers])
                    }.value
                    self.audioSessionConfigured = true
                }
                let activated = try await audioSession.activate(options: [])
                guard activated, generation == self.speechGeneration else {
                    _ = try? await audioSession.deactivate(options: .notifyOthersOnDeactivation)
                    return
                }
                self.synthesizer.speak(utterance)
            } catch {
                // Keep voice guidance best-effort when the system audio session is unavailable.
            }
        }
#else
        synthesizer.speak(utterance)
#endif
    }

    private func enqueueAudioSessionOperation(_ operation: @escaping @MainActor () async -> Void) {
        audioSessionOperationGeneration &+= 1
        let operationGeneration = audioSessionOperationGeneration
        let previousOperation = audioSessionOperation
        audioSessionOperation = Task { @MainActor [weak self] in
            await previousOperation?.value
            await operation()
            guard let self, self.audioSessionOperationGeneration == operationGeneration else { return }
            self.audioSessionOperation = nil
        }
    }
}

@MainActor
final class NavigationEngine {
    let state = NavigationState()
    private let locationManager = LocationManager()
    private let voice = VoiceGuidanceEngine()
    private var filter = LocationFilter()
    private var offRouteSince: Date?
    private var previousRouteMatch: (routeID: UUID, projection: RouteProjection, timestamp: Date)?
    private var lastAcceptedFix = Date.distantPast
    private var locationStartedAt = Date.distantPast
    private var gpsWatchdog: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var navigationTransitionTask: Task<Void, Never>?
    private var maneuverTransitionTask: Task<Void, Never>?
    private var cameraManeuverID: Int?
    private var lastReroute = Date.distantPast
    private var routeProvider: RouteProvider
    private var transitProvider: LodzTransitRouteProvider
    private var requestGeneration = 0
    private var trafficGeneration = 0
    private var speedLimitGeneration = 0
    private var roadDataGeneration = 0
    private var lastTrafficFetch = Date.distantPast
    private var lastSpeedLimitFetch = Date.distantPast
    private var lastTransitVehiclesFetch = Date.distantPast
    private var lastTransitProgressRefresh = Date.distantPast
    private var lastTransitPlanRefresh = Date.distantPast
    private var transitPlanRefreshInFlight = false
    private var lastTransitProgressLegIndex: Int?
    private var transitVehiclesRequestInFlight = false
    private var transitVehiclesGeneration = 0
    private var insideTransitCoverage = false
    private var autoReroutedClosures: Set<String> = []
    private var trafficProjectionRouteID: UUID?
    private var trafficProjectionUpdatedAt: Date?
    private var projectedTrafficIncidents: [(alongRoute: Double, delaySeconds: Int?)] = []
    private var trafficRequestInFlight = false
    private var routeTrafficRequestInFlight = false
    private var lastRouteTrafficFetch = Date.distantPast
    private var latestNearbyTrafficSnapshot: TrafficSnapshot?
    private var routeTrafficIncidents: [TrafficIncident] = []
    private var routeTrafficDataAvailable = false
    private var routeTrafficUpdatedAt: Date?
    private var speedLimitRequestInFlight = false
    private var speedLimitProvider: SpeedLimitProvider
    private let roadDataProvider: RoadDataProvider
    private var roadDataSnapshot: RoadDataSnapshot?
    private var trafficProvider: TrafficProvider?
    private var transitTripDetails: TransitTripDetails?
    private var transitTripDetailsID: String?
    private var transitRideTrackingID: String?
    private var confirmedTransitTripID: String?
    private var transitRideMotionEvidence = 0
    private var lastTransitRideDistance = 0.0
    private var tripSession: TripSession?
    var onTripFinished: ((TripRecord) -> Void)?

    init(routeProvider: RouteProvider) {
        self.routeProvider = routeProvider
        let endpoint = (routeProvider as? ValhallaRouteProvider)?.endpoint ?? URL(string: "https://valhalla1.openstreetmap.de")!
        transitProvider = LodzTransitRouteProvider(walkingRoutingEndpoint: endpoint)
        speedLimitProvider = ValhallaSpeedLimitProvider(endpoint: endpoint)
        roadDataProvider = OpenStreetMapRoadDataProvider()
        if let key = TrafficCredential.read() {
            trafficProvider = TomTomTrafficProvider(apiKey: key)
            state.trafficStatus = .updating
        }
        updateTrafficTileURLTemplates()
        locationManager.onLocation = { [weak self] in self?.receive($0) }
        locationManager.onAuthorization = { [weak self] authorization in
            guard let self else { return }
            self.state.transitBackgroundLocationAvailable = authorization == .authorizedAlways &&
                self.locationManager.backgroundLocationModeEnabled
            if authorization == .denied || authorization == .restricted {
                self.state.errorMessage = "Włącz dostęp do lokalizacji w ustawieniach urządzenia."
            } else {
#if os(iOS)
                if self.state.transportMode == .transit,
                   self.state.status == .navigating,
                   !self.locationManager.backgroundLocationModeEnabled {
                    self.state.errorMessage = "Aplikacja nie ma skonfigurowanego śledzenia lokalizacji w tle."
                } else if self.state.transportMode == .transit,
                          self.state.status == .navigating,
                          authorization != .authorizedAlways {
                    self.state.errorMessage = "Dostęp Zawsze pozwala prowadzić komunikacją i odtwarzać ostrzeżenia przy zablokowanym ekranie."
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
                if self.state.transportMode == .transit,
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

    func setFreeLook() {
        guard state.status == .navigating || state.status == .rerouting else { return }
        state.cameraState = .freeLook
        state.cameraIntent = nil
    }

    func returnToFollow() {
        state.cameraCommandID &+= 1
        guard state.status == .navigating || state.status == .rerouting else {
            state.cameraState = .browse
            updateCameraIntent()
            return
        }
        updateNavigationCameraState(force: true)
    }

    func showRouteOverview() {
        guard state.route != nil else { return }
        state.cameraCommandID &+= 1
        state.cameraState = .routeOverview
        updateCameraIntent()
    }

    func focusMap(on coordinate: Coordinate, zoom: Double = 15.5) {
        state.cameraCommandID &+= 1
        if state.status != .navigating && state.status != .rerouting {
            state.cameraState = .browse
        }
        state.cameraIntent = CameraIntent(target: coordinate, zoom: zoom, pitch: 0,
                                          bearing: 0, padding: .navigation)
    }

    private func updateCameraIntent() {
        state.cameraIntent = CameraPlanner.intent(for: state.cameraState, location: state.cameraLocation ?? state.location,
                                                  destination: state.destination, route: state.route,
                                                  alternatives: state.alternatives, progress: state.progress,
                                                  previousBearing: state.cameraIntent?.bearing ?? 0)
    }

    private func updateNavigationCameraState(force: Bool = false) {
        guard force || state.cameraState != .freeLook else { return }
        let previousState = state.cameraState
        let nextManeuver = state.progress?.nextManeuver
        let passedManeuver = cameraManeuverID != nil && cameraManeuverID != nextManeuver?.id
        cameraManeuverID = nextManeuver?.id

        if state.status == .rerouting { state.cameraState = .rerouting }
        else if state.weakGPS && (previousState == .maneuverNow || previousState == .leavingManeuver) {
            state.cameraState = previousState
        }
        else if state.weakGPS { state.cameraState = .weakGPS }
        else if (state.progress?.remainingDistance ?? .infinity) < 500 &&
                    (state.progress?.distanceToNextManeuver ?? .infinity) > 300 {
            state.cameraState = .approachingDestination
        }
        else if previousState == .leavingManeuver { state.cameraState = .leavingManeuver }
        else if passedManeuver && (previousState == .approachingManeuver || previousState == .maneuverNow) {
            state.cameraState = .leavingManeuver
            scheduleFollowAfterManeuver()
        } else if let nextManeuver {
            let distance = state.progress?.distanceToNextManeuver ?? .infinity
            if distance <= 22 {
                state.cameraState = .maneuverNow
            } else if distance <= (nextManeuver.kind.isExit ? 1_600 : 300) {
                state.cameraState = .approachingManeuver
            } else {
                state.cameraState = .followNavigation
            }
        } else {
            state.cameraState = .followNavigation
        }
        if let coordinate = state.cameraLocation?.coordinate ?? state.location?.coordinate {
            refreshTransitVehicles(near: coordinate)
        }

        let holdsCamera = (previousState == .maneuverNow && state.cameraState == .maneuverNow) ||
            (previousState == .leavingManeuver && state.cameraState == .leavingManeuver)
        if !holdsCamera {
            updateCameraIntent()
        }
    }

    private func scheduleFollowAfterManeuver() {
        maneuverTransitionTask?.cancel()
        maneuverTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self, self.state.cameraState == .leavingManeuver else { return }
            self.state.cameraState = self.state.weakGPS ? .weakGPS : .followNavigation
            self.updateCameraIntent()
        }
    }

    private func revealRoute() {
        revealTask?.cancel()
        state.routeRevealProgress = 0
        revealTask = Task { @MainActor [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            let duration = 1.35
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self, self.state.status == .routePreview else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let progress = min(1, elapsed / duration)
                self.state.routeRevealProgress = progress
                if progress >= 1 { return }
            }
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
        if mode != .car { resetRoadSafetyData() }
        state.transitProgress = nil
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        if state.status == .destinationPreview { return }
        if let destination = state.destination { await preview(destination) }
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
              !transitPlanRefreshInFlight,
              Date().timeIntervalSince(lastTransitPlanRefresh) >= 45,
              let destination = state.destination,
              let origin = state.location?.coordinate else { return }

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
            let routes = try await transitProvider.calculateRoutes(from: origin, to: destination.coordinate,
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
    func configureTraffic(apiKey: String?) -> Bool {
        guard TrafficCredential.save(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let normalizedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        trafficProvider = normalizedKey == nil || normalizedKey!.isEmpty ? nil : TomTomTrafficProvider(apiKey: normalizedKey!)
        updateTrafficTileURLTemplates()
        invalidateTraffic()
        state.traffic = nil
        state.trafficStatus = trafficProvider == nil ? .notConfigured : .updating
        lastTrafficFetch = .distantPast
        if trafficProvider != nil { refreshTraffic(force: true) }
        return true
    }

    private func updateTrafficTileURLTemplates() {
        state.trafficLightTileURLTemplate = trafficProvider?.rasterFlowTileURLTemplate(style: .light)
        state.trafficDarkTileURLTemplate = trafficProvider?.rasterFlowTileURLTemplate(style: .dark)
        state.trafficLightIncidentTileURLTemplate = trafficProvider?.rasterIncidentTileURLTemplate(style: .light)
        state.trafficDarkIncidentTileURLTemplate = trafficProvider?.rasterIncidentTileURLTemplate(style: .dark)
    }

    func refreshTraffic(force: Bool = false) {
        guard state.transportMode == .car || state.status == .idle else { return }
        guard let trafficProvider else { state.trafficStatus = .notConfigured; return }
        let coordinate = state.location?.coordinate
        let isNavigating = state.status == .navigating || state.status == .rerouting
        let nearbyRefreshInterval: TimeInterval = isNavigating ? 60 : 120
        if let coordinate, !trafficRequestInFlight,
           force || Date().timeIntervalSince(lastTrafficFetch) >= nearbyRefreshInterval {
            startNearbyTrafficRefresh(using: trafficProvider, at: coordinate)
        }

        guard let route = state.route,
              state.status == .routePreview || isNavigating else { return }
        let progress = state.progress
        let routeInterval = routeTrafficRefreshInterval(progress: progress)
        if !routeTrafficRequestInFlight,
           force || Date().timeIntervalSince(lastRouteTrafficFetch) >= routeInterval {
            startRouteTrafficRefresh(using: trafficProvider, route: route, progress: progress)
        }
    }

    private func startNearbyTrafficRefresh(using provider: TrafficProvider, at coordinate: Coordinate) {
        trafficRequestInFlight = true
        lastTrafficFetch = Date()
        if state.traffic == nil { state.trafficStatus = .updating }
        let generation = trafficGeneration
        Task {
            defer { if generation == trafficGeneration { trafficRequestInFlight = false } }
            do {
                let snapshot = try await provider.snapshot(near: coordinate, incidentRadiusMeters: 3_500)
                guard generation == trafficGeneration else { return }
                latestNearbyTrafficSnapshot = snapshot
                publishTrafficSnapshot()
                state.trafficStatus = .available
                if let route = state.route, state.status == .navigating || state.status == .rerouting {
                    let published = state.traffic ?? snapshot
                    if confirmedClosureAhead(in: published, on: route, progress: state.progress) == nil {
                        selectTrafficAdjustedRoute(from: published, currentRoute: route, location: coordinate)
                    }
                }
                updateProgress()
                if let published = state.traffic { handleConfirmedClosure(in: published, near: coordinate) }
            } catch {
                guard generation == trafficGeneration else { return }
                publishTrafficSnapshot()
                state.trafficStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    private func startRouteTrafficRefresh(using provider: TrafficProvider, route: NavigationRoute,
                                          progress: RouteProgress?) {
        let startDistance = max(0, progress?.traveledDistance ?? 0)
        let lookAhead = RouteTrafficMonitor.lookAheadDistance(for: route, progress: progress)
        let endDistance = startDistance + lookAhead
        let boxes = RouteTrafficMonitor.queryBoxes(for: route, from: startDistance, through: endDistance)
        guard !boxes.isEmpty else { return }
        routeTrafficRequestInFlight = true
        lastRouteTrafficFetch = Date()
        if state.traffic == nil { state.trafficStatus = .updating }
        let generation = trafficGeneration
        let routeID = route.id
        Task {
            defer { if generation == trafficGeneration { routeTrafficRequestInFlight = false } }
            do {
                let incidents = try await provider.incidents(in: boxes)
                guard generation == trafficGeneration,
                      state.route?.id == routeID else { return }
                routeTrafficIncidents = RouteTrafficMonitor.matching(
                    incidents, to: route, from: startDistance, through: endDistance)
                routeTrafficDataAvailable = true
                routeTrafficUpdatedAt = Date()
                publishTrafficSnapshot()
                state.trafficStatus = .available
                if let published = state.traffic {
                    let closureAhead = confirmedClosureAhead(in: published, on: route, progress: state.progress) != nil
                    if !closureAhead, state.status == .navigating,
                       let location = state.location?.coordinate {
                        selectTrafficAdjustedRoute(from: published, currentRoute: route,
                                                   location: location)
                    }
                    if let location = state.location?.coordinate {
                        handleConfirmedClosure(in: published, near: location)
                    }
                }
            } catch {
                guard generation == trafficGeneration else { return }
                routeTrafficIncidents = []
                routeTrafficDataAvailable = false
                routeTrafficUpdatedAt = nil
                publishTrafficSnapshot()
                state.trafficStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    private func routeTrafficRefreshInterval(progress: RouteProgress?) -> TimeInterval {
        let distance = progress?.traveledDistance ?? 0
        let nearest = routeTrafficIncidents.compactMap { incident -> (Double, Bool)? in
            guard let along = incident.distanceAlongRoute, along > distance else { return nil }
            return (along - distance, incident.isRoadClosure)
        }.min { $0.0 < $1.0 }
        if nearest?.1 == true, (nearest?.0 ?? .infinity) <= 3_000 { return 20 }
        if (nearest?.0 ?? .infinity) <= 10_000 { return 30 }
        return state.status == .routePreview ? 90 : 60
    }

    private func publishTrafficSnapshot() {
        let now = Date()
        let nearby = latestNearbyTrafficSnapshot.flatMap {
            now.timeIntervalSince($0.updatedAt) <= 180 ? $0 : nil
        }
        let routeDataIsFresh = routeTrafficDataAvailable &&
            now.timeIntervalSince(routeTrafficUpdatedAt ?? .distantPast) <= 120
        guard nearby != nil || routeDataIsFresh else {
            state.traffic = nil
            return
        }
        var incidentsByID: [String: TrafficIncident] = [:]
        for incident in (nearby?.incidents ?? []) + (routeDataIsFresh ? routeTrafficIncidents : []) {
            incidentsByID[incident.id] = incident
        }
        let routeUpdatedAt = routeDataIsFresh ? (routeTrafficUpdatedAt ?? .distantPast) : .distantPast
        state.traffic = TrafficSnapshot(
            flow: nearby?.flow,
            incidents: Array(incidentsByID.values),
            updatedAt: max(nearby?.updatedAt ?? .distantPast, routeUpdatedAt),
            partialError: nearby?.partialError,
            incidentDataAvailable: (nearby?.incidentDataAvailable ?? false) || routeDataIsFresh)
    }

    private func selectTrafficAdjustedRoute(from snapshot: TrafficSnapshot,
                                            currentRoute: NavigationRoute,
                                            location: Coordinate) {
        guard state.transportMode == .car, state.status == .navigating,
              state.route?.id == currentRoute.id else { return }
        let routes = state.routeOptions.isEmpty ? [currentRoute] : state.routeOptions
        guard routes.count > 1 else { return }
        let scores = routes.map { route in
            (route, trafficAdjustedETA(for: route, snapshot: snapshot, at: location))
        }
        guard let best = scores.min(by: { $0.1 < $1.1 }), best.0.id != currentRoute.id,
              let currentScore = scores.first(where: { $0.0.id == currentRoute.id })?.1,
              currentScore.isFinite,
              currentScore - best.1 >= max(120, currentScore * 0.15) else { return }
        state.route = best.0
        state.routeOptions = scores.sorted { $0.1 < $1.1 }.map(\.0)
        state.evChargingStops = best.0.chargingStops.map(\.destination)
        loadRoadData(for: best.0)
        trafficProjectionRouteID = nil
        updateProgress()
        invalidateSpeedLimit()
        if let currentLocation = state.location { refreshSpeedLimit(for: currentLocation) }
        routeTrafficIncidents = []
        routeTrafficDataAvailable = false
        routeTrafficUpdatedAt = nil
        lastRouteTrafficFetch = .distantPast
        publishTrafficSnapshot()
    }

    private func trafficAdjustedETA(for route: NavigationRoute, snapshot: TrafficSnapshot,
                                    at location: Coordinate) -> Double {
        guard let projection = MapMatcher.project(location, onto: route.coordinates),
              projection.distanceFromRoute <= max(150, (state.location?.accuracy ?? 70) * 2) else {
            return .infinity
        }
        let geometryDistance = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard geometryDistance > 0 else { return .infinity }
        let fraction = min(1, max(0, projection.alongRoute / geometryDistance))
        let plannedDrivingTime = max(0, route.expectedTravelTime - route.chargingDuration)
        var eta = plannedDrivingTime * (1 - fraction)
        eta += route.chargingStops.reduce(0.0) { total, stop in
            guard let chargeProjection = MapMatcher.project(stop.destination.coordinate, onto: route.coordinates),
                  chargeProjection.alongRoute > projection.alongRoute + 40 else { return total }
            return total + stop.estimatedChargingTime
        }
        let closures = snapshot.incidents.compactMap { incident -> Double? in
            guard incident.isRoadClosure,
                  let incidentProjection = MapMatcher.project(incident.coordinate, onto: route.coordinates),
                  incidentProjection.distanceFromRoute < 120,
                  incidentProjection.alongRoute > projection.alongRoute + 40 else { return nil }
            return incidentProjection.alongRoute
        }
        if !closures.isEmpty { return .infinity }
        if let flow = snapshot.flow,
           let flowProjection = MapMatcher.project(location, onto: flow.coordinates),
           flowProjection.distanceFromRoute < 80,
           flow.coordinates.count > 1 {
            let flowDistance = zip(flow.coordinates, flow.coordinates.dropFirst())
                .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            let currentSpeed = max(5, Double(flow.currentSpeedKph)) / 3.6
            let freeSpeed = Double(max(1, flow.freeFlowSpeedKph)) / 3.6
            eta += max(0, flowDistance / currentSpeed - flowDistance / freeSpeed)
        }
        let delays = snapshot.incidents.reduce(0.0) { total, incident in
            guard let incidentProjection = MapMatcher.project(incident.coordinate, onto: route.coordinates),
                  incidentProjection.distanceFromRoute < 120,
                  incidentProjection.alongRoute > projection.alongRoute + 40 else { return total }
            return total + Double(max(0, incident.delaySeconds ?? 0))
        }
        return eta + min(1_800, delays)
    }

    func estimatedCarTravelTime(to destination: Destination) async -> TimeInterval? {
        guard let origin = state.location?.coordinate else { return nil }
        do {
            if let provider = routeProvider as? AdvancedRouteProvider {
                let routes = try await provider.calculateRoutes(
                    from: origin, to: destination.coordinate, through: [], mode: .car,
                    preferences: state.routingPreferences, avoiding: [])
                return routes.first?.expectedTravelTime
            }
            let routes = try await routeProvider.calculateRoutes(from: origin, to: destination.coordinate, mode: .car)
            return routes.first?.expectedTravelTime
        } catch {
            return nil
        }
    }

    func selectDestination(_ destination: Destination) {
        requestGeneration += 1
        state.destination = destination
        state.waypoints = []
        state.evChargingStops = []
        state.status = .destinationPreview
        state.cameraState = .destinationPreview
        updateCameraIntent()
        state.route = nil
        state.routeOptions = []
        resetRoadSafetyData()
        state.progress = nil
        state.transitProgress = nil
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        state.errorMessage = nil
        invalidateTraffic()
    }

    func planRoute() async {
        guard let destination = state.destination else { return }
        guard state.location != nil else {
            state.errorMessage = "Czekam na dokładną pozycję GPS."
            return
        }
        await preview(destination)
    }

    func addWaypoint(_ destination: Destination) async {
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
        state.waypoints.swapAt(index, target)
        state.evChargingStops = []
        if let final = state.destination { await preview(final) }
    }

    func optimizeWaypoints() async {
        guard state.waypoints.count >= 2, let origin = state.location?.coordinate,
              let destination = state.destination else { return }
        guard state.transportMode == .car || state.transportMode == .walking || state.transportMode == .bicycle else {
            state.errorMessage = "Optymalizacja przystanków jest dostępna dla tras samochodowych, pieszych i rowerowych."
            return
        }
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            state.errorMessage = "Wybrany serwer nie obsługuje optymalizacji przystanków."
            return
        }
        do {
            let order = try await provider.optimizedWaypointOrder(from: origin, to: destination.coordinate,
                                                                 waypoints: state.waypoints, mode: state.transportMode,
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
        let nearestSearch = !nearDestination && destination == nil
        var coordinates = state.route?.coordinates ?? []
        if let current, let projection = MapMatcher.project(current, onto: coordinates) {
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
        let pendingStops = current.map { unvisitedStops(from: $0).map(\.coordinate) } ?? []
        state.nearbyStatus = .searching
        do {
            let placeProvider = OpenStreetMapNearbyPlaceProvider()
            let candidates: [NearbyPlaceCandidate]
            if nearDestination, let destination {
                candidates = try await placeProvider.search(category, around: destination.coordinate, radius: 2_000)
            } else if nearestSearch, let current {
                candidates = try await placeProvider.search(category, around: current,
                                                            radius: searchRadius, resultLimit: resultLimit)
            } else {
                candidates = try await placeProvider.search(category, along: coordinates, radius: 1_500)
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
            let selected = Array(candidates.prefix(8))
            for index in selected.indices { state.nearbySuggestions[index].estimateStatus = .calculating }
            do {
                if pendingStops.isEmpty, let matrix = provider as? ValhallaRouteProvider {
                    let targets = selected.map { $0.destination.coordinate }
                    async let outbound = matrix.searchMatrix(sources: [current], targets: targets + [destination.coordinate],
                                                              mode: .car, preferences: preferences)
                    async let onward = matrix.searchMatrix(sources: targets, targets: [destination.coordinate],
                                                           mode: .car, preferences: preferences)
                    let (first, second) = try await (outbound, onward)
                    try Task.checkCancellation()
                    guard nearbySearchID == searchID else { return }
                    if let baseline = first[0][targets.count].time {
                        for index in selected.indices {
                            if let arrival = first[0][index].time,
                               let continuation = second[index][0].time {
                                state.nearbySuggestions[index].detourSeconds = max(0, arrival + continuation - baseline)
                            }
                        }
                    }
                } else {
                    let baseline = try await provider.calculateRoutes(from: current, to: destination.coordinate,
                        through: pendingStops, mode: .car, preferences: preferences, avoiding: []).first?.expectedTravelTime
                    if let baseline {
                        // Limit server load while letting independent estimates complete together.
                        for start in stride(from: 0, to: selected.count, by: 3) {
                            try Task.checkCancellation()
                            guard nearbySearchID == searchID else { return }
                            await withTaskGroup(of: (Int, Double?).self) { group in
                                for index in start..<min(start + 3, selected.count) {
                                    let candidate = selected[index]
                                    group.addTask { @MainActor in
                                        do {
                                            let first = try await provider.calculateRoutes(from: current,
                                                to: candidate.destination.coordinate, through: nearDestination ? pendingStops : [],
                                                mode: .car, preferences: preferences, avoiding: []).first
                                            let second = nearDestination ? 0 : try await provider.calculateRoutes(
                                                from: candidate.destination.coordinate, to: destination.coordinate,
                                                through: pendingStops, mode: .car, preferences: preferences, avoiding: []).first?.expectedTravelTime
                                            guard let first, let second else { return (index, nil) }
                                            return (index, max(0, first.expectedTravelTime + second - baseline))
                                        } catch { return (index, nil) }
                                    }
                                }
                                for await (index, detour) in group {
                                    guard nearbySearchID == searchID, !Task.isCancelled else { continue }
                                    state.nearbySuggestions[index].detourSeconds = detour
                                    state.nearbySuggestions[index].estimateStatus = detour == nil ? .unavailable : .notRequested
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

    private func estimateNearbyTravel(for candidates: [NearbyPlaceCandidate], from origin: Coordinate,
                                      preferences: RoutingPreferences, searchID: UUID) async {
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            for index in state.nearbySuggestions.indices {
                state.nearbySuggestions[index].estimateStatus = .unavailable
            }
            return
        }
        for index in candidates.indices where index < state.nearbySuggestions.count {
            state.nearbySuggestions[index].estimateStatus = .calculating
        }
        do {
            if let matrix = routeProvider as? ValhallaRouteProvider {
                let rows = try await matrix.searchMatrix(sources: [origin],
                    targets: candidates.map { $0.destination.coordinate }, mode: .car,
                    preferences: preferences)
                try Task.checkCancellation()
                guard nearbySearchID == searchID else { return }
                for index in candidates.indices {
                    let estimate = rows[0][index]
                    state.nearbySuggestions[index].travelTime = estimate.time
                    state.nearbySuggestions[index].travelDistance = estimate.distance.map { $0 * 1_000 }
                }
            } else {
                for start in stride(from: 0, to: candidates.count, by: 3) {
                    try Task.checkCancellation()
                    guard nearbySearchID == searchID else { return }
                    await withTaskGroup(of: (Int, TimeInterval?, Double?).self) { group in
                        for index in start..<min(start + 3, candidates.count) {
                            let candidate = candidates[index]
                            group.addTask { @MainActor in
                                do {
                                    let route = try await provider.calculateRoutes(from: origin,
                                        to: candidate.destination.coordinate, through: [], mode: .car,
                                        preferences: preferences, avoiding: []).first
                                    return (index, route?.expectedTravelTime, route?.distance)
                                } catch {
                                    return (index, nil, nil)
                                }
                            }
                        }
                        for await (index, travelTime, travelDistance) in group {
                            guard nearbySearchID == searchID, !Task.isCancelled else { continue }
                            state.nearbySuggestions[index].travelTime = travelTime
                            state.nearbySuggestions[index].travelDistance = travelDistance
                        }
                    }
                }
            }
        } catch {
            guard nearbySearchID == searchID, !Task.isCancelled else { return }
        }
        guard nearbySearchID == searchID, !Task.isCancelled else { return }
        for index in candidates.indices where index < state.nearbySuggestions.count {
            let suggestion = state.nearbySuggestions[index]
            state.nearbySuggestions[index].estimateStatus = suggestion.travelTime != nil && suggestion.travelDistance != nil
                ? .notRequested : .unavailable
        }
    }

    func selectNearbyPlace(_ destination: Destination, asFinalParking: Bool) async {
        guard state.destination != nil else {
            await preview(destination)
            return
        }
        let active = state.status == .navigating || state.status == .rerouting
        if asFinalParking {
            state.destination = destination
            state.evChargingStops = []
            tripSession?.destination = destination
            if active, let location = state.location?.coordinate { await reroute(from: location) }
            else { await preview(destination) }
            return
        }
        if active, let location = state.location?.coordinate {
            state.waypoints.insert(destination, at: 0)
            tripSession?.waypoints.insert(destination, at: 0)
            await reroute(from: location)
        } else {
            await addWaypoint(destination)
        }
    }

    func preview(_ destination: Destination) async {
        guard let origin = state.location?.coordinate else {
            state.status = .error
            state.errorMessage = "Czekam na dokładną pozycję GPS."
            return
        }
        requestGeneration += 1
        let generation = requestGeneration
        state.destination = destination
        state.evChargingStops = []
        state.status = .routeCalculating
        state.route = nil
        state.routeOptions = []
        state.progress = nil
        state.transitProgress = nil
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        state.errorMessage = nil
        // The destination camera stays in place until route geometry is available.
        do {
            let routes = try await calculateRoutes(from: origin, to: destination.coordinate)
            guard generation == requestGeneration else { return }
            guard let firstRoute = routes.first else { throw RoutingError.invalidResponse }
            state.route = firstRoute
            state.routeOptions = routes
            state.status = .routePreview
            state.cameraState = .routeOverview
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
            if state.transportMode == .car { loadRoadData(for: firstRoute) }
        } catch {
            guard generation == requestGeneration else { return }
            state.status = .error
            state.errorMessage = error.localizedDescription
        }
    }
    func select(_ route: NavigationRoute) {
        guard state.status == .routePreview,
              state.route?.id != route.id,
              let selectedRoute = state.routeOptions.first(where: { $0.id == route.id }) else { return }
        state.route = selectedRoute
        state.evChargingStops = selectedRoute.chargingStops.map(\.destination)
        if state.transportMode == .car { loadRoadData(for: selectedRoute) }
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
    func begin() {
        guard let route = state.route,
              state.transportMode != .transit || route.journey != nil else { return }
        revealTask?.cancel()
        state.routeRevealProgress = 1
        voice.reset()
        resetTransitRideConfirmation()
        cameraManeuverID = state.progress?.nextManeuver?.id
        maneuverTransitionTask?.cancel()
        state.status = .navigating
        state.cameraState = .startingNavigation
        if state.transportMode == .transit {
            state.transitBackgroundLocationAvailable = locationManager.requestTransitBackgroundAuthorization()
            if !locationManager.backgroundLocationModeEnabled {
                state.errorMessage = "Aplikacja nie ma skonfigurowanego śledzenia lokalizacji w tle."
            }
        }
        if state.transportMode == .transit { updateProgress() }
        updateCameraIntent()
        navigationTransitionTask?.cancel()
        navigationTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self, self.state.status == .navigating else { return }
            self.updateNavigationCameraState()
        }
        if let destination = state.destination, let route = state.route {
            tripSession = TripSession(destination: destination, waypoints: state.waypoints,
                                      originalExpectedTravelTime: route.expectedTravelTime,
                                      startedAt: Date(), lastLocation: state.location)
        }
        invalidateSpeedLimit()
        if state.transportMode == .car { refreshTraffic(force: true) }
    }
    func stop() {
        finishTrip(arrived: state.status == .arrived)
        requestGeneration += 1
        invalidateTraffic()
        invalidateSpeedLimit()
        voice.reset()
        state.route = nil; state.routeOptions = []; state.progress = nil; state.destination = nil
        resetRoadSafetyData()
        state.transitProgress = nil
        transitTripDetails = nil
        transitTripDetailsID = nil
        lastTransitProgressLegIndex = nil
        resetTransitRideConfirmation()
        locationManager.stopBackgroundNavigationUpdates()
        state.waypoints = []
        state.evChargingStops = []
        state.weakGPS = false
        state.gpsQuality = .noSignal
        cameraManeuverID = nil
        revealTask?.cancel()
        navigationTransitionTask?.cancel()
        maneuverTransitionTask?.cancel()
        state.status = .idle; state.cameraState = .browse
        updateCameraIntent()
        state.traffic = nil
        offRouteSince = nil
        previousRouteMatch = nil
        refreshTraffic(force: true)
        
    }
    private func receive(_ raw: CLLocation) {
        guard filter.accept(raw, mode: state.transportMode) else { return }
        let coordinate = Coordinate(latitude: raw.coordinate.latitude, longitude: raw.coordinate.longitude)
        state.location = NavigationLocation(coordinate: coordinate, speed: raw.speed, course: raw.course,
                                            accuracy: raw.horizontalAccuracy, timestamp: raw.timestamp)
        state.cameraLocation = state.location
        lastAcceptedFix = raw.timestamp
        state.weakGPS = false
        state.gpsQuality = raw.horizontalAccuracy <= 10 ? .excellent : (raw.horizontalAccuracy <= 35 ? .good : .weak)
        tripSession?.record(state.location!)
        updateProgress()
        if state.status == .idle || state.status == .destinationPreview || state.status == .routeCalculating {
            updateCameraIntent()
        }
        if state.status == .navigating || state.status == .rerouting {
            if state.cameraState != .startingNavigation { updateNavigationCameraState() }
            if state.transportMode == .car {
                refreshSpeedLimit(for: state.location!)
            }
        }
        if state.transportMode == .car { refreshTraffic() }
    }
    private func updateProgress() {
        if state.transportMode == .transit,
           let route = state.route, let journey = route.journey {
            let isActive = state.status == .navigating || state.status == .rerouting
            let tracked = state.location.flatMap {
                TransitRouteProgressCalculator.progress(route: route, at: $0.coordinate,
                                                        accuracy: $0.accuracy,
                                                        previousLegIndex: lastTransitProgressLegIndex)
            }
            if let tracked { lastTransitProgressLegIndex = tracked.legIndex }
            var transitProgress = tracked
            if var matched = transitProgress, journey.legs.indices.contains(matched.legIndex) {
                let leg = journey.legs[matched.legIndex]
                if leg.mode.uppercased() == "WALK" {
                    resetTransitRideConfirmation()
                } else if isActive, let location = state.location {
                    let isOnVehicle = confirmTransitRide(progress: matched, leg: leg, location: location)
                    if isOnVehicle, let tripID = leg.tripID,
                       let vehicle = currentTransitVehicle(for: tripID),
                       let vehicleProgress = TransitRouteProgressCalculator.progress(
                        route: route, at: vehicle.coordinate, accuracy: 80,
                        previousLegIndex: matched.legIndex),
                       vehicleProgress.legIndex == matched.legIndex {
                        matched = vehicleProgress
                    }
                    matched.isOnVehicle = isOnVehicle
                    transitProgress = matched
                }
            }
            state.transitProgress = transitProgress

            let progressFraction = transitProgress?.routeFraction ??
                (isActive
                    ? max(0, min(1, 1 - journey.arrival.timeIntervalSinceNow / max(1, route.expectedTravelTime)))
                    : 0)
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
                                           nextManeuver: nil)
            state.estimatedArrival = isActive ? estimatedArrival : Date().addingTimeInterval(remainingTime)

            if isActive, let location = state.location,
               location.coordinate.distance(to: state.destination?.coordinate ?? route.coordinates.last!) <= 45 {
                state.status = .arrived
                state.cameraState = .arrived
                updateCameraIntent()
                locationManager.stopBackgroundNavigationUpdates()
                if state.voiceEnabled {
                    voice.announceTransit("Dotarłeś do celu.", key: "arrival-\(route.id)")
                }
                finishTrip(arrived: true)
                return
            }
            if isActive, let transitProgress {
                updateTransitVoice(for: transitProgress, journey: journey)
            }
            return
        }
        guard let route = state.route, let location = state.location else { return }
        let previousMatch = previousRouteMatch?.routeID == route.id ? previousRouteMatch : nil
        let routeMatch = MapMatcher.match(location, onto: route.coordinates,
                                          previous: previousMatch?.projection,
                                          previousTimestamp: previousMatch?.timestamp)
        guard let projection = routeMatch?.projection
            ?? MapMatcher.project(location.coordinate, onto: route.coordinates) else { return }
        previousRouteMatch = (route.id, projection, location.timestamp)
        let totalGeometry = route.distance > 0
            ? route.distance
            : zip(route.coordinates, route.coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        let fraction = totalGeometry > 0 ? min(1, projection.alongRoute / totalGeometry) : 0
        let next = route.maneuvers.first { $0.shapeIndex >= projection.segment + 1 }
        let maneuverDistance: Double
        if let next {
            maneuverDistance = route.coordinates[projection.segment...next.shapeIndex].adjacentDistance() -
                route.coordinates[projection.segment].distance(to: projection.coordinate)
        } else { maneuverDistance = 0 }
        let remainingDistance = route.distance * (1 - fraction)
        let plannedDrivingTime = max(0, route.expectedTravelTime - route.chargingDuration)
        var drivingTimeRemaining = plannedDrivingTime * (1 - fraction)
        if let session = tripSession, session.movingSeconds >= 45, session.distanceMeters > 25,
           plannedDrivingTime > 0 {
            let plannedSpeed = route.distance / plannedDrivingTime
            let observedSpeed = session.distanceMeters / session.movingSeconds
            let paceFactor = max(0.65, min(1.8, plannedSpeed / max(1, observedSpeed)))
            drivingTimeRemaining *= 1 + (paceFactor - 1) * 0.55
        }
        if let flow = state.traffic?.flow, flow.coordinates.count > 1,
           let flowProjection = MapMatcher.project(location.coordinate, onto: flow.coordinates),
           flowProjection.distanceFromRoute < 80 {
            let flowDistance = zip(flow.coordinates, flow.coordinates.dropFirst())
                .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            let currentSpeed = max(5, Double(flow.currentSpeedKph)) / 3.6
            let freeFlowSpeed = Double(max(1, flow.freeFlowSpeedKph)) / 3.6
            drivingTimeRemaining += max(0, flowDistance / currentSpeed - flowDistance / freeFlowSpeed)
        }
        let chargingTimeRemaining = route.chargingStops.reduce(0.0) { total, stop in
            guard let chargeProjection = MapMatcher.project(stop.destination.coordinate, onto: route.coordinates),
                  chargeProjection.alongRoute > projection.alongRoute + 40 else { return total }
            return total + stop.estimatedChargingTime
        }
        let remainingTime = drivingTimeRemaining + chargingTimeRemaining
            + upcomingTrafficDelay(on: route, after: projection.alongRoute)
        state.progress = RouteProgress(traveledDistance: route.distance * fraction,
                                       remainingDistance: remainingDistance,
                                       remainingTime: max(0, remainingTime),
                                       distanceToNextManeuver: max(0, maneuverDistance), nextManeuver: next)
        state.estimatedArrival = Date().addingTimeInterval(max(0, remainingTime))
        guard state.status == .navigating || state.status == .rerouting else { return }
        if location.speed >= 0, location.speed < 2,
           state.progress!.remainingDistance < 35,
           location.coordinate.distance(to: state.destination?.coordinate ?? coordinateFallback(route)) < 50 {
            state.status = .arrived
            state.cameraState = .arrived
            updateCameraIntent()
            voice.reset(); finishTrip(arrived: true); return
        }
        if let next, state.voiceEnabled { voice.announce(next, distance: max(0, maneuverDistance), speed: max(0, location.speed)) }
        if state.voiceEnabled {
            for alert in state.roadSafetyAlerts {
                guard let alongRoute = alert.distanceAlongRoute else { continue }
                let distance = alongRoute - projection.alongRoute
                if distance >= 0 && distance <= 1_200 {
                    voice.announce(alert, distance: distance, routeID: route.id)
                }
            }
        }
        guard state.transportMode != .parkRide else { return }
        let sustainedDeparture = location.accuracy <= 45
            && projection.distanceFromRoute > max(40, location.accuracy * 1.5)
            && (routeMatch?.confidence ?? 0) < 0.25
        if sustainedDeparture {
            if let offRouteSince,
               location.timestamp.timeIntervalSince(offRouteSince) >= 2,
               Date().timeIntervalSince(lastReroute) > 20,
               state.status != .rerouting {
                lastReroute = Date()
                self.offRouteSince = nil
                Task { await reroute(from: location.coordinate) }
            } else if offRouteSince == nil {
                offRouteSince = location.timestamp
            }
        } else {
            offRouteSince = nil
        }
    }

    private func upcomingTrafficDelay(on route: NavigationRoute, after distance: Double) -> Double {
        guard let traffic = state.traffic else { return 0 }
        if trafficProjectionRouteID != route.id || trafficProjectionUpdatedAt != traffic.updatedAt {
            trafficProjectionRouteID = route.id
            trafficProjectionUpdatedAt = traffic.updatedAt
            projectedTrafficIncidents = traffic.incidents.compactMap { incident in
                guard let projection = MapMatcher.project(incident.coordinate, onto: route.coordinates) else { return nil }
                return (alongRoute: projection.alongRoute, delaySeconds: incident.delaySeconds)
            }
        }
        let delay = projectedTrafficIncidents.reduce(0.0) { total, incident in
            guard incident.alongRoute > distance + 40 else { return total }
            return total + Double(max(0, incident.delaySeconds ?? 0))
        }
        return min(1_800, delay)
    }

    private func confirmTransitRide(progress: TransitNavigationProgress, leg: JourneyLeg,
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

    private func currentTransitVehicle(for tripID: String) -> TransitVehicle? {
        let now = Date()
        if transitTripDetailsID == tripID, let vehicle = transitTripDetails?.vehicle,
           (-60...120).contains(now.timeIntervalSince(vehicle.updatedAt)) {
            return vehicle
        }
        return state.transitVehicles.first {
            $0.tripID == tripID && (-60...120).contains(now.timeIntervalSince($0.updatedAt))
        }
    }

    private func updateTransitVoice(for progress: TransitNavigationProgress, journey: Journey) {
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
            voice.announceTransit(instruction, key: "walk-\(state.route?.id.uuidString ?? "route")-\(progress.legIndex)")
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
        if remainingStops == 2 {
            voice.announceTransit("Za dwa przystanki wysiądź na \(alightingStop.name).\(transfer)",
                                  key: "alight-2-\(tripID)-\(alightingStop.stopID)")
        } else if remainingStops == 1 {
            voice.announceTransit("Następny przystanek: \(alightingStop.name). Przygotuj się do wysiadania.\(transfer)",
                                  key: "alight-1-\(tripID)-\(alightingStop.stopID)")
        }
    }

    private func resetTransitRideConfirmation() {
        transitRideTrackingID = nil
        confirmedTransitTripID = nil
        transitRideMotionEvidence = 0
        lastTransitRideDistance = 0
    }
    private func coordinateFallback(_ route: NavigationRoute) -> Coordinate { route.coordinates.last! }

    private func refreshTransitVehicles(near coordinate: Coordinate) {
        let lodzCenter = Coordinate(latitude: 51.7592, longitude: 19.4560)
        guard coordinate.distance(to: lodzCenter) <= 100_000 else {
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
              Date().timeIntervalSince(lastTransitVehiclesFetch) >= 30 else { return }
        transitVehiclesRequestInFlight = true
        lastTransitVehiclesFetch = Date()
        transitVehiclesGeneration &+= 1
        let generation = transitVehiclesGeneration
        let provider = transitProvider
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

    private func invalidateTraffic() {
        trafficGeneration += 1
        trafficRequestInFlight = false
        routeTrafficRequestInFlight = false
        lastTrafficFetch = .distantPast
        lastRouteTrafficFetch = .distantPast
        latestNearbyTrafficSnapshot = nil
        routeTrafficIncidents = []
        routeTrafficDataAvailable = false
        routeTrafficUpdatedAt = nil
        state.traffic = nil
    }
    private func invalidateSpeedLimit() {
        speedLimitGeneration += 1
        speedLimitRequestInFlight = false
        lastSpeedLimitFetch = .distantPast
        state.speedLimitKph = nil
        state.speedLimitSource = nil
        state.speedLimitMessage = nil
    }
    private func refreshSpeedLimit(for location: NavigationLocation, force: Bool = false) {
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

    private func loadRoadData(for route: NavigationRoute) {
        guard route.coordinates.count > 1, state.transportMode == .car else { return }
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
                let snapshot = try await provider.load(for: route.coordinates)
                guard generation == self.roadDataGeneration,
                      self.state.route?.id == routeID,
                      self.state.transportMode == .car else { return }
                self.invalidateSpeedLimit()
                self.roadDataSnapshot = snapshot
                self.state.roadSafetyAlerts = snapshot.matchedAlerts(on: route.coordinates)
                self.state.roadSafetyStatus = .available
                self.updateProgress()
                if let location = self.state.location,
                   self.state.status == .navigating || self.state.status == .rerouting {
                    self.refreshSpeedLimit(for: location, force: true)
                }
            } catch {
                guard generation == self.roadDataGeneration,
                      self.state.route?.id == routeID else { return }
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
    private func finishTrip(arrived: Bool) {
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
    private func reroute(from origin: Coordinate) async {
        guard let destination = state.destination else { return }
        state.status = .rerouting
        if state.cameraState != .freeLook { state.cameraState = .rerouting; updateCameraIntent() }
        do {
            let remainingStops = unvisitedStops(from: origin)
            let routes = try await calculateRoutes(from: origin, to: destination.coordinate,
                                                   through: remainingStops.map(\.coordinate))
            guard state.status == .rerouting else { return }
            guard let firstRoute = routes.first else { throw RoutingError.invalidResponse }
            state.route = firstRoute; state.routeOptions = routes
            if state.transportMode == .car { loadRoadData(for: firstRoute) }
            tripSession?.rerouteCount += 1
            invalidateTraffic()
            invalidateSpeedLimit()
            state.status = .navigating; voice.reset(); updateProgress()
            updateNavigationCameraState()
            if state.transportMode == .car { refreshTraffic(force: true) }
        } catch {
            guard state.status == .rerouting else { return }
            state.status = .navigating
            updateNavigationCameraState()
            state.errorMessage = "Nie udało się przeliczyć trasy: \(error.localizedDescription)"
        }
    }

    private func unvisitedStops(from origin: Coordinate) -> [Destination] {
        let stops = state.waypoints + state.evChargingStops
        guard let route = state.route,
              let current = MapMatcher.project(origin, onto: route.coordinates) else { return stops }
        return stops.compactMap { stop -> (Destination, Double)? in
            guard let projection = MapMatcher.project(stop.coordinate, onto: route.coordinates),
                  projection.alongRoute > current.alongRoute + 50 else { return nil }
            return (stop, projection.alongRoute)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }
    private func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate]? = nil) async throws -> [NavigationRoute] {
        if state.transportMode == .transit {
            return try await transitProvider.calculateRoutes(from: from, to: to,
                                                            departingAt: Date())
        }
        if state.transportMode == .parkRide {
            return try await calculateParkRideRoutes(from: from, to: to)
        }
        let stops = through ?? state.waypoints.map(\.coordinate)
        if let provider = routeProvider as? AdvancedRouteProvider {
            if state.transportMode == .car, state.routingPreferences.evPlanningEnabled {
                let mandatoryStops = through.map { coordinates in
                    state.waypoints.filter { waypoint in
                        coordinates.contains { $0.distance(to: waypoint.coordinate) <= 10 }
                    }
                } ?? state.waypoints
                return try await calculateEVRoutes(from: from, to: to, explicitStops: mandatoryStops,
                                                   provider: provider, avoiding: [])
            }
            return try await provider.calculateRoutes(from: from, to: to, through: stops,
                                                      mode: state.transportMode,
                                                      preferences: state.routingPreferences, avoiding: [])
        }
        guard stops.isEmpty else { throw RoutingError.invalidResponse }
        return try await routeProvider.calculateRoutes(from: from, to: to, mode: state.transportMode)
    }

    private func calculateParkRideRoutes(from: Coordinate, to: Coordinate) async throws -> [NavigationRoute] {
        guard let provider = routeProvider as? AdvancedRouteProvider else {
            throw TransitRoutingError.noParkRide
        }
        let baseRoute: NavigationRoute
        do {
            guard let route = try await provider.calculateRoutes(
                from: from, to: to, through: [], mode: .car,
                preferences: state.routingPreferences, avoiding: []).first else {
                throw TransitRoutingError.noParkRide
            }
            baseRoute = route
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TransitRoutingError.noParkRide
        }
        let finalApproach = routeSuffix(baseRoute.coordinates, length: 40_000)
        async let corridorSearch = try? OpenStreetMapNearbyPlaceProvider()
            .search(.parkRide, along: finalApproach, radius: 5_000)
        async let destinationSearch = try? OpenStreetMapNearbyPlaceProvider()
            .search(.parkRide, around: to, radius: 15_000)
        let parkings: [NearbyPlaceCandidate]
        let (corridorCandidates, destinationCandidates) = await (corridorSearch, destinationSearch)
        try Task.checkCancellation()
        var uniqueParkings: [String: NearbyPlaceCandidate] = [:]
        for parking in (corridorCandidates ?? []) + (destinationCandidates ?? []) {
            uniqueParkings[parking.id] = parking
        }
        parkings = Array(uniqueParkings.values).sorted {
            to.distance(to: $0.destination.coordinate) < to.distance(to: $1.destination.coordinate)
        }
        guard !parkings.isEmpty else { throw TransitRoutingError.noParkRide }
        let departure = Date()
        var combined: [NavigationRoute] = []
        for parking in parkings.prefix(12) {
            try Task.checkCancellation()
            let carRoutes: [NavigationRoute]
            do {
                carRoutes = try await provider.calculateRoutes(
                    from: from, to: parking.destination.coordinate, through: [], mode: .car,
                    preferences: state.routingPreferences, avoiding: [])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            guard let carRoute = carRoutes.first else { continue }
            let parkingArrival = departure.addingTimeInterval(carRoute.expectedTravelTime)
            let transitRoutes: [NavigationRoute]
            do {
                transitRoutes = try await transitProvider.calculateRoutes(
                    from: parking.destination.coordinate, to: to, departingAt: parkingArrival)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            for transitRoute in transitRoutes.prefix(2) {
                guard let journey = transitRoute.journey else { continue }
                let carLeg = JourneyLeg(mode: "CAR", line: "P+R", from: "Początek",
                                        to: parking.destination.name, departure: departure,
                                        arrival: parkingArrival, realTime: false,
                                        coordinates: carRoute.coordinates)
                var coordinates = carRoute.coordinates
                coordinates.append(contentsOf: transitRoute.coordinates.dropFirst())
                combined.append(NavigationRoute(
                    coordinates: coordinates,
                    distance: carRoute.distance + transitRoute.distance,
                    expectedTravelTime: journey.arrival.timeIntervalSince(departure),
                    maneuvers: carRoute.maneuvers,
                    journey: Journey(departure: departure, arrival: journey.arrival,
                                     legs: [carLeg] + journey.legs,
                                     scheduleIsCached: journey.scheduleIsCached,
                                     realtimeFeedAvailable: journey.realtimeFeedAvailable,
                                     realtimeFeedUpdatedAt: journey.realtimeFeedUpdatedAt,
                                     alertsFeedAvailable: journey.alertsFeedAvailable,
                                     alerts: journey.alerts,
                                     walkingDuration: journey.walkingDuration,
                                     waitingDuration: journey.waitingDuration,
                                     transferCount: journey.transferCount,
                                     realtimeFreshness: journey.realtimeFreshness)
                ))
            }
        }
        guard !combined.isEmpty else { throw TransitRoutingError.noParkRide }
        return combined.sorted { parkRideCost($0) < parkRideCost($1) }.prefix(3).map { $0 }
    }

    private func routeSuffix(_ route: [Coordinate], length: Double) -> [Coordinate] {
        guard route.count > 1, length > 0 else { return route }
        var reversed = [route.last!]
        var remaining = length
        for index in stride(from: route.count - 2, through: 0, by: -1) {
            let start = route[index]
            let end = route[index + 1]
            let segmentLength = start.distance(to: end)
            if segmentLength >= remaining, segmentLength > 0 {
                let fraction = 1 - remaining / segmentLength
                reversed.append(Coordinate(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction))
                return Array(reversed.reversed())
            }
            reversed.append(start)
            remaining -= segmentLength
        }
        return Array(reversed.reversed())
    }

    private func parkRideCost(_ route: NavigationRoute) -> Double {
        guard let journey = route.journey else { return route.expectedTravelTime }
        let carTime = journey.legs.filter { $0.mode == "CAR" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        let rideTime = journey.legs.filter { $0.mode != "CAR" && $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        return carTime + rideTime + journey.walkingDuration * 1.6
            + journey.waitingDuration * 1.25 + Double(journey.transferCount) * 240
    }

    private func calculateEVRoutes(from: Coordinate, to: Coordinate, explicitStops: [Destination],
                                   provider: AdvancedRouteProvider,
                                   avoiding: [Coordinate] = []) async throws -> [NavigationRoute] {
        let preferences = state.routingPreferences
        guard preferences.evRangeKilometers > 0 else { throw EVPlanningError.rangeNotConfigured }
        guard preferences.evConsumptionKWhPer100Km > 0,
              preferences.evMaximumChargingPowerKW > 0 else {
            throw EVPlanningError.consumptionNotConfigured
        }
        let baseRoutes = try await provider.calculateRoutes(from: from, to: to,
                                                            through: explicitStops.map(\.coordinate), mode: .car,
                                                            preferences: preferences, avoiding: avoiding)
        guard let baseRoute = baseRoutes.first else { throw RoutingError.invalidResponse }
        let availableRange = preferences.availableEVRangeKilometers * 1_000
        let fullRange = preferences.evRangeKilometers * 1_000
        guard availableRange > 0, fullRange > 0 else { throw EVPlanningError.rangeNotConfigured }
        let baseLength = zip(baseRoute.coordinates, baseRoute.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard baseLength > 0 else { throw RoutingError.invalidResponse }
        guard baseLength > availableRange * 0.8 else {
            state.evChargingStops = []
            return baseRoutes
        }

        let chargers = try await OpenStreetMapNearbyPlaceProvider().search(.charging, along: baseRoute.coordinates,
                                                                           radius: 1_200)
        let eligibleChargers = chargers.filter { candidate in
            guard let station = candidate.chargingStation,
                  station.availability != .unavailable,
                  station.publicAccess != false,
                  let power = station.maximumPowerKW, power > 0,
                  !station.connectorTypes.isEmpty else { return false }
            guard !preferences.evConnectorTypes.isEmpty else { return true }
            let stationConnectors = Set(station.connectorTypes)
            return preferences.evConnectorTypes.contains { selected in
                switch selected {
                case "ccs": stationConnectors.contains("ccs") || stationConnectors.contains("type2_combo")
                case "type2": stationConnectors.contains("type2") || stationConnectors.contains("type2_combo")
                default: stationConnectors.contains(selected)
                }
            }
        }.sorted { $0.distanceFromRoute < $1.distanceFromRoute }
        var selected: [NearbyPlaceCandidate] = []
        var progress = 0.0
        var segmentRange = availableRange
        while baseLength - progress > segmentRange * 0.8 {
            let limit = progress + segmentRange * 0.68
            let selectedIDs = Set(selected.map(\.id))
            let reachable = eligibleChargers.filter { candidate in
                candidate.distanceFromRoute > progress + 300 && candidate.distanceFromRoute <= limit &&
                    !selectedIDs.contains(candidate.id)
            }
            guard let furthestProgress = reachable.map(\.distanceFromRoute).max() else {
                throw EVPlanningError.chargersUnavailable
            }
            let nearFurthest = reachable.filter { furthestProgress - $0.distanceFromRoute <= 1_000 }
            guard let next = nearFurthest.max(by: {
                ($0.chargingStation?.maximumPowerKW ?? 0) < ($1.chargingStation?.maximumPowerKW ?? 0)
            }) else { throw EVPlanningError.chargersUnavailable }
            selected.append(next)
            progress = next.distanceFromRoute
            segmentRange = fullRange
            if selected.count > 10 { throw EVPlanningError.chargersUnavailable }
        }
        let orderedStops = (explicitStops.map { destination -> (Destination, Double) in
            let along = MapMatcher.project(destination.coordinate, onto: baseRoute.coordinates)?.alongRoute ?? .infinity
            return (destination, along)
        } + selected.map { ($0.destination, $0.distanceFromRoute) })
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let routes = try await provider.calculateRoutes(from: from, to: to,
                                                        through: orderedStops.map(\.coordinate),
                                                        mode: .car, preferences: preferences, avoiding: avoiding)
        var energyFeasible: [NavigationRoute] = []
        for var route in routes {
            guard let chargePlan = evChargePlan(on: route, chargingCandidates: selected,
                                                fullRange: fullRange, initialRange: availableRange,
                                                consumptionKWhPer100Km: preferences.evConsumptionKWhPer100Km,
                                                vehicleMaximumPowerKW: preferences.evMaximumChargingPowerKW) else {
                continue
            }
            route.chargingStops = chargePlan.stops
            route.chargingDuration = chargePlan.duration
            route.expectedTravelTime += chargePlan.duration
            energyFeasible.append(route)
        }
        guard !energyFeasible.isEmpty else { throw EVPlanningError.chargersUnavailable }
        let rankedRoutes = energyFeasible.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
        state.evChargingStops = rankedRoutes[0].chargingStops.map(\.destination)
        return rankedRoutes
    }

    private func evChargePlan(on route: NavigationRoute, chargingCandidates: [NearbyPlaceCandidate],
                              fullRange: Double, initialRange: Double,
                              consumptionKWhPer100Km: Double,
                              vehicleMaximumPowerKW: Double) -> (stops: [EVChargingStop], duration: TimeInterval)? {
        let routeLength = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard routeLength > 0 else { return nil }
        let stations = chargingCandidates.compactMap { candidate -> (NearbyPlaceCandidate, Double, ChargingStationCapabilities)? in
            guard let station = candidate.chargingStation,
                  let projection = MapMatcher.project(candidate.destination.coordinate, onto: route.coordinates),
                  projection.distanceFromRoute <= 1_500,
                  station.maximumPowerKW != nil else { return nil }
            return (candidate, projection.alongRoute, station)
        }.sorted { $0.1 < $1.1 }
        guard !stations.isEmpty else { return nil }
        var progress = 0.0
        var remainingRange = initialRange
        var plans: [EVChargingStop] = []
        for index in stations.indices {
            let (candidate, stationPosition, station) = stations[index]
            let distanceToStation = stationPosition - progress
            guard distanceToStation > 0,
                  distanceToStation <= remainingRange * 0.8 else { return nil }
            let rangeAtStation = remainingRange - distanceToStation
            let nextPosition = index + 1 < stations.count ? stations[index + 1].1 : routeLength
            let distanceToNextStop = nextPosition - stationPosition
            guard distanceToNextStop > 0,
                  distanceToNextStop <= fullRange * 0.8 else { return nil }
            let targetRange = min(fullRange, distanceToNextStop / 0.8)
            let addedRange = max(0, targetRange - rangeAtStation)
            let acceptedPower = min(station.maximumPowerKW ?? 0, vehicleMaximumPowerKW)
            guard acceptedPower > 0 else { return nil }
            let energyKWh = addedRange / 1_000 / 100 * consumptionKWhPer100Km
            let chargingTime = energyKWh / acceptedPower * 3_600
            plans.append(EVChargingStop(
                id: candidate.id, destination: candidate.destination,
                connectorTypes: station.connectorTypes, maximumPowerKW: acceptedPower,
                estimatedChargingTime: chargingTime,
                availabilityKnown: station.availability == .available,
                publicAccess: station.publicAccess))
            remainingRange = min(fullRange, rangeAtStation + addedRange)
            progress = stationPosition
        }
        guard routeLength - progress <= remainingRange * 0.8 else { return nil }
        return (plans, plans.reduce(0) { $0 + $1.estimatedChargingTime })
    }

    private func handleConfirmedClosure(in snapshot: TrafficSnapshot, near location: Coordinate) {
        guard (state.status == .navigating || state.status == .rerouting), let route = state.route,
              let progress = state.progress, state.transportMode == .car,
              let provider = routeProvider as? AdvancedRouteProvider else { return }
        guard let closureIncident = confirmedClosureAhead(in: snapshot, on: route, progress: progress) else { return }
        guard autoReroutedClosures.insert(closureIncident.id).inserted else { return }
        Task {
            do {
                let stops = unvisitedStops(from: location)
                let routes: [NavigationRoute]
                if state.routingPreferences.evPlanningEnabled {
                    let mandatoryStops = stops.filter { stop in
                        state.waypoints.contains(where: { $0.id == stop.id })
                    }
                    routes = try await calculateEVRoutes(
                        from: location, to: state.destination?.coordinate ?? route.coordinates.last!,
                        explicitStops: mandatoryStops, provider: provider,
                        avoiding: [closureIncident.coordinate])
                } else {
                    routes = try await provider.calculateRoutes(
                        from: location, to: state.destination?.coordinate ?? route.coordinates.last!,
                        through: stops.map(\.coordinate), mode: .car,
                        preferences: state.routingPreferences, avoiding: [closureIncident.coordinate])
                }
                guard state.status == .navigating || state.status == .rerouting,
                      let alternative = routes.first else { return }
                state.route = alternative
                state.routeOptions = routes
                if state.transportMode == .car { loadRoadData(for: alternative) }
                tripSession?.rerouteCount += 1
                invalidateTraffic()
                updateProgress()
                updateNavigationCameraState()
                refreshTraffic(force: true)
            } catch {
                state.errorMessage = "Nie udało się ominąć zgłoszonego zamknięcia: \(error.localizedDescription)"
            }
        }
    }

    private func confirmedClosureAhead(in snapshot: TrafficSnapshot, on route: NavigationRoute,
                                       progress: RouteProgress?) -> TrafficIncident? {
        let traveledDistance = progress?.traveledDistance ?? 0
        let lookAheadEnd = traveledDistance + RouteTrafficMonitor.lookAheadDistance(for: route, progress: progress)
        return snapshot.incidents.compactMap { incident -> (TrafficIncident, Double)? in
            let updatedAt = incident.distanceAlongRoute != nil
                ? routeTrafficUpdatedAt
                : latestNearbyTrafficSnapshot?.updatedAt
            guard let updatedAt, Date().timeIntervalSince(updatedAt) <= 120 else { return nil }
            guard incident.isRoadClosure,
                  let distance = closureDistanceAlongRoute(for: incident, on: route),
                  distance > traveledDistance + 100,
                  distance < lookAheadEnd else { return nil }
            return (incident, distance)
        }.min { $0.1 < $1.1 }?.0
    }

    private func closureDistanceAlongRoute(for incident: TrafficIncident,
                                           on route: NavigationRoute) -> Double? {
        if let alongRoute = incident.distanceAlongRoute { return alongRoute }
        let geometry = incident.geometry.isEmpty ? [incident.coordinate] : incident.geometry
        guard let projection = geometry.compactMap({ MapMatcher.project($0, onto: route.coordinates) })
            .min(by: { $0.distanceFromRoute < $1.distanceFromRoute }),
              projection.distanceFromRoute <= RouteTrafficMonitor.routeMatchToleranceMeters else { return nil }
        return projection.alongRoute
    }
}

private extension ArraySlice where Element == Coordinate {
    func adjacentDistance() -> Double { zip(self, dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
}


private struct TripSession {
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
