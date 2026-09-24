# Jak NaviAstra wyznacza trasę

Ten dokument opisuje bieżącą implementację routingu. Głównym koordynatorem jest `NavigationEngine`; osobni dostawcy obliczają trasy drogowe oraz połączenia kolejowe i MPK. Mapa tylko prezentuje otrzymaną geometrię — nie wyszukuje samodzielnie dróg.

## W skrócie

- Początek trasy to ostatnia zaakceptowana pozycja GPS. Cel pochodzi z wyszukiwania, mapy albo wybranego miejsca.
- Wybrany tryb transportu decyduje o silniku: Valhalla dla samochodu, marszu i roweru; planer GTFS dla krajowych pociągów i MPK Łódź; połączenie obu silników dla P+R.
- Dla tras drogowych warianty zwraca serwer Valhalla. Podczas nawigacji TomTom może zmienić wybór na szybszy z już zwróconych wariantów; serwer Valhalla nadal dostarcza geometrię i podstawowe czasy.
- Planer transportu publicznego łączy krajowy rozkład pociągów PKP/ŁKA i innych przewoźników z rozkładem MPK Łódź. Macierz Valhalli wybiera osiągalne stacje i przystanki, routing pieszy wyznacza geometrię dojścia, a transfery korzystają z grafu GTFS i są sprawdzane przed zwróceniem trasy.
- Dane TomTom wpływają na pozostały czas i wybór wśród wariantów Valhalli. Zdarzenie zamknięcia jest rozpoznawane po polu kategorii, a nie po tekście opisu.

## Przebieg obliczenia

1. `NavigationEngine.planRoute()` wymaga wybranego celu i pozycji GPS. Gdy nie ma zaakceptowanej pozycji, nie zaczyna obliczeń.
2. `preview()` bierze bieżące współrzędne GPS jako początek, ustawia status obliczania i wywołuje `calculateRoutes()`.
3. `calculateRoutes()` przekazuje żądanie do dostawcy zależnie od trybu podróży.
4. Po otrzymaniu niepustej listy tras pierwszy element staje się początkowo wybraną trasą, a cała lista pozostaje dostępna jako warianty. Podczas jazdy traffic może zmienić wybór wśród tych wariantów.
5. Zmiana celu, przystanku pośredniego albo trybu wywołuje kolejne obliczenie. Identyfikator żądania zapobiega nadpisaniu nowszego podglądu spóźnioną odpowiedzią.

Pozycje GPS przechodzą przez `LocationFilter`. Akceptowane są pomiary z dokładnością poziomą do 70 m, nie starsze niż 15 sekund ani pochodzące z przyszłości o więcej niż 15 sekund. Kolejny pomiar musi mieć późniejszy czas. Granica prędkości skoku zależy od trybu: 10 m/s pieszo, 40 m/s rowerem, 75 m/s samochodem i P+R oraz 90 m/s komunikacją miejską. Dopiero zaakceptowany pomiar aktualizuje początek trasy i postęp nawigacji.

## Trasy samochodem, pieszo i rowerem

`ValhallaRouteProvider` wysyła żądania HTTPS `POST /route` oraz `POST /sources_to_targets` dla macierzy dojść pieszych. Przekazuje:

- współrzędne początku, celu oraz przystanków pośrednich w podanej kolejności;
- profil kosztowania: `auto`, `pedestrian` albo `bicycle`;
- jednostki kilometrów, język instrukcji `pl-PL` oraz prośbę o dwie alternatywy.

Odpowiedź może więc zawierać trasę podstawową i do dwóch alternatyw. Dostawca dekoduje geometrię polyline6, instrukcje manewrów, dystans i czas z podsumowania Valhalli. W podglądzie `NavigationEngine` domyślnie wybiera `routes.first`, zachowując kolejność serwera; użytkownik może wybrać inny zwrócony wariant. W trakcie jazdy TomTom może zmienić wybrany wariant po porównaniu opóźnień i zamknięć na tych trasach.

### Preferencje samochodowe

Dla profilu samochodowego ustawienia są przesyłane jako opcje kosztowania Valhalli:

| Ustawienie | Przekazywana opcja |
|---|---|
| Unikaj dróg płatnych | `use_tolls = 0` |
| Unikaj autostrad | `use_highways = 0` |
| Unikaj promów | `use_ferry = 0` |
| Unikaj dróg gruntowych | `exclude_unpaved = true` |

