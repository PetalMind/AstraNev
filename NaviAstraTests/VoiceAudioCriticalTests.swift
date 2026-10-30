#if os(iOS)
import Foundation
import AVFoundation
import Speech
import Testing
@testable import NaviAstra

struct VoiceAudioCriticalTests {
    @Test(arguments: [false, true])
    func stereoPCMActivityRespectsBothBufferLayouts(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000, channels: 2,
                                               interleaved: interleaved))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        pcm.frameLength = 32
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        #expect(buffers.count == (interleaved ? 1 : 2))
        for buffer in buffers {
            let samples = try #require(buffer.mData).assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0..<sampleCount { samples[index] = 0 }
        }
        #expect(!VoiceRecognitionEndpointPolicy.hasAudioActivity(pcm))
        #expect(VoiceRecognitionEndpointPolicy.audioMetrics(pcm).level == 0)

        // Populate raw AudioBufferList storage, independently of floatChannelData.
        // Activity only in the right channel catches first-channel-only scans.
        let right = try #require(buffers[interleaved ? 0 : 1].mData).assumingMemoryBound(to: Float.self)
        for frame in 0..<32 { right[interleaved ? frame * 2 + 1 : frame] = 0.1 }
        #expect(VoiceRecognitionEndpointPolicy.hasAudioActivity(pcm))
        let rightLevel = VoiceRecognitionEndpointPolicy.audioMetrics(pcm).level
        #expect(rightLevel > 0 && rightLevel <= 1)
        for frame in 0..<32 { right[interleaved ? frame * 2 + 1 : frame] = 0 }
        #expect(!VoiceRecognitionEndpointPolicy.hasAudioActivity(pcm))

        let left = try #require(buffers[0].mData).assumingMemoryBound(to: Float.self)
        for frame in 0..<32 { left[interleaved ? frame * 2 : frame] = 0.1 }
        #expect(VoiceRecognitionEndpointPolicy.hasAudioActivity(pcm))
        #expect(VoiceRecognitionEndpointPolicy.audioMetrics(pcm).level == rightLevel)

        left[0] = .nan
        let invalid = VoiceRecognitionEndpointPolicy.audioMetrics(pcm)
        #expect(invalid.active) // Corrupt buffers must not end a sentence.
        #expect(invalid.level.isFinite)
    }

    @Test func cancelledAndReplacedRecognitionCannotExecuteLateCommands() {
        var gate = VoiceRecognitionDeliveryGate()
        let first = gate.begin()
        gate.cancel()
        let cancelledDelivery = gate.claim(generation: first, isFinal: true)
        #expect(!cancelledDelivery)

        let second = gate.begin()
        let staleDelivery = gate.claim(generation: first, isFinal: true)
        #expect(!staleDelivery)
        let currentDelivery = gate.claim(generation: second, isFinal: true)
        #expect(currentDelivery)
        // Duplicate final callbacks still execute only once.
        let duplicateDelivery = gate.claim(generation: second, isFinal: true)
        #expect(!duplicateDelivery)

        let third = gate.begin()
        let previousGenerationDelivery = gate.claim(generation: second, isFinal: true)
        #expect(!previousGenerationDelivery)
        let replacementDelivery = gate.claim(generation: third, isFinal: true)
        #expect(replacementDelivery)
    }

    @Test func partialConfirmationNeverClaimsDeliveryEvenAfterSilence() {
        var gate = VoiceRecognitionDeliveryGate()
        let generation = gate.begin()
        let partialDelivery = gate.claim(generation: generation, isFinal: false)
        #expect(!partialDelivery)
        let repeatedPartialDelivery = gate.claim(generation: generation, isFinal: false)
        #expect(!repeatedPartialDelivery)
        let finalDelivery = gate.claim(generation: generation, isFinal: true)
        #expect(finalDelivery)
        let duplicateFinalDelivery = gate.claim(generation: generation, isFinal: true)
        #expect(!duplicateFinalDelivery)
    }

    @Test func transcriptionStallIsNotAnAcousticEndpoint() {
        var policy = VoiceRecognitionEndpointPolicy()
        policy.observeTranscript(at: 100)
        policy.observeAudio(active: true, at: 102)
        let endWhileSpeaking = policy.requestEndIfSilent(at: 102.1)
        #expect(!endWhileSpeaking)
        // Ending audio buffers altogether is an input failure, not silence.
        let endWithoutAudio = policy.requestEndIfSilent(at: 105)
        #expect(!endWithoutAudio)
        policy.observeAudio(active: false, at: 105)
        let endAfterSilence = policy.requestEndIfSilent(at: 105.1)
        #expect(endAfterSilence)
        let repeatedEnd = policy.requestEndIfSilent(at: 105.2)
        #expect(!repeatedEnd)
    }

    @Test func recognizerAndAudioMustBothBeQuietBeforeFinalization() {
        var policy = VoiceRecognitionEndpointPolicy()
        policy.observeAudio(active: false, at: 100)
        let endWithoutWords = policy.requestEndIfSilent(at: 100.1)
        #expect(!endWithoutWords)
        policy.observeTranscript(at: 100)
        policy.observeAudio(active: false, at: 101)
        let endBeforeQuietInterval = policy.requestEndIfSilent(at: 101.1)
        #expect(!endBeforeQuietInterval)
        policy.observeAudio(active: false, at: 102)
        policy.observeTranscript(at: 102) // delayed recognition still arriving
        let endDuringRecognition = policy.requestEndIfSilent(at: 102.1)
        #expect(!endDuringRecognition)
        policy.observeAudio(active: false, at: 105)
        let endWhenBothQuiet = policy.requestEndIfSilent(at: 105.1)
        #expect(endWhenBothQuiet)
    }

    @Test func aNaturalPauseDoesNotDiscardTheRestOfACommand() {
        var policy = VoiceRecognitionEndpointPolicy()
        policy.observeAudio(active: true, at: 100)
        policy.observeTranscript(at: 100) // „Znajdź stację paliw…”
        policy.observeAudio(active: false, at: 102)
        let endedInPause = policy.requestEndIfSilent(at: 102.1)
        #expect(!endedInPause)
        policy.observeAudio(active: true, at: 102.2)
        policy.observeTranscript(at: 102.4) // „…po trasie”
        policy.observeAudio(active: false, at: 104.6)
        let endedBeforeCompleteSilence = policy.requestEndIfSilent(at: 104.7)
        #expect(!endedBeforeCompleteSilence)
        policy.observeAudio(active: false, at: 105.1)
        let endedAfterWholeSentence = policy.requestEndIfSilent(at: 105.2)
        #expect(endedAfterWholeSentence)
    }

    @Test func manuallyEndingAudioStillRequiresARecognizerFinalResult() {
        var policy = VoiceRecognitionEndpointPolicy()
        var gate = VoiceRecognitionDeliveryGate()
        let generation = gate.begin()
        let firstFinish = policy.beginFinalization()
        let duplicateFinish = policy.beginFinalization()
        #expect(firstFinish)
        #expect(!duplicateFinish)
        let partialDelivery = gate.claim(generation: generation, isFinal: false)
        #expect(!partialDelivery)
        let finalDelivery = gate.claim(generation: generation, isFinal: true)
        #expect(finalDelivery)
        let duplicateDelivery = gate.claim(generation: generation, isFinal: true)
        #expect(!duplicateDelivery)
    }

    @Test func offlinePreferenceIsRequiredWithoutSilentlyFallingBackToNetwork() throws {
        #expect(VoiceRecognitionRequestFactory.make(offlineOnly: true, supportsOnDeviceRecognition: false,
                                                   commandMode: true, contextualStrings: []) == nil)
        let offline = try #require(VoiceRecognitionRequestFactory.make(
            offlineOnly: true, supportsOnDeviceRecognition: true, commandMode: true, contextualStrings: []))
        #expect(offline.requiresOnDeviceRecognition)
        for supportsOnDevice in [false, true] {
            let automatic = try #require(VoiceRecognitionRequestFactory.make(
                offlineOnly: false, supportsOnDeviceRecognition: supportsOnDevice,
                commandMode: true, contextualStrings: []))
            #expect(!automatic.requiresOnDeviceRecognition)
            #expect(automatic.taskHint == .dictation)
        }
    }

    @Test func commandContextKeepsTheWholeFuelRequestAndBoundsPersonalPlaceHints() throws {
        let places = ["  Łódź  Fabryczna  ", "łódź fabryczna", "", String(repeating: "a", count: 121)]
            + (0..<150).map { "Miejsce \($0)" }
        let request = try #require(VoiceRecognitionRequestFactory.make(
            offlineOnly: false, supportsOnDeviceRecognition: true,
            commandMode: true, contextualStrings: places))
        #expect(request.contextualStrings.contains("znajdź stację paliw po trasie"))
        #expect(request.contextualStrings.contains("Łódź Fabryczna"))
        #expect(!request.contextualStrings.contains("łódź fabryczna"))
        #expect(request.contextualStrings.count == 100)
        #expect(request.contextualStrings.allSatisfy { !$0.isEmpty && $0.count <= 120 })
    }

    @Test func navigationInstructionsCannotSurviveAWholeVoiceDialog() {
        #expect(VoicePendingGuidancePolicy.isFresh(updatedUptime: 100, now: 103, urgent: false))
        #expect(!VoicePendingGuidancePolicy.isFresh(updatedUptime: 100, now: 115, urgent: false))
        #expect(!VoicePendingGuidancePolicy.isFresh(updatedUptime: 100, now: 103, urgent: true))
        // Only a new progress observation may make a pending instruction fresh again.
        #expect(VoicePendingGuidancePolicy.isFresh(updatedUptime: 114, now: 115, urgent: false))
        #expect(!VoicePendingGuidancePolicy.isFresh(updatedUptime: 116, now: 115, urgent: false))
    }

    @Test func advancingManeuverInvalidatesHeldDirectionsButNotUnrelatedAlerts() {
        let identity = "turnRight|Dluga|520000-210000"
        #expect(!VoicePendingGuidancePolicy.isObsoleteManeuver(
            key: "maneuver|\(identity)|stage-0", currentIdentity: identity))
        #expect(VoicePendingGuidancePolicy.isObsoleteManeuver(
            key: "maneuver|turnLeft|Krotka|520010-210020|stage-1", currentIdentity: identity))
        #expect(VoicePendingGuidancePolicy.isObsoleteManeuver(
            key: "roundabout-enter|roundaboutEnter|Rondo|520020-210010", currentIdentity: identity))
        #expect(!VoicePendingGuidancePolicy.isObsoleteManeuver(
            key: "road-event|accident|520010-210020|stage-1", currentIdentity: identity))
    }

    @Test func closerStageReplacesOldDistanceWithoutSuppressingOtherEvents() {
        #expect(VoicePendingGuidancePolicy.supersedes("maneuver|A|stage-0", with: "maneuver|A|stage-1"))
        #expect(VoicePendingGuidancePolicy.supersedes("road-event|A|stage-1", with: "road-event|A|stage-2"))
        #expect(!VoicePendingGuidancePolicy.supersedes("maneuver|A|stage-1", with: "maneuver|A|stage-0"))
        #expect(!VoicePendingGuidancePolicy.supersedes("maneuver|A|stage-0", with: "maneuver|B|stage-1"))
        #expect(!VoicePendingGuidancePolicy.supersedes("arrival|A", with: "maneuver|A|stage-1"))
    }
}
#endif
