#if os(iOS)
import AppIntents
import Foundation
import UIKit

/// The system entry points expose a small set of typed actions, not arbitrary commands.
nonisolated enum VoiceIntentRequest: Equatable, Sendable {
    case conversation, home, work, arrival
    case setMuted(Bool)

    var command: String? {
        switch self {
        case .conversation: nil
        case .home: "Prowadź do domu"
        case .work: "Prowadź do pracy"
        case .arrival: "Kiedy dojadę?"
        case .setMuted(true): "Wycisz komunikaty"
        case .setMuted(false): "Włącz komunikaty"
        }
    }
}

/// Cold-launch handoff. A new explicit request supersedes an undelivered one.
nonisolated struct VoiceIntentHandoff {
    private(set) var pending: VoiceIntentRequest?

    mutating func enqueue(_ request: VoiceIntentRequest) {
        pending = request
    }

    mutating func takeIfReady(hasAssistant: Bool, isAppActive: Bool,
                              isProtectedDataAvailable: Bool) -> VoiceIntentRequest? {
        guard hasAssistant, isAppActive, isProtectedDataAvailable else { return nil }
        defer { pending = nil }
        return pending
    }
}

@MainActor
final class VoiceIntentBridge {
    static let shared = VoiceIntentBridge()
    private(set) weak var assistant: VoiceAssistant?
    private var handoff = VoiceIntentHandoff()

    func attach(assistant: VoiceAssistant) {
        self.assistant = assistant
        resumePendingRequest()
    }

    func enqueue(_ request: VoiceIntentRequest) {
        handoff.enqueue(request)
        resumePendingRequest()
    }

    /// Invoke when the app scene becomes active or protected data becomes available.
    /// No timer is needed: attachment and lifecycle events resolve the launch ordering.
    func resumePendingRequest() {
        guard let request = handoff.takeIfReady(
            hasAssistant: assistant != nil && assistant?.isApplyingChange == false,
            isAppActive: UIApplication.shared.applicationState == .active,
            isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
        ), let assistant else { return }
        if let command = request.command {
            assistant.submit(command)
        } else {
            assistant.open()
        }
    }
}

nonisolated struct OpenVoiceConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Rozmowa głosowa"
    static let description: IntentDescription? = IntentDescription("Otwiera NaviAstrę i włącza mikrofon po odblokowaniu urządzenia.")
    static let openAppWhenRun = true
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        VoiceIntentBridge.shared.enqueue(.conversation)
        return .result()
    }
}

nonisolated struct NavigateHomeVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Prowadź do domu"
    static let description: IntentDescription? = IntentDescription("Otwiera NaviAstrę i przygotowuje trasę do zapisanego domu. Zmianę celu potwierdzisz w aplikacji.")
    static let openAppWhenRun = true
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        VoiceIntentBridge.shared.enqueue(.home)
        return .result()
    }
}

nonisolated struct NavigateWorkVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Prowadź do pracy"
    static let description: IntentDescription? = IntentDescription("Otwiera NaviAstrę i przygotowuje trasę do zapisanej pracy. Zmianę celu potwierdzisz w aplikacji.")
    static let openAppWhenRun = true
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        VoiceIntentBridge.shared.enqueue(.work)
        return .result()
    }
}

nonisolated struct ReadArrivalVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Odczytaj czas dojazdu"
    static let description: IntentDescription? = IntentDescription("Otwiera NaviAstrę i odczytuje przewidywaną godzinę dotarcia podczas aktywnej podróży.")
    static let openAppWhenRun = true
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        VoiceIntentBridge.shared.enqueue(.arrival)
        return .result()
    }
}

nonisolated struct SetNavigationVoiceMutedIntent: AppIntent {
    static let title: LocalizedStringResource = "Ustaw wyciszenie nawigacji"
    static let description: IntentDescription? = IntentDescription("Włącza lub wycisza komunikaty nawigacji po otwarciu NaviAstry.")
    static let openAppWhenRun = true
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Wycisz komunikaty", default: true)
    var muted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ustaw wyciszenie komunikatów: \(\.$muted)")
    }

    init() {}

    init(muted: Bool) {
        self.muted = muted
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        VoiceIntentBridge.shared.enqueue(.setMuted(muted))
        return .result()
    }
}

nonisolated struct NaviAstraVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenVoiceConversationIntent(), phrases: [
            "Rozmawiaj z \(.applicationName)", "Włącz mikrofon w \(.applicationName)"
        ], shortTitle: "Rozmowa głosowa", systemImageName: "mic.fill")
        AppShortcut(intent: NavigateHomeVoiceIntent(), phrases: [
            "Prowadź do domu z \(.applicationName)"
        ], shortTitle: "Do domu", systemImageName: "house.fill")
        AppShortcut(intent: NavigateWorkVoiceIntent(), phrases: [
            "Prowadź do pracy z \(.applicationName)"
        ], shortTitle: "Do pracy", systemImageName: "briefcase.fill")
        AppShortcut(intent: ReadArrivalVoiceIntent(), phrases: [
            "Kiedy dojadę według \(.applicationName)", "Odczytaj czas dojazdu w \(.applicationName)"
        ], shortTitle: "Czas dojazdu", systemImageName: "clock.fill")
        AppShortcut(intent: SetNavigationVoiceMutedIntent(muted: true), phrases: [
            "Wycisz komunikaty w \(.applicationName)"
        ], shortTitle: "Wycisz komunikaty", systemImageName: "speaker.slash.fill")
    }
}
#endif
