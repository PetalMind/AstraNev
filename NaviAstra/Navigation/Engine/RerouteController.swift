import Foundation

@MainActor
final class RerouteController {
    private(set) var generation = 0
    private(set) var lastReroute = Date.distantPast
    private var automaticClosureTask: Task<Void, Never>?
    private var reroutedClosureIDs: Set<String> = []
    private var closureRetryAfter: [String: Date] = [:]

    var hasAutomaticClosureReroute: Bool { automaticClosureTask != nil }

    func isCurrent(_ requestGeneration: Int) -> Bool {
        generation == requestGeneration
    }

    func recordRerouteRequest(at date: Date = Date()) {
        lastReroute = date
    }

    @discardableResult
    func beginManualReroute() -> Int {
        invalidateAutomaticClosureReroute()
        generation &+= 1
        return generation
    }

    func beginAutomaticClosureReroute(for closureID: String, at date: Date = Date()) -> Int? {
        guard automaticClosureTask == nil,
              !reroutedClosureIDs.contains(closureID),
              closureRetryAfter[closureID, default: .distantPast] <= date else { return nil }
        generation &+= 1
        return generation
    }

    func setAutomaticClosureTask(_ task: Task<Void, Never>) {
        automaticClosureTask = task
    }

    func finishAutomaticClosureReroute(generation requestGeneration: Int) {
        guard isCurrent(requestGeneration) else { return }
        automaticClosureTask = nil
    }

    func markClosureRerouted(_ closureID: String) {
        reroutedClosureIDs.insert(closureID)
        closureRetryAfter[closureID] = nil
    }

    func scheduleClosureRetry(_ closureID: String, after delay: TimeInterval, from date: Date = Date()) {
        closureRetryAfter[closureID] = date.addingTimeInterval(delay)
    }

    func beginNavigation() {
        invalidateAutomaticClosureReroute()
        generation &+= 1
        reroutedClosureIDs.removeAll()
        closureRetryAfter.removeAll()
        lastReroute = .distantPast
    }

    func invalidateRequestsForRouteChange() {
        invalidateAutomaticClosureReroute()
        generation &+= 1
        reroutedClosureIDs.removeAll()
        closureRetryAfter.removeAll()
    }

    func stop() {
        invalidateAutomaticClosureReroute()
        generation &+= 1
        reroutedClosureIDs.removeAll()
        closureRetryAfter.removeAll()
    }

    func invalidateAutomaticClosureReroute() {
        automaticClosureTask?.cancel()
        automaticClosureTask = nil
    }
}
