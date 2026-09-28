import AVFoundation
import Observation
import Speech

@MainActor @Observable
final class SearchSpeechInput {
    private(set) var isStarting = false
    private(set) var isListening = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "pl-PL"))
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var hasInstalledAudioTap = false
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var keepAudioSessionActive = false
    @ObservationIgnored private var didChangeAudioSessionCategory = false
    @ObservationIgnored private var didActivateAudioSession = false

    func start(keepAudioSessionActive: Bool, onTranscript: @escaping (String) -> Void) {
        guard !isStarting, !isListening else { return }
        startGeneration += 1
        let generation = startGeneration
        self.keepAudioSessionActive = keepAudioSessionActive
        isStarting = true
        errorMessage = nil

        Task { @MainActor in
            await startListening(generation: generation, onTranscript: onTranscript)
        }
    }

    func stop(keepAudioSessionActive: Bool) {
        startGeneration += 1
        self.keepAudioSessionActive = keepAudioSessionActive
        isStarting = false
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
            errorMessage = "Zezwól na rozpoznawanie mowy, aby wyszukiwać głosem."
            return
        }

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard generation == startGeneration else { return }
        guard microphoneAuthorized else {
            errorMessage = "Zezwól na dostęp do mikrofonu, aby wyszukiwać głosem."
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Polskie rozpoznawanie mowy jest teraz niedostępne."
            return
        }

        #if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio,
                                         options: [.defaultToSpeaker, .duckOthers])
            didChangeAudioSessionCategory = true
            try audioSession.setActive(true)
            didActivateAudioSession = true
        } catch {
            restoreAudioSession()
            errorMessage = "Nie można uruchomić wejścia audio."
            return
        }
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            errorMessage = "Nie znaleziono wejścia mikrofonu."
            stopCapture()
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledAudioTap = true
        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Nie można uruchomić mikrofonu."
            stopCapture()
            return
        }

        isListening = true
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    onTranscript(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.stopCapture()
                        return
                    }
                }
                if error != nil {
                    self.stopCapture()
                    self.errorMessage = "Nie udało się rozpoznać wypowiedzianej frazy."
                }
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

    private func stopCapture() {
        isListening = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        restoreAudioSession()
    }

    private func restoreAudioSession() {
        #if os(iOS)
        guard didChangeAudioSessionCategory || didActivateAudioSession else { return }
        let audioSession = AVAudioSession.sharedInstance()
        if didChangeAudioSessionCategory {
            try? audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        if didActivateAudioSession && !keepAudioSessionActive {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
        didChangeAudioSessionCategory = false
        didActivateAudioSession = false
        #endif
    }
}
