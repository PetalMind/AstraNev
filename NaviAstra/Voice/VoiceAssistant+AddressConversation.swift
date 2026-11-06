#if os(iOS)
import Foundation

extension VoiceAssistant {
    var speechContext: [String] {
        let context = destinationDialog.map { [$0.query] } ?? []
        return context + choices.prefix(3).flatMap { [$0.destination.name, $0.detail] }
    }

    func clearDestinationDialog() {
        destinationDialog = nil
        lastSearchQuery = ""
    }

    func discardExpiredDialog() {
        if let recent = recentDestinationDialog, !recent.context.matches(navigation.state) {
            recentDestinationDialog = nil
        }
        if let dialog = destinationDialog, !dialog.context.matches(navigation.state) {
            clearDestinationDialog()
            pending = nil; choices = []; choiceContext = nil
        }
        if let context = choiceContext, !context.matches(navigation.state) {
            pending = nil; choices = []; choiceContext = nil
        }
        if let pending, !pending.context.matches(navigation.state) { self.pending = nil }
    }

    /// Context is consulted only for an actual final user utterance. A short
    /// place/number reply never becomes an action outside an active address draft.
    func handleUtterance(_ text: String, token: Int) async {
        guard isCurrent(token) else { return }
        discardExpiredDialog()
        let command = VoiceCommandParser.parse(text)
        let phrase = QueryClassifier.normalize(text).trimmingCharacters(in: .punctuationCharacters)
        if case .correct = command, destinationDialog == nil,
           let recent = recentDestinationDialog, recent.context.matches(navigation.state) {
            destinationDialog = recent
            lastSearchQuery = recent.query
        }
        if let dialog = destinationDialog {
            if ["sprobuj ponownie", "szukaj ponownie", "sprawdz ponownie"].contains(phrase) {
                await searchDestination(dialog.query, token: token)
                return
            }
            if phrase == "nie" {
                pending = nil; choices = []; choiceContext = nil
                destinationDialog?.awaiting = .correction
                say("Co poprawić w adresie „\(dialog.query)”? Podaj numer domu, miejscowość albo powiedz „popraw adres na” i nowy adres.", followUp: true)
                return
            }
            switch command {
            case .unknown:
                await refineDestination(text, explicitCorrection: false, token: token)
                return
            case .choose where choices.isEmpty:
                // Bare digits can answer an address question; an explicit
                // numbered-list command must still validate a real list.
                if !["wybierz", "propozycja", "wynik"].contains(where: phrase.hasPrefix),
                   VoiceAddressQuery.replacingBuildingNumber(in: dialog.baseQuery, with: text) != nil {
                    await refineDestination(text, explicitCorrection: false, token: token)
                    return
                }
            case .query(let query):
                say(actions.answer(query))
                return
            case .help:
                say("Pamiętam „\(dialog.query)”. Możesz podać miejscowość, powiedzieć „numer domu” i numer albo „popraw adres na” i cały adres.", followUp: true)
                return
            default: break
            }
        }
        await handle(command, token: token)
    }

    func refineDestination(_ text: String, explicitCorrection: Bool, token: Int) async {
        guard isCurrent(token) else { return }
        guard var dialog = destinationDialog, dialog.context.matches(navigation.state) else {
            clearDestinationDialog()
            pending = nil; choices = []; choiceContext = nil
            say("Nie mam aktualnego adresu do poprawienia. Powiedz „prowadź do” i podaj cel.")
            return
        }
        guard dialog.refine(text, explicitCorrection: explicitCorrection) else {
            // An unrecognized reply invalidates the executable confirmation,
            // but keeps the address draft available for a deliberate correction.
            pending = nil
            say("Pamiętam adres „\(dialog.query)”. Podaj miejscowość, powiedz „numer domu” i numer albo „popraw adres na” i nowy adres.")
            return
        }
        destinationDialog = dialog
        await searchDestination(dialog.query, token: token)
    }
}
#endif
