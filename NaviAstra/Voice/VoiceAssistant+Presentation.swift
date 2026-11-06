#if os(iOS)
import Foundation

extension VoiceAssistant {
    func setConversationDetailsPresented(_ presented: Bool) {
        isConversationDetailsPresented = presented
        if presented { cancelResponseDismissal() }
        else { scheduleResponseDismissal() }
    }

    func cancelResponseDismissal() {
        responseDismissalTask?.cancel()
        responseDismissalTask = nil
    }

    /// A completed reply leaves a short reading window. Closing the bar must
    /// never interrupt a new utterance, a pending choice, or an accepted route edit.
    func scheduleResponseDismissal() {
        cancelResponseDismissal()
        guard isPresented, phase == .idle, !canConfirm, choices.isEmpty, !isAwaitingDestinationDetails,
              !isConversationDetailsPresented else { return }
        let token = generation
        let wait = waitBeforeDismissal
        responseDismissalTask = Task { @MainActor [weak self] in
            do { try await wait() } catch { return }
            guard !Task.isCancelled, let self,
                  self.generation == token, self.isPresented, self.phase == .idle,
                  !self.isApplyingChange, !self.canConfirm, self.choices.isEmpty, !self.isAwaitingDestinationDetails,
                  !self.isConversationDetailsPresented else { return }
            self.responseDismissalTask = nil
            self.close()
        }
    }
}
#endif
