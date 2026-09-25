# Jak NaviAstra wyznacza trasę komunikacją miejską

Ten dokument opisuje implementację trybu **Komunikacja** w NaviAstra: od pozycji GPS i celu, przez wybór przystanków oraz kursów z GTFS, aż po gotowy wariant podróży. Kod źródłowy jest nadrzędny wobec tego opisu; szczegóły serwisów, formatów i ograniczeń mogą się zmieniać wraz z feedami i konfiguracją serwera.

## Zakres

Planer łączy dwie sieci rozkładowe:

- **Łódź:** GTFS miejskiej komunikacji MPK, w tym autobusy i tramwaje; aplikacja pobiera też miejskie aktualizacje GTFS-Realtime.
- **Kolej w Polsce:** krajowy feed GTFS używany do planowania przejazdów kolejowych. Identyfikatory jego obiektów dostają prefiks `rail/`, żeby odróżnić je od identyfikatorów feedu MPK.

Zależnie od położenia początku i celu wynik może składać się z samego MPK, z pociągu albo z pociągu połączonego z MPK. Dojścia, dojścia do przesiadek oraz dojście końcowe są piesze. To nie jest ogólnopolski planer autobusów i tramwajów: miejska sieć w tej implementacji pochodzi z feedu Łodzi.

P+R jest osobnym trybem `P+R`. Łączy trasę samochodową do parkingu z planem komunikacji publicznej obliczonym przez tego samego dostawcę; nie jest częścią trybu Komunikacja.

## Składniki

| Składnik | Rola |
| --- | --- |
| `NavigationEngine` | Wymaga pozycji i celu, przekazuje bieżący czas odjazdu, publikuje postęp planowania i udostępnia podgląd trasy. |
| `LodzTransitRouteProvider` | Publiczna fasada dostawcy używana przez silnik nawigacji i widoki transportu. |
| `LodzTransitRepository` | Współdzielony aktor koordynujący GTFS, realtime, cache i usługi piesze. Ciężkie wyszukiwanie wykonuje poza aktorem. |
| `TransitGTFSLoader` / `GTFSDatabase` | Czytają archiwa GTFS i budują indeksy tras, wzorców kursowania, przystanków, kalendarzy, kształtów oraz transferów pieszych. |
| `TransitSnapshot` | Niezmienna migawka rozkładu i realtime dla jednego żądania, z bitsetami aktywnych kursów dla dni w oknie. |
| `ValhallaRouteProvider` | Oblicza macierz dojść pieszych (`/sources_to_targets`) i, gdy trzeba, szczegółową geometrię dojścia (`/route`). |
| `NavigationRoute` / `Journey` / `JourneyLeg` | Przenoszą geometrię całej podróży, czasy, etapy, przystanki, przesiadki i status źródeł realtime do interfejsu. |

## Przepływ od żądania do wariantów

1. **Początek, cel i czas podróży.** `NavigationEngine.preview()` używa ostatniej zaakceptowanej pozycji GPS jako początku i wymaga wybranego celu. Bez pozycji zgłasza błąd zamiast zgadywać początek. Tryb czasu może użyć bieżącej chwili, wskazanego odjazdu albo — dla komunikacji — wskazanego terminu przyjazdu.
2. **Rozkłady statyczne.** Repozytorium sprawdza najpierw indeks GTFS w pamięci, potem binarny indeks plist na urządzeniu. Jeśli oba są nieaktualne lub nieprawidłowe, pobiera archiwum miejskie i opcjonalnie archiwum kolejowe, a następnie buduje indeks.
3. **Przystanki dostępne pieszo.** Indeks przestrzenny wybiera pobliskie przystanki. Dla początku i celu powstają wstępne czasy dojścia z oszacowania `odległość × 1,5 / 0,9 m/s`; na tym etapie nie ma żądania do Valhalli. Pobranie realtime trwa równolegle.
4. **Wyszukiwanie wstępne.** Niezmienna migawka powstaje poza aktorem. RAPTOR skanuje tylko wzorce tras dotykające oznaczonych przystanków, a wyszukiwanie binarne znajduje pierwszy odjazd, na który można zdążyć. Planer sprawdza kolejno okna 2, 6 i maksymalnie 18 godzin.
5. **Dokładne dojścia.** Spośród maksymalnie 15 kandydatów zbierane są oddzielnie przystanki początkowe i końcowe. Dopiero dla nich Valhalla wyznacza macierze piesze; następnie RAPTOR ponownie liczy trasy z dokładnymi czasami.
6. **Geometria i walidacja.** Valhalla uzupełnia transfery. Planer ponownie sprawdza, czy dojścia mieszczą się między kursami, odrzuca niewykonalne połączenia i szereguje pozostałe także według zapasu na przesiadkę.
7. **Gotowy podgląd.** Po zakończeniu uzupełniania geometrii można wybrać wariant i rozpocząć nawigację. W trakcie uzupełniania wybór oraz przycisk rozpoczęcia są zablokowane.

