#if os(iOS)
import Foundation

/// Commands describe an intention only. The dialogue owns confirmation and execution.
nonisolated enum VoiceCommand: Equatable {
    case navigate(String)
    case searchStop(NearbyPlaceCategory, nearDestination: Bool)
    case query(VoiceQuery)
    case setMuted(Bool)
    case setVerbosity(VoiceVerbosity)
    case adjustRate(Double)
    case adjustVolume(Double)
    case overview
    case follow
    case start
    case stop
    case removeNextStop
    case avoidHighways
    case avoidTolls
    case alternativeRoute
    case confirm
    case cancel
    /// The index is zero based; the dialogue must check it against its current results.
    case choose(Int)
    case next
    case correct(String)
    case help
    case unknown
}

nonisolated enum VoiceQuery: String {
    case arrival, remaining, maneuver, lanes, roundabout, traffic
    case transitAlighting, transitTransfer, transitLine
}

nonisolated struct VoiceCommandParser {
    private static let locale = Locale(identifier: "pl_PL")
    private static let boundaryPunctuation = CharacterSet(charactersIn: ".,!?;:\"„”")

    /// Only complete utterances belong here. Partial recognition must never execute an action.
    static func parse(_ text: String) -> VoiceCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("„"), !trimmed.hasPrefix("\""), !trimmed.hasPrefix("“") else { return .unknown }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .unknown }
        var raw = words.joined(separator: " ")
            .trimmingCharacters(in: boundaryPunctuation)
        var phrase = normalize(raw)

        // The name is an optional address inside a completed utterance, not a
        // wake word. Remove only the first whole word, keeping all qualifiers.
        if phrase.hasPrefix("astra ") || phrase.hasPrefix("astra, ") {
            raw = raw.split(separator: " ", maxSplits: 1).dropFirst().joined(separator: " ")
            guard !raw.hasPrefix("„"), !raw.hasPrefix("\""), !raw.hasPrefix("“") else { return .unknown }
            phrase = normalize(raw)
        }

        // A single polite wrapper is accepted, without discarding a negation or other intent.
        if phrase.hasPrefix("prosze ") || phrase.hasPrefix("prosze, ") {
            raw = raw.split(separator: " ", maxSplits: 1).dropFirst().joined(separator: " ")
            guard !raw.hasPrefix("„"), !raw.hasPrefix("\""), !raw.hasPrefix("“") else { return .unknown }
            phrase = normalize(raw)
        }
        if phrase.hasSuffix(" prosze") {
            raw = raw.split(separator: " ").dropLast().joined(separator: " ")
                .trimmingCharacters(in: boundaryPunctuation)
            phrase = normalize(raw)
        }

        if let command = exactCommands[phrase] { return command }
        if let query = informationalQuery(in: phrase) { return query }
        if let choice = choiceIndex(in: phrase) { return .choose(choice) }

        // Corrections intentionally precede navigation: the pending dialogue determines their role.
        if let corrected = argument(in: raw, normalized: phrase, prefixes: [
            "nie, chodzi mi o", "nie, chodzilo mi o",
            "nie, chodzi o", "nie, chodzilo o",
            "chodzi mi o", "chodzilo mi o", "chodzi o", "chodzilo o",
            "popraw adres na", "popraw cel na"
        ]) {
            return .correct(VoiceAddressQuery.normalized(corrected))
        }
        if let correctedNumber = argument(in: raw, normalized: phrase, prefixes: [
            "popraw numer budynku na", "zmien numer budynku na", "popraw numer na", "zmien numer na"
        ]) {
            return .correct(VoiceAddressQuery.normalized("numer " + correctedNumber))
        }
        if let corrected = argument(in: raw, normalized: phrase, prefixes: ["nie,"]),
           normalize(corrected).hasPrefix("numer ") || normalize(corrected).hasPrefix("litera ") {
            return .correct(VoiceAddressQuery.normalized(corrected))
        }
        // "Numer 2" keeps its established list-selection meaning above. A
        // qualified building number or a letter is instead a contextual edit.
        if ["numer budynku ", "numer domu ", "numer ", "litera ", "litere "].contains(where: phrase.hasPrefix) {
            return .correct(VoiceAddressQuery.normalized(raw))
        }

        if let stop = stopSearch(in: phrase) { return stop }

        if let destination = argument(in: raw, normalized: phrase, prefixes: [
            "czy mozesz mnie poprowadzic do", "czy mozesz poprowadzic mnie do",
            "mozesz mnie poprowadzic do", "chcialbym jechac do", "chcialabym jechac do",
            "chce jechac do", "chce dojechac do", "chce dotrzec do",
            "wyznacz trase do", "wyznacz droge do", "rozpocznij nawigacje do",
            "rozpocznij prowadzenie do", "zmien cel na", "prowadz mnie do",
            "poprowadz mnie do", "nawiguj do", "prowadz do", "poprowadz do",
            "nawiguj pod adres", "prowadz pod adres", "jedz pod adres",
            "jedz do", "zabierz mnie do"
        ]) {
            return .navigate(VoiceAddressQuery.normalized(destination))
        }
        return .unknown
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
            .replacingOccurrences(of: "ł", with: "l")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(boundaryPunctuation))
    }

    /// Natural question introductions apply only to information requests. They
    /// must not turn quoted commands, confirmations or negations into actions.
    private static func informationalQuery(in phrase: String) -> VoiceCommand? {
        let prefixes = ["czy mozesz mi powiedziec", "czy mozesz powiedziec",
                        "mozesz mi powiedziec", "mozesz powiedziec",
                        "powiedz mi prosze", "powiedz mi", "powiedz"]
        for prefix in prefixes {
            guard phrase.hasPrefix(prefix + " ") || phrase.hasPrefix(prefix + ", ") else { continue }
            let question = String(phrase.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(boundaryPunctuation))
            guard let command = exactCommands[question] else { continue }
            switch command {
            case .query(_), .help: return command
            default: continue
            }
        }
        return nil
    }

    /// Prefix matching uses normalized text; payload extraction uses the original word sequence.
    private static func argument(in raw: String, normalized: String, prefixes: [String]) -> String? {
        for prefix in prefixes where normalized.hasPrefix(prefix + " ") {
            let wordCount = prefix.split(separator: " ").count
            let value = raw.split(separator: " ").dropFirst(wordCount).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(boundaryPunctuation))
            guard !value.isEmpty else { return nil }
            return value
        }
        return nil
    }

    private static func choiceIndex(in phrase: String) -> Int? {
        let prefixes = ["wybierz propozycje numer ", "wybierz wynik numer ", "wybierz numer ",
                        "wybierz ", "propozycja numer ", "wynik numer ", "numer "]
        let value: String
        if let prefix = prefixes.first(where: phrase.hasPrefix) {
            value = String(phrase.dropFirst(prefix.count))
        } else {
            value = phrase
        }
        let ordinals: [[String]] = [
            ["pierwsza", "pierwszy", "pierwsze", "jeden", "pierwsza propozycje", "pierwszy wynik"],
            ["druga", "drugi", "drugie", "dwa", "druga propozycje", "drugi wynik"],
            ["trzecia", "trzeci", "trzecie", "trzy", "trzecia propozycje", "trzeci wynik"],
            ["czwarta", "czwarty", "cztery", "czwarta propozycje", "czwarty wynik"],
            ["piata", "piaty", "piec", "piata propozycje", "piaty wynik"]
        ]
        if let index = ordinals.firstIndex(where: { $0.contains(value) }) { return index }
        // Deliberately bounded before subtracting, including when recognition returns digits.
        if value.allSatisfy(\.isNumber), let number = Int(value), (1...99).contains(number) {
            return number - 1
        }
        return nil
    }

    private static func stopSearch(in phrase: String) -> VoiceCommand? {
        var request = phrase
        let nearDestinationSuffixes = [" w poblizu miejsca docelowego", " przy miejscu docelowym",
                                       " w poblizu celu", " przy celu", " blisko celu"]
        let routeSuffixes = [" po trasie", " po drodze", " w poblizu", " blisko mnie"]
        var nearDestination = false
        if let suffix = nearDestinationSuffixes.first(where: request.hasSuffix) {
            request = String(request.dropLast(suffix.count))
            nearDestination = true
        } else if let suffix = routeSuffixes.first(where: request.hasSuffix) {
            request = String(request.dropLast(suffix.count))
        }
        // Match complete requests so a negation, compound command or unsupported
        // requirement (brand, price, coffee, opening hours) is never discarded.
        let naturalRequests: [(NearbyPlaceCategory, [String])] = [
            (.parking, ["gdzie zaparkowac", "gdzie moge zaparkowac", "chce zaparkowac", "potrzebuje zaparkowac"]),
            (.fuel, ["gdzie zatankowac", "gdzie moge zatankowac", "chce zatankowac", "potrzebuje zatankowac"]),
            (.charging, ["gdzie naladowac samochod", "gdzie moge naladowac samochod",
                         "chce naladowac samochod", "potrzebuje naladowac samochod"])
        ]
        if let match = naturalRequests.first(where: { $0.1.contains(request) }) {
            return .searchStop(match.0, nearDestination: nearDestination)
        }
        let prefixes = ["znajdz mi ", "wyszukaj mi ", "dodaj postoj na ", "dodaj postoj przy ",
                        "znajdz ", "wyszukaj ", "dodaj ", "potrzebuje "]
        guard let prefix = prefixes.first(where: request.hasPrefix) else { return nil }
        let category = String(request.dropFirst(prefix.count))
        let categories: [(NearbyPlaceCategory, [String])] = [
            (.fuel, ["stacje paliw", "stacja paliw", "stacji paliw", "paliwo", "paliwa",
                     "stacje benzynowa", "stacji benzynowej", "benzyne", "benzyny"]),
            (.food, ["restauracje", "restauracja", "restauracji", "jedzenie"]),
            (.parking, ["parking", "parkingi", "parkingu", "miejsce parkingowe", "miejsca parkingowego",
                        "miejsce do zaparkowania", "miejsca do zaparkowania", "miejsce na postoj", "postoj"]),
            (.charging, ["ladowarke", "ladowarki", "ladowarke ev", "stacje ladowania", "stacji ladowania"]),
            (.restArea, ["mop", "miejsce odpoczynku", "miejsce obslugi podroznych"]),
            (.parcels, ["paczkomat", "paczkomaty", "paczkomatu", "punkt odbioru", "punkt odbioru paczek"])
        ]
        guard let match = categories.first(where: { $0.1.contains(category) }) else { return nil }
        return .searchStop(match.0, nearDestination: nearDestination)
    }

    private static let exactCommands: [String: VoiceCommand] = {
        let groups: [(VoiceCommand, [String])] = [
            (.query(.arrival), ["kiedy dojade", "kiedy dojedziemy", "kiedy dojade do celu", "o ktorej dojade", "o ktorej godzinie dojade", "o ktorej bede na miejscu", "kiedy bedziemy na miejscu"]),
            (.query(.remaining), ["ile zostalo", "ile jeszcze", "ile kilometrow zostalo", "ile czasu zostalo", "ile czasu zostalo do celu", "ile zostalo mi do celu", "jak daleko do celu", "za ile bede na miejscu"]),
            (.query(.maneuver), ["powtorz", "powtorz manewr", "powtorz wskazowke", "powtorz komunikat", "co dalej", "jaki jest nastepny manewr", "co mam zrobic na nastepnym skrzyzowaniu"]),
            (.query(.lanes), ["ktory pas", "jaki pas", "ktorym pasem jechac", "ktorym pasem mam jechac", "ktory pas wybrac", "na ktorym pasie jechac"]),
            (.query(.roundabout), ["ktory zjazd", "ktory zjazd z ronda", "ktorym zjazdem zjechac", "ktorym zjazdem mam zjechac"]),
            (.query(.traffic), ["czy sa korki", "czy na trasie sa korki", "czy sa korki na trasie", "jakie sa utrudnienia", "co z ruchem", "jaki jest ruch na trasie"]),
            (.query(.transitAlighting), ["za ile wysiadam", "kiedy wysiadam", "gdzie wysiadam", "ile przystankow zostalo"]),
            (.query(.transitTransfer), ["gdzie mam przesiadke", "gdzie sie przesiadam", "kiedy mam przesiadke", "jaka jest nastepna przesiadka"]),
            (.query(.transitLine), ["jaka jest nastepna linia", "jaka linia dalej", "w jaka linie mam wsiasc", "ktora linia dalej"]),
            (.setMuted(true), ["wycisz komunikaty", "wycisz glos", "wylacz komunikaty", "wylacz glos"]),
            (.setMuted(false), ["wlacz komunikaty", "wlacz glos", "przywroc komunikaty", "przywroc glos"]),
            (.setVerbosity(.concise), ["mow mniej", "mniej komunikatow", "krotsze komunikaty"]),
            (.setVerbosity(.standard), ["standardowe komunikaty", "mow standardowo", "normalne komunikaty"]),
            (.setVerbosity(.detailed), ["mow wiecej", "wiecej komunikatow", "szczegolowe komunikaty"]),
            (.adjustRate(-0.04), ["mow wolniej", "wolniej mow", "wolniejsze komunikaty"]),
            (.adjustRate(0.04), ["mow szybciej", "szybciej mow", "szybsze komunikaty"]),
            (.adjustVolume(0.15), ["glosniej", "mow glosniej", "zwieksz glosnosc", "glosniejsze komunikaty"]),
            (.adjustVolume(-0.15), ["ciszej", "mow ciszej", "zmniejsz glosnosc", "cichsze komunikaty"]),
            (.overview, ["pokaz cala trase", "pokaz trase", "pokaz przeglad trasy"]),
            (.follow, ["wroc do prowadzenia", "pokaz moja pozycje", "sledz moja pozycje", "wroc do mojej pozycji"]),
            (.start, ["rozpocznij nawigacje", "rozpocznij prowadzenie", "uruchom nawigacje", "zacznij nawigacje"]),
            (.stop, ["zakoncz nawigacje", "zakoncz prowadzenie", "zatrzymaj nawigacje", "wylacz nawigacje"]),
            (.removeNextStop, ["usun nastepny postoj", "usun kolejny postoj", "pomin nastepny postoj", "pomin kolejny postoj"]),
            (.avoidHighways, ["omin autostrady", "omijaj autostrady", "unikaj autostrad", "wybierz trase bez autostrad", "trasa bez autostrad"]),
            (.avoidTolls, ["omin oplaty", "omijaj oplaty", "unikaj oplat", "omijaj drogi platne", "unikaj drog platnych", "wybierz trase bez oplat", "trasa bez oplat"]),
            (.alternativeRoute, ["inna trasa", "trasa alternatywna", "znajdz inna trase", "znajdz trase alternatywna", "objazd"]),
            (.confirm, ["tak", "tak prosze", "potwierdzam", "potwierdz", "zatwierdz", "zgadzam sie"]),
            (.cancel, ["nie", "anuluj", "anuluj polecenie", "anuluj zmiane", "nie zmieniaj", "rezygnuje"]),
            (.next, ["nastepna", "nastepny", "kolejna", "kolejny", "a nastepna", "a nastepny", "pokaz nastepna", "pokaz nastepny", "inna propozycja"]),
            (.help, ["pomoc", "co moge powiedziec", "jakie sa polecenia", "pomoc glosowa"])
        ]
        var result: [String: VoiceCommand] = [:]
        for (command, phrases) in groups {
            for phrase in phrases { result[phrase] = command }
        }
        return result
    }()
}
#endif
