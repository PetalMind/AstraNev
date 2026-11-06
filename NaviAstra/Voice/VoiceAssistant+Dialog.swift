#if os(iOS)
import Foundation

extension VoiceAssistant {
    func searchDestination(_ query: String, token: Int, startsResolvedPlaceImmediately: Bool = false) async {
        pending = nil
        choices = []
        choiceContext = nil
        let context = VoiceDialogContext(state: navigation.state)
        let query = VoiceAddressQuery.normalized(query)
        if destinationDialog?.query != query {
            destinationDialog = VoiceDestinationDialog(baseQuery: query, context: context)
        }
        destinationDialog?.context = context
        destinationDialog?.awaiting = .selection
        lastSearchQuery = query
        let saved = actions.savedDestinations(named: query)
        if saved.count == 1, let destination = saved.first, startsResolvedPlaceImmediately {
            await applyChange(.destination(destination), context: context, token: token)
            return
        } else if !saved.isEmpty {
            // Repeated saved labels stay local and still require an explicit choice.
            choices = saved.prefix(3).map { Choice(destination: $0, detail: $0.address ?? "", isStop: false) }
        } else {
            let normalized = QueryClassifier.normalize(query)
            if ["dom", "domu", "do domu", "praca", "pracy", "do pracy"].contains(normalized) {
                clearDestinationDialog()
                say("Najpierw zapisz jednoznaczny adres domu lub pracy w zapisanych miejscach.")
                return
            }
            do {
                let resolution = try await actions.resolveDestination(query)
                guard validate(context, token: token) else { return }
                switch resolution {
                case .direct(let result):
                    if startsResolvedPlaceImmediately {
                        await applyChange(.destination(result.navigationDestination), context: context, token: token)
                        return
                    }
                    choices = [Choice(destination: result.navigationDestination, detail: result.subtitle, isStop: false)]
                case .choices(let results):
                    choices = results.prefix(3).map {
                        Choice(destination: $0.navigationDestination, detail: $0.subtitle, isStop: false)
                    }
                case .needsAddressDetails(let message):
                    destinationDialog?.awaiting = .locality
                    say(message, followUp: true)
                    return
                case .unavailable(let message):
                    // Contacts and GPS failures are not invitations to publish
                    // a person's name as a public address search.
                    clearDestinationDialog()
                    say(message)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(token) else { return }
                destinationDialog?.awaiting = .correction
                say("Nie mogę teraz sprawdzić adresu „\(query)”. Zachowałam go. Sprawdź połączenie, potem powiedz „spróbuj ponownie” albo popraw adres.")
                return
            }
        }
        guard isCurrent(token) else { return }
        choiceContext = context
        guard !choices.isEmpty else {
            destinationDialog?.awaiting = .locality
            say("Nie znalazłam „\(query)”. W jakiej miejscowości lub gminie mam szukać?", followUp: true)
            return
        }
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
        guard let (choice, context) = currentChoice(at: index) else { return }
        let detail = choice.detail.isEmpty ? choice.destination.name :
            (choice.isStop ? choice.detail : "\(choice.destination.name), \(choice.detail)")
        let alternatives = choices.count > 1 ? " Możesz też powiedzieć „następna”." : ""
        pending = Pending(change: choice.isStop ? .waypoint(choice.destination) : .destination(choice.destination), context: context)
        if choice.isStop {
            say("\(detail). Dodać postój?\(alternatives)", followUp: true)
        } else {
            say("Propozycja \(index + 1): \(detail). Powiedz „wybierz numer \(index + 1)”, aby rozpocząć prowadzenie.\(alternatives)", followUp: true)
        }
    }

    /// Naming an address from the current list is the user's final choice.
    /// Merely browsing with "następna" continues to use selectChoice instead.
    func chooseDestination(_ index: Int, token: Int) async {
        guard isCurrent(token), !isApplyingChange,
              let (choice, context) = currentChoice(at: index) else { return }
        guard !choice.isStop else {
            selectChoice(index)
            return
        }
        await applyChange(.destination(choice.destination), context: context, token: token)
    }

    private func currentChoice(at index: Int) -> (Choice, VoiceDialogContext)? {
        guard let context = choiceContext, context.matches(navigation.state) else {
            pending = nil; choices = []; choiceContext = nil
            discardExpiredDialog()
            say("Nie ma aktualnej listy do wyboru. Powiedz, dokąd chcesz jechać lub jakiego postoju szukasz.")
            return nil
        }
        guard choices.indices.contains(index) else {
            pending = nil
            say("Nie ma kolejnej propozycji. Powiedz „wybierz pierwszą” albo „anuluj”.", followUp: true)
            return nil
        }
        choiceIndex = index
        return (choices[index], context)
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

    func proposeAlternativeRoute(token: Int) async {
        guard isCurrent(token) else { return }
        let state = navigation.state
        guard let current = state.route else {
            say("Najpierw wybierz cel i wyznacz trasę.")
            return
        }
        if state.status == .navigating {
            let context = VoiceDialogContext(state: state)
            do {
                let proposal = try await navigation.voiceAlternativeRoute()
                guard validate(context, token: token) else { return }
                let chargingDetails = proposal.additionalChargingStops.isEmpty ? ""
                    : " Potrzebne są też dodatkowe postoje ładowania: \(proposal.additionalChargingStops.map(\.name).joined(separator: ", "))."
                ask(.activeAlternativeRoute(proposal),
                    text: "Znalazłam inną trasę do tego samego celu, z zachowaniem pozostałych postojów. Szacowany czas dalszej podróży: \(VoiceNavigationActions.duration(proposal.route.expectedTravelTime)).\(chargingDetails) Zmienić trasę?")
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(token) else { return }
                say((error as? VoiceAlternativeRouteError)?.errorDescription
                    ?? "Nie mogę teraz sprawdzić innej trasy. Bieżące prowadzenie pozostaje bez zmian.")
            }
            return
        }
        guard state.status == .routePreview else {
            say("Poczekaj na zakończenie przeliczania, aby wybrać inny wariant trasy.")
            return
        }
        let options = state.routeOptions
        guard let currentIndex = options.firstIndex(where: { $0.id == current.id }) else {
            say("Nie ma teraz innego gotowego wariantu trasy.")
            return
        }
        let ordered = options.dropFirst(currentIndex + 1) + options.prefix(currentIndex)
        guard let alternative = ordered.first(where: {
            $0.id != current.id && $0.coordinates.count >= 2 &&
            $0.previewTravelTime.isFinite && $0.previewTravelTime >= 0
        }) else {
            say("Nie ma teraz innego gotowego wariantu trasy.")
            return
        }
        ask(.alternativeRoute(alternative.id),
            text: "Inny wariant: szacowany czas podróży \(VoiceNavigationActions.duration(alternative.previewTravelTime)). Wybrać tę trasę?")
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
        await applyChange(pending.change, context: pending.context, token: token)
    }

    /// Both an explicit confirmation and an unambiguous destination command use
    /// the same route mutation and stale-context protection.
    func applyChange(_ change: Change, context: VoiceDialogContext, token: Int) async {
        guard isCurrent(token), !isApplyingChange else { return }
        guard context.matches(navigation.state) else {
            pending = nil
            choices = []; choiceContext = nil
            clearDestinationDialog()
            say("Podróż się zmieniła lub potwierdzenie wygasło. Podaj cel dla aktualnej podróży.")
            return
        }
        pending = nil
        choices = []; choiceContext = nil
        let addressDraft = destinationDialog
        clearDestinationDialog()
        isApplyingChange = true
        defer {
            finishApplyingChange(token: token)
            VoiceIntentBridge.shared.resumePendingRequest()
        }
        navigation.state.errorMessage = nil
        switch change {
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
                navigation.setJourneyTimeMode(.now)
                await navigation.planRoute()
                guard isCurrent(token) else { return }
                if navigation.state.destination?.id == destination.id,
                   navigation.state.status == .routePreview { navigation.begin() }
            }
            guard isCurrent(token) else { return }
            let description = [destination.name, destination.address?.trimmingCharacters(in: .whitespacesAndNewlines)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            let applied = navigation.state.destination?.id == destination.id && navigation.state.status == .navigating
            if var draft = addressDraft, navigation.state.destination?.id == destination.id {
                draft.context = VoiceDialogContext(state: navigation.state)
                draft.awaiting = .correction
                recentDestinationDialog = draft
                if !applied {
                    destinationDialog = draft
                    lastSearchQuery = draft.query
                }
            }
            reportChange(success: "Prowadzę do \(description).", applied: applied)
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
        case .alternativeRoute(let id):
            // The offered option can disappear while the confirmation is read,
            // without changing the currently selected route or dialog context.
            guard navigation.state.status == .routePreview,
                  let route = navigation.state.routeOptions.first(where: { $0.id == id }),
                  route.id != navigation.state.route?.id,
                  route.coordinates.count >= 2,
                  route.previewTravelTime.isFinite, route.previewTravelTime >= 0 else {
                say("Ten wariant trasy nie jest już dostępny. Poproś ponownie o inną trasę.")
                return
            }
            navigation.select(route)
            reportChange(success: "Wybrano inny wariant trasy.", applied: navigation.state.route?.id == id)
        case .activeAlternativeRoute(let proposal):
            do {
                try await navigation.applyVoiceAlternativeRoute(proposal)
                guard isCurrent(token) else { return }
                reportChange(success: "Prowadzę inną trasą. Cel i zaplanowane postoje zostały zachowane.",
                    applied: navigation.state.route?.id == proposal.route.id && navigation.state.status == .navigating)
            } catch {
                guard isCurrent(token) else { return }
                say((error as? VoiceAlternativeRouteError)?.errorDescription
                    ?? "Nie udało się zastosować innej trasy. Bieżące prowadzenie pozostaje bez zmian.")
            }
        }
    }

    private func reportChange(success: String, applied: Bool) {
        if !applied || navigation.state.errorMessage != nil || navigation.state.status == .error {
            say("Nie udało się ukończyć zmiany trasy. Sprawdź trasę na ekranie przed dalszą jazdą.")
        } else { say(success) }
    }
}
#endif
