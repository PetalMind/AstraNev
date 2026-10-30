import AVFoundation
import Observation
import Speech

/// A late recognition callback must never execute in a newer listening session.
nonisolated struct VoiceRecognitionDeliveryGate {
    private(set) var generation = 0
    private var accepting = false

    mutating func begin() -> Int {
        generation &+= 1
        accepting = true
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        accepting = false
    }

    mutating func claim(generation: Int, isFinal: Bool) -> Bool {
        guard isFinal, accepting, self.generation == generation else { return false }
        accepting = false
        return true
    }
}

/// A transcription stall is not silence. Endpointing also needs recent quiet
/// audio buffers; it only asks the recognizer for its final result.
nonisolated struct VoiceRecognitionEndpointPolicy {
    static let silenceInterval: TimeInterval = 2.5
    private var lastActivity: TimeInterval?
    private var lastAudio: TimeInterval?
    private var lastTranscript: TimeInterval?
    private(set) var isFinalizing = false

    mutating func observeAudio(active: Bool, at uptime: TimeInterval) {
        lastAudio = uptime
        if active { lastActivity = uptime }
    }

    mutating func observeTranscript(at uptime: TimeInterval) { lastTranscript = uptime }

    mutating func requestEndIfSilent(at uptime: TimeInterval) -> Bool {
        guard !isFinalizing, let lastAudio, let lastTranscript,
              uptime >= lastAudio, uptime - lastAudio <= 0.5,
              uptime - lastTranscript >= Self.silenceInterval,
              uptime - (lastActivity ?? lastTranscript) >= Self.silenceInterval else { return false }
        return beginFinalization()
    }

    mutating func beginFinalization() -> Bool {
        guard !isFinalizing else { return false }
        isFinalizing = true
        return true
    }

    static func hasAudioActivity(_ buffer: AVAudioPCMBuffer) -> Bool {
        audioMetrics(buffer).active
    }

    /// The visual level comes from the same microphone samples as endpointing.
    /// Unsupported or invalid buffers never count as proof of silence.
    static func audioMetrics(_ buffer: AVAudioPCMBuffer) -> (active: Bool, level: Double) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return (true, 0) }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return (true, 0) }
        var peakMeanSquare = 0.0
        // Deliberately conservative: loud road noise can postpone endpointing,
        // but cannot turn a stalled partial confirmation into an executed action.
        for channel in 0..<channelCount {
            var sum = 0.0
            let samples = buffer.format.isInterleaved ? channels[0] : channels[channel]
            let offset = buffer.format.isInterleaved ? channel : 0
            for frame in 0..<count {
                let value = Double(samples[frame * buffer.stride + offset])
                guard value.isFinite else { return (true, 0) }
                sum += value * value
            }
            peakMeanSquare = max(peakMeanSquare, sum / Double(count))
        }
        let decibels = 10 * log10(max(peakMeanSquare, 1e-12))
        let level = min(1, max(0, (decibels + 60) / 50))
        return (peakMeanSquare >= 0.00001, level)
    }
}

#if os(iOS)
/// One configuration path keeps the offline privacy setting authoritative.
nonisolated enum VoiceRecognitionRequestFactory {
    static let commandContext = [
        "NaviAstra", "prowadź do domu", "prowadź do pracy", "kiedy dojadę",
        "znajdź stację paliw po trasie", "znajdź ładowarkę po trasie",
        "znajdź parking po trasie", "znajdź restaurację po trasie",
        "powtórz wskazówkę", "który pas", "anuluj", "potwierdzam"
    ]

    static func make(offlineOnly: Bool, supportsOnDeviceRecognition: Bool,
                     commandMode: Bool, contextualStrings: [String]) -> SFSpeechAudioBufferRecognitionRequest? {
        guard !offlineOnly || supportsOnDeviceRecognition else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Let Speech choose its processing path unless the user explicitly
        // requires local recognition. Capability alone is not that preference.
        request.requiresOnDeviceRecognition = offlineOnly
        request.taskHint = commandMode ? .dictation : .search
        request.addsPunctuation = false
        if commandMode {
            var seen = Set<String>()
            request.contextualStrings = (commandContext + contextualStrings).compactMap { phrase in
                let value = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !value.isEmpty, value.count <= 120,
                      seen.insert(value.lowercased(with: Locale(identifier: "pl_PL"))).inserted else { return nil }
                return value
            }.prefix(100).map { $0 }
        }
        return request
    }
}
#endif