Te ustawienia aplikacja przekazuje wyłącznie dla samochodu. Faktyczny wariant nadal zależy od grafu dróg i interpretacji opcji przez używany serwer. Współrzędne omijanych punktów są przekazywane przy automatycznym omijaniu wykrytego zamknięcia.

### Przystanki pośrednie

Można dodać do ośmiu przystanków. Zwykłe wyznaczanie trasy zachowuje ich bieżącą kolejność. Dla samochodu, marszu i roweru dostępna jest osobna optymalizacja kolejności przez endpoint Valhalli `/optimized_route`. Aplikacja sprawdza długość zwróconej listy i zakres indeksów, po czym zmienia kolejność punktów i ponownie liczy trasę.

## Komunikacja: kolej i MPK Łódź

`LodzTransitRouteProvider` łączy miejski rozkład MPK i jego feedy GTFS-Realtime z krajowym rozkładem pociągów PKP PLK/ŁKA i feedem aktualizacji czasu przejazdu. Te publiczne źródła pobierane są bez klucza API. Identyfikatory krajowego feedu dostają prefiks `rail/`, aby nie kolidowały z identyfikatorami MPK. Baza GTFS jest przechowywana w cache; jej ponowne załadowanie z cache jest oznaczane w wyniku. Obowiązywanie kursów jest liczone według kalendarza `Europe/Warsaw`, z uwzględnieniem wyjątków kalendarza GTFS. Dane realtime mają stan `live` do 90 sekund, `degraded` do 180 sekund, `stale` powyżej 180 sekund albo `unavailable`, gdy feed nie ma poprawnego znacznika czasu. Nieświeże aktualizacje nie zmieniają czasów kursów.

### Wybór połączeń

Planer używa rund w stylu RAPTOR i stosuje następujące ograniczenia i kryteria:

- Dla każdego końca wyszukuje obsługiwane stacje i przystanki w promieniu 10 km, niezależnie od tego, czy należą do krajowego feedu kolejowego, czy do miejskiego feedu MPK. Pyta Valhallę `/sources_to_targets` o czasy dojścia pieszo; do planu trafiają dojścia do 30 minut. Kandydaci kolei i MPK są wybierani osobno, żeby gęsta sieć miejskich przystanków nie wyparła pobliskiej stacji. Macierz jest dzielona na porcje po 40 celów.
- Geometria dojścia, dojścia końcowego i transferów jest pobierana przez Valhallę `/route` dla pieszych. Jeśli routing macierzowy lub wyznaczenie geometrii nie powiedzie się, planer zgłasza błąd zamiast rysować dojście po prostej.
- Rozpatruje kursy w oknie do 18 godzin i szuka podróży składających się z jednego do czterech przejazdów pojazdem. Planowanie obejmuje stacje z krajowego feedu, więc cel podróży może leżeć poza województwem łódzkim.
- Przy standardowym planowaniu żądany czas odjazdu to bieżąca chwila. Interfejs silnika przyjmuje też inny czas, ale `NavigationEngine` przekazuje `Date()`.
- Przy przesiadce na tym samym przystanku wymaga co najmniej 60 sekund. Dane `transfers.txt` (w tym zakaz transferu typu 3), przejścia z `pathways.txt`, wspólna `parent_station` oraz osobne przystanki do 350 m budują skierowany graf dojść. Bufory z GTFS są zachowywane, a wybrane dojścia muszą zmieścić się w rzeczywistym czasie między kursami.
- Uwzględnia aktualizacje czasu przejazdu i odwołane kursy z realtime, jeśli feed jest dostępny. Bez aktualizacji używa godzin rozkładowych. Komunikaty są dołączane do tras, których linii lub przystanków dotyczą.
- Planer nie odcina odjazdów limitem 2 kursów na wzorzec ani 48 kursów na przystanek. W każdej rundzie zachowuje niedominowane etykiety czasu przyjazdu, łącznego chodzenia i liczby przesiadek.

Warianty ocenia koszt uogólniony:

```text
czas jazdy + 1,6 × chodzenie + 1,25 × oczekiwanie + 4 min × liczba przesiadek
```

