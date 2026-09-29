# Komunikacja publiczna w NaviAstra

Planowanie tras, wyszukiwanie przystanków, tablice odjazdów i przystanki na mapie korzystają z API Transitous. Nie są ograniczone do Łodzi: działają wszędzie tam, gdzie Transitous ma odpowiednie dane. Zasięg i dostępność realtime zależą od poszczególnych feedów; aplikacja nie zakłada, że każdy przewoźnik lub region jest pokryty.

## Zakres funkcji

| Funkcja | Źródło | Zachowanie |
| --- | --- | --- |
| Planowanie Komunikacją | Transitous `/api/v6/plan` | Wysyła współrzędne początku, celu, czas oraz preferencje przesiadek. Odpowiedź API jest mapowana na etapy podróży używane przez podgląd i nawigację. |
| Planowanie P+R | Transitous `/api/v6/plan` | Po dojeździe do parkingu aplikacja wyznacza dalszy odcinek tym samym dostawcą. |
| Wyszukiwanie przystanków | Transitous `/api/v1/geocode` | Przeszukuje przystanki według nazwy i przekazuje bieżącą pozycję jako wskazówkę lokalizacji, gdy jest dostępna. Wyniki lokalnego indeksu kolejowego i MPK są scalane z odpowiedzią. |
| Przystanki mapy | Transitous `/api/v6/map/stops` | Pobiera przystanki dla aktualnego prostokąta mapy, gdy zbliżenie osiąga co najmniej 13. Zapytanie jest opóźnione o 350 ms po zmianie widoku i używa cache. |
| Tablica odjazdów i alerty | Transitous `/api/v6/stoptimes` | Dla wybranego przystanku pokazuje dostępne odjazdy, informacje realtime i komunikaty. |
| Przebieg kursu | Transitous `/api/v6/trip` | Pobiera kolejne przystanki oraz geometrię wybranego kursu, jeśli API ją udostępnia. |
| Rzeczywiste pozycje pojazdów | Lokalny feed GTFS-Realtime MPK Łódź | Dostępne tylko w zasięgu regionalnego feedu. Poza nim aplikacja nie pokazuje zmyślonych pozycji; trasy Transitous nadal działają niezależnie. |

## Przepływ danych

`AppDependencies.live()` tworzy `TransitousRouteProvider` dla planowania i `TransitousTransitDataProvider` dla wyszukiwania oraz szczegółów. Ten drugi łączy API Transitous z `LocalTransitDataProvider`: lokalne dane nadal uzupełniają wyszukiwanie linii i stacji, tablice dla lokalnych identyfikatorów oraz pozycje pojazdów MPK.

`TransitousMapper` przekształca itineraria API w model podróży aplikacji, a `TransitNavigationRouteMapper` zachowuje etapy, identyfikatory kursów i przystanków, czasy, geometrię oraz opóźnienia. Identyfikatory Transitous mają prefiks `transitous/`, aby nie pomylić ich z identyfikatorami lokalnych feedów. Szczegóły i tablice rozpoznają ten prefiks i odpytują właściwe źródło.

Renderery MapLibre na iOS i MapKit na macOS przekazują widoczne granice oraz poziom zbliżenia do `TransitStore`. Dane przystanków mapy łączą się z regionalnymi przystankami z feedu pojazdów, a powtórzone identyfikatory są usuwane.

## Cache i ograniczenia

- Odpowiedzi wyszukiwania przystanków i obszaru mapy są cache'owane przez 45 sekund; tablice odjazdów przez 12 sekund; wynik planowania przez 25 sekund.
- Przystanki mapy są pobierane dopiero po zbliżeniu do poziomu 13, aby ograniczyć liczbę znaczników i wielkość zapytania.
- Brak wyników z API oznacza brak danych dla zapytania lub chwilową niedostępność źródła. Nie jest zastępowany fikcyjnym rozkładem.
- Pozycje pojazdów są osobną funkcją i nadal zależą od istniejącego feedu MPK Łódź. Zasięg pobierania pozycji jest ograniczony do 100 km od centrum regionu zdefiniowanego przez `TransitRegion`.
- Realtime, odwołania i alerty są dostępne tylko wtedy, gdy źródło Transitous dostarcza je dla danego kursu lub przystanku.

## Prywatność i źródła

Żądanie trasy przekazuje Transitous współrzędne początku i celu oraz wybrany czas. Wyszukiwanie przystanków wysyła tekst zapytania i, jeśli dostępna, pozycję używaną do rankingu wyników. Odsłonięcie obszaru mapy wysyła jego granice. Odczyt tablicy lub szczegółów kursu przekazuje identyfikator wybranego przystanku albo kursu.

Publiczny kontakt dla nagłówka `User-Agent` można ustawić w Ustawieniach. Szczegóły zasad oraz aktualną listę feedów opisują [zasady API Transitous](https://transitous.org/api/) i [źródła danych Transitous](https://transitous.org/sources/). Zasięg należy rozumieć jako regiony faktycznie obsługiwane przez te feedy.

## Główne miejsca w kodzie

- `NaviAstra/App/AppDependencies.swift` — wybór dostawców dla działającej aplikacji.
- `NaviAstra/Transit/Transitous/TransitousRouteProvider.swift` — planowanie tras przez Transitous.
- `NaviAstra/Transit/Transitous/TransitousTransitDataProvider.swift` — łączenie globalnych danych Transitous z lokalnym feedem MPK.
- `NaviAstra/Transit/Transitous/TransitousClient.swift` — żądania API oraz cache.
- `NaviAstra/Transit/Transitous/TransitousMapper.swift` — mapowanie itinerariów i kursów.
- `NaviAstra/Transit/TransitStore.swift` — stan szczegółów oraz opóźnione pobieranie przystanków mapy.
- `NaviAstra/Maps/MapLibreView.swift` i `NaviAstra/Maps/MacMapView.swift` — granice widocznego obszaru na iOS i macOS.
- `NaviAstra/Transit/TransitRepository+Queries.swift` — lokalne wyszukiwanie, rozkłady i pozycje MPK.