Silnik nadaje żądaniom generację. Spóźniona odpowiedź z wcześniejszego planowania nie powinna nadpisać podglądu po zmianie celu lub trybu.

W trybie **Przyjazd na…** silnik wykonuje do 10 wyszukiwań dla różnych chwil odjazdu w 18-godzinnym przedziale przed terminem, zawężając przedział do minut. Zostawia najpóźniejszy kurs, który przyjeżdża przed terminem. Tryb ten jest dostępny dla komunikacji miejskiej; P+R obsługuje bieżący czas i wskazany odjazd.

## Feed GTFS, indeks i czas usługi

### Pobieranie i cache

- Adresy źródeł są zapisane w `LodzTransitRepository`: osobne archiwa GTFS dla Łodzi i kolei, miejskie feedy aktualizacji kursów, komunikatów i pozycji pojazdów oraz feed kolejowych aktualizacji czasu.
- Archiwum GTFS jest uznawane za świeże przez 24 godziny. Gdy świeże pobranie się nie powiedzie, aplikacja może użyć poprawnego archiwum zapisanego wcześniej — także starszego niż 24 godziny.
- Sparsowany indeks jest przechowywany jako binarny plist z numerem wersji schematu i wczytywany przez mapowane `Data`. Może być użyty, jeśli jest młodszy niż 24 godziny i zawiera przystanki oraz kursy. Nowy indeks jest zapisywany w tle.
- Obok indeksu głównego jest płaski indeks numerów usług przypisanych do kursów. Ma wersję i fingerprint feedu, jest otwierany przez mapowane `Data` i odrzucany, jeśli nie pasuje do aktualnego feedu.
- Graf transferów GTFS ma osobny trwały cache binarny. Jest używany przez 30 dni tylko wtedy, gdy fingerprint archiwów feedu jest zgodny; zmieniony feed wymusza ponowne zbudowanie grafu.
- Cache dokładnych geometrii pieszych jest trwały, rozdzielony według endpointu Valhalli i kierunku przejścia. Przechowuje do 5 000 geometrii przez 30 dni. Cache dokładnych czasów dojścia dla obszaru GPS i przystanku służy tylko wstępnemu przybliżeniu, ma limit 10 000 wpisów i TTL 6 godzin.
- Współdzielony `LodzTransitRepository` scala równoległe żądania ładowania. Odczyt i zapis cache pieszych działa w zadaniach pomocniczych; błąd zapisu nie blokuje planowania.
- Brak krajowego feedu kolejowego nie uniemożliwia zbudowania feedu MPK. Oznacza natomiast, że trasa kolejowa nie może być obliczona; jeśli nie ma dostępnego rozkładu lokalnego, użytkownik otrzymuje błąd pobrania.

Ładowanie kursu respektuje `calendar.txt` i wyjątki `calendar_dates.txt`. Kalendarz planowania ma strefę `Europe/Warsaw`. Sprawdzane są również kursy z poprzedniego dnia usługi, co pozwala obsłużyć rozkładowe godziny po północy (np. `25:10:00`).

## Dobór przystanków i dojść

