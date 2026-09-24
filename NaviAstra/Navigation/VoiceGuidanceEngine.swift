import AVFoundation
import Foundation

nonisolated enum VoiceVerbosity: String, CaseIterable, Identifiable {
    case concise
    case standard
    case detailed

    var id: Self { self }

    var title: String {
        switch self {
        case .concise: "Mała"
        case .standard: "Standardowa"
        case .detailed: "Szczegółowa"
        }
    }

    var detail: String {
        switch self {
        case .concise: "Manewry, krótkie wskazówki dojścia, najważniejsze alerty i wysiadanie na następnym przystanku."
        case .standard: "Pełne prowadzenie i ważne ostrzeżenia drogowe."
        case .detailed: "Pełne prowadzenie, alerty drogowe i informacje o ruchu."
        }
    }

    func includesManeuverStage(_ stage: Int) -> Bool {
        switch self {
        case .concise: stage != 1
        case .standard, .detailed: true
        }
    }

    func includesAlightingStage(_ remainingStops: Int) -> Bool {
        self != .concise || remainingStops == 1
    }

    func includes(_ type: RoadAlertType) -> Bool {
        switch self {
        case .concise:
            type.isEnforcement || type == .speedLimitChange || type == .roadClosed || type == .accident
        case .standard:
            type != .congestion
        case .detailed:
            true
        }
    }

    func includes(_ category: TrafficIncidentCategory) -> Bool {
        switch self {
        case .concise:
            [.accident, .dangerousConditions, .ice, .laneClosed, .roadClosed, .flooding]
                .contains(category)
        case .standard:
            category != .unknown && category != .cluster && category != .jam
        case .detailed:
            category != .unknown
        }
    }
}

nonisolated struct VoiceGuidancePreferences: Equatable {
    var isEnabled: Bool
    var verbosity: VoiceVerbosity
    var voiceIdentifier: String?
    var speechRate: Float
    var volume: Float

    static func load() -> Self {
        let defaults = UserDefaults.standard
        let verbosity = defaults.string(forKey: "voiceVerbosity")
            .flatMap(VoiceVerbosity.init(rawValue:)) ?? .standard
        let storedRate = defaults.object(forKey: "voiceSpeechRate") as? Double
        let storedVolume = defaults.object(forKey: "voiceVolume") as? Double
        return Self(
            isEnabled: defaults.object(forKey: "voiceEnabled") as? Bool ?? true,
            verbosity: verbosity,
            voiceIdentifier: defaults.string(forKey: "voiceIdentifier"),
            speechRate: Float(min(0.62, max(0.38, storedRate ?? 0.5))),
            volume: Float(min(1, max(0, storedVolume ?? 1)))
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: "voiceEnabled")
        defaults.set(verbosity.rawValue, forKey: "voiceVerbosity")
        if let voiceIdentifier {
            defaults.set(voiceIdentifier, forKey: "voiceIdentifier")
        } else {
            defaults.removeObject(forKey: "voiceIdentifier")
        }
        defaults.set(Double(speechRate), forKey: "voiceSpeechRate")
        defaults.set(Double(volume), forKey: "voiceVolume")
    }
}

private enum VoiceAnnouncementPriority: Int, Comparable {
    case informational = 0
    case safety = 1
    case navigation = 2
    case maneuverNow = 3
    case critical = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var bypassesCooldown: Bool { self == .critical || self == .maneuverNow }
}

private struct VoiceAnnouncement {
    let key: String
    let text: String
    let priority: VoiceAnnouncementPriority
    let enqueuedAt: Date
}

@MainActor
final class VoiceGuidanceEngine {
    private let scheduler = VoiceAnnouncementScheduler()
    private(set) var preferences: VoiceGuidancePreferences

    init(preferences: VoiceGuidancePreferences = .load()) {
        self.preferences = preferences
        scheduler.updatePreferences(preferences)
    }

    func updatePreferences(_ preferences: VoiceGuidancePreferences) {
        self.preferences = preferences
        scheduler.updatePreferences(preferences)
    }

