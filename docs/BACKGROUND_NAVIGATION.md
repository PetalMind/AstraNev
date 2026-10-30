# Nawigacja w tle

`NaviAstraApp` utrzymuje `AppDependencies` przez czas życia aplikacji.
`NavigationSession` otrzymuje Core Location bez pośrednictwa ContentView ani MLNMapView.
Końcowy zapis TripRecord i checkpointy aktywnego przejazdu są podłączone w
AppDependencies, niezależnie od widoku.

## Cykl życia

- Eksploracja: pojedynczy odczyt lokalizacji. Przycisk powrotu do pozycji wymusza kolejny odczyt; wyznaczanie trasy czeka na świeży odczyt, jeżeli zapisany punkt ma ponad 15 sekund.
- Podgląd: odczyt GPS na żądanie, bez aktualizacji w tle.
- Prowadzenie/rerouting: ciągły GPS, map matching, postęp, głos, wykrywanie zjazdu i utrudnień. Samochód używa automotiveNavigation, pieszy/rower/komunikacja otherNavigation.
- Ekran nieaktywny: mapa jest usuwana z drzewa widoków. Dismantle anuluje zadania POI/ścieżek rowerowych i display link. Sesja zapisuje checkpoint, anuluje zadania kamery i zachowuje prowadzenie.
- Dojazd: co najmniej trzy różne świeże próbki przez minimum 5 sekund, prędkość poniżej 5 km/h i dokładność do 30 m. Samochód rozpoznaje cel w promieniu 100 m od wskazanego miejsca lub wybranego punktu dojazdu, również z drugiej strony i poza końcowym przebiegiem trasy. Jeśli pozostały przystanki pośrednie lub ładowania, nadal wymaga mniej niż 75 m pozostałej trasy. Pozostałe tryby wymagają celu w promieniu 50 m i mniej niż 75 m pozostałej trasy. Pojedynczy punkt, punkt stary lub przejazd obok celu z prędkością co najmniej 5 km/h nie kończą podróży.
- Koniec: zatrzymanie GPS nawigacyjnego, anulowanie reroutingu, zakończenie Live Activity i jeden końcowy zapis TripRecord o tym samym UUID co checkpointy. Przy dojeździe samochodem punkt zatrzymania jest zachowany dla istniejącego, opcjonalnego zapisu parkingu. Nowy podgląd lub start najpierw zapisuje poprzedni przejazd jako zastąpiony inną podróżą.

`NavigationSession.onTripCheckpoint` zapisuje aktywny przejazd przy starcie,
co 15 sekund oraz przy przejściu w tło. `PlaceStore.saveActiveTrip(_:)` zapisuje
go atomowo w osobnym `active-trip.json`; nie przepisuje wtedy całej historii.
Zapis końcowy przechodzi przez `pending-trip-<UUID>.json` przed zatwierdzeniem
archiwum. Nieudany zapis jest ponawiany także przy kolejnym checkpoincie i po
powrocie na pierwszy plan przez `onHistoryMaintenance`.

Po zamknięciu procesu następny start aplikacji odzyskuje ostatni udany checkpoint
jako przerwany przejazd z przyczyną `interruptedRecovered`, bez oceny prowadzenia.
Koniec odpowiada czasowi checkpointu; aplikacja nie dolicza czasu, gdy proces nie
działał, i nie wznawia automatycznie prowadzenia. Stały UUID zapobiega duplikatom,
jeśli zapis końcowy zakończył się przed przerwanym sprzątaniem plików roboczych.
Odcinki bez wiarygodnych pomiarów GPS są oznaczane jako czas bez pomiaru, a nie
postój. Pełny opis odzyskiwania, usuwania i retencji znajduje się w
[Historii przejazdów w iOS](ROUTE_HISTORY.md).

UIBackgroundModes zawiera location i audio. LocationManager utrzymuje
CLBackgroundActivitySession tylko podczas aktywnego prowadzenia i przy udzielonej
zgodzie na lokalizację. Tradycyjne aktualizacje CLLocationManager pozostają źródłem
punktów GPS. Zgoda When In Use pozwala kontynuować rozpoczętą nawigację z widocznym
wskaźnikiem pracy w tle; wcześniej udzielone uprawnienie Always również jest respektowane.

## Live Activity w iOS 1.1.139 (141)

NaviAstraWidgets jest osadzonym rozszerzeniem WidgetKit. Wspólny kontrakt w
SharedNavigation zawiera manewr, nazwę drogi, opcjonalne metryki po trasie, ETA,
postęp, stan GPS/przeliczania oraz schemat najbliższego odcinka. Schemat ma do 36
znormalizowanych punktów, pozycję i znacznik manewru, bez współrzędnych geograficznych
ani adresu celu. Nie używa mapy, kafelków, sieci, tekstur 3D ani ciągłych animacji.
Część prywatna jest oznaczona privacySensitive. Dane mają limit 3500 B z zapasem
do 4 KB ActivityKit, a atrybut celu jest stałą ogólną etykietą.