Dla początku i celu planer bierze przystanki obsługiwane przez kursy, które leżą nie dalej niż 10 km w linii prostej. Indeks przestrzenny zwraca pobliskie punkty, a kandydatów MPK i kolei limituje osobno — maksymalnie 80 lokalnych oraz 40 kolejowych, aby gęsta sieć miejska nie wyparła stacji kolejowej.

Pierwszy przebieg używa oszacowania `odległość w linii prostej × 1,5 / 0,9 m/s` i limitu 30 minut. To przybliżenie służy tylko do przeszukania rozkładu. Po wstępnym wyszukaniu Valhalla dostaje osobne macierze dla przystanków początkowych i końcowych użytych w kandydujących trasach. Żądanie HTTPS `POST /sources_to_targets` używa profilu `pedestrian`, macierze są dzielone na porcje do 20 celów, a plan jest liczony ponownie z dokładnymi czasami dojścia.

Macierz może od razu dostarczyć czas, dystans i geometrię. Brak geometrii w odpowiedzi nie unieważnia czasu: na tym etapie odcinek może być przedstawiony linią między punktami, a pobranie dokładnego przebiegu następuje później.

### Awaria macierzy pieszej

Jeśli żądanie macierzy nie powiedzie się, planer nie wysyła osobnego zapytania dla każdego przystanku. Zachowuje użyteczne wyniki z cache lub z ukończonej części pracy i dla ograniczonej puli najbliższych kandydatów może oszacować brakujące dojście:

```text
szacowany dystans = odległość w linii prostej × 1,5
szacowany czas = szacowany dystans ÷ 0,9 m/s
```

Przybliżenie nadal musi zmieścić się w limicie 30 minut. Wybór obejmuje maksymalnie 12 kandydatów MPK i 8 kolejowych, preferując bliższe punkty. Takie czasy są oznaczone w modelu i interfejsie jako szacunkowe. Jeżeli nie ma osiągalnych przystanków na obu końcach, nie powstaje podróż.

## Przeszukiwanie rozkładu

Planer używa rundowego przeszukiwania wzorców tras podobnego do RAPTOR. Dla każdego przejazdu pojazdem wykonuje kolejną rundę, maksymalnie cztery. Oznacza to do czterech przejazdów i do trzech przesiadek między kursami. Bitsety kalendarza wybierają aktywne kursy, indeksy odjazdów są sortowane, a wyszukiwanie binarne pomija odjazdy wcześniejsze od dotarcia na oznaczony przystanek. Późniejszy kurs jest odrzucany, jeśli nie poprawia czasu dotarcia do żadnego dalszego przystanku tego wzorca. W ramach rundy:

1. rozchodzi się po dostępnych dojściach pieszych i regułach transferu;
2. znajduje kursy obsługujące osiągnięte przystanki;
3. przegląda możliwe odjazdy po czasie dotarcia do przystanku i zapisuje etykiety dojścia do kolejnych przystanków kursu;
4. sprawdza, czy przystanek można połączyć dojściem końcowym z celem.

Okno odjazdów jest rozszerzane stopniowo: 2 godziny, następnie 6, a na końcu maksymalnie 18 godzin, jeśli wcześniejszy etap nie daje wystarczających dokładnie zweryfikowanych tras. Maksymalny czas podróży to 18 godzin od żądanego odjazdu. Uwzględniane są kursy z poprzedniego dnia usługi, które nadal jadą po maksymalnie godzinnym zapasie.

Na każdym przystanku planer zachowuje etykiety niedominowane jednocześnie pod względem czasu dotarcia, łącznego chodzenia i liczby przesiadek. Etykieta jest usuwana, jeżeli istnieje już inna, która dociera nie później, wymaga nie więcej chodzenia i nie ma większej liczby przesiadek. Dzięki temu sama najszybsza droga do danego przystanku nie usuwa automatycznie alternatywy z krótszym dojściem lub mniejszą liczbą zmian.

## Transfery i minimalny czas przesiadki

Graf dojść między przystankami budowany jest podczas tworzenia indeksu z kilku źródeł, a nie z jednej zasady odległości:

