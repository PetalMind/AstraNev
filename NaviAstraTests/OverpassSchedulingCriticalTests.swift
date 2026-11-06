import Foundation
import Testing
@testable import NaviAstra

/// A blocked background map download must not consume the search deadline;
/// cancellation of a queued lookup must not release somebody else's slot.
struct OverpassSchedulingCriticalTests {
    @Test func interactiveLaneUsesAnIdleServerWithoutParallelQueriesToOneHost() async {
        let gate = OSMCyclingRequestGate()
        #expect(await gate.waitUntilAllowed(host: "primary.example"))
        let sameHost = Task { await gate.waitUntilAllowed(priority: true, host: "primary.example") }
        try? await Task.sleep(for: .milliseconds(150))
        sameHost.cancel()
        #expect(await sameHost.value == false)
        #expect(await gate.occupiedHosts() == ["primary.example"])
        #expect(await withinTwoSeconds {
            await gate.waitUntilAllowed(priority: true, host: "mirror.example")
        })
        #expect(await gate.occupiedHosts() == ["primary.example", "mirror.example"])
        await gate.requestDidFinish(priority: true, host: "mirror.example")
        await gate.requestDidFinish(host: "primary.example")
        #expect(await gate.occupiedHosts().isEmpty)
    }

    @Test func interactiveLookupBypassesMapDownloadWithoutOpeningExtraSlots() async {
        let gate = OSMCyclingRequestGate()
        #expect(await gate.waitUntilAllowed())
        let interactiveStarted = await withinTwoSeconds {
            await gate.waitUntilAllowed(priority: true)
        }
        #expect(interactiveStarted)
        guard interactiveStarted else {
            await gate.requestDidFinish()
            return
        }

        // Neither a second lookup nor another map request may join the two
        // active requests. Cancelling either waiter must leave both occupied.
        for priority in [true, false, true] {
            let queued = Task { await gate.waitUntilAllowed(priority: priority) }
            try? await Task.sleep(for: .milliseconds(150))
            queued.cancel()
            #expect(await queued.value == false)
        }
        await gate.requestDidFinish(priority: true)
        await gate.requestDidFinish()
        #expect(await withinTwoSeconds { await gate.waitUntilAllowed(priority: true) })
        await gate.requestDidFinish(priority: true)
        #expect(await withinTwoSeconds { await gate.waitUntilAllowed() })
        await gate.requestDidFinish()
    }

    private func withinTwoSeconds(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