    func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        scheduler.setEnabled(enabled)
    }

    func reset(preservingSpokenAnnouncements: Bool = false) {
        scheduler.reset(preservingSpokenAnnouncements: preservingSpokenAnnouncements)
    }

    func announce(_ maneuver: Maneuver, coordinate: Coordinate?, distance: Double, speed: Double) {
        let early = max(200, min(1_200, speed * 24))
        let stage: Int
        if distance <= 35 { stage = 2 }
        else if distance <= max(80, speed * 8) { stage = 1 }
        else if distance <= early { stage = 0 }
        else { return }
        guard preferences.verbosity.includesManeuverStage(stage) else { return }

        let distancePrefix = distancePrefix(distance, immediate: stage == 2)
        let key = "maneuver|\(maneuverIdentity(maneuver, coordinate: coordinate))|stage-\(stage)"
        scheduler.enqueue(
            key: key,
            text: (distancePrefix ?? "") + maneuver.spokenInstruction,
            priority: stage == 2 ? .maneuverNow : .navigation
        )
    }

    func announceTransit(_ instruction: String, key: String, urgent: Bool = false) {
        scheduler.enqueue(key: key, text: instruction, priority: urgent ? .maneuverNow : .navigation)
    }

    func shouldAnnounceAlighting(remainingStops: Int) -> Bool {
        preferences.verbosity.includesAlightingStage(remainingStops)
    }

    func announce(_ alert: RoadSafetyAlert, distance: Double) {
        guard preferences.verbosity.includes(alert.type),
              let stage = roadAlertStage(for: distance) else { return }
        let priority: VoiceAnnouncementPriority = alert.type == .roadClosed ? .critical : .safety
        let key = "road|\(alert.id)|stage-\(stage)"
        scheduler.enqueue(
            key: key,
            text: (distancePrefix(distance, immediate: stage == 2) ?? "") + alert.title,
            priority: stage == 2 ? max(priority, .maneuverNow) : priority
        )
    }

    func announce(_ incident: TrafficIncident, distance: Double) {
        guard preferences.verbosity.includes(incident.category),
              let stage = roadAlertStage(for: distance) else { return }
        let isCritical = incident.category == .roadClosed ||
            ((incident.category == .accident || incident.category == .dangerousConditions || incident.category == .ice)
                && incident.severity == .major && distance <= 300)
        let priority: VoiceAnnouncementPriority = isCritical ? .critical :
            (incident.category == .jam || incident.category == .cluster ? .informational : .safety)
        var message = incident.category.mapLabel
        if preferences.verbosity == .detailed,
           incident.category == .jam,
           let delay = incident.delaySeconds,
           delay > 0 {
            message += ". Opóźnienie około \(max(1, Int((Double(delay) / 60).rounded()))) minut."
        }
        scheduler.enqueue(
            key: "traffic|\(incident.id)|stage-\(stage)",
            text: (distancePrefix(distance, immediate: stage == 2) ?? "") + message,
            priority: stage == 2 ? max(priority, .maneuverNow) : priority
        )
    }

    func announceArrival(destination: Destination?) {
        let destinationKey = destination.map {
            "\(Int(($0.coordinate.latitude * 10_000).rounded()))-\(Int(($0.coordinate.longitude * 10_000).rounded()))"
        } ?? "unknown"
        scheduler.enqueue(key: "arrival|\(destinationKey)", text: "Dotarłeś do celu.", priority: .critical)
    }

    func announceReroute(number: Int) {
        scheduler.enqueue(key: "reroute|\(number)", text: "Trasa została przeliczona.", priority: .navigation)
    }

    private func roadAlertStage(for distance: Double) -> Int? {
        if distance <= 40 { return 2 }
        if distance <= 250 { return 1 }
        if distance <= 1_200 { return 0 }
        return nil
    }

    private func distancePrefix(_ distance: Double, immediate: Bool) -> String? {
        guard !immediate, distance >= 50 else { return nil }
        let bucket = Int(distance / 50) * 50
        guard bucket > 0 else { return nil }
        return "Za \(bucket) metrów "
    }

    private func maneuverIdentity(_ maneuver: Maneuver, coordinate: Coordinate?) -> String {
        let street = (maneuver.streetName ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let place: String
        if let coordinate {
            place = "\(Int((coordinate.latitude * 10_000).rounded()))-\(Int((coordinate.longitude * 10_000).rounded()))"
        } else {
            place = "unknown"
        }
        return "\(maneuver.kind.rawValue)|\(street)|\(place)"
    }
}