Activity jest rozpoczynana w aktywnej aplikacji, aktualizowana z sesji także w tle
(ruch w porcjach 40 m nie częściej niż co 5 sekund, od razu przy zmianie manewru,
reroutingu lub sygnału GPS, odświeżenie aktualności po 30 sekundach) i kończona
natychmiast po dojeździe lub anulowaniu. Aktualizacje są serializowane i scalane.
Dane są oznaczane jako nieaktualne po 45 sekundach; nieaktualna pozycja ukrywa
schemat i metryki. Pozycja poza trasą nie jest zastępowana fikcyjną pozycją na trasie.
Szybki stop/start ma osobne generacje, więc stare zakończenie nie usuwa nowej sesji.
Użytkownik może wyłączyć Live Activities
w systemie; brak Activity nie blokuje prowadzenia. Zakończenie procesu nie oznacza
automatycznego przywrócenia nawigacji; stare Activities są usuwane przy kolejnym starcie.

LocationManager zachowuje ciągłą sesję GPS rozpoczętą na pierwszym planie przy
przejściu do tła, zamiast zatrzymywać ją i uruchamiać ponownie podczas blokowania.
Koniec prowadzenia wyłącza aktualizacje w tle. Funkcja nie wymusza zgody „Zawsze”.

Zweryfikowany „iPhone (Dominik)” to iPhone 15 (iPhone15,4), iOS 27.2. Ten model
nie obsługuje Always-On: podgląd jest dostępny po podświetleniu ekranu blokady
i w Dynamic Island. Aplikacja nie wyświetla obrazu na fizycznie wyłączonym ekranie.
Na obsługiwanych modelach przyciemniony widok podlega ustawieniom i budżetom iOS.
System może zakończyć Live Activity po ośmiu godzinach. Źródła:
[ActivityKit](https://developer.apple.com/documentation/ActivityKit/displaying-live-data-with-live-activities),
[lokalizacja w tle](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background),
[modele Always-On](https://support.apple.com/en-md/109351).

## Weryfikacja wydania 1.1.139 (141) — 27 października 2026

Podpisana kompilacja iOS oraz osadzonego rozszerzenia zakończyła się powodzeniem.
Kompilacja pakietu testów iOS również przeszła; dwa wcześniej uszkodzone pliki
`TransitousTests.swift` i `NaviAstraTests.swift` wyłączono wyłącznie parametrem
komendy, bez zmiany ich źródeł. Brak zainstalowanego środowiska symulatora oznacza,
że samo build-for-testing nie jest wykonaniem testów. Osobne narzędzia uruchomiły
produkcjny kod: 7 krytycznych kontroli wyszukiwania i 4 kontroli Activity, GPS,
metryk oraz geometrii Transitous przeszły. Kontrole godzin objęły święto, zmianę
tygodnia, przedziały nocne oraz obie godziny 02:30 przy jesiennej zmianie czasu.

Instalacja aktualizacji na iPhonie 15 została potwierdzona odczytem wersji z urządzenia.
Przed i po instalacji zachowano wszystkie 431 ścieżek Application Support, w tym
`DrivingLearning/NavigationLearning.sqlite`, miejsca, plany i historię podróży.
Próba uruchomienia przez CoreDevice została odrzucona przez iOS z powodu blokady
telefonu, również w trybie bez aktywowania aplikacji. Do uruchomienia i weryfikacji
systemowego widoku Activity potrzebne jest odblokowanie urządzenia; nie potwierdzono
jeszcze rzeczywistego przejazdu z tą wersją ani wyglądu podglądu na ekranie blokady.

## Ruch i maintenance

W tle TomTom jest odpytywany w korytarzu przed pojazdem, zwykle co 90 sekund,
a przy oszczędzaniu energii lub wysokiej temperaturze co 120 sekund. Nie jest wtedy
pobierany ruch wokół całej pozycji ani warstwy mapy. Flow zachowuje własny interwał
180 sekund. Istniejący wybór szybszej trasy wymaga pełnych danych porównawczych,
co najmniej 2 minut i 15 procent zysku; zmiana jest ogłaszana głosowo.

BGAppRefreshTask utrzymuje cache szczegółów miejsc. BGProcessingTask odświeża i
indeksuje istniejący, wcześniej pobrany lokalny feed GTFS i utrzymuje cache. Zadania
mają obsługę wygaśnięcia; processing wymaga sieci i zasilania. Nie odświeżają ruchu
ani nie zastępują lokalizacji. Najwcześniejszy start to odpowiednio 6 i 24 godziny;
system decyduje o rzeczywistym wykonaniu.

## Weryfikacja

Krytyczne regresje są w BackgroundNavigationCriticalTests: postęp w tle bez kamery,
wykrywanie dojazdu, odrzucanie starych i słabych próbek oraz jednokrotny zapis podróży.
Kompilacja rozszerzenia nie potwierdza działania systemowego GPS/audio przy blokadzie;
ten scenariusz wymaga rzeczywistego urządzenia i zgód użytkownika.

Mechanizmy systemowe: [lokalizacja w tle](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background),
[CLBackgroundActivitySession](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-4nl4y),
[Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).
