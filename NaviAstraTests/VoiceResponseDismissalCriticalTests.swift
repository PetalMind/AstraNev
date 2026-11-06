#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

/// Closing a transient reply must never end navigation or cancel the next command.
@MainActor
struct VoiceResponseDismissalCriticalTests {
    @Test func completedReplyClosesOnlyAfterSpeechAndReadingDelay() async throws {
        let fixture = try VoiceResponseFixture()
        defer { fixture.cleanUp() }
        let routeID = fixture.session.state.route?.id
        await fixture.submit("pomoc")
        #expect(fixture.assistant.phase == .speaking)
        #expect(fixture.assistant.responseDismissalTask == nil)

        fixture.speaker.finish(0)
        let dismissal = try #require(fixture.assistant.responseDismissalTask)
        await fixture.delay.waitUntilScheduled()
        #expect(fixture.assistant.isPresented)
        fixture.delay.advance()
        await dismissal.value

        #expect(!fixture.assistant.isPresented)
        #expect(fixture.session.state.status == .navigating)
        #expect(fixture.session.state.route?.id == routeID)
    }

    @Test func oldDelayCannotCloseANewerReply() async throws {
        let fixture = try VoiceResponseFixture()
        defer { fixture.cleanUp() }
        await fixture.submit("pomoc")
        fixture.speaker.finish(0)
        let oldDismissal = try #require(fixture.assistant.responseDismissalTask)
        await fixture.delay.waitUntilScheduled()

        await fixture.submit("kiedy dojadę")
        fixture.delay.advance()
        await oldDismissal.value
        #expect(fixture.assistant.isPresented)
        #expect(fixture.assistant.phase == .speaking)

        fixture.speaker.finish(1)
        let currentDismissal = try #require(fixture.assistant.responseDismissalTask)
        await fixture.delay.waitUntilScheduled()
        fixture.delay.advance()
        await currentDismissal.value
        #expect(!fixture.assistant.isPresented)
    }

    @Test func oldDelayCannotDiscardAPendingNavigationDecision() async throws {
        let fixture = try VoiceResponseFixture()
        defer { fixture.cleanUp() }
        await fixture.submit("pomoc")
        fixture.speaker.finish(0)
        let oldDismissal = try #require(fixture.assistant.responseDismissalTask)
        await fixture.delay.waitUntilScheduled()

        await fixture.submit("zakończ nawigację")
        #expect(fixture.assistant.canConfirm)
        fixture.delay.advance()
        await oldDismissal.value
        #expect(fixture.assistant.isPresented)
        #expect(fixture.assistant.canConfirm)
        #expect(fixture.session.state.status == .navigating)
    }

    @Test func readingFullReplyPausesDismissalAndStartsANewDelayAfterClosing() async throws {
        let fixture = try VoiceResponseFixture()
        defer { fixture.cleanUp() }
        await fixture.submit("pomoc")
        fixture.speaker.finish(0)
        let oldDismissal = try #require(fixture.assistant.responseDismissalTask)
        await fixture.delay.waitUntilScheduled()
        fixture.assistant.setConversationDetailsPresented(true)
        fixture.delay.advance()
        await oldDismissal.value
        #expect(fixture.assistant.isPresented)
        #expect(fixture.assistant.responseDismissalTask == nil)

        fixture.assistant.setConversationDetailsPresented(false)
        let newDismissal = try #require(fixture.assistant.responseDismissalTask)
        await fixture.delay.waitUntilScheduled()
        #expect(fixture.assistant.isPresented)
        fixture.delay.advance()
        await newDismissal.value
        #expect(!fixture.assistant.isPresented)
    }

    @Test func lateSpeechCompletionCannotReopenOrScheduleAClosedConversation() async throws {
        let fixture = try VoiceResponseFixture()
        defer { fixture.cleanUp() }
        await fixture.submit("pomoc")
        fixture.assistant.close()
        fixture.speaker.finish(0)
        #expect(!fixture.assistant.isPresented)
        #expect(fixture.assistant.responseDismissalTask == nil)
        #expect(fixture.session.state.status == .navigating)
    }
}

@MainActor
private final class VoiceResponseFixture {
    let directory: URL
    let session: NavigationSession
    let assistant: VoiceAssistant
    let speaker: ControlledReplySpeaker
    let delay: ControlledResponseDelay

    init() throws {
        let speaker = ControlledReplySpeaker()
        let delay = ControlledResponseDelay()
        self.speaker = speaker
        self.delay = delay
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-response-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let places = PlaceStore(repository: LocalDataStore(directory: directory))
        session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        session.voice.setEnabled(false)
        session.state.voiceEnabled = false
        session.state.transportMode = .walking
        let start = Coordinate(latitude: 52, longitude: 21)
        let end = Coordinate(latitude: 52.01, longitude: 21)
        session.state.destination = Destination(name: "Cel", coordinate: end)
        session.state.route = NavigationRoute(coordinates: [start, end], distance: 1_000,
                                             expectedTravelTime: 600, maneuvers: [])
        session.state.status = .navigating
        assistant = VoiceAssistant(navigationStore: NavigationStore(session: session), placeStore: places,
            replySpeaker: { _, completion in speaker.completions.append(completion) },
            interactionAvailable: { true }, waitBeforeDismissal: { await delay.wait() })
    }

    func submit(_ command: String) async {
        assistant.submit(command)
        await assistant.task?.value
    }

    func cleanUp() {
        assistant.close()
        delay.advanceAll()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class ControlledReplySpeaker {
    var completions: [(Bool) -> Void] = []
    func finish(_ index: Int) { completions[index](true) }
}

@MainActor
private final class ControlledResponseDelay {
    private var waits: [CheckedContinuation<Void, Never>] = []
    private var scheduled: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            waits.append($0)
            scheduled?.resume()
            scheduled = nil
        }
    }

    func waitUntilScheduled() async {
        guard waits.isEmpty else { return }
        await withCheckedContinuation { scheduled = $0 }
    }

    func advance() {
        guard !waits.isEmpty else { return }
        waits.removeFirst().resume()
    }

    func advanceAll() {
        while !waits.isEmpty { advance() }
        scheduled?.resume()
        scheduled = nil
    }
}
#endif
