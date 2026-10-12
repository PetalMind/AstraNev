# Routing samochodowy — P1

Stan: 12 października 2026 r., NaviAstra 1.1.72 (build 74). Opis dotyczy kodu lokalnego checkoutu. Nie jest potwierdzeniem przejazdu ani kompletności danych dostawców.

## Diagnostyka decyzji i lokalna telemetria

W Ustawieniach otwórz narzędzia tras („Zasięg, ślady GPS i obszary omijane”), następnie „Ranking, jakość danych i benchmarki”. Widok działa również bez skonfigurowanego serwera.

Ostatnia decyzja jest dostępna w pamięci. Opcjonalny przełącznik „Zapisuj decyzje routingu” zapisuje lokalne JSON-y w `Application Support/RoutingDiagnostics`. Nie ma wysyłania telemetrii do serwera. Zapis zawiera współrzędne wariantów, jest wyłączony z kopii iCloud i ograniczony do 20 plików oraz 20 MB; pojedynczy plik może mieć najwyżej 10 MB. Eksport do miejsca wskazanego przez użytkownika jest osobną akcją. Błędy zapisu są widoczne.

Każdy zapis zawiera:

- aktywny i rekomendowany wariant, preferencję, źródło decyzji i wersję aplikacji, jeśli dostępna w pakiecie;
- czas, dystans, surowe składowe oceny i znormalizowane koszty;
- liczbę instrukcji, geometrię, pokrycie świeżymi pomiarami;
- czas obliczeń, jeśli był mierzony; w porównaniu ruchu także rzeczywistą liczbę zapytań i budżet;
- uzasadnienie oparte na dostępnych danych, z oznaczeniem braków.

Diagnostyka obejmuje wspólne planowanie drogowe, plan EV po kontroli wykonalności, ukończony podgląd, przeliczenie oraz sprawdzony objazd. Porównanie ruchu rejestruje aktywną trasę oddzielnie od zwycięzcy rankingu: warunki jakości danych lub minimalna oszczędność mogą zablokować przełączenie. Podgląd zapisuje również błąd planowania. Czas `preview-complete` obejmuje przygotowanie podglądu, a `road-plan` / `ev-plan` wspólną funkcję obliczenia drogi.

Długość manewru oznaczonego `rough` lub `toll` nie jest dokładną długością fragmentu gruntowego ani płatnego. Dlatego te metryki są oddzielne. Dokładny dystans nieutwardzony/płatny pozostaje nieznany przy oznaczeniu części manewru; brak danych nie staje się zerem. Nie ma obliczania taryf opłat.

## Normalizacja rankingu

Najszybsza trasa nadal porównuje ETA, a najkrótsza dystans. Zrównoważona i wygodna porównują składowe w zakresie 0–1, gdzie **niższa wartość jest lepsza**.

Dla czasu, dystansu, kosztu manewrów i nawierzchni:

`znormalizowany koszt = x / (x + s)`

`s` jest górną medianą dodatnich, skończonych wartości danej składowej w porównywanym zestawie; przy braku dodatnich wartości wynosi 1. Dzięki temu zmiana jednostek nie zmienia porządku rankingu. Wynik zależy od porównywanego zestawu, więc nie jest absolutną oceną wszystkich tras świata.

| Składowa | Zrównoważona | Wygodna |
|---|---:|---:|
| Czas | 0,55 | 0,30 |
| Dystans | 0,10 | 0,10 |
| Manewry | 0,20 | 0,45 |
| Znana nawierzchnia | 0,05 | 0,05 |
| Pokrycie pomiarami ruchu | 0,10 | 0,10 |

Brak porównywalnej składowej wyłącza ją dla całego zestawu; pozostałe wagi są ponownie sumowane do 1. Brak instrukcji nie oznacza bezpłatnych manewrów. Waga ruchu korzysta z `1 − udział świeżych pomiarów`, gdy wszystkie porównywane warianty mają pomiary. Nie jest statystycznym prawdopodobieństwem problemów. Ranking nie dopisuje tych kosztów do ETA.

## MapMatchingEngine i postęp

Wspólny silnik dopasowuje GPS do geometrii bieżącej trasy. Bierze pod uwagę dokładność, wiarygodny kurs, prędkość, poprzednie dopasowanie i czas między pomiarami. Odrzuca niepoprawne i stare pomiary. Używa indeksowanych kandydatów istniejącego `RouteProgressGeometry`.

