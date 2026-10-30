#if os(iOS)
import Testing
@testable import NaviAstra

struct VoiceCommandCriticalTests {
    @Test func routeChangesRequireCompleteUnambiguousCommands() {
        let valid: [(String, VoiceCommand)] = [
            ("Zakończ nawigację!", .stop),
            ("Proszę, usuń następny postój.", .removeNextStop),
            ("Omijaj autostrady", .avoidHighways),
            ("Wybierz trasę bez opłat", .avoidTolls),
            ("Rozpocznij nawigację", .start)
        ]
        for (utterance, expected) in valid {
            #expect(VoiceCommandParser.parse(utterance) == expected)
        }
        for utterance in ["stop", "koniec", "start", "usuń", "zakończ", "postój",
                          "nie zakończ nawigacji", "nie, zakończ nawigację",
                          "nie usuwaj następnego postoju", "nie chodzi o Kraków", "czy możesz zakończyć nawigację",
                          "zakończ nawigację i prowadź do domu", "tak, ale bez autostrad",
                          "hotel zakończ nawigację", "omijaj autostrady tylko jutro"] {
            #expect(VoiceCommandParser.parse(utterance) == .unknown)
        }
    }

    @Test func destinationAndCorrectionRetainPolishNamesAndAddressPunctuation() {
        #expect(VoiceCommandParser.parse("Prowadź do Łodzi, ul. Piotrkowska 10") ==
                .navigate("Łodzi, ul. Piotrkowska 10"))
        #expect(VoiceCommandParser.parse("  PROWADŹ   do\nGdańska, ul. Długa 12  ") ==
                .navigate("Gdańska, ul. Długa 12"))
        #expect(VoiceCommandParser.parse("Nie, chodziło o Kraków, Wawel") ==
                .correct("Kraków, Wawel"))
        #expect(VoiceCommandParser.parse("Zmień cel na Hotel Stop") == .navigate("Hotel Stop"))
        #expect(VoiceCommandParser.parse("Prowadź do domu, proszę") == .navigate("domu"))
        for utterance in ["Prowadź do", "Nie, chodzi o", "Zmień cel na", "", "?!"] {
            #expect(VoiceCommandParser.parse(utterance) == .unknown)
        }
    }

    @Test func dialogueSelectionAndCancellationCannotBeConfusedWithDestructiveActions() {
        #expect(VoiceCommandParser.parse("Nie") == .cancel)
        #expect(VoiceCommandParser.parse("Anuluj") == .cancel)
        #expect(VoiceCommandParser.parse("Tak") == .confirm)
        #expect(VoiceCommandParser.parse("Wybierz pierwszą") == .choose(0))
        #expect(VoiceCommandParser.parse("Drugą") == .choose(1))
        #expect(VoiceCommandParser.parse("Wybierz trzecią propozycję") == .choose(2))
        #expect(VoiceCommandParser.parse("Wybierz numer 3") == .choose(2))
        #expect(VoiceCommandParser.parse("A następna?") == .next)
        for utterance in ["0", "-1", "100", "999999999999999999999999999999999",
                          "wybierz pierwszą i zakończ nawigację", "nie wybieraj drugiej",
                          "powiedz mi tak", "czy możesz powiedzieć tak", "powiedz mi, nie"] {
            #expect(VoiceCommandParser.parse(utterance) == .unknown)
        }
    }

    @Test func stopSearchKeepsDestinationScopeAndRejectsUnsupportedFilters() {
        #expect(VoiceCommandParser.parse("Znajdź stację paliw po trasie") ==
                .searchStop(.fuel, nearDestination: false))
        #expect(VoiceCommandParser.parse("Znajdź parking przy celu") ==
                .searchStop(.parking, nearDestination: true))
        #expect(VoiceCommandParser.parse("Dodaj ładowarkę") ==
                .searchStop(.charging, nearDestination: false))
        #expect(VoiceCommandParser.parse("Znajdź miejsce odpoczynku po drodze") ==
                .searchStop(.restArea, nearDestination: false))
        // A known category must not silently discard a requested brand, price or opening state.
        for utterance in ["znajdź tani parking przy celu", "znajdź stację paliw Orlen po trasie",
                          "znajdź otwartą restaurację", "znajdź kawiarnię", "dodaj ładowarkę i usuń następny postój",
                          "stację paliw", "stację paliw po trasie", "parking przy celu"] {
            #expect(VoiceCommandParser.parse(utterance) == .unknown)
        }
    }

    @Test func drivingQuestionsAndAudioChangesHaveStableMeaning() {
        let examples: [(String, VoiceCommand)] = [
            ("Kiedy dojadę?", .query(.arrival)),
            ("Ile kilometrów zostało?", .query(.remaining)),
            ("Powtórz", .query(.maneuver)),
            ("Który pas?", .query(.lanes)),
            ("Który zjazd z ronda?", .query(.roundabout)),
            ("Czy są korki?", .query(.traffic)),
            ("Za ile wysiadam?", .query(.transitAlighting)),
            ("Gdzie mam przesiadkę?", .query(.transitTransfer)),
            ("Jaka jest następna linia?", .query(.transitLine)),
            ("Wycisz komunikaty", .setMuted(true)),
            ("Włącz głos", .setMuted(false)),
            ("Mów mniej", .setVerbosity(.concise)),
            ("Mów wolniej", .adjustRate(-0.04))
        ]
        for (utterance, expected) in examples {
            #expect(VoiceCommandParser.parse(utterance) == expected)
        }
    }

    @Test func naturalQuestionIntroductionsCannotAuthorizeRouteChanges() {
        let questions: [(String, VoiceCommand)] = [
            ("Powiedz mi, o której godzinie dojadę?", .query(.arrival)),
            ("Czy możesz mi powiedzieć, ile czasu zostało do celu?", .query(.remaining)),
            ("Powiedz mi proszę, którym pasem mam jechać?", .query(.lanes)),
            ("Możesz powiedzieć, czy są korki na trasie?", .query(.traffic))
        ]
        for (utterance, expected) in questions {
            #expect(VoiceCommandParser.parse(utterance) == expected)
        }
        for utterance in ["powiedz mi, zakończ nawigację", "czy możesz powiedzieć usuń następny postój",
                          "powiedz mi, znajdź stację paliw po trasie", "powiedz mi, nie zakończ nawigacji",
                          "powiedz mi, tak, ale bez autostrad", "powiedz mi, kiedy dojadę i zakończ nawigację",
                          "nie powiedz mi kiedy dojadę"] {
            #expect(VoiceCommandParser.parse(utterance) == .unknown)
        }
    }
}
#endif