Planer zachowuje do trzech różnych wariantów: najniższy koszt uogólniony, najszybszy, z najmniejszą liczbą przesiadek lub z najmniejszą ilością chodzenia. Wyniki przechodzą dodatkową walidację pieszych geometrii i czasu przesiadek. Geometria kursu pochodzi z kształtu GTFS, jeśli jest dostępny; w przeciwnym razie jest odtwarzana z pozycji przystanków.

Graf transferów może przejść przez maksymalnie 12 krawędzi, z limitem 30 minut samego chodzenia. Planer działa w zakresie przystanków MPK Łódź i najbliższych okolic. Brak przystanków w zasięgu, brak osiągalnego połączenia albo niedostępny routing pieszy kończy się błędem, a nie trasą zastępczą.

## P+R

Tryb P+R łączy trasę samochodem do parkingu i dalszą podróż MPK:

1. Valhalla liczy bazową trasę samochodową do celu. OpenStreetMap/Overpass wyszukuje parkingi w korytarzu ostatnich 40 km trasy oraz w promieniu 15 km od celu. Kandydaci muszą mieć tag `amenity=parking` i `park_ride=yes`.
2. Dla maksymalnie dwunastu kandydatów Valhalla liczy trasę samochodową. Używany jest pierwszy wariant samochodowy.
3. Planer MPK szuka połączenia z parkingu do celu, z czasem odjazdu ustawionym na przewidywany przyjazd samochodem.
4. Wyniki są sortowane według łącznego kosztu jazdy, chodzenia, oczekiwania i przesiadek; zwracane są maksymalnie trzy warianty.

Wynik zawiera odcinek samochodowy oraz odcinki piesze i komunikacyjne z planera MPK. Dostępność parkingu, wolnych miejsc ani czas parkowania nie są sprawdzane. W trybie P+R automatyczne przeliczanie po zejściu z geometrii trasy jest wyłączone.

## Szczegóły parkingu

Karta parkingu dociąga z OpenStreetMap status opłat (`fee` i `fee:conditional`), opis taryfy (`charge` i `charge:conditional`), godziny (`opening_hours`), limit postoju (`maxstay` i `maxstay:conditional`), dostęp (`access`) oraz pojemność (`capacity`). Proste zasady darmowego czasu w warunku postoju są pokazywane dodatkowo w minutach lub godzinach; treść warunku OSM pozostaje widoczna. Dla tagów `parking:left/right/both:*`, `parking:condition:*` i `parking:lane:*` karta pokazuje osobne warunki stron ulicy.

Brak tagu `fee` jest prezentowany jako brak danych, nie jako parking bezpłatny. Pojemność oznacza łączną liczbę miejsc, jeśli została opisana; OSM nie dostarcza NaviAstra bieżącej liczby wolnych miejsc. Obecnie aplikacja korzysta tu z OSM i nie pobiera miejskich taryf ani dostępności na żywo od zewnętrznego operatora. Dane są prezentowane w karcie POI, a nie jako kolorowa warstwa zajętości lub zasad na geometrii ulic.

## Planowanie ładowania EV

Planowanie EV jest rozszerzeniem samochodowego routingu Valhalli i działa tylko wtedy, gdy wybrany serwer obsługuje zaawansowany interfejs routingu. Ustawienia pojazdu obejmują zasięg pełnej baterii, bieżący poziom, zużycie kWh/100 km, maksymalną moc przyjmowaną przez auto i obsługiwane złącza.

1. Z ustawionego zasięgu przy pełnej baterii i poziomu baterii liczony jest aktualny zasięg. Brak dodatniego zasięgu zgłasza błąd.
2. Najpierw liczona jest bazowa trasa z ręcznie dodanymi przystankami. Jeśli jej dystans nie przekracza 80% aktualnego zasięgu, ładowarki nie są dodawane.
3. W przeciwnym razie aplikacja szuka w OpenStreetMap ładowarek (`amenity=charging_station`) w korytarzu do 1,2 km od geometrii trasy. Kandydat musi mieć opisane złącze i moc, nie może być oznaczony jako niedziałający ani prywatny. Zaznaczone złącza pojazdu są filtrem; pusty wybór dopuszcza wszystkie opisane typy.
4. Wybiera kolejną ładowarkę w zasięgu bieżącego odcinka. Trasa zachowuje rezerwę 20%; na postoju oblicza energię potrzebną do następnej ładowarki lub celu. Uwzględnia ograniczenie mocy auta i deklarowaną moc stacji, więc nie zakłada pełnego ładowania przy każdym postoju.
5. Wybrane ładowarki i ręczne przystanki są porządkowane wzdłuż trasy, a Valhalla liczy trasę końcową. Plan jest ponownie sprawdzany na geometrii tej trasy. Szacowany czas ładowania jest dodawany do ETA. Limit to dziesięć ładowarek.

