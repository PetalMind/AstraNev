import Foundation
import OSLog
#if os(iOS) && NAVIGATION_WIDGETS_ENABLED
import ActivityKit
#endif

@MainActor
final class NavigationLiveActivityManager {
#if os(iOS) && NAVIGATION_WIDGETS_ENABLED
    private var activity: Activity<NavigationActivityAttributes>?
    private var pending: NavigationActivityAttributes.ContentState?
    private var worker: Task<Void, Never>?
    private var lastPublished: NavigationActivityAttributes.ContentState?
    private var updatePolicy = NavigationActivityUpdatePolicy()
    private var lifecycle = NavigationActivityLifecyclePolicy()
    private let logger = Logger(subsystem: "NaviAstra", category: "LiveActivity")

    init() {
        // A terminated process cannot restore turn-by-turn navigation from a widget.
        // Clear only activities that existed at launch, never a newly started trip.
        let orphaned = Activity<NavigationActivityAttributes>.activities
        Task { for item in orphaned { await item.end(nil, dismissalPolicy: .immediate) } }
    }

    func update(destinationName: String, state: NavigationActivityAttributes.ContentState,
                canStart: Bool) {
        guard NavigationActivityPayload.isWithinBudget(state) else { return }
        let now = Date()
        let maneuverKey = "\(state.maneuver)|\(state.roadName)|\(state.instruction)|\(state.isRerouting)|\(state.gpsSignalLost)"
        if activity == nil {
            guard lifecycle.requestStart(isForeground: canStart,
                systemAuthorized: ActivityAuthorizationInfo().areActivitiesEnabled) else { return }
            do {
                activity = try Activity.request(
                    attributes: NavigationActivityAttributes(destinationName: "Aktywna trasa"),
                    content: ActivityContent(state: state, staleDate: now.addingTimeInterval(45)),
                    pushType: nil)
                lastPublished = state
                updatePolicy.didPublish(maneuverKey: maneuverKey, movementBucket: state.movementBucket, at: now)
            } catch { logger.error("Cannot start navigation activity: \(error.localizedDescription)") }
            return
        }
        guard updatePolicy.shouldPublish(maneuverKey: maneuverKey,
            movementBucket: state.movementBucket, at: now) else { return }
        pending = state
        drain()
    }

    func end() {
        // Detach immediately, so a new foreground trip can start even while the
        // previous ActivityKit dismissal is still finishing asynchronously.
        let previous = activity
        activity = nil
        pending = nil
        lifecycle.end()
        updatePolicy.end()
        worker?.cancel()
        worker = nil
        lastPublished = nil
        if let previous { Task { await previous.end(nil, dismissalPolicy: .immediate) } }
    }

    private func drain() {
        guard worker == nil else { return }
        let generation = lifecycle.generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.lifecycle.generation == generation { self.worker = nil } }
            while !Task.isCancelled, self.lifecycle.generation == generation, let activity = self.activity {
                guard let state = self.pending else { return }
                self.pending = nil
                self.lastPublished = state
                let key = "\(state.maneuver)|\(state.roadName)|\(state.instruction)|\(state.isRerouting)|\(state.gpsSignalLost)"
                self.updatePolicy.didPublish(maneuverKey: key, movementBucket: state.movementBucket, at: Date())
                await activity.update(ActivityContent(state: state,
                    staleDate: Date().addingTimeInterval(45)))
            }
        }
    }
#else
    func end() {}
#endif
}

extension NavigationSession {
    func updateLiveActivity() {
#if os(iOS) && NAVIGATION_WIDGETS_ENABLED
        guard state.status == .navigating || state.status == .rerouting else {
            liveActivity.end()
            return
        }
        guard let progress = state.progress, let destination = state.destination else { return }
        let maneuver = progress.nextManeuver
        let instruction = maneuver?.displayInstruction ?? state.transitProgress?.nextStop?.name ?? "Kontynuuj do celu"
        let metric = state.route == nil ? nil : RoutedTravelMetrics(time: progress.remainingTime, distance: progress.remainingDistance)
        let location = state.location
        let freshGPS = location.map {
            (-1...15).contains(Date().timeIntervalSince($0.timestamp)) && $0.accuracy.isFinite && (0...50).contains($0.accuracy)
        } ?? false
        let signalLost = !freshGPS || state.gpsQuality == .noSignal || state.weakGPS
        let total = progress.traveledDistance + progress.remainingDistance
        let routeProgress = total.isFinite && total > 0 && progress.traveledDistance.isFinite
            ? min(1, max(0, progress.traveledDistance / total)) : 0
        var content = NavigationActivityAttributes.ContentState(
            maneuver: maneuver?.type ?? 0,
            symbolName: maneuver?.iconName ?? (usesJourneyVoiceGuidance ? "tram.fill" : "arrow.up"),
            instruction: String(instruction.prefix(100)),
            roadName: String((maneuver?.streetName ?? "").prefix(60)),
            maneuverDistance: progress.distanceToNextManeuver.isFinite && progress.distanceToNextManeuver >= 0
                ? progress.distanceToNextManeuver : nil,
            remainingDistance: metric?.distance,
            remainingTime: metric?.time,
            arrivalTime: metric.flatMap { metric in state.estimatedArrival ?? Date().addingTimeInterval(metric.time) },
            routeProgress: routeProgress,
            isRerouting: state.status == .rerouting,
            roundabout: maneuver?.roundabout,
            gpsSignalLost: signalLost,
            routeSketch: signalLost ? nil : state.route.flatMap {
                NavigationActivitySketchBuilder.make(route: $0, progress: progress,
                    location: location?.coordinate, course: location?.course)
            },
            movementBucket: progress.traveledDistance.isFinite ? Int(max(0, min(400_000_000, progress.traveledDistance)) / 40) : 0)
        if !NavigationActivityPayload.isWithinBudget(content) { content.routeSketch = nil; content.roundabout = nil }
        liveActivity.update(destinationName: destination.name, state: content, canStart: appIsForeground)
#endif
    }
}
