# Jak NaviAstra wyznacza trasę

Ten dokument opisuje bieżącą implementację routingu. Głównym koordynatorem jest `NavigationSession`; dostawcy obliczają trasy drogowe oraz połączenia komunikacją publiczną. Mapa prezentuje otrzymaną geometrię i widoczne przystanki.

## W skrócie

- Początek trasy to ostatnia zaakceptowana pozycja GPS. Cel pochodzi z wyszukiwania, mapy albo wybranego miejsca.
- Wybrany tryb transportu decyduje o silniku: Valhalla dla samochodu, marszu i roweru; Transitous dla komunikacji publicznej i jej odcinka w P+R.
- Dla tras drogowych warianty zwraca serwer Valhalla. Podczas nawigacji TomTom może zmienić wybór na szybszy z już zwróconych wariantów; serwer Valhalla nadal dostarcza geometrię i podstawowe czasy.
- Transitous wyznacza połączenia w regionach objętych jego feedami. Pokrycie zależy od dostępnych danych, a rzeczywiste pozycje pojazdów są obecnie dostępne wyłącznie z feedu MPK Łódź.
- Dane TomTom wpływają na pozostały czas i wybór wśród wariantów Valhalli. Zdarzenie zamknięcia jest rozpoznawane po polu kategorii, a nie po tekście opisu.

## Przebieg obliczenia

1. `NavigationSession.planRoute()` wymaga wybranego celu i pozycji GPS. Gdy nie ma zaakceptowanej pozycji, nie zaczyna obliczeń.
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

Odpowiedź może więc zawierać trasę podstawową i do dwóch alternatyw. Dostawca dekoduje geometrię polyline6, instrukcje manewrów, dystans i czas z podsumowania Valhalli. W podglądzie `NavigationSession` domyślnie wybiera `routes.first`, zachowując kolejność serwera; użytkownik może wybrać inny zwrócony wariant. W trakcie jazdy TomTom może zmienić wybrany wariant po porównaniu opóźnień i zamknięć na tych trasach.

Dla wybranego POI `POIAccessResolver` przed żądaniem trasy pobiera z Overpass parkingi, główne wejścia i drogi do 250 m od miejsca. Samochód dostaje najlepiej powiązany punkt drogi serwisowej wewnątrz parkingu, a pieszy, rowerzysta i transport publiczny — `entrance=main`, gdy taki punkt jest opisany; w przeciwnym razie resolver wybiera najbliższą drogę dostępną dla danego trybu. P+R używa wejścia do końcowego dojścia pieszego oraz osobnego celu samochodowego do obliczenia odcinka bazowego. Ocena parkingu uwzględnia geometrię budynku, odległość od głównego wejścia, zgodność nazwy/marki i dostęp dla klientów; wjazdy prywatne i strefy dostaw są pomijane. Wybrany punkt i poziom pewności są osobne od współrzędnych POI używanych do etykiety i karty miejsca. Jeśli OSM nie zwróci wiarygodnego punktu albo Overpass jest niedostępny, NaviAstra kontynuuje trasę, wysyłając do Valhalli oryginalną współrzędną POI; Valhalla może wtedy przypiąć cel do pobliskiej krawędzi sieci drogowej, co nie zawsze wskaże właściwy parking lub wejście. Wynik resolvera jest cache'owany lokalnie przez 6 godzin.

### Ścieżki rowerowe na mapie

Menu warstw mapy włącza dodatkową warstwę geometrii z OpenStreetMap. Skonfigurowany serwer Overpass dostaje zapytanie tylko dla zbliżonego widoku mapy. Warstwa obejmuje osobne drogi `highway=cycleway` i ścieżki `highway=path` oznaczone `bicycle=designated`; nie wyciąga osobnych linii z tagów pasa `cycleway=*` na jezdni. Wyniki są cache'owane w pamięci przez 30 minut i usuwane przy wyłączeniu warstwy lub oddaleniu poza obsługiwany zakres. Aby utrzymać rendering responsywnym, pokazuje najwyżej 3000 odcinków z jednego zapytania; menu sygnalizuje, gdy lista została ograniczona, i pokazuje osobne stany ładowania, pustego wyniku, zbyt małego zbliżenia oraz niedostępności API. Atrybucja prowadzi do strony praw autorskich OpenStreetMap.

Warstwa opisuje infrastrukturę z OSM, a nie wyznaczoną trasę. Trasę rowerową nadal oblicza skonfigurowany serwer Valhalla z profilem `bicycle`, wykorzystując swój graf i reguły dostępu. Widoczne ścieżki mogą być niekompletne lub nieaktualne, a publiczny Overpass może być niedostępny albo limitować zapytania.