Plan bazuje na zasięgu i zużyciu podanym przez użytkownika oraz metadanych OSM. Nie ma danych o bieżącej zajętości stacji. Jeśli status operacyjny lub dostęp publiczny nie są opisane, UI pokazuje tę lukę. Szacunek nie modeluje krzywej ładowania, maksymalnej mocy konkretnego auta poza limitem użytkownika, zużycia zależnego od prędkości, przewyższeń ani pogody. Brak stacji z wymaganymi metadanymi kończy planowanie błędem zamiast zakładać dostępność.

## Postęp, ruch i ponowne wyznaczanie

Podczas nawigacji `MapMatcher` ocenia kandydackie odcinki geometrii według odległości, kursu, prędkości, dokładności GPS i ciągłości postępu od poprzedniego pomiaru. Najlepsze dopasowanie zasila postęp, następny manewr i dystans do celu.

- Dla tras samochodowych, pieszych i rowerowych ponowne wyznaczanie rozpoczyna się, gdy confidence spadnie poniżej `0,25` przez co najmniej dwie sekundy, przy dokładności GPS nie gorszej niż 45 m i odległości od trasy większej niż `max(40 m, 1,5 × dokładność GPS)`. Między automatycznymi próbami musi minąć co najmniej 20 sekund. Słaby pomiar nie wywołuje pochopnego reroutingu.
- Przy przeliczeniu pozostają nieodwiedzone przystanki pośrednie i ładowania. Są wybierane, jeśli leżą ponad 50 m przed aktualnym postępem na poprzedniej geometrii, a następnie sortowane wzdłuż tej geometrii.
- Kafelki przepływu i zdarzeń TomTom Orbis rysują ruch w bieżącym widoku mapy. Podczas prowadzenia raster ustępuje miejsca trasie, a własne znaczniki pokazują dopasowane zdarzenia do 12 km przed kierowcą. Osobny pomiar Flow Segment Data opisuje drogę najbliższą GPS, a zdarzenia w promieniu około 3,5 km zasilają pobliskie znaczniki.
- `RouteTrafficMonitor` wybiera pozostały odcinek o horyzoncie do 25 minut, z limitem zależnym od średniej prędkości (18 km dla ruchu miejskiego, 35 km dla dróg krajowych i 100 km dla szybkich tras). Orbis pobiera zdarzenia z nakładających się zapytań wzdłuż korytarza trasy; geometria zdarzenia musi pasować do drogi w odległości do 140 m. Wyniki odświeżają ETA i wybór wariantu, a zamknięcia przed kierowcą uruchamiają trasę omijającą.
- Odświeżanie danych pobliskich odbywa się co 120 s poza nawigacją i co 60 s podczas jazdy. Dla zdarzeń do 10 km skraca się do 30 s, a dla zamknięcia do 3 km do 20 s. Po przeliczeniu trasy pobieranie korytarza rusza ponownie od razu.
- Aplikacja nie zapisuje feedu TomTom do kafli live traffic Valhalli. Wybór ruchowy działa na wariantach zwróconych przez skonfigurowany serwer; pełna optymalizacja drogi wymaga serwera Valhalla z aktualnymi kaflami ruchu.
- Automatyczny mechanizm „poza trasą” nie działa dla P+R. Połączenia MPK korzystają z osobnego śledzenia etapu podróży i danych realtime.

## Limity prędkości i ostrzeżenia drogowe

Przy samochodowej trasie NaviAstra pobiera z Overpass wybrane drogi z OSM, które niosą tagi limitu, oraz fotoradary i relacje kontroli. Żądanie obejmuje korytarz całej geometrii trasy i jest wykonywane po wyznaczeniu lub zmianie wariantu, a nie dla każdego pomiaru GPS. Odpowiedź jest zapisywana jako JSON w Application Support i może być ponownie użyta dla tej samej geometrii przez 24 godziny.

