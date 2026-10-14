import Foundation

/// Arrival requires fresh, accurate, distinct fixes; timer and traffic callbacks
/// must never turn one old GPS sample into evidence of a stopped vehicle.
struct ArrivalDetector {
    private var firstTimestamp: Date?
    private var lastTimestamp: Date?
    private var sampleCount = 0

    mutating func observe(_ location: NavigationLocation, destinationDistance: Double,
                          remainingDistance: Double?, destinationRadius: Double = 50,
                          now: Date = Date()) -> Bool {
        // A car can arrive from another access road while map matching still
        // reports a long detour. Only require route completion when supplied.
        let routeIsComplete = remainingDistance.map { $0 >= 0 && $0 < 75 } ?? true
        guard location.accuracy >= 0, location.accuracy <= 30,
              location.speed.isFinite, location.speed >= 0, location.speed < 5 / 3.6,
              destinationDistance >= 0, destinationDistance <= destinationRadius, routeIsComplete,
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
