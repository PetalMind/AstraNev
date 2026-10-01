import Foundation

/// Arrival requires fresh, accurate, distinct fixes; timer and traffic callbacks
/// must never turn one old GPS sample into evidence of a stopped vehicle.
struct ArrivalDetector {
    private var firstTimestamp: Date?
    private var lastTimestamp: Date?
    private var sampleCount = 0

    mutating func observe(_ location: NavigationLocation, destinationDistance: Double,
                          remainingDistance: Double, now: Date = Date()) -> Bool {
        guard location.accuracy >= 0, location.accuracy <= 30,
              location.speed.isFinite, location.speed >= 0, location.speed < 5 / 3.6,
              destinationDistance < 50, remainingDistance < 75,
              abs(now.timeIntervalSince(location.timestamp)) <= 5 else {
            reset()
            return false
        }
        if let lastTimestamp {
            guard location.timestamp > lastTimestamp else { return false }
            if location.timestamp.timeIntervalSince(lastTimestamp) > 10 { reset() }
        }
        if firstTimestamp == nil { firstTimestamp = location.timestamp }
        lastTimestamp = location.timestamp
        sampleCount += 1
        return sampleCount >= 3 && location.timestamp.timeIntervalSince(firstTimestamp!) >= 5
    }

    mutating func reset() {
        firstTimestamp = nil
        lastTimestamp = nil
        sampleCount = 0
    }
}