@MainActor
private final class VoiceAnnouncementScheduler: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var enabled = true
    private var speechRate: Float = 0.5
    private var volume: Float = 1
    private var voiceIdentifier: String?
    private var spokenKeys: Set<String> = []
    private var pendingKeys: Set<String> = []
    private var queue: [VoiceAnnouncement] = []
    private var current: VoiceAnnouncement?
    private var currentUtterance: AVSpeechUtterance?
    private var currentUtteranceID: ObjectIdentifier?
    private var currentDidStart = false
    private var speechGeneration = 0
    private var lastSpeechEndedAt = Date.distantPast
    private var cooldownTask: Task<Void, Never>?
    private var startWatchdogTask: Task<Void, Never>?
    private var audioSessionConfigured = false
    private var audioSessionActive = false
    private var audioSessionOperationGeneration = 0
    private var audioSessionOperation: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func updatePreferences(_ preferences: VoiceGuidancePreferences) {
        speechRate = min(0.62, max(0.38, preferences.speechRate))
        volume = min(1, max(0, preferences.volume))
        voiceIdentifier = preferences.voiceIdentifier
        setEnabled(preferences.isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        guard !enabled else { return }
        stopImmediately()
    }

    func reset(preservingSpokenAnnouncements: Bool) {
        cooldownTask?.cancel()
        cooldownTask = nil
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        queue.removeAll()
        pendingKeys.removeAll()
        if !preservingSpokenAnnouncements { spokenKeys.removeAll() }
        speechGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        current = nil
        currentUtterance = nil
        currentUtteranceID = nil
        currentDidStart = false
        lastSpeechEndedAt = .distantPast
        deactivateAudioSession()
    }

    func enqueue(key: String, text: String, priority: VoiceAnnouncementPriority) {
        guard enabled, !text.isEmpty,
              !spokenKeys.contains(key), !pendingKeys.contains(key) else { return }
        let announcement = VoiceAnnouncement(key: key, text: text, priority: priority, enqueuedAt: Date())

        if let current, canInterrupt(with: priority, current: current.priority) {
            interruptCurrent(startNext: false)
        } else if current != nil || !queue.isEmpty {
            guard priority != .informational else { return }
            queue.append(announcement)
            pendingKeys.insert(key)
            sortQueue()
            if priority.bypassesCooldown {
                cooldownTask?.cancel()
                cooldownTask = nil
                pump()
            }
            return
        }

        queue.append(announcement)
        pendingKeys.insert(key)
        sortQueue()
        pump()
    }

    private func canInterrupt(with new: VoiceAnnouncementPriority,
                              current: VoiceAnnouncementPriority) -> Bool {
        switch new {
        case .critical:
            true
        case .maneuverNow:
            current == .safety || current == .informational
        case .safety:
            current == .informational
        case .navigation, .informational:
            false
        }
    }

    private func sortQueue() {
        queue.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.enqueuedAt < $1.enqueuedAt
        }
    }

    private func pump() {
        guard enabled, current == nil, !queue.isEmpty else { return }
        guard let next = queue.first else { return }
        if !next.priority.bypassesCooldown {
            let remaining = 2.5 - Date().timeIntervalSince(lastSpeechEndedAt)
            if remaining > 0 {
                guard cooldownTask == nil else { return }
                cooldownTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled, let self else { return }
                    self.cooldownTask = nil
                    self.pump()
                }
                return
            }
        }

        cooldownTask?.cancel()
        cooldownTask = nil
        current = queue.removeFirst()
        currentDidStart = false
        let utterance = makeUtterance(for: current!.text)
        currentUtterance = utterance
        currentUtteranceID = ObjectIdentifier(utterance)
        let identifier = currentUtteranceID!
        let generation = speechGeneration
#if os(iOS)
        if audioSessionActive {
            speak(utterance, identifier: identifier)
        } else {
            activateAudioSessionAndSpeak(utterance, identifier: identifier, generation: generation)
        }
#else
        synthesizer.speak(utterance)
        scheduleStartWatchdog(for: identifier)