| Źródło | Reguła w implementacji |
| --- | --- |
| `transfers.txt`, typ 0 lub 1 | Skierowane dojście pomiędzy wskazanymi przystankami; czas marszu to odległość współrzędnych podzielona przez 1 m/s. |
| `transfers.txt`, typ 2 | Jak wyżej, z zachowaniem `min_transfer_time` jako dodatkowego minimalnego bufora. |
| `transfers.txt`, typ 3 | Jawnie zakazana skierowana para nie dostaje krawędzi transferu. |
| `pathways.txt` | Kierunek podany przez feed; czas pochodzi z `traversal_time`, a gdy go brak — z `length / 0,8 m/s`. Krawędź odwrotna powstaje tylko przy `is_bidirectional=1`. |
| Wspólna `parent_station` | Krawędzie między obsługiwanymi peronami tej samej stacji, jeśli są do 500 m od siebie; czas to co najmniej 45 s przy tempie 0,9 m/s plus bufor 30 s. |
| Bliskie różne przystanki | Połączenie w obie strony między przystankami do 350 m od siebie; dystans jest mnożony przez 1,5, tempo wynosi 1 m/s, a minimalny bufor to 60 s. |

Jeżeli ten sam skierowany transfer opisują różne reguły, indeks zachowuje tę regułę, której suma czasu dojścia i minimalnego bufora jest krótsza. W grafie przejście może mieć maksymalnie 12 krawędzi, a łączne chodzenie od początku podróży do rozpatrywanego przystanku (dojście początkowe wraz z transferami) nie może przekroczyć 30 minut. Bufor minimalny nie jest wliczany do tego limitu.

Przy wejściu na pierwszy kurs nie dolicza się bufora przesiadkowego. Po przejeździe planer wymaga co najmniej 60 sekund na przesiadkę na tym samym węźle; transfer przez inną krawędź uwzględnia zapisany czas chodzenia i minimalny bufor. Zanim trasa zostanie uznana za gotową, sprawdza się, czy faktyczne czasy dojść między przejazdami mieszczą się w przerwach rozkładowych.

## Opóźnienia, odwołania i komunikaty

Feedy realtime są pobierane niezależnie od rozkładu. W planowaniu używana jest ostatnia migawka, jeśli jest świeża; gdy ma 45–180 sekund od pobrania, może posłużyć do bieżącego wyniku, a odświeżanie odbywa się w tle. Gdy migawki brak lub przekroczyła 180 sekund, wyznaczanie trasy nie czeka na sieć realtime i rozpoczyna wyszukiwanie na rozkładzie statycznym, równolegle uruchamiając pobranie nowej migawki.

Poprawność aktualizacji oceniana jest po znaczniku czasu feedu, oddzielnie dla Łodzi i kolei:

| Stan | Wiek znacznika feedu | Znaczenie |
| --- | --- | --- |
| `live` | do 90 s | Świeże aktualizacje. |
| `degraded` | powyżej 90 s do 180 s | Aktualizacje opóźnione, ale nadal używane. |
| `stale` | powyżej 180 s lub znacznik zbyt odległy w przyszłości | Aktualizacja nie zmienia czasu kursu. |
| `unavailable` | Brak poprawnego znacznika czasu | Brak potwierdzonej aktualizacji. |

Znacznik maksymalnie 60 sekund w przyszłości jest akceptowany, np. z powodu różnicy zegarów. Dla świeżego kursu aktualizacja może podać opóźnienie albo konkretną godzinę przyjazdu/odjazdu. Czas bezwzględny ma pierwszeństwo; dostępne opóźnienie jest przenoszone na dalsze przystanki kursu do momentu podania nowszej wartości. Odwołany kurs jest wykluczany.

Świeżość podróży odzwierciedla feedy użyte przez jej przejazdy. Jeżeli trasa łączy MPK i kolej, brak świeżości któregokolwiek z tych źródeł oznacza, że nie można traktować całej podróży jako w pełni aktualizowanej na żywo. Przy nieświeżych lub niedostępnych danych plan nadal bazuje na rozkładzie statycznym, a interfejs pokazuje odpowiedni stan.

