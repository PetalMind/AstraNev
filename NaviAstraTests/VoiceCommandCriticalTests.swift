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
            ("Rozpocznij nawigację", .start),
            ("Astra, proszę, omijaj autostrady.", .avoidHighways),
            ("Omiń autostrady", .avoidHighways),
            ("Omiń opłaty", .avoidTolls),
            ("Inna trasa", .alternativeRoute),
            ("Trasa alternatywna", .alternativeRoute),
            ("Astra, znajdź inną trasę", .alternativeRoute),
            ("Objazd", .alternativeRoute)
        ]
        for (utterance, expected) in valid {
            #expect(VoiceCommandParser.parse(utterance) == expected)
        }
        for utterance in ["stop", "koniec", "start", "usuń", "zakończ", "postój",
                          "nie zakończ nawigacji", "nie, zakończ nawigację",
                          "nie usuwaj następnego postoju", "nie chodzi o Kraków", "czy możesz zakończyć nawigację",
                          "zakończ nawigację i prowadź do domu", "tak, ale bez autostrad",
                          "hotel zakończ nawigację", "omijaj autostrady tylko jutro",
                          "Astra, nie zakończ nawigacji", "Astralny zakończ nawigację",
                          "Astra, „Zakończ nawigację”", "Astra, \"Zakończ nawigację\"",
                          "Astra, proszę, „Zakończ nawigację”", "Astra, zakończ nawigację i prowadź do domu",
                          "Nie szukaj innej trasy", "Inna trasa tylko jutro", "Objazd i zakończ nawigację",
                          "Powiedz mi, znajdź inną trasę"] {
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
        #expect(VoiceCommandParser.parse("Prowadź do dom") == .navigate("dom"))
        #expect(VoiceCommandParser.parse("Nie prowadź do domu") == .unknown)
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
        #expect(VoiceCommandParser.parse("Wybierz drugi") == .choose(1))
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
        for utterance in ["Gdzie mogę zaparkować?", "Gdzie zaparkować po drodze?",
                          "Znajdź mi miejsce parkingowe", "Potrzebuję miejsca parkingowego",
                          "Chcę zaparkować", "Astra, znajdź postój", "Astra znajdź mi parking."] {
            #expect(VoiceCommandParser.parse(utterance) == .searchStop(.parking, nearDestination: false))
        }
        #expect(VoiceCommandParser.parse("Astra, gdzie mogę zaparkować przy celu?") ==
                .searchStop(.parking, nearDestination: true))
        for utterance in ["Gdzie mogę zatankować?", "Chcę zatankować po drodze", "Potrzebuję benzyny",
                          "Znajdź mi stację benzynową"] {
            #expect(VoiceCommandParser.parse(utterance) == .searchStop(.fuel, nearDestination: false))
        }
        #expect(VoiceCommandParser.parse("Gdzie mogę naładować samochód w pobliżu celu?") ==
                .searchStop(.charging, nearDestination: true))
        // A known category must not silently discard a requested brand, price or opening state.
        for utterance in ["znajdź tani parking przy celu", "znajdź stację paliw Orlen po trasie",
                          "znajdź otwartą restaurację", "znajdź kawiarnię", "dodaj ładowarkę i usuń następny postój",
                          "stację paliw", "stację paliw po trasie", "parking przy celu",
                          "Nie chcę zaparkować", "Astra, nie znajdź parkingu", "Gdzie mogę tanio zaparkować",
                          "Gdzie mogę zaparkować i napić się kawy", "Gdzie mogę zatankować na Orlenie",
                          "Znajdź miejsce parkingowe tylko jutro", "Astra, parking przy celu",
                          "Astra, gdzie mogę zaparkować, ale nie przy celu"] {
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
            ("Mów wolniej", .adjustRate(-0.04)),
            ("Astra, głośniej.", .adjustVolume(0.15)),
            ("Astra, ciszej.", .adjustVolume(-0.15)),
            ("Zwiększ głośność", .adjustVolume(0.15)),
            ("Mów ciszej", .adjustVolume(-0.15))
        ]
        for (utterance, expected) in examples {
            #expect(VoiceCommandParser.parse(utterance) == expected)
        }
        for utterance in ["Nie mów głośniej", "Astra, ciszej i zakończ nawigację",
                          "Powiedz mi, głośniej", "Głośniej o połowę"] {
            #expect(VoiceCommandParser.parse(utterance) == .unknown)
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

    @Test func spokenBuildingSuffixPreservesWholeDestination() {
        let examples: [(String, String)] = [
            ("Nawiguj do Nowa Wieś 24 B", "Nowa Wieś 24B"),
            ("Chcę jechać do Nowa Wieś, numer dwadzieścia cztery litera be", "Nowa Wieś, 24B"),
            ("Czy możesz mnie poprowadzić do Łódź, Dębowa czternaście a", "Łódź, Dębowa 14A"),
            ("Prowadź pod adres Łódź, ul. 11 Listopada numer 14 A", "Łódź, ul. 11 Listopada 14A"),
            ("Prowadź do Dębowa 14 w Warszawie", "Dębowa 14 w Warszawie"),
            ("Prowadź do Dębowa 14 A w Warszawie", "Dębowa 14A w Warszawie"),
            ("Prowadź do Dębowa 14 A Warszawa", "Dębowa 14A Warszawa"),
            ("Prowadź do Warszawa, ul. 3 Maja 12, 00-001", "Warszawa, ul. 3 Maja 12, 00-001"),
            ("Prowadź do Hotel Trzy", "Hotel Trzy"),
            ("Prowadź do Trzy Korony", "Trzy Korony")
        ]
        for (utterance, expected) in examples {
            #expect(VoiceCommandParser.parse(utterance) == .navigate(expected))
        }
        #expect(VoiceAddressQuery.normalized("ulica Siedem Dębów 14 A") == "ulica Siedem Dębów 14A")
        for utterance in ["Nie chcę jechać do Warszawy", "Czy możesz nie prowadzić do domu",
                          "Powiedz „prowadź do domu”", "„Prowadź do domu”"] {
            #expect(VoiceCommandParser.parse(utterance) == .unknown)
        }
    }

    @Test func buildingCorrectionDoesNotReplaceStreetDateOrLocality() {
        let query = "Warszawa, ul. 11 Listopada 14A, 00-001"
        #expect(VoiceAddressQuery.replacingBuildingNumber(in: query, with: "numer szesnaście litera B")
                == "Warszawa, ul. 11 Listopada 16B, 00-001")
        #expect(VoiceAddressQuery.replacingBuildingNumber(in: query, with: "litera C")
                == "Warszawa, ul. 11 Listopada 14C, 00-001")
        #expect(VoiceAddressQuery.replacingBuildingNumber(in: "Nowa Wieś", with: "24 B") == "Nowa Wieś 24B")
        #expect(VoiceAddressQuery.replacingBuildingNumber(in: "ul. 3 Maja, Łódź", with: "numer 16")
                == "ul. 3 Maja, Łódź 16")
        #expect(VoiceAddressQuery.replacingBuildingNumber(in: "Dębowa 12, Leśna 14", with: "16") == nil)
        #expect(VoiceAddressQuery.replacingBuildingNumber(in: query, with: "nie 14 tylko 16") == nil)
        #expect(VoiceAddressQuery.replacingBuildingNumber(in: query, with: "Warszawa") == nil)
        #expect(VoiceCommandParser.parse("Nie, numer 16 B") == .correct("16B"))
        #expect(VoiceCommandParser.parse("Popraw numer budynku na szesnaście litera B") == .correct("16B"))
        #expect(VoiceCommandParser.parse("Chodzi mi o Dębowa 16 B, Warszawa") == .correct("Dębowa 16B, Warszawa"))
        #expect(VoiceCommandParser.parse("Numer 2") == .choose(1))
        #expect(VoiceCommandParser.parse("Numer budynku 2") == .correct("2"))
    }
}
#endif
