// Temporarily disabled for distribution without the widget extension.
// Re-enable NAVIGATION_WIDGETS_ENABLED together with extension embedding and Live Activities support.
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
    private var ending = false
    private var lastPublished: NavigationActivityAttributes.ContentState?
    private var lastPublishedAt = Date.distantPast
    private var attemptedStart = false
    private let logger = Logger(subsystem: "NaviAstra", category: "LiveActivity")

    init() {
        // A terminated process cannot restore turn-by-turn navigation from a widget.
        // Clear only activities that existed at launch, never a newly started trip.
        let orphaned = Activity<NavigationActivityAttributes>.activities
        Task { for item in orphaned { await item.end(nil, dismissalPolicy: .immediate) } }
    }

    func update(destinationName: String, state: NavigationActivityAttributes.ContentState,
                canStart: Bool) {
        guard !ending else { return }
        let now = Date()
        if activity == nil {
            guard canStart, !attemptedStart, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            attemptedStart = true
            do {
                activity = try Activity.request(
                    attributes: NavigationActivityAttributes(destinationName: destinationName),
                    content: ActivityContent(state: state, staleDate: now.addingTimeInterval(90)),
                    pushType: nil)
                lastPublished = state
                lastPublishedAt = now
            } catch { logger.error("Cannot start navigation activity: \(error.localizedDescription)") }
            return
        }
        let changedManeuver = lastPublished?.maneuver != state.maneuver ||
            lastPublished?.roadName != state.roadName || lastPublished?.instruction != state.instruction ||
            lastPublished?.isRerouting != state.isRerouting || lastPublished?.gpsSignalLost != state.gpsSignalLost
        guard changedManeuver || now.timeIntervalSince(lastPublishedAt) >= 5 else { return }
        pending = state
        drain()
    }

    func end() {
        attemptedStart = false
        pending = nil
        guard activity != nil else { return }
        ending = true
        drain()
    }

    private func drain() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while let activity = self.activity {
                if self.ending {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    self.activity = nil
                    self.ending = false
                    self.lastPublished = nil
                    return
                }
                guard let state = self.pending else { return }
                self.pending = nil
                self.lastPublished = state
                self.lastPublishedAt = Date()
                await activity.update(ActivityContent(state: state,
                    staleDate: Date().addingTimeInterval(90)))
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
        guard state.status == .navigating || state.status == .rerouting else { return }
        guard let progress = state.progress, let destination = state.destination else { return }
        let maneuver = progress.nextManeuver
        let instruction = maneuver?.displayInstruction ?? state.transitProgress?.nextStop?.name ?? "Kontynuuj do celu"
        liveActivity.update(destinationName: destination.name,
            state: NavigationActivityAttributes.ContentState(
                maneuver: maneuver?.type ?? 0,
                symbolName: maneuver?.iconName ?? (usesJourneyVoiceGuidance ? "tram.fill" : "arrow.up"),
                instruction: instruction,
                roadName: maneuver?.streetName ?? "",
                maneuverDistance: progress.distanceToNextManeuver.isFinite ? max(0, progress.distanceToNextManeuver) : nil,
                remainingDistance: max(0, progress.remainingDistance),
                remainingTime: max(0, progress.remainingTime),
                arrivalTime: state.estimatedArrival ?? Date().addingTimeInterval(progress.remainingTime),
                routeProgress: min(1, max(0, progress.traveledDistance / max(1, progress.traveledDistance + progress.remainingDistance))),
                isRerouting: state.status == .rerouting,
                gpsSignalLost: state.gpsQuality == .noSignal || state.weakGPS),
            canStart: appIsForeground)
#endif
    }
}