Podczas jazdy `RoadDataSnapshot` dopasowuje bieżącą pozycję do segmentów OSM według odległości i kursu. Obsługiwane są limity kierunkowe, liczbowe wartości km/h i mph oraz proste warunki dni tygodnia i przedziałów godzinowych z `maxspeed:conditional`. Dla polskich kontekstów prawnych OSM (`source:maxspeed`, `maxspeed:type`, `zone:traffic` lub stary zapis `maxspeed=PL:*`) koduje wybrane wartości domyślne. `PL:rural=100` wymaga oznaczonej drogi dwujezdniowej i co najmniej dwóch pasów na kierunek; `PL:expressway` rozróżnia drogę jedno- i dwujezdniową. Jeśli klasy drogi nie da się ustalić z tagów, silnik korzysta z Valhalli. Nieznane składnie warunkowe również nie są interpretowane jako pewny limit.

Znaczniki `highway=speed_camera` i członkowie relacji `type=enforcement` dla `average_speed` / `traffic_signals` są dopasowywani do geometrii trasy. Najbliższe ostrzeżenie pojawia się w panelu prędkości, punkty są widoczne na mapie, a głos prowadzenia ogłasza je w trzech odległościach. Dane oznaczane są jako OpenStreetMap. Bieżące zdarzenia, takie jak wypadki, remonty i korki, nadal pochodzą z skonfigurowanego TomTom Traffic.

Publiczny Overpass służy tu jako źródło prototypowe. Repozytorium nie zawiera własnego serwera importującego OSM ani bazy współdzielonej między instalacjami; `RoadDataProvider` jest granicą, przez którą można później podłączyć taki backend. Oficjalna strona CANARD opisuje mapę jako poglądową, a publiczna odpowiedź GITD informuje, że stos technologiczny mapy nie będzie upubliczniany. Nie znalazłem udokumentowanego interfejsu do pobierania tych obiektów, więc aplikacja nie pobiera z niej danych przez scraping. W tej wersji fotoradary pochodzą z OSM, więc aktualność zależy od kompletności mapy.

## Co wpływa na wynik, a czego aplikacja nie gwarantuje

Jakość tras drogowych zależy od danych i konfiguracji serwera Valhalla. Routing kolejowy i MPK dodatkowo wymaga dostępnego Valhalla Matrix i geometrii dla pieszych. Rozkład kolejowy zależy od krajowego GTFS i aktualizacji PKP PLK, a komunikacja MPK od GTFS/GTFS-Realtime Łodzi. P+R i ładowarki EV zależą od oznaczeń i metadanych OpenStreetMap. Aplikacja wymaga internetu do wyznaczania tras i nie ma trybu routingu offline.

Wyników nie należy interpretować jako gwarancji najkrótszej drogi, dostępności parkingu lub ładowarki ani rzeczywistego czasu przejazdu. Dla samochodu podstawowy wybór tras wykonuje Valhalla; dla pociągów i MPK stosowane są opisane powyżej heurystyki czasu jazdy, przesiadek i dojścia.

## Główne miejsca w kodzie

- `NaviAstra/Navigation/NavigationEngine.swift` — orkiestracja obliczeń, wybór dostawcy, EV, P+R, postęp i rerouting.
- `NaviAstra/Navigation/ValhallaRouteProvider.swift` — żądania `/route` i `/optimized_route`, preferencje i dekodowanie wyniku.
- `NaviAstra/Navigation/LodzTransitRouteProvider.swift` — pobieranie GTFS/GTFS-Realtime, wyszukiwanie przystanków, ranking i budowanie połączeń.
- `NaviAstra/Navigation/Models.swift` — tryby transportu, preferencje, modele tras i etapów podróży.
- `NaviAstra/Places/NearbyPlaceProvider.swift` — wyszukiwanie parkingów, P+R i ładowarek oraz odczyt ich metadanych OpenStreetMap.
- `NaviAstra/ContentView.swift` — prezentacja świeżości realtime, ustawień EV i postojów ładowania.
- `NaviAstra/Traffic/TrafficProvider.swift` — pobieranie danych TomTom o ruchu i zdarzeniach.
