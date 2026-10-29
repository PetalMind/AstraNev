import Foundation
import Testing
@testable import NaviAstra

struct SatelliteTileRecoveryCriticalTests {
    private let first = SatelliteTileAddress(x: 146_371, y: 86_251, z: 18)
    private let second = SatelliteTileAddress(x: 146_372, y: 86_251, z: 18)
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func errorBurstDoesNotPostponeRetryAndSuccessfulTilesCancelTheirOwnFailures() {
        var recovery = SatelliteTileRecovery(namespace: "critical-check")
        let source = recovery.identifier(for: .poland)
        recovery.failed(sourceID: source, tile: first, now: start)
        recovery.failed(sourceID: source, tile: second, now: start.addingTimeInterval(1))
        #expect(recovery.nextRetry == start.addingTimeInterval(2))
        recovery.succeeded(sourceID: source, tile: first)
        #expect(recovery.nextRetry != nil)
        recovery.succeeded(sourceID: source, tile: second)
        #expect(recovery.nextRetry == nil)
        #expect(recovery.takeDueAttempts(now: start.addingTimeInterval(10)).isEmpty)
    }

    @Test func failedRasterIsRecreatedWithANewIDAndBoundedBackoff() {
        var recovery = SatelliteTileRecovery(namespace: "critical-check")
        var now = start
        for delay in [2.0, 5, 15, 30, 60, 120, 120] {
            let oldID = recovery.identifier(for: .poland)
            recovery.failed(sourceID: oldID, tile: first, now: now)
            let deadline = now.addingTimeInterval(delay)
            #expect(recovery.nextRetry == deadline)
            #expect(recovery.takeDueAttempts(now: deadline.addingTimeInterval(-0.001)).isEmpty)
            let attempts = recovery.takeDueAttempts(now: deadline)
            #expect(attempts.count == 1)
            #expect(attempts.first?.previousIdentifier == oldID)
            #expect(recovery.identifier(for: .poland) != oldID)
            now = deadline
        }
    }

    @Test func staleEventsAndUnrelatedSourcesCannotChangeCurrentRetry() {
        var recovery = SatelliteTileRecovery(namespace: "critical-check")
        let oldID = recovery.identifier(for: .poland)
        recovery.failed(sourceID: oldID, tile: first, now: start)
        _ = recovery.takeDueAttempts(now: start.addingTimeInterval(2))
        let current = recovery.identifier(for: .poland)
        recovery.failed(sourceID: oldID, tile: second, now: start.addingTimeInterval(3))
        recovery.failed(sourceID: "traffic", tile: first, now: start.addingTimeInterval(3))
        #expect(recovery.nextRetry == nil)
        recovery.failed(sourceID: current, tile: first, now: start.addingTimeInterval(3))
        recovery.succeeded(sourceID: oldID, tile: first)
        #expect(recovery.nextRetry == start.addingTimeInterval(8))
        recovery.succeeded(sourceID: current, tile: first)
        #expect(recovery.nextRetry == nil)
    }

    @Test func foregroundOrNetworkRecoveryResumesOnlyPendingWorkAndQuietPeriodResetsBackoff() {
        var recovery = SatelliteTileRecovery(namespace: "critical-check")
        recovery.failed(sourceID: recovery.identifier(for: .poland), tile: first, now: start)
        // The owner does not consume attempts while backgrounded or offline.
        let resumed = start.addingTimeInterval(1)
        recovery.retryPendingNow(resumed)
        #expect(recovery.takeDueAttempts(now: resumed).count == 1)
        recovery.retryPendingNow(resumed.addingTimeInterval(1))
        #expect(recovery.takeDueAttempts(now: resumed.addingTimeInterval(1)).isEmpty)
        let later = start.addingTimeInterval(200)
        recovery.failed(sourceID: recovery.identifier(for: .poland), tile: first, now: later)
        #expect(recovery.nextRetry == later.addingTimeInterval(2))
        _ = recovery.takeDueAttempts(now: later.addingTimeInterval(2))
        recovery.failed(sourceID: recovery.identifier(for: .world), tile: first, now: later)
        recovery.resetFailures()
        #expect(recovery.nextRetry == nil)
    }

}
