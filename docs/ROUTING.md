# Jak NaviAstra wyznacza trasę

Ten dokument opisuje bieżącą implementację routingu. Głównym koordynatorem jest `NavigationEngine`; osobni dostawcy obliczają trasy drogowe i połączenia MPK. Mapa tylko prezentuje otrzymaną geometrię — nie wyszukuje samodzielnie dróg.

## W skrócie

- Początek trasy to ostatnia zaakceptowana pozycja GPS. Cel pochodzi z wyszukiwania, mapy albo wybranego miejsca.
- Wybrany tryb transportu decyduje o silniku: Valhalla dla samochodu, marszu i roweru; lokalny planer GTFS dla komunikacji miejskiej; połączenie obu silników dla P+R.
- Dla tras drogowych domyślny wariant i alternatywy zwraca serwer Valhalla. Aplikacja wyświetla pierwszy wariant jako wybrany i zachowuje kolejność serwera.
- Dla MPK NaviAstra sama tworzy kandydatów na podstawie rozkładu GTFS i sortuje ich według czasu przyjazdu z dodatkową karą za dojście pieszo.
- Dane o ruchu wpływają na szacowany czas pozostały do celu. Zgłoszone zamknięcie może uruchomić dodatkowe przeliczenie trasy samochodowej z ominięciem punktu zdarzenia.

## Przebieg obliczenia

1. `NavigationEngine.planRoute()` wymaga wybranego celu i pozycji GPS. Gdy nie ma zaakceptowanej pozycji, nie zaczyna obliczeń.
2. `preview()` bierze bieżące współrzędne GPS jako początek, ustawia status obliczania i wywołuje `calculateRoutes()`.
3. `calculateRoutes()` przekazuje żądanie do dostawcy zależnie od trybu podróży.
4. Po otrzymaniu niepustej listy tras pierwszy element staje się trasą wybraną, a cała lista pozostaje dostępna jako warianty.
5. Zmiana celu, przystanku pośredniego albo trybu wywołuje kolejne obliczenie. Identyfikator żądania zapobiega nadpisaniu nowszego podglądu spóźnioną odpowiedzią.

Pozycje GPS przechodzą przez `LocationFilter`. Akceptowane są pomiary z dokładnością poziomą do 70 m, nie starsze niż 15 sekund ani pochodzące z przyszłości o więcej niż 15 sekund. Kolejny pomiar musi mieć późniejszy czas; odrzucany jest też skok oznaczający prędkość większą niż 75 m/s. Dopiero zaakceptowany pomiar aktualizuje początek trasy i postęp nawigacji.

## Trasy samochodem, pieszo i rowerem

`ValhallaRouteProvider` wysyła żądanie HTTPS `POST /route`. Przekazuje:

- współrzędne początku, celu oraz przystanków pośrednich w podanej kolejności;
- profil kosztowania: `auto`, `pedestrian` albo `bicycle`;
- jednostki kilometrów, język instrukcji `pl-PL` oraz prośbę o dwie alternatywy.

Odpowiedź może więc zawierać trasę podstawową i do dwóch alternatyw. Dostawca dekoduje geometrię polyline6, instrukcje manewrów, dystans i czas z podsumowania Valhalli. Nie sortuje później tras według dystansu lub czasu. `NavigationEngine` wybiera `routes.first`, więc kryteria samego wyboru podstawowej trasy wynikają z profilu i danych skonfigurowanego serwera Valhalla. Użytkownik może wybrać inny zwrócony wariant w podglądzie.

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

## Komunikacja miejska MPK Łódź

`LodzTransitRouteProvider` nie odpytuje Valhalli o trasę komunikacją. `LodzTransitRepository` pobiera statyczny rozkład GTFS oraz feedy GTFS-Realtime z otwartych danych miasta Łódź. Baza GTFS jest przechowywana w cache; jej ponowne załadowanie z cache jest oznaczane w wyniku. Realtime jest buforowany na krótko, a aktualizacje starsze niż pięć minut lub zbyt daleko w przyszłości są uznawane za nieświeże. Obowiązywanie kursów jest liczone według kalendarza `Europe/Warsaw`, z uwzględnieniem wyjątków kalendarza GTFS.

### Wybór połączeń

Planer stosuje następujące ograniczenia i kryteria:

