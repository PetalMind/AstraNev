# Nawigacja w tle

`NaviAstraApp` utrzymuje `AppDependencies` przez czas życia aplikacji.
`NavigationSession` otrzymuje Core Location bez pośrednictwa ContentView ani MLNMapView.
Zapis TripRecord jest podłączony w AppDependencies, niezależnie od widoku.

## Cykl życia

- Eksploracja: pojedynczy odczyt lokalizacji. Przycisk powrotu do pozycji wymusza kolejny odczyt; wyznaczanie trasy czeka na świeży odczyt, jeżeli zapisany punkt ma ponad 15 sekund.
- Podgląd: odczyt GPS na żądanie, bez aktualizacji w tle.
- Prowadzenie/rerouting: ciągły GPS, map matching, postęp, głos, wykrywanie zjazdu i utrudnień. Samochód używa automotiveNavigation, pieszy/rower/komunikacja otherNavigation.
- Ekran nieaktywny: mapa jest usuwana z drzewa widoków. Dismantle anuluje zadania POI/ścieżek rowerowych i display link. Sesja anuluje zadania kamery, ale zachowuje prowadzenie.
- Dojazd: co najmniej trzy różne świeże próbki przez minimum 5 sekund, prędkość poniżej 5 km/h, dokładność do 30 m, cel poniżej 50 m i pozostała trasa poniżej 75 m. Pojedynczy punkt, punkt stary lub przejazd obok celu nie kończą podróży.
- Koniec: zatrzymanie GPS nawigacyjnego, anulowanie reroutingu, zakończenie Live Activity i jeden zapis TripRecord. Przy dojeździe samochodem punkt zatrzymania jest zachowany dla istniejącego, opcjonalnego zapisu parkingu.

UIBackgroundModes zawiera location i audio. LocationManager utrzymuje
CLBackgroundActivitySession tylko podczas aktywnego prowadzenia i przy udzielonej
zgodzie na lokalizację. Tradycyjne aktualizacje CLLocationManager pozostają źródłem
punktów GPS. Zgoda When In Use pozwala kontynuować rozpoczętą nawigację z widocznym
wskaźnikiem pracy w tle; istniejąca opcja Always dla podróży komunikacją pozostaje dostępna.

## Live Activity

NaviAstraWidgets jest osadzonym rozszerzeniem WidgetKit. Wspólny kontrakt w
SharedNavigation zawiera manewr, nazwę drogi, odległości, czas, ETA, postęp oraz stan
reroutingu/GPS. Nie zawiera geometrii ani współrzędnych GPS.

Activity jest rozpoczynana w aktywnej aplikacji, aktualizowana z sesji także w tle
(zwykle co 5 sekund, od razu przy zmianie manewru/statusu) i kończona po dojeździe,
anulowaniu lub zmianie celu. Aktualizacje są serializowane i scalane. Dane są
oznaczane jako nieaktualne po 90 sekundach. Użytkownik może wyłączyć Live Activities
w systemie; brak Activity nie blokuje prowadzenia. Zakończenie procesu nie oznacza
automatycznego przywrócenia nawigacji; stare Activities są usuwane przy kolejnym starcie.

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
