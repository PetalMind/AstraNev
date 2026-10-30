#if os(iOS)
import Foundation
import Observation
import UIKit

@MainActor @Observable
final class VoiceAssistant {
    enum Phase { case idle, listening, working, speaking }
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

    enum Change {
        case destination(Destination), waypoint(Destination), stop, remove(UUID), preferences(RoutingPreferences), start
    }
    struct Pending { let change: Change; let context: VoiceDialogContext }
    struct Choice { let destination: Destination; let detail: String; let isStop: Bool }

    init(navigationStore: NavigationStore, placeStore: PlaceStore) {
        navigation = navigationStore
        actions = VoiceNavigationActions(navigationStore: navigationStore, placeStore: placeStore)
    }

    var canConfirm: Bool { pending != nil }
    var canChooseNext: Bool { choices.count > 1 }

    var confirmationLabel: String {
        guard let pending else { return "Potwierdź" }
        switch pending.change {
        case .destination: return isNavigating ? "Zmień cel" : "Prowadź"
        case .waypoint: return "Dodaj postój"
        case .stop: return "Zakończ nawigację"
        case .remove: return "Usuń postój"
        case .preferences: return "Zmień trasę"
        case .start: return "Rozpocznij"
        }
    }

    var isCapturingSpeech: Bool {
        phase == .listening && speechInput.isListening && !speechInput.isStarting && !speechInput.isFinalizing
    }

    var statusTitle: String {
        switch phase {
        case .idle: return "Asystent głosowy"
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
        isPresented = true
        guard !isApplyingChange else {
            phase = .working
            response = "Kończę zatwierdzoną zmianę trasy."
            return
        }
        listen()
    }

    func close() {
        generation += 1
        if !isApplyingChange { task?.cancel(); task = nil }
        speechInput.stop(keepAudioSessionActive: isNavigating)
        VoiceAudioCoordinator.shared.cancelReply()
        pending = nil
        choices = []
        choiceContext = nil
        phase = .idle
        isPresented = false
    }

    func suspend() {
        close()
        response = "Rozmowa została zakończona. Po odblokowaniu ekranu włącz mikrofon ponownie."
    }

    func listen() {
        guard !isApplyingChange, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { return }
        generation += 1
        task?.cancel()
        VoiceAudioCoordinator.shared.cancelReply()
        speechInput.stop(keepAudioSessionActive: isNavigating)
        transcript = ""
        phase = .listening
        let token = generation
        speechInput.startCommand(onPartial: { [weak self] text in
            guard let self, token == self.generation else { return }
            self.transcript = text
        }, onFinal: { [weak self] text in
            guard let self, token == self.generation else { return }
            self.submit(text)
        }, onEnd: { [weak self] message in
            guard let self, token == self.generation else { return }
            self.phase = .idle
            self.pending = nil
            self.choices = []
            self.choiceContext = nil
            self.response = message ?? "Nie usłyszałam polecenia. Dotknij mikrofonu, aby spróbować ponownie."
        })
    }

    func submit(_ text: String) {
        guard !isApplyingChange else { return }
        guard UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { suspend(); return }
        generation += 1
        let token = generation
        task?.cancel()
        speechInput.stop(keepAudioSessionActive: isNavigating)
        VoiceAudioCoordinator.shared.cancelReply()
        isPresented = true
        transcript = text
        phase = .working
        task = Task { [weak self] in
            await self?.handle(VoiceCommandParser.parse(text), token: token)
        }
    }

    var isNavigating: Bool { navigation.state.status == .navigating || navigation.state.status == .rerouting }
    func isCurrent(_ token: Int) -> Bool { token == generation && !Task.isCancelled && isPresented }

    func validate(_ context: VoiceDialogContext, token: Int) -> Bool {
        guard isCurrent(token) else { return false }
        guard context.matches(navigation.state) else {
            pending = nil; choices = []; choiceContext = nil
            say("Podróż zmieniła się podczas sprawdzania. Powtórz polecenie.")
            return false
        }
        return true
    }

    func say(_ text: String, followUp: Bool = false) {
        response = text
        phase = .speaking
        let token = generation
        VoiceAudioCoordinator.shared.speakReply(text) { [weak self] finished in
            guard let self, self.generation == token, self.isPresented else { return }
            self.phase = .idle
            if finished && followUp {
                self.listen()
            } else if !finished {
                self.pending = nil
                self.choices = []
                self.choiceContext = nil
                self.response = "Odpowiedź została przerwana. Dotknij mikrofonu i powtórz polecenie."
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
            pending = nil; choices = []; choiceContext = nil
            say("Anulowano polecenie.")
        case .choose(let index): selectChoice(index)
        case .next: selectChoice(choiceIndex + 1)
        case .correct(let query):
            guard let context = choiceContext, context.matches(navigation.state),
                  !choices.isEmpty else {
                say("Nie ma adresu do poprawienia. Powiedz „prowadź do” i podaj cel.")
                return
            }
            guard choices.allSatisfy({ !$0.isStop }) else {
                pending = nil; choices = []; choiceContext = nil
                say("Podaj ponownie rodzaj postoju, na przykład „znajdź stację paliw po trasie”.")
                return
            }
            await searchDestination(query, token: token)
        default:
            pending = nil; choices = []; choiceContext = nil
            switch command {
            case .query(let query): say(actions.answer(query))
            case .navigate(let query): await searchDestination(query, token: token)
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
            case .help:
                say("Możesz powiedzieć: prowadź do domu, kiedy dojadę, który pas, znajdź stację paliw po trasie albo wycisz komunikaty.")
            case .unknown:
                say("Nie rozumiem całego polecenia. Powtórz pełne zdanie, na przykład: „Znajdź stację paliw po trasie”.")
            default: break
            }
        }
    }
}
#endif