- Dla początku i celu bierze do ośmiu najbliższych obsługiwanych przystanków, maksymalnie 1,5 km od każdego punktu.
- Odległość dojścia liczy po prostej i przelicza ze stałą prędkością 1,35 m/s. Geometria tych dojść także jest prostym odcinkiem, a nie trasą pieszą po chodnikach.
- Rozpatruje kursy w oknie do 18 godzin i szuka podróży składających się z jednego do czterech przejazdów pojazdem.
- Przy standardowym planowaniu żądany czas odjazdu to bieżąca chwila. Interfejs silnika przyjmuje też inny czas, ale `NavigationEngine` przekazuje `Date()`.
- Przy przesiadce wymaga co najmniej 60 sekund między przyjazdem poprzedniego kursu a odjazdem następnego. Pierwsze wejście do pojazdu nie ma dodanego osobnego bufora na dojście po peronie czy zakup biletu.
- Przesiadka jest możliwa na tym samym identyfikatorze przystanku GTFS. Planer nie tworzy dodatkowych połączeń pieszych między osobnymi, choćby bliskimi, przystankami.
- Uwzględnia aktualizacje czasu przejazdu i odwołane kursy z realtime, jeśli feed jest dostępny. Bez aktualizacji używa godzin rozkładowych. Komunikaty są dołączane do tras, których linii lub przystanków dotyczą.
- Aby ograniczyć liczbę sprawdzanych kursów, na każdym wzorcu trasy bierze maksymalnie dwa odjazdy i analizuje maksymalnie 48 odjazdów na przystanek w danej warstwie wyszukiwania.

Kandydaci są sortowani według:

```text
czas przyjazdu do celu + 0,75 × łączny czas dojścia pieszego
```

Czas przyjazdu zawiera już dojście, więc dodatkowy składnik oznacza, że dojście jest silniej karane niż sam czas przejazdu i oczekiwania. Planer usuwa duplikaty oparte na linii, przystankach wejścia/wyjścia i czasie odjazdu, a następnie zwraca maksymalnie trzy pierwsze połączenia. Nie dodaje osobnego punktowego bonusu za mniejszą liczbę przesiadek.

Kształt odcinka pojazdu pochodzi z kształtu GTFS, jeśli jest dostępny; w przeciwnym razie geometrię odtwarza z pozycji przystanków. Planer działa w zakresie przystanków MPK Łódź i najbliższych okolic. Brak przystanków w zasięgu lub brak osiągalnego połączenia kończy się błędem, a nie trasą zastępczą.

## P+R

Tryb P+R łączy trasę samochodem do parkingu i dalszą podróż MPK:

1. OpenStreetMap/Overpass wyszukuje oznaczone parkingi P+R w promieniu 20 km od początku. Kandydaci muszą mieć tag `amenity=parking` i `park_ride=yes`.
2. Dla maksymalnie ośmiu najbliższych kandydatów Valhalla liczy trasę samochodową. Używany jest pierwszy wariant samochodowy.
3. Planer MPK szuka połączenia z parkingu do celu, z czasem odjazdu ustawionym na przewidywany przyjazd samochodem.
4. Wyniki są sortowane po łącznym przewidywanym czasie i zwracane są maksymalnie trzy warianty.

Wynik zawiera odcinek samochodowy oraz odcinki piesze i komunikacyjne z planera MPK. Dostępność parkingu, wolnych miejsc ani czas parkowania nie są sprawdzane. W trybie P+R automatyczne przeliczanie po zejściu z geometrii trasy jest wyłączone.

## Planowanie ładowania EV

Planowanie EV jest rozszerzeniem samochodowego routingu Valhalli i działa tylko wtedy, gdy wybrany serwer obsługuje zaawansowany interfejs routingu.

1. Z ustawionego zasięgu przy pełnej baterii i poziomu baterii liczony jest aktualny zasięg. Brak dodatniego zasięgu zgłasza błąd.
2. Najpierw liczona jest bazowa trasa z ręcznie dodanymi przystankami. Jeśli jej dystans nie przekracza 80% aktualnego zasięgu, ładowarki nie są dodawane.
3. W przeciwnym razie aplikacja szuka w OpenStreetMap ładowarek (`amenity=charging_station`) w korytarzu do 1,2 km od geometrii trasy.
4. Wybiera kolejną ładowarkę możliwie daleko na trasie, ale nie dalej niż 68% bieżącego zasięgu. Pierwsza ładowarka musi być ponad 300 m od początku odcinka; dla kolejnych używany jest pełny zasięg.
5. Poszukiwanie kończy się, gdy do celu pozostaje nie więcej niż 80% zasięgu danego odcinka. Wybrane ładowarki i ręczne przystanki są porządkowane wzdłuż trasy, a Valhalla liczy trasę końcową. Limit to dziesięć ładowarek.

