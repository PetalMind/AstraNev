#if os(iOS)
import Foundation
import Observation
import UIKit

@MainActor @Observable
final class VoiceAssistant {
    enum Phase { case idle, listening, working, speaking }
    typealias ReplySpeaker = @MainActor (String, @escaping (Bool) -> Void) -> Void
    private(set) var isPresented = false
    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var response = "Powiedz na przykład: „Prowadź do domu” lub „Kiedy dojadę?”."
    var isApplyingChange = false
    let speechInput = SearchSpeechInput()
    @ObservationIgnored let navigation: NavigationStore
    @ObservationIgnored let actions: VoiceNavigationActions
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var generation = 0
    @ObservationIgnored var pending: Pending?
    @ObservationIgnored var choices: [Choice] = []
    @ObservationIgnored var choiceIndex = 0
    @ObservationIgnored var choiceContext: VoiceDialogContext?
    @ObservationIgnored var lastSearchQuery = ""
    var destinationDialog: VoiceDestinationDialog?
    @ObservationIgnored var recentDestinationDialog: VoiceDestinationDialog?
    @ObservationIgnored let replySpeaker: ReplySpeaker
    @ObservationIgnored let interactionAvailable: @MainActor () -> Bool
    @ObservationIgnored let waitBeforeDismissal: @MainActor () async throws -> Void
    @ObservationIgnored var responseDismissalTask: Task<Void, Never>?
    @ObservationIgnored var isConversationDetailsPresented = false

    enum Change {
        case destination(Destination), waypoint(Destination), stop, remove(UUID), preferences(RoutingPreferences), start
        case alternativeRoute(UUID)
        case activeAlternativeRoute(VoiceAlternativeRouteProposal)
    }
    struct Pending { let change: Change; let context: VoiceDialogContext }
    struct Choice { let destination: Destination; let detail: String; let isStop: Bool }