Przy bliskich kosztach dopasowania do różnych części drogi zgłasza niejednoznaczność i obniża jakość. Sąsiednie segmenty tej samej polilinii nie są automatycznie traktowane jako dwie drogi. Zwraca pozycję, postęp, kurs odcinka, dostępną nazwę drogi, liczbę kandydatów i jakość dopasowania.

Niejednoznaczny lub słaby wynik nie przesuwa wiarygodnego postępu, ETA ani wyboru następnego manewru poza ostatni zaakceptowany punkt. Znacznik auta nie jest wtedy przyciągany do wybranej jezdni; korzysta z pomiaru GPS. Zachowywana jest osobna aktualna projekcja potrzebna do wykrywania zjazdu. Taki pomiar nie potwierdza pominięcia przystanku i nie uruchamia komunikatu nowego manewru.

`OffRouteDetector` udostępnia stany `onRoute`, `suspicious`, `probablyOffRoute`, `offRoute`. Nadal potrzebuje trzech różnych pomiarów i co najmniej dwóch sekund potwierdzenia; powrót na trasę resetuje stan.

Silnik **nie ma grafu wszystkich pobliskich dróg** ani danych poziomu estakady. Nie potwierdza drogi OSM na podstawie samej polilinii i nie rozwiązuje wszystkich przypadków tuneli czy równoległych jezdni.

## TrafficCoverage, RouteReliability i ETAConfidence

Pokrycie jest długością sumy przedziałów z dopasowanymi pomiarami prędkości lub zamknięcia. Nakładanie próbek nie zwiększa wyniku. Liczone są osobno:

- pozostała geometria całej trasy;
- monitorowany korytarz;
- dystans obserwowany w dostępnym snapshotcie;
- dystans pokryty świeżymi pomiarami;
- udział świeżych pomiarów w korytarzu i w całej pozostałej trasie.

Pomiar przepływu zachowuje swój czas pobrania i wygasa po 240 s. Zdarzenie zachowuje czas obserwacji i wygasa dla decyzji po 120 s. Nowy przepływ nie odmładza starego zdarzenia. Są to czasy obserwacji klienta, nie gwarancja wieku danych po stronie dostawcy.

Budżet zapytań na korytarz wynosi 40 w podglądzie, 64 podczas zwykłej nawigacji, do 96 przy wykrytym problemie i 24 w tle. Limit 96 jest pułapem. Korytarz nadal odpowiada do 25 minutom jazdy. Porównanie kilku wariantów wykonuje osobny zestaw zapytań dla każdego i raportuje ich łączną liczbę.

Automatyczne przełączenie wymaga świeżego pokrycia co najmniej 50% obu porównywanych korytarzy. Kandydat nie może mieć pokrycia gorszego o więcej niż 10 punktów procentowych. Nadal obowiązują zgodność pozycji/kierunku, pozyskanie zdarzeń, minimum 75% odpowiedzi na próbki i oszczędność `max(120 s, 15% aktualnego ETA)`.

Ocena jakości danych ma stany: brak danych, ograniczone, częściowe pokrycie, dobre pokrycie, zamknięcie. Dobre pokrycie najbliższego korytarza nie oznacza dobrego pokrycia wielogodzinnej podróży. `ETAConfidence` uwzględnia również jakość GPS. Wyjaśnienie pojawia się w rozwiniętym panelu jazdy oraz diagnostyce.

Nie ma wiarygodnego statystycznego przedziału „± 3 min” bez zbioru błędów prognoza–rzeczywisty przyjazd. `uncertaintySeconds` pozostaje nieznane; procent pokrycia nie jest prawdopodobieństwem punktualnego przyjazdu.

## Destination Intelligence

Resolver pobiera z OSM również oznaczone wjazdy parkingowe i bariery. Dla powiązanego parkingu analizuje przecięcia jego granicy z drogami serwisowymi. Rozróżnia wjazd do celu oraz wyjazd z ręcznie wybranego początku POI, sprawdzając `oneway=yes` i `oneway=-1` w odpowiednim kierunku.

Dostęp samochodowy jest odczytywany w kolejności `motorcar`, `motor_vehicle`, `vehicle`, `access`. Oznaczenia `no`, `private` i `delivery` wykluczają kandydata, o ile nie ma bardziej szczegółowego dopuszczenia pojazdu. Znane bariery blokujące również eliminują drogę. Zwykłe drzwi z `entrance=main` nie stają się automatycznie wjazdem autem.

Ranking kandydatów korzysta z oznaczonego wjazdu, potwierdzonego kierunku, bliskości celu oraz dostępnego początku/kursu. Kontekst dojazdu nie jest przechowywany jako uniwersalny wynik dla wszystkich kierowców; cache surowych obiektów nadal jest wspólny. Punkty pośrednie otrzymują kontekst poprzedniego przystanku. Cel przechowuje identyfikator OSM kandydata i powody wyboru.