Domyślny publiczny host `valhalla1.openstreetmap.de` jest objęty lokalną bramką, która przepuszcza najwyżej jedno żądanie co 1,1 sekundy; równoległe zadania aplikacji nadal czekają w tej bramce. Własny adres HTTPS można ustawić w sekcji „Serwer Valhalla” w ustawieniach. Dla innego hosta klient nie dodaje tego odstępu, więc jego wydajność zależy od zasobów i limitów skonfigurowanej instancji.

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

## Komunikacja publiczna

Szczegóły źródeł, endpointów, wyszukiwania, tablic odjazdów, danych mapy, cache i ograniczeń zasięgu opisuje [docs/TRANSIT_ROUTING.md](TRANSIT_ROUTING.md). W skrócie: `TransitousRouteProvider` planuje podróż dla współrzędnych GPS i celu, a `TransitousTransitDataProvider` obsługuje wyszukiwanie przystanków, rozkłady, alerty i przystanki mapy. Działa to w regionach objętych Transitous; Łódź nie jest granicą planowania.

Lokalne indeksy GTFS pozostają źródłem uzupełniającego wyszukiwania i lokalnych szczegółów. Feed pozycji pojazdów MPK jest niezależny od globalnego routingu i ograniczony do jego zasięgu. Aplikacja nie wyświetla pozycji pojazdu tam, gdzie nie ma odpowiedniego feedu.

## P+R

Tryb P+R łączy trasę samochodem do parkingu i dalszą podróż komunikacją publiczną:

1. Valhalla liczy bazową trasę samochodową do celu. OpenStreetMap/Overpass wyszukuje parkingi w korytarzu ostatnich 40 km trasy oraz w promieniu 15 km od celu. Kandydaci muszą mieć tag `amenity=parking` i `park_ride=yes`.
2. Dla maksymalnie dwunastu kandydatów Valhalla liczy trasę samochodową. Używany jest pierwszy wariant samochodowy.
3. Transitous szuka połączenia z parkingu do celu, z czasem odjazdu ustawionym na przewidywany przyjazd samochodem.
4. Wyniki są sortowane według łącznego kosztu jazdy, chodzenia, oczekiwania i przesiadek; zwracane są maksymalnie trzy warianty.

Wynik zawiera odcinek samochodowy oraz odcinki piesze i komunikacyjne z Transitous. Dostępność parkingu, wolnych miejsc ani czas parkowania nie są sprawdzane. W trybie P+R automatyczne przeliczanie po zejściu z geometrii trasy jest wyłączone.

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

Przy samochodowej trasie NaviAstra pobiera z Overpass wybrane drogi z OSM, które niosą tagi limitu, fotoradary i relacje kontroli, a także oznaczone w OSM znaki drogowe, znaki STOP/ustąp pierwszeństwa i przejazdy kolejowe. Żądanie obejmuje korytarz całej geometrii trasy i jest wykonywane po wyznaczeniu lub zmianie wariantu, a nie dla każdego pomiaru GPS. Odpowiedź jest zapisywana jako JSON w Application Support i może być ponownie użyta dla tej samej geometrii przez 24 godziny.

Podczas jazdy `RoadDataSnapshot` dopasowuje bieżącą pozycję do segmentów OSM według odległości i kursu. Obsługiwane są limity kierunkowe, liczbowe wartości km/h i mph oraz proste warunki dni tygodnia i przedziałów godzinowych z `maxspeed:conditional`. Dla polskich kontekstów prawnych OSM (`source:maxspeed`, `maxspeed:type`, `zone:traffic` lub stary zapis `maxspeed=PL:*`) koduje wybrane wartości domyślne. `PL:rural=100` wymaga oznaczonej drogi dwujezdniowej i co najmniej dwóch pasów na kierunek; `PL:expressway` rozróżnia drogę jedno- i dwujezdniową. Jeśli klasy drogi nie da się ustalić z tagów, silnik korzysta z Valhalli. Nieznane składnie warunkowe również nie są interpretowane jako pewny limit.

