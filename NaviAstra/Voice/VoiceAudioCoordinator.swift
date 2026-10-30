#if os(iOS)
import AVFoundation
import UIKit

/// Owns the app's audio session. A microphone, navigation instruction and
/// assistant reply must never own it at the same time.
@MainActor
final class VoiceAudioCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceAudioCoordinator()

    private struct Capture {
        let id: UUID
        let interrupted: (String) -> Void
    }
    private struct Guidance {
        let owner: UUID
        let urgent: Bool
        let interrupted: () -> Void
    }
    private struct Reply {
        let text: String
        let completion: (Bool) -> Void
    }

    private let session = AVAudioSession.sharedInstance()
    private let synthesizer = AVSpeechSynthesizer()
    private var capture: Capture?
    private var guidance: Guidance?
    private var pendingReply: Reply?
    private var replyCompletion: ((Bool) -> Void)?
    private var replyID: ObjectIdentifier?
    private var replyWatchdog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var sessionInterrupted = false

    private override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(began: raw == AVAudioSession.InterruptionType.began.rawValue)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                    raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.interruptCapture("Zmieniono urządzenie audio. Dotknij mikrofonu i spróbuj ponownie.")
                self?.finishReply()
            }
        })
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cancelReply()
                    self?.interruptCapture("Nasłuchiwanie zakończone. Otwórz aplikację, aby wydać polecenie.")
                }
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleInterruption(began: true)
                self?.sessionInterrupted = false
            }
        })
    }

    enum AudioError: LocalizedError {
        case unavailable, urgentGuidance, background
        var errorDescription: String? {
            switch self {
            case .unavailable: "Dźwięk jest teraz zajęty. Spróbuj ponownie po zakończeniu rozmowy."
            case .urgentGuidance: "Poczekaj na zakończenie ważnej wskazówki i spróbuj ponownie."
            case .background: "Otwórz NaviAstrę, aby używać mikrofonu."
            }
        }
    }

    func beginCapture(onInterrupted: @escaping (String) -> Void) throws -> UUID {
        guard UIApplication.shared.applicationState == .active else { throw AudioError.background }
        guard !sessionInterrupted else { throw AudioError.unavailable }
        guard guidance?.urgent != true else { throw AudioError.urgentGuidance }
        cancelReply()
        interruptCapture("Rozpoczęto nową rozmowę głosową.")
        if let previous = guidance {
            guidance = nil
            previous.interrupted()
        }
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            deactivateIfIdle()
            throw AudioError.unavailable
        }
        let id = UUID()
        capture = Capture(id: id, interrupted: onInterrupted)
        return id
    }

    func endCapture(_ id: UUID) {
        guard capture?.id == id else { return }
        capture = nil
        resumePendingReply()
        deactivateIfIdle()
    }

    /// False means a short conversation owns audio; the caller retains its queue.
    func beginGuidance(owner: UUID, urgent: Bool, onInterrupted: @escaping () -> Void) throws -> Bool {
        guard !sessionInterrupted else { throw AudioError.unavailable }
        if let guidance, guidance.owner != owner { return false }
        if !urgent && (capture != nil || replyID != nil || pendingReply != nil) { return false }
        if urgent {
            // Claim priority before invoking callbacks: a dialog cannot restart capture.
            guidance = Guidance(owner: owner, urgent: true, interrupted: onInterrupted)
            interruptCapture("Nasłuchiwanie przerwane przez ważną wskazówkę nawigacji.")
            cancelReply()
        }
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            if guidance?.owner == owner { guidance = nil }
            deactivateIfIdle()
            throw AudioError.unavailable
        }
        guidance = Guidance(owner: owner, urgent: urgent, interrupted: onInterrupted)
        return true
    }

    func endGuidance(owner: UUID) {
        guard guidance?.owner == owner else { return }
        guidance = nil
        resumePendingReply()
        deactivateIfIdle()
    }

    func speakReply(_ text: String, completion: @escaping (Bool) -> Void) {
        cancelReply()
        guard !text.isEmpty, !sessionInterrupted,
              UIApplication.shared.applicationState == .active else {
            completion(false)
            return
        }
        interruptCapture("Nasłuchiwanie zakończone.")
        pendingReply = Reply(text: text, completion: completion)
        resumePendingReply()
    }

    func cancelReply() {
        let completion = replyCompletion ?? pendingReply?.completion
        pendingReply = nil
        replyID = nil
        replyCompletion = nil
        replyWatchdog?.cancel()
        replyWatchdog = nil
        synthesizer.stopSpeaking(at: .immediate)
        deactivateIfIdle()
        completion?(false)
    }

    private func resumePendingReply() {
        guard capture == nil, guidance == nil, replyID == nil,
              let reply = pendingReply else { return }
        pendingReply = nil
        guard !sessionInterrupted, UIApplication.shared.applicationState == .active else {
            reply.completion(false)
            return
        }
        let preferences = VoiceGuidancePreferences.load()
        let utterance = AVSpeechUtterance(string: reply.text)
        utterance.voice = preferences.voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: "pl-PL")
        utterance.rate = preferences.speechRate
        // Explicit questions still receive an answer when automatic guidance is muted.
        utterance.volume = preferences.volume
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            deactivateIfIdle()
            reply.completion(false)
            return
        }
        let id = ObjectIdentifier(utterance)
        replyID = id
        replyCompletion = reply.completion
        synthesizer.speak(utterance)
        replyWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, self?.replyID == id else { return }
            self?.finishReply()
        }
    }

    private func finishReply(identifier: ObjectIdentifier? = nil, successfully: Bool = false) {
        if let identifier, replyID != identifier { return }
        let completion = replyCompletion ?? pendingReply?.completion
        pendingReply = nil
        replyCompletion = nil
        replyID = nil
        replyWatchdog?.cancel()
        replyWatchdog = nil
        synthesizer.stopSpeaking(at: .immediate)
        deactivateIfIdle()
        completion?(successfully)
    }

    private func interruptCapture(_ reason: String) {
        guard let previous = capture else { return }
        capture = nil
        previous.interrupted(reason)
        deactivateIfIdle()
    }

    private func handleInterruption(began: Bool) {
        sessionInterrupted = began
        guard began else { return }
        interruptCapture("Nasłuchiwanie przerwane. Spróbuj ponownie po zakończeniu rozmowy.")
        let previous = guidance
        guidance = nil
        previous?.interrupted()
        finishReply()
        pendingReply = nil
    }

    private func deactivateIfIdle() {
        guard capture == nil, guidance == nil, replyID == nil else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                      didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishReply(identifier: id, successfully: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                      didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishReply(identifier: id) }
    }
}
#endif