To geometria i heurystyka, nie osobne trasowanie do każdego wjazdu. Nie potwierdza godzin otwarcia, kodu bramy, pozwolenia kierowcy, wolnego parkingu ani strony drogi poza opcją przekazaną Valhalli. Przy braku wiarygodnego wjazdu pozostają wcześniejsze możliwości punktu parkingu lub najbliższej drogi.

## Pasy i moment komunikatów

`LaneGuidanceEngine` korzysta z `active` i `valid` dostawcy. Preferuje wskazane przez niego aktywne pasy, w innym przypadku pokazuje dopuszczalne. Dodaje opis tekstowy i głosowy, np. „Trzymaj się prawego pasa”. Nie wybiera zmyślonego pasa, gdy brakuje danych, i nie ustala aktualnego pasa auta z GPS.

`GuidanceQualityEngine` uwzględnia węzeł, włączenie do ruchu, rondo, liczbę pasów, ostry skręt i odstęp do następnego manewru. Prędkość i złożoność zmieniają dystans przygotowania, wskazania pasa i manewru bezpośredniego. Zachowane są deduplikacja głosu, priorytety i ustawienia szczegółowości. Etykieta „TERAZ” używa tego samego progu.

Nie ma niezależnego od dostawcy planowania zmiany pasa na podstawie `change:lanes` ani ustalania pasa na podstawie pozycji auta.

## Benchmarki i granice walidacji

W diagnostyce można uruchomić **120 deterministycznych scenariuszy syntetycznych**: po dziesięć wariantów dla 12 kategorii. Kategorie obejmują ranking miejskich i długich tras, złożone manewry, ruch, zamknięcia, podobieństwo, dostęp do POI, ładowanie, GPS oraz pasy i moment komunikatów. To matematyczne/regresyjne dane wejściowe, nie 120 dróg obliczonych przez serwer.

[Raport bazowy JSON](benchmarks/p1-synthetic-baseline.json) pochodzi z rzeczywistego uruchomienia kodu algorytmów na macOS. Zawiera wyniki, pomiary i czas wykonania. Nie potwierdza ruchu rzeczywistego ani wydajności serwera.

Zapisane decyzje można wyeksportować i zaimportować do odtworzenia. Odtwarzany jest ranking na zarejestrowanych składowych, bez nowych zapytań do Valhalli i TomTom. Pozwala to sprawdzić zmianę wag lub kolejności; nie ponawia przygotowania grafu, map matchingu całego śladu ani pozyskiwania danych. Zbiór 100–300 rzeczywistych tras trzeba dopiero zebrać przez lokalną diagnostykę.

Regresje krytyczne P0/P1 znajdują się w `RoutingSelectionCriticalTests.swift` i `RoutingP1CriticalTests.swift`. W środowisku macOS uruchamiany jest wydzielony zestaw z rzeczywistym kodem obliczeń, z pominięciem warstwy UI/transit. Kompilacja całej aplikacji potwierdza integrację. Testy iOS mogą zostać skompilowane po pominięciu istniejących błędów w niezmienionych `TransitousTests.swift` i `NaviAstraTests.swift`; bez runtime’u symulatora nie jest to uruchomienie testów na iOS. Nie wykonano przejazdu.

## Podstawa w kodzie

- `Navigation/Engine/MapMatchingEngine.swift`, `RouteProgressTracker.swift`, `OffRouteDetector.swift`, `NavigationPuckEngine.swift`;
- `Traffic/TrafficCoverage.swift`, `RouteTrafficMonitor.swift`, `TrafficProvider.swift`;
- `Navigation/Engine/RouteScoringEngine.swift`, `RoutingDiagnostics.swift`, `RoutingBenchmarkSuite.swift`;
- `Places/DestinationIntelligenceEngine.swift`, `POIAccessResolver.swift`;
- `Navigation/Engine/LaneGuidanceEngine.swift`, `GuidanceQualityEngine.swift`, `Navigation/VoiceGuidanceEngine.swift`;
- `Navigation/UI/RoutingDiagnosticsView.swift` i integracja w `NavigationSession`.

Znaczenie flag pasów i parametrów drogowych opisuje [API Valhalli](https://valhalla.github.io/valhalla/api/route/api-reference/). Jakość danych ETA i opisane wagi są heurystykami klienta NaviAstra, a nie gwarancjami dostawcy.
