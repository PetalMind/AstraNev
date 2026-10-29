import Foundation

/// GPS may arrive every second; publish movement only at bounded intervals.
/// Maneuver, reroute and signal changes are important enough to publish at once.
nonisolated struct NavigationActivityUpdatePolicy {
    private(set) var lastPublishedAt: Date?
    private var lastMovementBucket: Int?
    private var lastManeuverKey: String?

    func shouldPublish(maneuverKey: String, movementBucket: Int, at now: Date) -> Bool {
        guard let previous = lastPublishedAt else { return true }
        if lastManeuverKey != maneuverKey { return true }
        let elapsed = now.timeIntervalSince(previous)
        return elapsed >= 30 || (elapsed >= 5 && movementBucket != lastMovementBucket)
    }

    mutating func didPublish(maneuverKey: String, movementBucket: Int, at now: Date) {
        lastPublishedAt = now
        lastManeuverKey = maneuverKey
        lastMovementBucket = movementBucket
    }

    mutating func end() {
        lastPublishedAt = nil
        lastMovementBucket = nil
        lastManeuverKey = nil
    }
}

/// Starting is foreground-only. A failed or dismissed session is not repeatedly
/// recreated by background GPS; an explicit end resets the next navigation.
nonisolated struct NavigationActivityLifecyclePolicy {
    private(set) var attemptedStart = false
    private(set) var generation = 0

    mutating func requestStart(isForeground: Bool, systemAuthorized: Bool) -> Bool {
        guard isForeground, systemAuthorized, !attemptedStart else { return false }
        attemptedStart = true
        return true
    }

    mutating func end() { attemptedStart = false; generation &+= 1 }
}