Komunikaty dotyczące trasy pochodzą z miejskiego feedu alertów; są dołączane, gdy odnoszą się do linii lub przystanków użytych przez podróż, z uwzględnieniem okresu obowiązywania. Feed kolejowych aktualizacji czasu nie zastępuje miejskiego feedu alertów.

Położenia pojazdów są osobną funkcją prezentacji i śledzenia. Nie zastępują rozkładu przy wyszukiwaniu połączeń i nie tworzą nowego wariantu trasy. Podczas aktywnej podróży pozycja dopasowanego pojazdu może uściślić śledzenie bieżącego etapu.

## Koszt i wybór wariantów

Kandydaci są najpierw porządkowani według kosztu uogólnionego:

```text
czas jazdy
+ 1,6 × czas chodzenia
+ 1,25 × czas oczekiwania
+ 240 s × liczba przesiadek
+ kara jakościowa za krótki zapas transferu lub niedokładną geometrię transferu
```

Wynik obejmuje do trzech odrębnych tras wybranych spośród: najniższego kosztu uogólnionego, najszybszej podróży, najmniejszej liczby przesiadek oraz najkrótszego chodzenia. Jeśli kilka kryteriów wskazuje ten sam przebieg kursów, wariant nie jest duplikowany. Po wyznaczeniu dokładniejszych dojść czasy i koszt są liczone ponownie. Końcowy koszt dodaje karę za transfer z zapasem krótszym niż dwie minuty po wymaganym marszu oraz za transfer bez dokładnie wyznaczonej geometrii.

Wariant rozpoznawany jest po kursach i odcinkach podróży, a nie wyłącznie po geometrii linii. Dwa przejazdy tą samą linią, lecz o innym czasie lub innym kursie, mogą być różnymi wariantami.

## Geometria trasy i walidacja

- Dojścia początkowe i końcowe pochodzą z macierzy Valhalli. Dla końca podróży geometria pobrana od celu do przystanku jest odwracana, aby biegła od przystanku do celu.
- Geometria przejazdu pojazdem pochodzi z `shapes.txt`, ograniczonego do najbliższych punktów kształtu przy przystanku wsiadania i wysiadania. Jeśli kurs nie ma użytecznego kształtu, stosowana jest linia łącząca współrzędne przystanków.
- Transfer początkowo opiera się na krawędzi grafu GTFS, więc jego linia na mapie jest orientacyjna. Szczegółowy przebieg może zostać pobrany przez Valhallę (`/route`, profil `pedestrian`). Dla brakujących dojść dodatkowe żądania mają współbieżność do czterech, a cache jest rozdzielony według endpointu i kierunku odcinka.
- Dokładne czasy dojścia aktualizują czasy etapów oraz ETA. Jeśli dokładne dojście transferowe nie mieści się przed następnym odjazdem, wariant jest usuwany. Jeśli nie uda się uzyskać geometrii, dostępny wariant może pozostać pokazany orientacyjnie i otrzymuje stan niepełnej geometrii.
- Publiczny serwer `valhalla1.openstreetmap.de` przechodzi przez bramkę ograniczającą żądania do jednego na 1,1 s. Inny endpoint HTTPS można ustawić jako serwer tras; jego limity i dostępność zależą od operatora.

Geometrie wszystkich etapów są składane w jedną linię dla mapy. Odcinki marszu oraz jazdy mają osobne dane w `JourneyLeg`, więc interfejs może pokazać właściwą linię, przystanki, godzinę i opóźnienie dla każdego etapu.

## Podgląd i śledzenie podróży

Podczas planowania interfejs rozróżnia pobieranie rozkładu, szukanie połączeń i uzupełnianie dojść. Po znalezieniu kandydatów może pokazać podsumowanie czasu, chodzenia, czekania i przesiadek, ale wybór oraz rozpoczęcie są dostępne po walidacji.