To przybliżenie oparte na dystansie geometrii trasy i obecności obiektów OSM. Kod nie uwzględnia mocy ładowarki, czasu potrzebnego na ładowanie, dostępności złącza, bieżącego działania stacji, zużycia energii zależnego od prędkości, przewyższeń, pogody ani rezerwy innej niż wskazany próg 80%. Podawany czas trasy nie dolicza postoju na ładowanie. Brak odpowiednich punktów kończy planowanie błędem zamiast udawać, że zasięg wystarczy.

## Postęp, ruch i ponowne wyznaczanie

Podczas nawigacji aplikacja dopasowuje pozycję GPS do najbliższego odcinka geometrii trasy (`MapMatcher`) i na tej podstawie oblicza postęp, następny manewr i dystans do celu.

- Dla tras samochodowych, pieszych i rowerowych ponowne wyznaczanie rozpoczyna się po trzech kolejnych zaakceptowanych pomiarach poza trasą o więcej niż `max(40 m, 2 × dokładność GPS)`. Między automatycznymi próbami musi minąć co najmniej 20 sekund.
- Przy przeliczeniu pozostają nieodwiedzone przystanki pośrednie i ładowania. Są wybierane, jeśli leżą ponad 50 m przed aktualnym postępem na poprzedniej geometrii, a następnie sortowane wzdłuż tej geometrii.
- Dane TomTom o przepływie drogowym służą do prezentacji sytuacji na drodze. Opóźnienia zgłoszonych zdarzeń leżących przed użytkownikiem są dodawane do pozostałego czasu, z limitem 30 minut.
- Dla samochodu opis zdarzenia zawierający `zamkn`, `closed` albo `closure`, położone 100 m–10 km przed użytkownikiem, może uruchomić dodatkowe zapytanie do Valhalli z punktem do ominięcia. To nie jest ogólna optymalizacja trasy na podstawie całego natężenia ruchu.
- Automatyczny mechanizm „poza trasą” nie działa dla P+R. Połączenia MPK korzystają z osobnego śledzenia etapu podróży i danych realtime.

## Co wpływa na wynik, a czego aplikacja nie gwarantuje

Jakość tras drogowych zależy od danych drogowych i konfiguracji wybranego serwera Valhalla. Jakość MPK zależy od aktualności i kompletności GTFS/GTFS-Realtime miasta. P+R i EV zależą dodatkowo od oznaczeń obiektów w OpenStreetMap. Aplikacja wymaga internetu do wyznaczania tras i nie ma trybu routingu offline.

Wyników nie należy interpretować jako gwarancji najkrótszej drogi, dostępności parkingu lub ładowarki ani rzeczywistego czasu przejazdu. Dla samochodu podstawowy wybór tras wykonuje Valhalla; dla MPK stosowane są opisane powyżej heurystyki czasu i dojścia.

## Główne miejsca w kodzie

- `NaviAstra/Navigation/NavigationEngine.swift` — orkiestracja obliczeń, wybór dostawcy, EV, P+R, postęp i rerouting.
- `NaviAstra/Navigation/ValhallaRouteProvider.swift` — żądania `/route` i `/optimized_route`, preferencje i dekodowanie wyniku.
- `NaviAstra/Navigation/LodzTransitRouteProvider.swift` — pobieranie GTFS/GTFS-Realtime, wyszukiwanie przystanków, ranking i budowanie połączeń.
- `NaviAstra/Navigation/Models.swift` — tryby transportu, preferencje, modele tras i etapów podróży.
- `NaviAstra/Places/NearbyPlaceProvider.swift` — wyszukiwanie parkingów, P+R i ładowarek w OpenStreetMap.
- `NaviAstra/Traffic/TrafficProvider.swift` — pobieranie danych TomTom o ruchu i zdarzeniach.
