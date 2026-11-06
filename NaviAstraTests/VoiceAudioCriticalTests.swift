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
        policy.observeTranscript("prowadź do ulicy Lipowej", at: 100)
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
        policy.observeTranscript("prowadź do ulicy Lipowej", at: 100)
        policy.observeAudio(active: false, at: 101)
        let endBeforeQuietInterval = policy.requestEndIfSilent(at: 101.1)
        #expect(!endBeforeQuietInterval)
        policy.observeAudio(active: false, at: 102)
        policy.observeTranscript("prowadź do ulicy Lipowej 14", at: 102) // delayed recognition still arriving
        let endDuringRecognition = policy.requestEndIfSilent(at: 102.1)
        #expect(!endDuringRecognition)
        policy.observeAudio(active: false, at: 105)
        let endWhenBothQuiet = policy.requestEndIfSilent(at: 105.1)
        #expect(endWhenBothQuiet)
    }

    @Test func aNaturalPauseDoesNotDiscardTheRestOfACommand() {
        var policy = VoiceRecognitionEndpointPolicy()
        policy.observeAudio(active: true, at: 100)
        policy.observeTranscript("prowadź do ulicy Lipowej", at: 100)
        policy.observeAudio(active: false, at: 102)
        let endedInPause = policy.requestEndIfSilent(at: 102.1)
        #expect(!endedInPause)
        policy.observeAudio(active: true, at: 102.2)
        policy.observeTranscript("prowadź do ulicy Lipowej 14 A", at: 102.4)
        policy.observeAudio(active: false, at: 104.6)
        let endedBeforeCompleteSilence = policy.requestEndIfSilent(at: 104.7)
        #expect(!endedBeforeCompleteSilence)
        policy.observeAudio(active: false, at: 105.1)
        let endedAfterWholeSentence = policy.requestEndIfSilent(at: 105.2)
        #expect(endedAfterWholeSentence)
    }

    @Test func repeatedSnapshotsDoNotLoseTheWholeAddressToTheListeningDeadline() {
        var policy = VoiceRecognitionEndpointPolicy()
        policy.observeAudio(active: true, at: 100)
        policy.observeTranscript("prowadź do ulicy Lipowej 14", at: 100)
        policy.observeTranscript("prowadź do ulicy Lipowej 14 A", at: 102)
        policy.observeAudio(active: true, at: 102)
        policy.observeTranscript("prowadź do ulicy Lipowej 14 A", at: 104.5)
        policy.observeAudio(active: false, at: 104.6)
        let shouldFinalize = policy.requestEndIfSilent(at: 104.7)
        #expect(shouldFinalize)
        // No partial (including a full-looking address) is executable before
        // the recognizer supplies its final result.
        var gate = VoiceRecognitionDeliveryGate()
        let generation = gate.begin()
        let partialDelivery = gate.claim(generation: generation, isFinal: false)
        let finalDelivery = gate.claim(generation: generation, isFinal: true)
        #expect(!partialDelivery)
        #expect(finalDelivery)
    }

    @Test func microphoneHandoffWaitsForThePreviousSpokenReplyTail() {
        var policy = VoiceCaptureHandoffPolicy()
        #expect(policy.remainingDelay(at: 100) == 0)
        policy.outputEnded(at: 100, outputLatency: 0.02, bufferDuration: 0.01)
        #expect(policy.remainingDelay(at: 100) >= 0.34)
        #expect(policy.remainingDelay(at: 100.4) == 0)
        // A delayed route gets time to drain as well, bounded to avoid an
        // indefinitely starting microphone when a driver reports bad latency.
        policy.outputEnded(at: 101, outputLatency: 2, bufferDuration: 0.1)
        #expect(policy.remainingDelay(at: 102) > 1)
        #expect(policy.remainingDelay(at: 104) == 0)
        policy.outputEnded(at: 105, outputLatency: 999, bufferDuration: .infinity)
        #expect(policy.remainingDelay(at: 105) == 3)
        policy.outputEnded(at: 105, outputLatency: .nan, bufferDuration: .nan)
        #expect(policy.remainingDelay(at: 105) == 3)
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
        // Even an existing preference that permits online search dictation
        // cannot opt Astra's commands into sending microphone audio away.
        for offlineOnly in [false, true] {
            #expect(VoiceRecognitionRequestFactory.make(offlineOnly: offlineOnly, supportsOnDeviceRecognition: false,
                                                       commandMode: true, contextualStrings: []) == nil)
            let command = try #require(VoiceRecognitionRequestFactory.make(
                offlineOnly: offlineOnly, supportsOnDeviceRecognition: true, commandMode: true, contextualStrings: []))
            #expect(command.requiresOnDeviceRecognition)
            #expect(command.taskHint == .dictation)
        }
        #expect(VoiceRecognitionRequestFactory.make(offlineOnly: true, supportsOnDeviceRecognition: false,
                                                   commandMode: false, contextualStrings: []) == nil)
        let localSearch = try #require(VoiceRecognitionRequestFactory.make(
            offlineOnly: true, supportsOnDeviceRecognition: true, commandMode: false, contextualStrings: []))
        #expect(localSearch.requiresOnDeviceRecognition)
        for supportsOnDevice in [false, true] {
            let automatic = try #require(VoiceRecognitionRequestFactory.make(
                offlineOnly: false, supportsOnDeviceRecognition: supportsOnDevice,
                commandMode: false, contextualStrings: []))
            #expect(!automatic.requiresOnDeviceRecognition)
            #expect(automatic.taskHint == .search)
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
