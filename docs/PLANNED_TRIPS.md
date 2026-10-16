# Planowane podróże — wersja lokalna

Dostęp: **Trasa → Zaplanuj na później** albo **Zaplanowane podróże** na ekranie mapy. Widok Podróże zawiera Zaplanowane, Regularne i dostęp do istniejącej historii. Poprzednie plany można edytować lub usunąć.

Plan zapisuje start, cel, ręczne postoje, środek transportu, godzinę wyjazdu albo termin przyjazdu, strefę czasową, bufor, łączny czas postojów, preferencje routingu, wybrany wariant i przypomnienia. Wariant jest rozpoznawany po próbkach jego przebiegu; zapisane współrzędne służą dopasowaniu aktualnych alternatyw, a nie odtworzeniu starej trasy z pominięciem ograniczeń. Jeśli wariant nie jest już dostępny, interfejs informuje o zastosowaniu aktualnej rekomendacji.

Dane są zapisywane atomowo w lokalnym `Application Support/NaviAstra/planned-trips.json`. Błąd odczytu wstrzymuje zapis, aby nie nadpisać uszkodzonego pliku pustą listą. Nie ma CloudKit, synchronizacji planów z iCloud, uczenia maszynowego ani serwera powiadomień. Wcześniej istniejąca personalizacja jazdy jest pomijana podczas wyliczania planowanych tras.

## Wyliczanie terminów

Dla tras drogowych:

`wyjazd = termin przyjazdu − czas przejazdu − łączny czas postojów − bufor`

Bufor dotyczy przyjazdu. Czas postoju nie zmienia samych kilometrów ani czasu przejazdu z silnika tras. Ładowanie EV uwzględnia istniejący silnik routingu. Transport publiczny korzysta z rzeczywistych godzin odjazdu i przyjazdu połączenia. Ręczne postoje są dostępne dla auta, roweru i podróży pieszych.

Przy pierwszym odczycie po wycofaniu trybu P+R aplikacja zachowuje kopię pliku planów w lokalnym archiwum `planned-trips-retired-mode-<UUID>.json` i usuwa te plany z aktywnego harmonogramu. Nie zamienia ich na inny transport. Historia przejazdów pozostaje czytelna; wycofany tryb jest prezentowany jako niedostępny.

`TripPlanningService` używa odrębnej sesji istniejącego `NavigationSession`, aby obliczenia nie zmieniały aktywnej nawigacji. Przed wyjazdem auta, jeśli do rekomendowanej godziny pozostała najwyżej godzina, pobierane są dostępne pomiary i zdarzenia TomTom. Zastosowanie `RoadRouteETA` zastępuje czas na zmierzonych odcinkach, unikając podwójnego doliczania opóźnień. Nieznane odcinki zachowują szacunek silnika. Brak klucza, pomiarów lub zdarzeń jest pokazany w szczegółach; bieżący ruch nie jest traktowany jako prognoza na przyszłe dni. Potwierdzone zamknięcie powoduje komunikat o konieczności wybrania innej trasy.

Przycisk „Rozpocznij teraz” wymaga świeżej pozycji GPS, ponownie przelicza trasę z bieżącego miejsca i rozpoczyna nawigację. Termin jest wykorzystany dopiero po wejściu w nawigację. Błąd GPS lub routingu nie zużywa planu. Nie można rozpocząć kolejnego planu podczas aktywnej nawigacji.

## Powtarzanie i przypomnienia

Powtarzanie: nigdy, codziennie, dni robocze, co tydzień, wybrane dni. Kalendarz działa w zapisanej strefie czasowej i zachowuje godzinę lokalną po zmianie czasu. Dni robocze oznaczają poniedziałek–piątek; nie jest stosowany kalendarz świąt. Można pominąć pojedynczy termin.

