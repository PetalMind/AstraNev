#if os(iOS)
import Foundation

extension VoiceAssistant {
    func searchDestination(_ query: String, token: Int) async {
        pending = nil
        choices = []
        let context = VoiceDialogContext(state: navigation.state)
        lastSearchQuery = query
        if let saved = actions.savedDestination(named: query) {
            choices = [Choice(destination: saved, detail: saved.address ?? "", isStop: false)]
        } else {
            let normalized = QueryClassifier.normalize(query)
            if ["dom", "domu", "do domu", "praca", "pracy", "do pracy"].contains(normalized) {
                say("Najpierw zapisz jednoznaczny adres domu lub pracy w zapisanych miejscach.")
                return
            }
            do {
                let results = try await actions.searchDestinations(query)
                guard validate(context, token: token) else { return }
                choices = results.prefix(3).map { Choice(destination: $0, detail: $0.address ?? "", isStop: false) }
            } catch {
                guard isCurrent(token) else { return }
                say("Nie udało się wyszukać miejsca. Sprawdź połączenie i spróbuj ponownie.")
                return
            }
        }
        guard isCurrent(token) else { return }
        choiceContext = context
        guard !choices.isEmpty else { say("Nie znalazłam miejsca. Podaj nazwę wraz z miejscowością."); return }
        selectChoice(0)
    }

    func searchStops(_ category: NearbyPlaceCategory, nearDestination: Bool, token: Int) async {
        guard navigation.state.destination != nil else { say("Najpierw wybierz cel podróży."); return }
        guard navigation.state.transportMode != .transit else {
            say("Postoje pośrednie są dostępne podczas jazdy samochodem, rowerem lub marszu."); return
        }
        let context = VoiceDialogContext(state: navigation.state)
        let results = await actions.findStops(category, nearDestination: nearDestination)
        guard validate(context, token: token) else { return }
        choices = results.prefix(3).map {
            Choice(destination: $0.candidate.destination, detail: actions.describeStop($0), isStop: true)
        }
        choiceContext = context
        guard !choices.isEmpty else {
            if case .unavailable(let message) = navigation.state.nearbyStatus { say(message) }
            else { say("Nie znalazłam odpowiedniego miejsca przy tej trasie.") }
            return
        }
        selectChoice(0)
    }

    func selectChoice(_ index: Int) {
        guard let context = choiceContext, context.matches(navigation.state) else {
            pending = nil; choices = []; choiceContext = nil
            say("Nie ma aktualnej listy do wyboru. Powiedz, dokąd chcesz jechać lub jakiego postoju szukasz.")
            return
        }
        guard choices.indices.contains(index) else {
            pending = nil
            say("Nie ma kolejnej propozycji. Powiedz „wybierz pierwszą” albo „anuluj”.", followUp: true)
            return
        }
        choiceIndex = index
        let choice = choices[index]
        let detail = choice.detail.isEmpty ? choice.destination.name :
            (choice.isStop ? choice.detail : "\(choice.destination.name), \(choice.detail)")
        let alternatives = choices.count > 1 ? " Możesz też powiedzieć „następna”." : ""
        pending = Pending(change: choice.isStop ? .waypoint(choice.destination) : .destination(choice.destination), context: context)
        say("\(detail). \(choice.isStop ? "Dodać postój?" : "Rozpocząć prowadzenie do tego miejsca?")\(alternatives)", followUp: true)
    }

    func proposePreferences(_ command: VoiceCommand, token: Int) async {
        guard navigation.state.route != nil, navigation.state.transportMode == .car else {
            say("Najpierw wyznacz trasę samochodową."); return
        }
        let context = VoiceDialogContext(state: navigation.state)
        var preferences = navigation.state.routingPreferences
        let description: String
        if command == .avoidHighways { preferences.avoidHighways = true; description = "z omijaniem autostrad" }
        else { preferences.avoidTolls = true; description = "z omijaniem płatnych dróg" }
        guard preferences != navigation.state.routingPreferences else { say("Ta opcja jest już włączona."); return }
        let estimate = await navigation.voiceRouteEstimate(preferences: preferences)
        guard validate(context, token: token) else { return }
        guard let estimate else { say("Nie mogę teraz obliczyć nowego wariantu. Trasa pozostaje bez zmian."); return }
        ask(.preferences(preferences), text: "Szacowany czas dalszej podróży \(description): \(VoiceNavigationActions.duration(estimate)). Zastosować zmianę?")
    }

    func proposeRemovingStop(token: Int) async {
        let state = navigation.state
        let next = navigation.nextVoiceWaypoint
        guard let next else { say("Nie ma kolejnego postoju do usunięcia."); return }
        let context = VoiceDialogContext(state: state)
        let estimate = await navigation.voiceRouteEstimate(preferences: state.routingPreferences, removingWaypointID: next.id)
        guard validate(context, token: token) else { return }
        let detail = estimate.map { " Szacowany czas dalszej podróży: \(VoiceNavigationActions.duration($0))." } ?? ""
        ask(.remove(next.id), text: "Usunąć postój \(next.name)?\(detail)")
    }

    func confirm(token: Int) async {
        guard isCurrent(token), !isApplyingChange else { return }
        guard let pending else { say("Nie ma zmiany do potwierdzenia."); return }
        self.pending = nil
        guard pending.context.matches(navigation.state) else {
            choices = []; choiceContext = nil
            say("Podróż się zmieniła lub potwierdzenie wygasło. Powtórz polecenie.")
            return
        }
        choices = []; choiceContext = nil
        isApplyingChange = true
        defer {
            isApplyingChange = false
            VoiceIntentBridge.shared.resumePendingRequest()
        }
        navigation.state.errorMessage = nil
        switch pending.change {
        case .stop:
            navigation.stop()
            say("Nawigacja zakończona.")
        case .start:
            navigation.begin()
            say(navigation.state.status == .navigating ? "Prowadzenie rozpoczęte." : "Przygotowuję nawigację.")
        case .destination(let destination):
            if isNavigating {
                await navigation.replaceVoiceDestination(destination)
            } else {
                navigation.selectDestination(destination)
                await navigation.planRoute()
                guard isCurrent(token) else { return }
                if navigation.state.status == .routePreview { navigation.begin() }
            }
            guard isCurrent(token) else { return }
            reportChange(success: "Prowadzę do \(destination.name).",
                         applied: navigation.state.destination?.id == destination.id && navigation.state.status == .navigating)
        case .waypoint(let destination):
            await navigation.addVoiceWaypoint(destination)
            guard isCurrent(token) else { return }
            reportChange(success: "Dodano postój: \(destination.name).",
                         applied: navigation.state.waypoints.contains { $0.id == destination.id })
        case .remove(let id):
            await navigation.removeVoiceWaypoint(id)
            guard isCurrent(token) else { return }
            reportChange(success: "Usunięto postój.", applied: !navigation.state.waypoints.contains { $0.id == id })
        case .preferences(let preferences):
            await navigation.applyVoicePreferences(preferences)
            guard isCurrent(token) else { return }
            reportChange(success: "Zastosowano zmianę trasy.", applied: navigation.state.routingPreferences == preferences)
        }
    }

    private func reportChange(success: String, applied: Bool) {
        if !applied || navigation.state.errorMessage != nil || navigation.state.status == .error {
            say("Nie udało się ukończyć zmiany trasy. Sprawdź trasę na ekranie przed dalszą jazdą.")
        } else { say(success) }
    }
}
#endif