#endif
    }

    private func makeUtterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice()
        utterance.rate = speechRate
        utterance.volume = volume
        return utterance
    }

    private func currentVoice() -> AVSpeechSynthesisVoice? {
        if let identifier = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "pl-PL")
    }

    private func speak(_ utterance: AVSpeechUtterance, identifier: ObjectIdentifier) {
        guard currentUtteranceID == identifier, enabled else { return }
        synthesizer.speak(utterance)
        scheduleStartWatchdog(for: identifier)
    }

    private func scheduleStartWatchdog(for identifier: ObjectIdentifier) {
        startWatchdogTask?.cancel()
        startWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self,
                  self.currentUtteranceID == identifier, !self.currentDidStart else { return }
            self.synthesizer.stopSpeaking(at: .immediate)
            self.finishCurrent(identifier: identifier, didSpeak: false)
        }
    }

#if os(iOS)
    private func activateAudioSessionAndSpeak(_ utterance: AVSpeechUtterance,
                                              identifier: ObjectIdentifier,
                                              generation: Int) {
        let audioSession = AVAudioSession.sharedInstance()
        enqueueAudioSessionOperation { [weak self] in
            guard let self,
                  self.currentUtteranceID == identifier,
                  self.speechGeneration == generation,
                  self.enabled else { return }
            do {
                if !self.audioSessionConfigured {
                    try await Task.detached(priority: .userInitiated) {
                        try AVAudioSession.sharedInstance().setCategory(
                            .playback, mode: .spokenAudio, options: [.duckOthers])
                    }.value
                    self.audioSessionConfigured = true
                }
                let activated = try await audioSession.activate(options: [])
                guard activated,
                      self.currentUtteranceID == identifier,
                      self.speechGeneration == generation,
                      self.enabled else {
                    _ = try? await audioSession.deactivate(options: .notifyOthersOnDeactivation)
                    self.audioSessionActive = false
                    self.finishCurrent(identifier: identifier, didSpeak: false)
                    return
                }
                self.audioSessionActive = true
                self.speak(utterance, identifier: identifier)
            } catch {
                _ = try? await audioSession.deactivate(options: .notifyOthersOnDeactivation)
                self.audioSessionActive = false
                self.finishCurrent(identifier: identifier, didSpeak: false)
            }
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        let audioSession = AVAudioSession.sharedInstance()
        enqueueAudioSessionOperation {
            _ = try? await audioSession.deactivate(options: .notifyOthersOnDeactivation)
        }
    }
#endif

    private func enqueueAudioSessionOperation(_ operation: @escaping @MainActor () async -> Void) {
        audioSessionOperationGeneration &+= 1
        let operationGeneration = audioSessionOperationGeneration
        let previousOperation = audioSessionOperation
        audioSessionOperation = Task { @MainActor [weak self] in
            await previousOperation?.value
            await operation()
            guard let self, self.audioSessionOperationGeneration == operationGeneration else { return }
            self.audioSessionOperation = nil
        }
    }

    private func interruptCurrent(startNext: Bool) {
        guard let current else { return }
        if !spokenKeys.contains(current.key) { pendingKeys.remove(current.key) }
        speechGeneration &+= 1
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        self.current = nil
        currentUtterance = nil
        currentUtteranceID = nil
        currentDidStart = false
        if startNext { pump() }
    }

    private func stopImmediately() {
        cooldownTask?.cancel()
        cooldownTask = nil
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        speechGeneration &+= 1
        queue.removeAll()
        pendingKeys.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        current = nil
        currentUtterance = nil
        currentUtteranceID = nil
        currentDidStart = false
        deactivateAudioSession()
    }

    private func finishCurrent(identifier: ObjectIdentifier, didSpeak: Bool) {
        guard currentUtteranceID == identifier, let current else { return }
        if didSpeak { spokenKeys.insert(current.key) }
        pendingKeys.remove(current.key)
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
        self.current = nil
        currentUtterance = nil
        currentUtteranceID = nil
        currentDidStart = false
        if didSpeak { lastSpeechEndedAt = Date() }
        if queue.isEmpty {
#if os(iOS)
            deactivateAudioSession()
#endif
        }
        pump()
    }

    private func handleDidStart(identifier: ObjectIdentifier) {
        guard currentUtteranceID == identifier else { return }
        currentDidStart = true
        startWatchdogTask?.cancel()
        startWatchdogTask = nil
    }

    private func handleDidFinish(identifier: ObjectIdentifier) {
        finishCurrent(identifier: identifier, didSpeak: true)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.handleDidStart(identifier: identifier) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.handleDidFinish(identifier: identifier) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishCurrent(identifier: identifier, didSpeak: false) }
    }
}