Przypomnienia: dzień, godzinę, 15 minut przed wyjazdem i w chwili wyjazdu. `UNUserNotificationCenter` otrzymuje konkretne daty; identyfikatory umożliwiają zastąpienie terminu po zmianie planu. Zdarzenia minione nie są odtwarzane natychmiast. Usunięcie planu usuwa jego oczekujące przypomnienia. Budżet obejmuje do 60 najbliższych powiadomień z uwzględnieniem pozostałych powiadomień aplikacji, a horyzont powtarzania wynosi 30 dni. Kolejka uzupełnia się podczas otwarcia aplikacji lub odświeżenia w tle. Odmowa uprawnienia nie blokuje zapisu planu.

Dla kolejnych terminów regularnej trasy drogowej przypomnienie jest orientacyjne i zawiera datę ostatniego przeliczenia. Transport publiczny nie ekstrapoluje nieznanego rozkładu na następne dni: godzinę wyjazdu wyznacza aktualnie przeliczone połączenie. Na takie terminy przypomnienia są dodawane dopiero po odświeżeniu.

Aplikacja odświeża plany po wejściu na pierwszy plan, okresowo podczas używania oraz w istniejącym zadaniu `BackgroundMaintenance`. Żądanie pracy w tle jest składane w związku z najbliższym wyjazdem, ale **iOS decyduje o jego faktycznym uruchomieniu**. Bez ponownego otwarcia aplikacji lub przydzielenia pracy w tle pozostają ustawione przypomnienia według ostatniego obliczenia. Nie jest gwarantowany alarm oparty na korkach dokładnie w momencie jego wyświetlenia.

Akcja powiadomienia „Otwórz trasę” otwiera szczegóły właściwego planu, także po uruchomieniu aplikacji z powiadomienia. Rozpoczęcie nawigacji pozostaje świadomą akcją w szczegółach.

## Kalendarz

Opcjonalny wybór wydarzenia prosi o dostęp dopiero po otwarciu widoku kalendarza. Użytkownik wybiera wydarzenie z godziną i lokalizacją z najbliższych 30 dni. Lokalizacja o znanych współrzędnych jest kopiowana; adres tekstowy przechodzi przez wyszukiwarkę miejsc i wymaga wyboru wyniku. Aplikacja nie zapisuje wydarzeń, nie obserwuje zmian kalendarza i nie tworzy planów automatycznie. Plan jest lokalną kopią wybranej intencji.

## Walidacja krytyczna

`PlannedTripsCriticalTests` obejmuje obliczanie wyjazdu z buforem i postojami, powtarzanie podczas zmiany czasu, pomijanie terminów, brak wymyślonych godzin dla nieznanego rozkładu, niedostępny preferowany wariant, odtworzenie danych lokalnych, ochronę uszkodzonego pliku oraz aktualizację stabilnych identyfikatorów przypomnień. Testy nie wymagają zgody na powiadomienia ani połączenia z usługami routingu.

Sprawdzenie kompilacji z 13 października 2026:

- iOS Simulator arm64 oraz `build-for-testing` grupy `PlannedTripsCriticalTests`: poprawne (`/tmp/naviastra-planned-trips-critical-build.log`). Starsze pliki testowe wyłączono tylko w tym poleceniu kompilacji, ponieważ pełny cel testowy ma niezależne błędy w `TransitousTests.swift` i `NaviAstraTests.swift`; nie zmieniano ich dla tej funkcji.
- `git diff --check`, sprawdzenie składni nowych źródeł i uprawnień kalendarza: poprawne.
- Testów nie uruchomiono: lokalny CoreSimulator nie ma żadnego zainstalowanego środowiska iOS ani urządzenia symulowanego. Dostarczanie powiadomień, wybór wydarzeń po nadaniu uprawnień i rzeczywiste żądania TomTom pozostają bez weryfikacji podczas działania aplikacji.

## Nowy interfejs iOS — 1.1.80, build 82

Na iOS tworzenie i edycja planu otwiera jeden ekran z mapą i wspólnym panelem `NavigationBottomSheet`. Start, cel i ponumerowane punkty pośrednie znajdują się w jednej karcie; niżej występują termin, rzeczywiste warianty trasy i wynik obliczeń. Przycisk zapisu oraz skrót wyniku pozostają w stopce. Przypomnienia, harmonogram i preferencje są dostępne w rozwijanej sekcji. Warianty pochodzą z istniejącej sesji routingu — jeśli dostawca zwróci jedną trasę, interfejs pokazuje jedną trasę.