@MainActor @Observable
final class SearchSpeechInput {
    private(set) var isStarting = false
    private(set) var isListening = false
    private(set) var isFinalizing = false
    private(set) var inputLevel: Double = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pl-PL"))
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var hasInstalledAudioTap = false
    @ObservationIgnored private var deliveryGate = VoiceRecognitionDeliveryGate()
    private var startGeneration: Int { deliveryGate.generation }
    @ObservationIgnored private var keepAudioSessionActive = false
    @ObservationIgnored private var commandFinal: ((String) -> Void)?
    @ObservationIgnored private var commandEnd: ((String?) -> Void)?
    @ObservationIgnored private var lastTranscript = ""
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var endpointPolicy = VoiceRecognitionEndpointPolicy()
    @ObservationIgnored private var lastLevelUptime: TimeInterval = 0
    #if os(iOS)
    @ObservationIgnored private var captureLease: UUID?
    @ObservationIgnored private var contextualStrings: [String] = []

    var supportsOnDeviceRecognition: Bool { speechRecognizer?.supportsOnDeviceRecognition == true }

    var recognitionAvailabilityLabel: String {
        if UserDefaults.standard.bool(forKey: "voiceOfflineOnly") {
            return supportsOnDeviceRecognition
                ? "Polskie rozpoznawanie wyłącznie na urządzeniu"
                : "Polskie rozpoznawanie offline jest niedostępne na tym urządzeniu"
        }
        return "Automatyczne polskie rozpoznawanie mowy. Nagranie może być przetwarzane przez Apple przez internet."
    }

    /// Partials are display-only. Exactly one recognizer-final result may execute a command.
    /// onEnd is only called when no command was delivered (error, silence, interruption).
    func startCommand(contextualStrings: [String] = [],
                      onPartial: @escaping (String) -> Void,
                      onFinal: @escaping (String) -> Void,
                      onEnd: @escaping (String?) -> Void) {
        guard !isStarting, !isListening else { return }
        commandFinal = onFinal
        commandEnd = onEnd
        self.contextualStrings = contextualStrings
        begin(onTranscript: onPartial)
    }

    /// Explicitly finishes the audio stream, never the partial transcript.
    func finishCommand() {
        guard commandFinal != nil, isListening, endpointPolicy.beginFinalization() else { return }
        requestFinalRecognition(generation: startGeneration)
    }
    #endif

    func start(keepAudioSessionActive: Bool, onTranscript: @escaping (String) -> Void) {
        guard !isStarting, !isListening else { return }
        commandFinal = nil
        commandEnd = nil
        self.keepAudioSessionActive = keepAudioSessionActive
        begin(onTranscript: onTranscript)
    }

    private func begin(onTranscript: @escaping (String) -> Void) {
        let generation = deliveryGate.begin()
        lastTranscript = ""
        endpointPolicy = VoiceRecognitionEndpointPolicy()
        isFinalizing = false
        inputLevel = 0
        lastLevelUptime = 0
        isStarting = true
        errorMessage = nil

        Task { @MainActor in
            await startListening(generation: generation, onTranscript: onTranscript)
        }
    }

    func stop(keepAudioSessionActive: Bool) {
        deliveryGate.cancel()
        self.keepAudioSessionActive = keepAudioSessionActive
        isStarting = false
        commandFinal = nil
        commandEnd = nil
        stopCapture()
    }

    private func startListening(generation: Int, onTranscript: @escaping (String) -> Void) async {
        defer {
            if generation == startGeneration {
                isStarting = false
            }
        }

        let speechAuthorization = await requestSpeechAuthorization()
        guard generation == startGeneration else { return }
        guard speechAuthorization == .authorized else {
            fail("Zezwól na rozpoznawanie mowy, aby używać głosu.")
            return
        }

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard generation == startGeneration else { return }
        guard microphoneAuthorized else {
            fail("Zezwól na dostęp do mikrofonu, aby używać głosu.")
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            fail("Polskie rozpoznawanie mowy jest teraz niedostępne.")
            return
        }

        #if os(iOS)
        let offlineOnly = UserDefaults.standard.bool(forKey: "voiceOfflineOnly")
        guard !offlineOnly || speechRecognizer.supportsOnDeviceRecognition else {
            fail("Polskie rozpoznawanie offline jest niedostępne. Wyłącz tryb tylko offline w ustawieniach głosu, aby korzystać z internetu.")
            return
        }
        do {
            captureLease = try VoiceAudioCoordinator.shared.beginCapture { [weak self] reason in
                guard let self, self.startGeneration == generation else { return }
                self.fail(reason)
            }
        } catch {
            fail((error as? VoiceAudioCoordinator.AudioError)?.errorDescription
                 ?? "Nie można uruchomić wejścia audio.")
            return
        }
        #endif

        #if os(iOS)
        guard let request = VoiceRecognitionRequestFactory.make(
            offlineOnly: offlineOnly, supportsOnDeviceRecognition: speechRecognizer.supportsOnDeviceRecognition,
            commandMode: commandFinal != nil, contextualStrings: contextualStrings) else {
            fail("Polskie rozpoznawanie offline jest niedostępne na tym urządzeniu.")
            return
        }
        #else
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        #endif
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            fail("Nie znaleziono wejścia mikrofonu.")
            return
        }