Znaczniki `highway=speed_camera`, członkowie relacji `type=enforcement` dla `average_speed` / `traffic_signals` oraz węzły `traffic_sign`, `highway=stop`, `highway=give_way` i `railway=level_crossing` są dopasowywani do geometrii trasy. Znaki są pokazywane jako osobne POI w korytarzu do 45 m od trasy; pozostałe alerty zachowują dotychczasowy zasięg dopasowania. Obejmuje to m.in. B-20, A-7, B-2, B-5, B-16, B-18, B-25, B-33/B-34, B-43/B-44 oraz D-40–D-43. Znaki na mapach iOS/macOS rysuje wspólny wektorowy `RoadSignView`: STOP ma ośmiokąt, ustąp pierwszeństwa trójkąt, zakazy i limity czerwony pierścień, a znaki strefowe prostokątną tablicę. Wartości ograniczeń są rysowane wyłącznie wtedy, gdy poda je OSM; jednostki tonażu i wysokości są normalizowane do `t` i `m`. Wybór zachowuje standardowe barwy znaku, dodaje cyanowy obrys i powiększa go o 1,15×. Podczas nawigacji znaki rosną do 28–32 pt. Gdy kilka zdarzeń nakłada się przy małym zoomie, widoczny zostaje znak o najwyższym priorytecie z plakietką `+N`, zamiast samej liczby. Znaki z tagiem `traffic_sign:forward` lub `traffic_sign:backward` są przygaszone do 66%, bo same węzły Overpass nie wystarczają do bezpiecznego ustalenia kierunku względem trasy. Wybór znacznika pokazuje opis, kod znaku, odległość i źródło OSM. Te POI są informacją wizualną i nie są automatycznie ogłaszane przez głos.

Najbliższe ostrzeżenie pojawia się również w panelu prędkości, a istniejące kamery i relacje kontroli są ogłaszane przez głos w trzech odległościach. Dane oznaczane są jako OpenStreetMap. Bieżące zdarzenia, takie jak wypadki, remonty i korki, nadal pochodzą z skonfigurowanego TomTom Traffic. Nie podłączono Mapillary; znaki są dostępne tylko wtedy, gdy zostały opisane w OSM.

Publiczny Overpass służy tu jako źródło prototypowe. Repozytorium nie zawiera własnego serwera importującego OSM ani bazy współdzielonej między instalacjami; `RoadDataProvider` jest granicą, przez którą można później podłączyć taki backend. Oficjalna strona CANARD opisuje mapę jako poglądową, a publiczna odpowiedź GITD informuje, że stos technologiczny mapy nie będzie upubliczniany. Nie znalazłem udokumentowanego interfejsu do pobierania tych obiektów, więc aplikacja nie pobiera z niej danych przez scraping. W tej wersji fotoradary pochodzą z OSM, więc aktualność zależy od kompletności mapy.

## Co wpływa na wynik, a czego aplikacja nie gwarantuje

Jakość tras drogowych zależy od danych i konfiguracji serwera Valhalla. Routing komunikacją publiczną zależy od pokrycia, dostępności oraz aktualności danych Transitous. Rzeczywiste pozycje pojazdów zależą od feedu MPK Łódź. P+R i ładowarki EV zależą od oznaczeń i metadanych OpenStreetMap. Aplikacja wymaga internetu do wyznaczania tras i nie ma trybu routingu offline.

Wyników nie należy interpretować jako gwarancji najkrótszej drogi, dostępności parkingu lub ładowarki ani rzeczywistego czasu przejazdu. Dla samochodu podstawowy wybór tras wykonuje Valhalla; połączenia komunikacyjne i ich czasy zależą od danych i wyniku API Transitous.

## Główne miejsca w kodzie

- `NaviAstra/Navigation/NavigationSession.swift` — stan sesji i cykl życia; rozszerzenia `NavigationSession+Routing.swift`, `NavigationSession+Progress.swift` i `NavigationSession+Traffic.swift` obsługują trasę, postęp, ruch i rerouting.
- `NaviAstra/Navigation/ValhallaRouteProvider.swift` — żądania `/route` i `/optimized_route`, preferencje i dekodowanie wyniku.
- `NaviAstra/Transit/Transitous/TransitousRouteProvider.swift` i `TransitousClient.swift` — planowanie połączeń przez Transitous.
- `NaviAstra/Navigation/Models.swift` — tryby transportu, preferencje, modele tras i etapów podróży.
- `NaviAstra/Places/NearbyPlaceProvider.swift` — wyszukiwanie parkingów, P+R i ładowarek oraz odczyt ich metadanych OpenStreetMap.
- `NaviAstra/Navigation/UI/ContentView+RoutePreview.swift` i `ContentView+Journey.swift` — ustawienia EV, postoje i podsumowanie aktywnej podróży.
- `NaviAstra/Traffic/TrafficProvider.swift` — pobieranie danych TomTom o ruchu i zdarzeniach.