`IOSPlannedTripDraft` przechowuje wszystkie pola szkicu i posiada własną sesję nawigacji przeznaczoną wyłącznie do przeliczeń. Przejścia między wyszukiwaniem, wyborem na mapie i kalendarzem zachowują szkic. Podgląd i zmiany jego punktów nie modyfikują aktywnej nawigacji. Prezentacja zachowuje ten sam obiekt szkicu przez cały czas edycji.

Wybór miejsca zawiera widoczne pole adresu, akcję wyboru na mapie, zapisane i ostatnie miejsca oraz ich lokalne dopasowania do wpisywanego tekstu. Wyniki z usług są wyświetlane stopniowo przez istniejący `SearchEngine`; opcjonalne obliczenia dojazdu nie blokują wyboru pierwszych adresów. Wysłanie zapytania uruchamia również istniejący mechanizm dokładnego adresu. Dla komunikacji dostępne jest wyszukiwanie przystanków jako startu lub celu.

Mapa pozwala wybrać POI, przystanek lub punkt pod centralną pinezką. W nowym trybie wyboru odświeżanie środka mapy ma próg 1 m; standardowy tryb mapy zachowuje dotychczasowy próg 35 m. Dane wskazanego POI są zachowane podczas programowej animacji kamery, a ręczne przesuwanie mapy ponownie ustala punkt i jego adres. Potwierdzenie zmienia odpowiednie pole szkicu.

Punkty pośrednie mają jawne opcje zmiany miejsca, przesunięcia i usunięcia. Obowiązuje limit ośmiu punktów oraz kontrola duplikatów. Zmiana transportu nie usuwa danych; ograniczenie wybranego trybu blokuje zapis i zostaje opisane przy trasie.

Klucz danych routingu unieważnia podgląd po zmianie punktów, terminu, transportu i preferencji. Zmiana nazwy lub przypomnień nie przelicza trasy, a wybór już obliczonego wariantu zachowuje jego podgląd i rzeczywisty czas obliczenia. Godziny mają dokładność minutową, aby ukryte sekundy nie pomijały pierwszego dnia powtarzanej podróży.

Zapis pokazuje osobne podsumowanie zamiast bezwarunkowo zamykać ekran. Bez podglądu dostępna jest świadoma akcja „Zapisz bez wyliczenia trasy”; brak wyliczenia jest wskazany w podsumowaniu. Podczas zapisu pola i wybór wariantu są zablokowane. Po zakończeniu użytkownik wraca do zapisanej podróży. Lista na iOS grupuje terminy według dni, a zakładka Regularne pokazuje definicje harmonogramu. Przycisk rozpoczęcia jasno wskazuje start z bieżącego miejsca.

Nowe widoki i model edycji znajdują się w `NaviAstra/Trips/iOS/` i są kompilowane wyłącznie dla iOS. Integracja w głównym widoku jest warunkowa; dotychczasowy edytor pozostałych platform nie otrzymał tej przebudowy.

Krytyczna grupa `IOSPlannedTripEditingCriticalTests` obejmuje zachowanie punktów i intencji przy zmianie transportu, stabilny wybór wariantu i czas obliczenia, zastąpienie punktu z zachowaniem identyfikatora, limit i duplikaty, blokadę zapisu nieaktualnego podglądu, dokładność minutową powtarzania oraz zachowanie metadanych POI podczas animacji kamery. Kompilacja grupy i istniejących `PlannedTripsCriticalTests` przeszła. Uruchomienie pozostaje niedostępne: lokalny CoreSimulator nie ma zainstalowanego środowiska iOS ani urządzeń symulowanych. Pozostałe, niezależnie błędne grupy testów pominięto jedynie w poleceniu kompilacji.