        let commandMode = commandFinal != nil
        let captureBlock = Self.makeCaptureBlock(request: request, commandMode: commandMode) { [weak self] active, level, uptime in
            Task { @MainActor [weak self] in
                guard let self, self.startGeneration == generation, self.isListening,
                      !self.isFinalizing else { return }
                self.endpointPolicy.observeAudio(active: active, at: uptime)
                if uptime - self.lastLevelUptime >= 1.0 / 30.0 {
                    self.inputLevel = level * 0.65 + self.inputLevel * 0.35
                    self.lastLevelUptime = uptime
                }
            }
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            do {
                try inputNode.__installTap(onBus: 0, bufferSize: 1_024, format: format,
                                          error: (), block: captureBlock)
            } catch {
                fail("Nie można uruchomić wejścia audio.")
                return
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: captureBlock)
        }
        hasInstalledAudioTap = true
        audioEngine.prepare()

        // Install the recognition consumer before the first microphone buffer.
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening, self.startGeneration == generation else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.lastTranscript = transcript
                    self.endpointPolicy.observeTranscript(at: ProcessInfo.processInfo.systemUptime)
                    onTranscript(transcript)
                    guard self.isListening, self.startGeneration == generation else { return }
                    if result.isFinal {
                        self.completeRecognition(generation: generation, isFinal: result.isFinal)
                        return
                    }
                    self.scheduleSilenceCompletion(generation: generation)
                }
                if error != nil {
                    self.fail("Nie udało się rozpoznać wypowiedzianej frazy. Spróbuj ponownie.")
                }
            }
        }

        do {
            try audioEngine.start()
        } catch {
            fail("Nie można uruchomić mikrofonu.")
            return
        }

        isListening = true
        if commandFinal != nil {
            deadlineTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.startGeneration == generation else { return }
                // A hard limit must not execute an unfinished sentence.
                self.fail("Czas nasłuchiwania minął. Wypowiedz krótsze polecenie.")
            }
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // AVAudioNodeTapBlock is not Sendable in the SDK. Construct it outside the
    // main actor, because the audio engine invokes it on its realtime thread.
    nonisolated private static func makeCaptureBlock(
        request: SFSpeechAudioBufferRecognitionRequest,
        commandMode: Bool,
        observe: @escaping @Sendable (Bool, Double, TimeInterval) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard commandMode else { return }
            let metrics = VoiceRecognitionEndpointPolicy.audioMetrics(buffer)
            observe(metrics.active, metrics.level, ProcessInfo.processInfo.systemUptime)
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func scheduleSilenceCompletion(generation: Int) {
        guard commandFinal != nil, silenceTask == nil, !endpointPolicy.isFinalizing else { return }
        silenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.isListening,
                      self.startGeneration == generation else { return }
                if self.endpointPolicy.requestEndIfSilent(at: ProcessInfo.processInfo.systemUptime) {
                    self.requestFinalRecognition(generation: generation)
                    return
                }
            }
        }
    }

    private func requestFinalRecognition(generation: Int) {
        guard generation == startGeneration, isListening, !isFinalizing else { return }
        isFinalizing = true
        inputLevel = 0
        deadlineTask?.cancel()
        deadlineTask = nil
        // Stop appending before ending the stream, but retain ownership until
        // final recognition (or timeout), so navigation cannot enter its input.
        stopAudioEngine()
        recognitionRequest?.endAudio()
        finalizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.isListening,
                  self.startGeneration == generation else { return }
            self.fail("Nie udało się zakończyć rozpoznawania. Powtórz polecenie.")
        }
    }

    private func completeRecognition(generation: Int, isFinal: Bool) {
        guard deliveryGate.claim(generation: generation, isFinal: isFinal) else { return }
        let text = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail("Nie usłyszałem polecenia. Spróbuj ponownie.")
            return
        }
        let completion = commandFinal
        commandFinal = nil
        commandEnd = nil
        isStarting = false
        stopCapture()
        completion?(text)
    }

    private func fail(_ message: String) {
        let completion = commandEnd
        commandEnd = nil
        commandFinal = nil
        deliveryGate.cancel()
        isStarting = false
        errorMessage = message
        stopCapture()
        completion?(message)
    }

    private func stopCapture() {
        isListening = false
        isFinalizing = false
        inputLevel = 0
        silenceTask?.cancel()
        silenceTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        restoreAudioSession()
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
    }

    private func restoreAudioSession() {
        #if os(iOS)
        if let lease = captureLease {
            captureLease = nil
            VoiceAudioCoordinator.shared.endCapture(lease)
        }
        #endif
    }
}
