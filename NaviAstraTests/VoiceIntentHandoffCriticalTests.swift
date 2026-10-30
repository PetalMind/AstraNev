#if os(iOS)
import AppIntents
import Testing
@testable import NaviAstra

struct VoiceIntentHandoffCriticalTests {
    @Test func requestSurvivesColdLaunchUntilAllDeliveryGatesAreReady() {
        var handoff = VoiceIntentHandoff()
        handoff.enqueue(.home)
        for hasAssistant in [false, true] {
            for isAppActive in [false, true] {
                for isProtectedDataAvailable in [false, true] {
                    guard !(hasAssistant && isAppActive && isProtectedDataAvailable) else { continue }
                    #expect(handoff.takeIfReady(hasAssistant: hasAssistant, isAppActive: isAppActive,
                                               isProtectedDataAvailable: isProtectedDataAvailable) == nil)
                    #expect(handoff.pending == .home)
                }
            }
        }
        #expect(handoff.takeIfReady(hasAssistant: true, isAppActive: true,
                                   isProtectedDataAvailable: true) == .home)
        #expect(handoff.pending == nil)
        #expect(handoff.takeIfReady(hasAssistant: true, isAppActive: true,
                                   isProtectedDataAvailable: true) == nil)
    }

    @Test func latestExplicitRequestReplacesUndeliveredCommand() {
        var handoff = VoiceIntentHandoff()
        handoff.enqueue(.conversation)
        handoff.enqueue(.home)
        handoff.enqueue(.work)
        #expect(handoff.takeIfReady(hasAssistant: true, isAppActive: true,
                                   isProtectedDataAvailable: true) == .work)
        #expect(handoff.takeIfReady(hasAssistant: true, isAppActive: true,
                                   isProtectedDataAvailable: true) == nil)
    }

    @Test func everySystemEntryRequiresAuthenticationAndForegroundExecution() {
        func requiresAuthentication(_ policy: IntentAuthenticationPolicy) -> Bool {
            if case .requiresAuthentication = policy { return true }
            return false
        }
        let policies = [OpenVoiceConversationIntent.authenticationPolicy,
                        NavigateHomeVoiceIntent.authenticationPolicy,
                        NavigateWorkVoiceIntent.authenticationPolicy,
                        ReadArrivalVoiceIntent.authenticationPolicy,
                        SetNavigationVoiceMutedIntent.authenticationPolicy]
        #expect(policies.allSatisfy(requiresAuthentication))
        let modes = [OpenVoiceConversationIntent.supportedModes,
                     NavigateHomeVoiceIntent.supportedModes,
                     NavigateWorkVoiceIntent.supportedModes,
                     ReadArrivalVoiceIntent.supportedModes,
                     SetNavigationVoiceMutedIntent.supportedModes]
        #expect(modes.allSatisfy { $0 == .foreground })
        let targets = [OpenVoiceConversationIntent.allowedExecutionTargets,
                       NavigateHomeVoiceIntent.allowedExecutionTargets,
                       NavigateWorkVoiceIntent.allowedExecutionTargets,
                       ReadArrivalVoiceIntent.allowedExecutionTargets,
                       SetNavigationVoiceMutedIntent.allowedExecutionTargets]
        #expect(targets.allSatisfy { $0 == .main })
    }

    @Test func systemEntryCommandsCannotConfirmOrStopAPendingJourney() {
        let requests: [VoiceIntentRequest] = [.conversation, .home, .work, .arrival,
                                             .setMuted(true), .setMuted(false)]
        for request in requests {
            guard let text = request.command else { continue }
            let command = VoiceCommandParser.parse(text)
            #expect(command != .confirm && command != .stop && command != .removeNextStop)
            #expect(command != .unknown)
        }
    }
}
#endif