    init(navigationStore: NavigationStore, placeStore: PlaceStore,
         replySpeaker: @escaping ReplySpeaker = { text, completion in
             VoiceAudioCoordinator.shared.speakReply(text, completion: completion)
         },
         interactionAvailable: @escaping @MainActor () -> Bool = {
             UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
         },
         waitBeforeDismissal: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .seconds(4))
         },
         destinationResolver: VoiceDestinationResolver? = nil) {
        navigation = navigationStore
        actions = VoiceNavigationActions(navigationStore: navigationStore, placeStore: placeStore,
                                         destinationResolver: destinationResolver)
        self.replySpeaker = replySpeaker
        self.interactionAvailable = interactionAvailable
        self.waitBeforeDismissal = waitBeforeDismissal
    }

    var canConfirm: Bool { pending != nil }
    var canChooseNext: Bool { choices.count > 1 }
    var isAwaitingDestinationDetails: Bool { destinationDialog != nil }

    var confirmationLabel: String {
        guard let pending else { return "Potwierdź" }
        switch pending.change {
        case .destination: return isNavigating ? "Zmień cel" : "Prowadź"
        case .waypoint: return "Dodaj postój"
        case .stop: return "Zakończ nawigację"
        case .remove: return "Usuń postój"
        case .preferences, .alternativeRoute, .activeAlternativeRoute: return "Zmień trasę"
        case .start: return "Rozpocznij"
        }
    }

    var isCapturingSpeech: Bool {
        phase == .listening && speechInput.isListening && !speechInput.isStarting && !speechInput.isFinalizing
    }

    var statusTitle: String {
        switch phase {
        case .idle: return "Astra"
        case .listening:
            if speechInput.isFinalizing { return "Kończę rozpoznawanie…" }
            return isCapturingSpeech ? "Słucham…" : "Przygotowuję mikrofon…"
        case .working: return "Sprawdzam…"
        case .speaking: return "Odpowiadam…"
        }
    }

    func finishUtterance() {
        guard isCapturingSpeech else { return }
        speechInput.finishCommand()
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Opt-in visual fixture; never records audio or exists in a device build.
    func prepareVisualAudit() {
        guard let mode = ProcessInfo.processInfo.environment["NAVIASTRA_VOICE_UI_AUDIT"],
              ["response", "confirmation"].contains(mode) else { return }
        isPresented = true
        phase = .idle
        transcript = "Znajdź stację paliw po trasie"
        response = "Stacja paliw przy ulicy Pomorskiej. Dodatkowy czas jazdy: około 3 minuty. Dodać postój?"
        if mode == "confirmation" {
            let destination = Destination(name: "Stacja paliw przy ulicy Pomorskiej",
                coordinate: Coordinate(latitude: 51.765, longitude: 19.464))
            pending = Pending(change: .waypoint(destination), context: VoiceDialogContext(state: navigation.state))
        }
    }
    #endif

    func open() {
        cancelResponseDismissal()
        isPresented = true
        guard !isApplyingChange else {
            phase = .working
            response = "Kończę zatwierdzoną zmianę trasy."
            return
        }
        listen()
    }

    func close() {
        cancelResponseDismissal()
        isConversationDetailsPresented = false
        generation += 1
        if !isApplyingChange { task?.cancel(); task = nil }
        speechInput.stop(keepAudioSessionActive: isNavigating)
        VoiceAudioCoordinator.shared.cancelReply()
        pending = nil
        choices = []
        choiceContext = nil
        clearDestinationDialog()
        phase = .idle
        isPresented = false
    }

    func finishApplyingChange(token: Int) {
        isApplyingChange = false
        // Closing the conversation invalidates its speech, while an accepted
        // route mutation may still finish. Recover a bar reopened in that gap.
        guard generation != token, isPresented, phase == .working else { return }
        phase = .idle
        response = "Możesz już wydać kolejne polecenie. Sprawdź trasę na mapie."
        scheduleResponseDismissal()
    }

    func suspend() {
        close()
        response = "Rozmowa została zakończona. Po odblokowaniu ekranu włącz mikrofon ponownie."
    }

    func listen() {
        guard !isApplyingChange, interactionAvailable() else { return }
        cancelResponseDismissal()
        generation += 1
        task?.cancel()
        VoiceAudioCoordinator.shared.cancelReply()
        speechInput.stop(keepAudioSessionActive: isNavigating)
        transcript = ""
        phase = .listening
        let token = generation
        speechInput.startCommand(contextualStrings: speechContext, onPartial: { [weak self] text in
            guard let self, token == self.generation else { return }
            self.transcript = text
        }, onFinal: { [weak self] text in
            guard let self, token == self.generation else { return }
            self.submit(text)
        }, onEnd: { [weak self] message in
            guard let self, token == self.generation else { return }
            self.captureEnded(message)
        })
    }

    func captureEnded(_ message: String?) {
        phase = .idle
        discardExpiredDialog()
        pending = nil; choices = []; choiceContext = nil
        if destinationDialog != nil {
            response = (message ?? "Nie usłyszałam odpowiedzi.")
                + " Pamiętam adres „\(lastSearchQuery)”. Dotknij mikrofonu, aby go doprecyzować."
        } else {
            response = message ?? "Nie usłyszałam polecenia. Dotknij mikrofonu, aby spróbować ponownie."
        }
        scheduleResponseDismissal()
    }

    func submit(_ text: String) {
        guard !isApplyingChange else { return }
        guard interactionAvailable() else { suspend(); return }
        cancelResponseDismissal()
        generation += 1
        let token = generation
        task?.cancel()
        speechInput.stop(keepAudioSessionActive: isNavigating)
        VoiceAudioCoordinator.shared.cancelReply()
        isPresented = true
        transcript = text
        phase = .working
        task = Task { [weak self] in
            await self?.handleUtterance(text, token: token)
        }
    }

    var isNavigating: Bool { navigation.state.status == .navigating || navigation.state.status == .rerouting }
    func isCurrent(_ token: Int) -> Bool { token == generation && !Task.isCancelled && isPresented }

    func validate(_ context: VoiceDialogContext, token: Int) -> Bool {
        guard isCurrent(token) else { return false }
        guard context.matches(navigation.state) else {
            pending = nil; choices = []; choiceContext = nil
            clearDestinationDialog()
            say("Podróż zmieniła się podczas sprawdzania. Podaj cel dla aktualnej podróży.")
            return false
        }
        return true
    }

    func say(_ text: String, followUp: Bool = false) {
        cancelResponseDismissal()
        response = text
        phase = .speaking
        let token = generation
        replySpeaker(text) { [weak self] finished in
            guard let self, self.generation == token, self.isPresented else { return }
            self.phase = .idle
            if finished && followUp {
                self.listen()
            } else {
                if !finished {
                    self.discardExpiredDialog()
                    self.pending = nil; self.choices = []; self.choiceContext = nil
                    self.response = self.destinationDialog == nil
                        ? "Odpowiedź została przerwana. Dotknij mikrofonu, aby mówić dalej."
                        : "Odpowiedź została przerwana. Pamiętam adres. Dotknij mikrofonu, aby go doprecyzować."
                }
                self.scheduleResponseDismissal()
            }
        }
    }

    func ask(_ change: Change, text: String) {
        pending = Pending(change: change, context: VoiceDialogContext(state: navigation.state))
        say(text, followUp: true)
    }

    func handle(_ command: VoiceCommand, token: Int) async {
        guard isCurrent(token) else { return }
        switch command {
        case .confirm: await confirm(token: token)
        case .cancel:
            recentDestinationDialog = nil
            pending = nil; choices = []; choiceContext = nil
            clearDestinationDialog()
            say("Anulowano polecenie.")
        case .choose(let index): await chooseDestination(index, token: token)
        case .next: selectChoice(choiceIndex + 1)
        case .correct(let query):
            await refineDestination(query, explicitCorrection: true, token: token)
        default:
            pending = nil; choices = []; choiceContext = nil
            clearDestinationDialog()
            switch command {
            case .query(let query): say(actions.answer(query))
            case .navigate(let query):
                recentDestinationDialog = nil
                await searchDestination(query, token: token, startsResolvedPlaceImmediately: true)
            case .searchStop(let category, let nearDestination):
                await searchStops(category, nearDestination: nearDestination, token: token)
            case .setMuted(let muted):
                navigation.setVoiceEnabled(!muted)
                say(muted ? "Komunikaty nawigacji wyciszone." : "Komunikaty nawigacji włączone.")
            case .setVerbosity(let verbosity):
                var preferences = navigation.state.voicePreferences
                preferences.verbosity = verbosity
                navigation.setVoicePreferences(preferences)
                say("Szczegółowość komunikatów: \(verbosity.title.lowercased()).")
            case .adjustRate(let delta):
                var preferences = navigation.state.voicePreferences
                preferences.speechRate = min(0.62, max(0.38, preferences.speechRate + Float(delta)))
                navigation.setVoicePreferences(preferences)
                say(delta < 0 ? "Będę mówić wolniej." : "Będę mówić szybciej.")
            case .adjustVolume(let delta):
                var preferences = navigation.state.voicePreferences
                let previous = preferences.volume
                preferences.volume = min(1, max(0, previous + Float(delta)))
                navigation.setVoicePreferences(preferences)
                if preferences.volume == previous {
                    say(delta > 0 ? "Głośność komunikatów jest już maksymalna." : "Głośność komunikatów wynosi już zero.")
                } else {
                    say(delta > 0 ? "Zwiększyłam głośność komunikatów." : "Zmniejszyłam głośność komunikatów.")
                }
            case .overview: navigation.showRouteOverview(); say("Pokazuję całą trasę.")
            case .follow: navigation.returnToFollow(); say("Mapa śledzi Twoją pozycję.")
            case .start:
                guard navigation.state.status == .routePreview else { say("Najpierw wybierz cel i wyznacz trasę."); return }
                ask(.start, text: "Rozpocząć prowadzenie do \(navigation.state.destination?.name ?? "wybranego celu")?")
            case .stop:
                guard isNavigating else { say("Nawigacja nie jest uruchomiona."); return }
                ask(.stop, text: "Zakończyć bieżącą nawigację?")
            case .removeNextStop: await proposeRemovingStop(token: token)
            case .avoidHighways, .avoidTolls: await proposePreferences(command, token: token)
            case .alternativeRoute: await proposeAlternativeRoute(token: token)
            case .help:
                say("Możesz powiedzieć: Astra, prowadź do domu, kiedy dojadę, gdzie mogę zaparkować, znajdź stację paliw po trasie, omiń autostrady albo głośniej. Dotknij mikrofonu, aby przerwać moją odpowiedź i mówić.")
            case .unknown:
                say("Nie zrozumiałam polecenia. Powiedz na przykład „znajdź parking po drodze” albo „pomoc”.")
            default: break
            }
        }
    }
}
#endif