Po rozpoczęciu aplikacja śledzi postęp względem etapów podróży oraz sekwencji przystanków. W trybie Komunikacja nie ma instrukcji manewrów drogowych; model trasy zawiera etapy pojazdem i pieszo, a powiadomienia głosowe opierają się na postępie do przystanków, wysiadaniu i przesiadkach. Na iOS aplikacja prosi o zgodę na lokalizację w tle potrzebną do kontynuowania śledzenia przy zablokowanym ekranie.

Plan może być odświeżany w podglądzie i podczas podróży, ale silnik pomija odświeżenie, gdy użytkownik jest rozpoznany jako jadący pojazdem. Odświeżenie podczas postoju lub dojścia pieszo zachowuje ten sam przebieg, jeśli jego kursy nadal pasują; w przeciwnym razie wybiera pierwszy nowy wariant. Błąd chwilowego pobrania nie usuwa już wyświetlanej trasy.

## Błędy i ograniczenia

Plan kończy się błędem lub pustym wynikiem, gdy m.in. nie ma poprawnego rozkładu, brak dojścia do obsługiwanych przystanków w limicie 30 minut, kursy nie tworzą podróży w oknie 18 godzin, odpowiedź usługi jest nieprawidłowa lub serwer pieszy nie odpowiada. Aplikacja pokazuje błąd zamiast podstawiać połączenie, którego nie znalazła.

Wynik zależy od kompletności i aktualności GTFS, kalendarzy kursów, feedów realtime, kształtów linii i reguł transferów opublikowanych przez operatorów, a także od dostępności oraz danych serwera Valhalla. Awaria macierzy może wprowadzić oznaczone przybliżenia. Nawet dokładna geometria nie potwierdza dostępności windy, peronu, przejścia ani faktycznej możliwości przesiadki w terenie.

Planer nie jest trybem offline. Publiczne feedy mogą być czasowo niedostępne, niekompletne lub opóźnione. Godziny z rozkładu nie gwarantują, że pojazd rzeczywiście przyjedzie lub że kurs zostanie wykonany.

## Dane wysyłane do usług

Pozycja początku, cel oraz współrzędne wybranych przystanków trafiają do skonfigurowanego serwera Valhalla w celu wyznaczenia macierzy i przebiegu dojść pieszych. Rozkłady i aktualizacje pobierane są z adresów feedów zapisanych w kodzie. Tryb komunikacji nie korzysta z TomTom do wyznaczania połączeń. Szczegółowy opis źródeł mapy oraz pozostałych żądań aplikacji znajduje się w [README](../README.md).

## Diagnostyka planowania

Planer zapisuje pomiary `os_signpost` w logu subsystemu `STDMSolution.NaviAstra`, kategorii `TransitPlanning`. Każde planowanie ma `planningID`. Zdarzenie `PlanningSummary` podaje czasy budowy migawki, macierzy, wyszukiwania i geometrii, a także liczbę aktywnych wzorców, oznaczonych przystanków, skanowanych i zdominowanych kursów, etap okna, trafienia cache oraz świeżość realtime. Te pomiary pomagają ustalić, czy opóźnienie wynikało z pobierania danych, wyszukiwania czy doprecyzowania przebiegu.

## Najważniejsze miejsca w kodzie

- `NaviAstra/Navigation/NavigationEngine.swift` — uruchomienie podglądu, status planowania, wybór wariantu, rozpoczęcie i odświeżanie podróży.
- `NaviAstra/Navigation/LodzTransitRouteProvider.swift` — fasada, cache i koordynacja GTFS/realtime, dojścia, algorytm wyszukiwania, graf transferów, ranking i budowa `Journey`.
- `NaviAstra/Navigation/ValhallaRouteProvider.swift` — żądania pieszej macierzy i trasy oraz bramka żądań dla publicznego endpointu.
- `NaviAstra/Navigation/Models.swift` — `NavigationRoute`, `Journey`, `JourneyLeg`, stany realtime i postęp podróży.
- `NaviAstra/ContentView.swift` — podsumowanie wariantów, świeżość realtime, komunikaty, etapy i sygnalizacja przybliżonych dojść.
- `NaviAstra/Navigation/TransitDetailsSheet.swift` — szczegóły przystanków, linii, kursu, odjazdów i pojazdu.
