# Wyznaczanie tras samochodowych w NaviAstra

Aktualizacja iOS 1.1.157 (159): bieżące zasady rankingu, personalizacji, ruchu, EV i komunikacji opisuje [ROUTING_IMPROVEMENTS.md](ROUTING_IMPROVEMENTS.md). W tych obszarach zastępuje wcześniejsze zasady opisane poniżej.

Stan dokumentacji: 12 października 2026 r., wersja aplikacji 1.1.72 (build 74). Opis uwzględnia bieżący kod lokalnego checkoutu, także jego niezacommitowane zmiany.

Dokument opisuje działanie wynikające z kodu aplikacji. Nie potwierdza aktualności danych ani konfiguracji działającego serwera tras. Dotyczy trybu samochodowego; ogólny opis wszystkich trybów znajduje się w [ROUTING.md](ROUTING.md).

## 1. Na jakiej podstawie powstaje trasa

NaviAstra przekazuje początek, cel, punkty pośrednie i preferencje do silnika **Valhalla**, który oblicza przebieg drogi, manewry, dystans i podstawowy czas przejazdu. Zwykle działa on na serwerze; na iOS może działać lokalnie z zainstalowaną paczką grafu drogowego. Aplikacja ocenia otrzymane warianty wspólnym `RouteScoringEngine`, według wybranej preferencji kierowcy: czasu, dystansu albo czasu z oceną wygody. Następnie usuwa warianty z bardzo podobną geometrią. Podczas jazdy może korygować czas i wybór wariantu na podstawie danych **TomTom**, a przy zgłoszonym zamknięciu poprosić Valhallę o objazd.

| Źródło / element | Do czego służy |
|---|---|
| Valhalla i graf drogowy jej serwera | Obliczenie drogi możliwej do przejechania samochodem, wariantów, manewrów i czasu bazowego |
| OpenStreetMap przez Overpass | Ustalenie dojazdu do POI, parkingów i parametrów stacji ładowania |
| GPS urządzenia | Początek podróży, kierunek jazdy, postęp i wykrywanie zjazdu z trasy |
| Preferencje kierowcy | Ograniczenie korzystania z opłat, autostrad, promów i dróg gruntowych |
| TomTom, jeśli skonfigurowany i dostępny | Prędkości ruchu i zdarzenia; korekta ETA, porównywanie istniejących wariantów, wykrywanie zamknięć |
| Parametry EV podane przez użytkownika | Planowanie ładowania i jego szacowanego czasu |

Domyślnym adresem routingu jest `https://valhalla1.openstreetmap.de`. Można skonfigurować własny serwer. Klient wymaga HTTPS; dla domyślnego hosta rozdziela żądania odstępem co najmniej 1,1 s. Zwykłe żądanie trasy ma timeout 15 s. Na iOS zwykłe żądanie `/route` może zostać wykonane lokalnie; warunki i ograniczenia opisuje sekcja 15.

Mapa wyświetlająca drogę i silnik wyznaczający trasę pełnią różne role.

## 2. Co bierze pod uwagę silnik drogowy

Domyślny samochód korzysta z profilu `auto`. Tryb drogowy pozwala też wybrać motocykl (`motorcycle`), skuter (`motor_scooter`), ciężarówkę (`truck`), autobus (`bus`) lub taksówkę (`taxi`). Dalszy opis zwykłego auta zakłada profil `auto`. Według [dokumentacji Valhalli](https://valhalla.github.io/valhalla/api/route/api-reference/) profil szuka trasy o krótkim czasie, uwzględniając także koszt skrzyżowań i manewrów. Nie gwarantuje bezwzględnie najkrótszego czasu ani dystansu.

Graf serwera reprezentuje połączenia dróg oraz ich zasady dostępu, kierunki i ograniczenia skrętów. Ich poprawność zależy od danych i sposobu przygotowania grafu. Podstawowe prędkości zależą m.in. od tagów OSM i domyślnych wartości klas dróg; `speed` używane do obliczeń i `speed_limit` do prezentacji są odrębnymi polami. Szczegóły opisuje [dokumentacja prędkości Valhalli](https://valhalla.github.io/valhalla/concepts/speeds/).

Domyślnie NaviAstra ustawia `shortest = false` (użytkownik może włączyć najkrótszą trasę), `maneuver_penalty = 12`, `service_penalty = 30` i `use_living_streets = 0`. Jeżeli unikanie autostrad jest wyłączone, przekazuje `use_highways = 1`; włączenie unikania ustawia 0. Pozostałe wagi pozostawia profilowi i konfiguracji serwera. Nie sprawdza daty aktualizacji jego grafu ani dostępności jego danych historycznego i bieżącego ruchu.

Ważne rozróżnienie: prośba o polskie instrukcje, informacje o pasach, zjazdach z rond i przekraczanych granicach dotyczy odpowiedzi i prowadzenia. Sama nie oznacza dodatkowego kryterium wyboru drogi.

## 3. Początek, cel i dojazd do miejsca

Początek można wskazać ręcznie albo użyć aktualnej lokalizacji. Dla bieżącej lokalizacji aplikacja wykorzystuje świeży pomiar lub próbuje pobrać nowy. Bez dostępnego początku nie może zaplanować trasy.

Filtr GPS akceptuje pomiary z dokładnością poziomą od 0 do 70 m oraz czasem odległym od bieżącego o mniej niż 15 s. Kolejne pomiary muszą mieć rosnące znaczniki czasu. Dla samochodu odrzuca skoki pozycji oznaczające prędkość powyżej 75 m/s. Jest to filtr wiarygodności lokalizacji, a nie dopuszczalna prędkość jazdy.

Kierunek początkowy trafia do Valhalli tylko przy dostatecznie wiarygodnej lokalizacji: dokładność do 45 m, prędkość co najmniej 2,5 m/s, pomiar nie starszy niż 10 s, pozycja do 50 m od początku oraz poprawny kurs. Dokładność kursu musi wynosić do 45° albo być nieznana. Żądanie używa tolerancji kierunku 45°. Przy postoju lub słabym pomiarze aplikacja pomija ten parametr.

Cel pochodzi z wybranego adresu, punktu mapy lub miejsca. Dla POI aplikacja najpierw próbuje ustalić punkt dojazdu z OSM w promieniu 250 m:

1. Szuka parkingu powiązanego z miejscem przez geometrię, odległość od budynku i wejścia oraz zgodność nazwy lub marki.
2. Preferuje odpowiednią drogę serwisową w parkingu. Pomija rozpoznane drogi prywatne, zakaz dostępu i strefy dostaw.
3. Gdy nie ma takiej drogi, może wskazać reprezentatywny punkt parkingu.
4. Kolejną możliwością jest najbliższa odpowiednia droga do 100 m od punktu odniesienia.
5. Gdy brakuje wyniku lub Overpass nie odpowiada, wysyła oryginalną współrzędną POI do Valhalli.

Ostatni przypadek może poprowadzić do pobliskiej drogi zamiast właściwego wjazdu. Wyznaczenie punktu parkingu nie potwierdza dostępności wolnych miejsc ani otwarcia obiektu w chwili przyjazdu. Cele dojazdu są przechowywane w pamięci do 6 godzin, pobrane obiekty OSM do godziny.

## 4. Preferencje kierowcy

| Ustawienie | Parametr wysyłany do Valhalli | Znaczenie w aplikacji |
|---|---|---|
| Unikaj dróg płatnych | `use_tolls = 0` | Ogranicza preferencję korzystania z opłat |
| Unikaj autostrad | `use_highways = 0` | Ogranicza preferencję korzystania z autostrad |
| Unikaj promów | `use_ferry = 0` | Ogranicza preferencję korzystania z promów |
| Unikaj dróg gruntowych | `exclude_unpaved = true` | Żąda wykluczenia dróg nieutwardzonych |

Domyślnie wszystkie cztery opcje są wyłączone. Niewłączone opcje opłat, promów i dróg gruntowych nie trafiają do żądania. Preferencja autostrad jest przekazywana jawnie. Pierwsze trzy opcje są preferencjami, a nie bezwarunkowym zakazem. Efekt zależy od odpowiednich oznaczeń dróg i obsługi parametrów przez serwer.

Dodatkowe ustawienia obejmują najkrótszą trasę (`shortest`), stronę dojazdu do celu (`preferred_side`: `either`, `same`, `opposite`) oraz do ośmiu omijanych obszarów (`exclude_polygons`). Każdy obszar musi mieć 3–32 różne, poprawne wierzchołki, niezerowe pole i brak przecięć krawędzi. Poligony są wysyłane jako zamknięte pierścienie w kolejności długość, szerokość geograficzna. Parametry są wspólne dla zwykłych tras, EV, objazdów i optymalizacji przystanków.

Profil ciężarówki przekazuje wysokość, szerokość i długość w metrach, masę i nacisk osi w tonach oraz flagę materiałów niebezpiecznych. Skuter przekazuje maksymalną prędkość i pomija odziedziczoną preferencję autostrad. EV wymaga profilu `auto`.

Zwykła trasa nie jest optymalizowana pod cenę paliwa, sumę opłat ani koszt całej podróży. „Unikaj opłat” nie oblicza kwoty, którą kierowca zapłaci.

## 5. Punkty pośrednie i warianty

Można dodać do ośmiu punktów pośrednich. Zwykłe wyznaczanie odwiedza je w bieżącej kolejności. Dla miejsc POI również rozwiązuje punkty dojazdu.

Osobna akcja optymalizacji korzysta z `/optimized_route`, zachowuje początek i cel, sprawdza zwrócone indeksy, zmienia kolejność przystanków i ponownie wyznacza trasę. Nie uruchamia się automatycznie przy każdym planowaniu. Jej timeout wynosi 25 s. Samo `/optimized_route` jest wykonywane na serwerze i nie korzysta z lokalnego mechanizmu zastępczego dla `/route`.

Bez punktów pośrednich aplikacja prosi o dwie alternatywy, więc może otrzymać do trzech tras łącznie. Nie musi otrzymać wszystkich. Dla trasy z punktami pośrednimi wysyła `alternates = 0`. Wspólny ranking drogowy uwzględnia preferencję kierowcy. Domyślna „Najszybsza” porównuje czas Valhalli, „Najkrótsza” porównuje dystans, a „Zrównoważona” i „Wygodna” porównują znormalizowane składowe czasu, dystansu, manewrów, znanej nawierzchni i pokrycia ruchem. Przy remisie decydują czas, dystans i kolejność wejściowa. Ranking obejmuje wszystkie profile pojazdów w trybie `.car`, wyznaczanie, EV i objazdy. Ocena wygody nie jest dopisywana do ETA. Szczegóły i wagi opisuje sekcja 17.

Dostawca zwraca gotowe warianty bez dodatkowego zapytania Overpass o światła. Pole liczby świateł nie jest obecnie używane w rankingu; bez długości cyklu i faz nie można z niego ustalić rzeczywistego opóźnienia.

`RouteSimilarity` zachowuje rekomendowany wariant, a kolejne warianty drogi dopuszcza przy udziale wspólnej geometrii poniżej 80%. Jest to przybliżenie geometryczne, nie porównanie identyfikatorów krawędzi OSM. Różne zestawy postojów EV pozostają osobnymi opcjami, także gdy korzystają z tej samej drogi. Użytkownik może wybrać inny zachowany wariant. Filtrowanie nie generuje samo dodatkowej trasy, której Valhalla nie zwróciła.

Dla wyjazdu teraz bez przystanków żądanie zawiera także `prioritize_bidirectional = true`, aby umożliwić otrzymanie alternatyw; przy wyjeździe lub przyjeździe na wskazaną godzinę aplikacja pozostawia dobór algorytmu zależnego od czasu silnikowi. Faktyczna liczba alternatyw nadal zależy od dostawcy.

Zmiana planu anuluje poprzednią pracę. Kontrola generacji żądania chroni przed nadpisaniem nowej trasy spóźnioną odpowiedzią.

## 6. Jak ruch wpływa na trasę

TomTom wymaga skonfigurowanego klucza. Brak konfiguracji, błąd pobierania i brak świeżych danych mają osobne stany; brak informacji nie dowodzi braku korków.

NaviAstra pobiera dane w okolicy pozycji oraz w korytarzu pozostałej trasy. Horyzont korytarza odpowiada do 25 minutom jazdy, z limitem dystansu zależnym od średniej prędkości: 18 km poniżej 45 km/h, 35 km poniżej 85 km/h, 100 km przy wyższej prędkości. Obejmuje najwyżej pozostałą długość trasy.

Zdarzenia są pobierane w obszarach wzdłuż drogi. Dopasowanie liniowego zdarzenia wymaga ciągłego wspólnego odcinka z trasą i zgodności osi drogi do 30°. Tolerancja wynosi 10 m dla zamknięć i 20 m dla innych zdarzeń; wymagane nakładanie to co najmniej mniejsza z wartości 30 m i 80% długości zdarzenia. Punktowe zamknięcie bez geometrii odcinka nie uruchamia objazdu ani komunikatu o zamknięciu trasy. Próbki przepływu również wymagają dopasowania osi drogi. Przepływ ruchu jest próbkowany adaptacyjnie. Budżet wynosi 40 zapytań w podglądzie, 64 podczas jazdy, do 96 przy wykrytym problemie i 24 w tle. Gęstość wynika z dostępnych klas FRC poprzednich dopasowanych pomiarów, flagi autostrady i prędkości wynikającej z czasów odcinków Valhalli; nie udaje rozpoznania klasy drogi, jeśli brakuje tych danych. Odstępy nominalne wynoszą od 350 m dla wolniejszych odcinków do 4 km na autostradzie. Do 24 miejsc w budżecie jest przeznaczonych na okolice manewrów i znanych, dopasowanych zdarzeń. Po wyczerpaniu budżetu próbki są rozłożone po całym monitorowanym korytarzu. To nie jest ciągły pomiar całej podróży: próbkowanie dotyczy horyzontu do 25 minut, a nie np. całych 330 km trasy. Próbka z podaną pewnością poniżej 0,5 jest pomijana. Aplikacja pobiera też `roadNumbers` zdarzeń i porównuje je z rozpoznanymi numerami dróg w bieżącym manewrze Valhalli. Sprzeczne numery w tej samej rodzinie (np. A2 i A4) odrzucają dopasowanie. A2 i E30 mogą opisywać tę samą drogę: różne rodziny numerów bez wspólnego odniesienia nie są traktowane jako dowód sprzeczności. Brak numeru pozostaje nieznany. Kontrola ta jest wspólna dla zdarzeń na trasie, ETA, ostrzeżeń i objazdów.

Dopasowanie wymaga też ciągłości postępu po geometrii, a próbka przepływu musi obejmować okolicę swojego punktu zapytania; fragment innego ramienia pętli nie wystarcza. Kierunek geometryczny jest sprawdzany ze znakiem tylko przy jawnie określonym kierunku źródła. Obecne adaptery TomTom pozostawiają go nieznany, ponieważ używane odpowiedzi nie dają zweryfikowanego kierunku zgodnego z grafem OSM. Samo uporządkowanie współrzędnych ani znak TMC nie są przyjmowane jako taki dowód. Bez wspólnych identyfikatorów krawędzi, poziomów drogi i kierunku pasa nadal możliwe są niejednoznaczne równoległe jezdnie i estakady.

Odświeżanie zależy od stanu nawigacji, pracy w tle i polityki energii. Dla korytarza na pierwszym planie standardowy odstęp wynosi co najmniej 60 s podczas jazdy lub 90 s w podglądzie. Zdarzenie do 10 km pozwala na odstęp co najmniej 30 s, zależny od polityki energii; zamknięcie do 3 km ustawia 20 s. Próbki przepływu są pobierane ponownie po 180 s lub zmianie trasy. Dane korytarza o zdarzeniach wygasają po 120 s, o przepływie po 240 s, pobliski snapshot po 180 s.

### Wybór szybszego wariantu podczas jazdy

Aplikacja porównuje już dostępne warianty Valhalli najwyżej raz na 180 s. Mechanizm jest wyłączony przy preferencji najkrótszej trasy. Dla pozostałych preferencji korzysta z tego samego rankingu co początkowy wybór, uzupełnionego aktualnymi danymi ruchu. Sprawdza możliwość kontynuowania wariantu z obecnej pozycji i kierunku. Wymaga udanego pobrania zdarzeń, co najmniej 75% odpowiedzi na żądane próbki oraz świeżego pokrycia co najmniej 50% każdego porównywanego korytarza. Pokrycie kandydata nie może być gorsze o ponad 10 punktów procentowych.

Przełączenie wymaga oszczędności co najmniej:

`max(120 sekund, 15% pozostałego czasu obecnej trasy)`

Przykład: przy pozostałych 20 minutach oszczędność musi wynosić co najmniej 3 minuty. Przy 8 minutach — co najmniej 2 minuty. Mechanizm działa podczas nawigacji, nie sortuje automatycznie zwykłych wariantów w początkowym podglądzie według TomTom.

TomTom nie zastępuje silnika trasowania i aplikacja nie zapisuje jego feedu do grafu Valhalli. Porównanie wariantów nie jest pełnym przeszukiwaniem wszystkich możliwych dróg z uwzględnieniem korków.

## 7. Czas przejazdu i przewidywany przyjazd

Początkowy czas pochodzi z Valhalli. Wspólny model `RoadRouteETA` liczy pozostały czas z `travelSegments`, czyli czasów odcinków przypisanych do zakresów odległości na geometrii trasy. Dla brakujących zakresów używa proporcji czasu bazowego całej drogi.

Po co najmniej 45 s ruchu i przejechaniu ponad 25 m aplikacja uwzględnia obserwowane tempo podróży. Porównuje średnią prędkość zaplanowaną i zaobserwowaną, ogranicza ich iloraz do 0,65–1,8 i stosuje 55% wynikającej korekty. Ta korekta dotyczy wyświetlanego postępu; porównanie alternatyw używa domyślnego mnożnika 1.

Świeże prędkości TomTom zwiększają czas na zmierzonych zakresach, gdy przejazd wychodzi wolniejszy od bazowego. Nie skracają go poniżej tego oszacowania. Opóźnienie zdarzenia jest doliczane tylko przed kierowcą i poza odcinkami już pokrytymi pomiarem przepływu, aby nie liczyć go dwukrotnie. Pozostałe postoje ładowania zwiększają ETA.

Zamknięcie na pozostałej drodze oznacza nieskończony koszt w ocenie wariantu. Podczas szukania objazdu interfejs zachowuje skończony czas bazowy. Wyświetlany wówczas czas nie potwierdza przejezdności zamkniętej drogi.

## 8. Kiedy powstaje nowa trasa

### Zjazd z wyznaczonej drogi

`OffRouteDetector` wymaga jednocześnie dokładności GPS do 45 m, odległości od trasy większej niż `max(40 m, 1,5 × dokładność GPS)` oraz pewności dopasowania poniżej 0,25. Dodatkowo kurs musi różnić się od drogi o co najmniej 55° albo pewność musi spaść poniżej 0,1.

Dowód zjazdu musi obejmować co najmniej trzy różne pomiary przez minimum 2 s. Między automatycznymi próbami musi minąć więcej niż 20 s. Nowa trasa zaczyna się w aktualnej pozycji i zachowuje pozostałe punkty planu. Rozpoznawanie pozostałych przystanków korzysta z postępu po starej geometrii; zwykły próg wynosi ponad 50 m przed kierowcą, z wyjątkiem punktów oznaczonych jako priorytetowe.

### Zamknięcie drogi

Automatyczny objazd uruchamia świeże zdarzenie kategorii zamknięcia, dopasowane do trasy, ponad 100 m przed kierowcą i wewnątrz horyzontu monitorowania. Nie wystarcza słowo „zamknięcie” w opisie ani samo zamknięcie pojedynczego pasa.

`RoadClosureAvoidance` tworzy dla każdego odcinka pełnej geometrii zamknięcia prostokątny bufor o połowie szerokości 12 m, wydłużony o 12 m na końcach. Wszystkie pierścienie trafiają do `exclude_polygons` razem z obszarami wskazanymi przez użytkownika. Nie następuje redukcja do 20 punktów. Geometria z ponad 256 niezerowymi odcinkami kończy się jawnym błędem zamiast częściowego wykluczenia.

Po otrzymaniu odpowiedzi aplikacja sprawdza każdy odcinek trasy pod kątem przecięcia tych samych prostokątów. Wykrywa również przejazd przez środek zamknięcia, gdy oba końce długiego segmentu trasy leżą daleko od niego. Odrzucone warianty nie trafiają do opcji trasy. Bezpieczne warianty podlegają wspólnemu rankingowi. Ten mechanizm obejmuje pełny otrzymany odcinek zgłoszenia, ale nie potwierdza pełnej geometrii fizycznego zamknięcia ani poziomu drogi; bufor może objąć bliską drogę lub most. Po błędzie zachowuje dotychczasową trasę i pokazuje komunikat, a próbę dla danego zdarzenia może ponowić po 60 s.

## 9. Planowanie samochodem elektrycznym

EV jest opcjonalne. Korzysta z zadeklarowanych przez użytkownika: zasięgu przy pełnym naładowaniu, procentu baterii, zużycia kWh/100 km, maksymalnej mocy ładowania auta i typów złączy. Dostępny zasięg wynosi:

`zasięg pełny × procent baterii / 100`

Planner używa 80% dostępnego zasięgu jako limitu odcinka, zachowując margines 20%. Przykładowo deklarowane 400 km i 50% baterii dają 200 km dostępnego zasięgu i 160 km limitu pierwszego odcinka.

Sprawdza do trzech tras bazowych. Dla dłuższych dróg szuka stacji OSM w korytarzu 3 km, z limitem 1000 wyników. Kandydat musi mieć dodatnią znaną moc i opisane złącza; odrzucane są stacje oznaczone jako niedostępne lub niepubliczne. Przy wybranych złączach wymagana jest zgodność, a `ccs` uwzględnia też `type2_combo`. Nieznana dostępność nie musi wykluczać stacji i nie jest potwierdzeniem wolnego stanowiska.

Wyszukiwanie zachowuje ograniczoną liczbę sekwencji, do trzech planów na wariant bazowy, z maksymalnie dziesięcioma ładowaniami w sekwencji. Dla wybranych stacji ponownie oblicza rzeczywisty dojazd Valhallą i kontroluje wykonalność odcinków. Ranking końcowy stosuje wybraną preferencję trasy. W trybach czasowych uwzględnia jazdę wraz z ładowaniem, a w najkrótszym dystans po dodaniu dojazdów do stacji. Zwraca do trzech wyników po kontroli wykonalności i podobieństwa. Nie gwarantuje globalnie najlepszego planu.

Czas ładowania bierze mniejszą z mocy auta i stacji. Szacowana pojemność baterii wynika z zasięgu i zużycia. Model przyjmuje 85% mocy do 60% SOC, 65% między 60 a 80% i 35% powyżej 80%, oraz 5 minut na obsługę postoju. To ogólna heurystyka, bez krzywej konkretnego samochodu, temperatury baterii i czasu kolejki. Wstępny wybór sekwencji używa uproszczonej oceny; dokładniejszy model ładowania stosowany jest po trasowaniu.

Brak poprawnych parametrów lub wykonalnego zestawu stacji kończy się błędem planowania EV.

## 10. Czego aplikacja obecnie nie uwzględnia

| Czynnik | Granica obecnej implementacji |
|---|---|
| Pogoda, śnieg, temperatura | Nie są osobnymi parametrami obliczenia trasy ani zużycia EV; niektóre zagrożenia mogą być zdarzeniami TomTom |
| Godzina wyjazdu lub przyjazdu | Żądanie przekazuje `date_time`; wynik zależy od danych i obsługi czasu w silniku. Bieżący TomTom nie jest prognozą korków na przyszłą godzinę |
| Ograniczenia czasowe | Silnik otrzymuje czas podróży i może raportować obecność ograniczeń; kompletność oceny zależy od grafu i konfiguracji |
| Wymiary i masa pojazdu | Dostępne w profilu ciężarówki; zwykłe `auto` nie przekazuje gabarytów |
| Strefy emisji i uprawnienia do wjazdu | Brak przekazywania klasy emisji, zezwoleń i indywidualnej kwalifikacji kierowcy |
| Ceny paliwa, energii i opłat | Nie są kryterium rankingu trasy samochodowej |
| Rzeczywisty SOC i zużycie auta | Brak telemetrii pojazdu; EV bazuje na konfiguracji użytkownika |
| Wolne miejsca parkingowe i kolejki do ładowarek | Brak potwierdzenia na żywo |
| Fotoradary i ostrzeżenia drogowe | Służą prowadzeniu i ostrzeganiu; aplikacja nie stosuje ich jako własnego kryterium unikania drogi |

Informacja o limicie prędkości, pasach lub ostrzeżeniu w interfejsie nie oznacza automatycznie, że została użyta jako osobny czynnik wyboru trasy przez aplikację. Serwer może uwzględniać część cech w swoim modelu, ale jego aktualnej konfiguracji ten przegląd nie weryfikuje.

## 11. Przykład całego procesu

Kierowca wybiera sklep jako cel i włącza unikanie opłat. NaviAstra ustala świeży początek GPS i próbuje znaleźć dojazd na parking sklepu. Wysyła do Valhalli współrzędne, profil `auto` oraz `use_tolls = 0`, prosząc o alternatywy, jeśli nie ma przystanków. W domyślnym trybie najszybszym wybiera wariant według czasu zwróconego przez Valhallę, pokazując jego czas bazowy; inne preferencje stosują własne kryterium rankingu.

Po rozpoczęciu jazdy dopasowuje GPS do drogi i aktualizuje ETA. Dostępny ruch TomTom może zwiększyć czas. Gdy inny otrzymany wariant można kontynuować z obecnej pozycji i daje wymaganą oszczędność przy wystarczających danych, aplikacja może przełączyć trasę. Świeże zamknięcie przed autem uruchamia osobne żądanie objazdu. Włączony tryb EV dodaje ocenę zasięgu i postojów ładowania.

## 12. Podstawa w kodzie

| Zakres | Pliki źródłowe |
|---|---|
| Wybór dostawcy i endpointu | [AppDependencies.swift](../NaviAstra/App/AppDependencies.swift), [NavigationSessionDependencies.swift](../NaviAstra/Navigation/Engine/NavigationSessionDependencies.swift) |
| Parametry żądań i odpowiedzi Valhalli | [ValhallaRouteProvider.swift](../NaviAstra/Navigation/ValhallaRouteProvider.swift), [ValhallaRoutingOptions.swift](../NaviAstra/Navigation/ValhallaRoutingOptions.swift) |
| Początek i początkowy wybór wariantu | [NavigationSession+RoutePreview.swift](../NaviAstra/Navigation/NavigationSession+RoutePreview.swift) |
| Routing, kierunek, EV i objazdy | [NavigationSession+Routing.swift](../NaviAstra/Navigation/NavigationSession+Routing.swift) |
| Preferencje i model ładowania | [Models.swift](../NaviAstra/Navigation/Models.swift) |
| Wspólny ranking i podobieństwo tras | [RouteScoringEngine.swift](../NaviAstra/Navigation/Engine/RouteScoringEngine.swift) |
| Tożsamość drogi i bufory zamknięć | [TrafficRoadIdentity.swift](../NaviAstra/Traffic/TrafficRoadIdentity.swift), [RoadClosureAvoidance.swift](../NaviAstra/Navigation/Engine/RoadClosureAvoidance.swift) |
| Dojazd do POI | [POIAccessResolver.swift](../NaviAstra/Places/POIAccessResolver.swift) |
| Filtr GPS i wykrywanie zjazdu | [LocationFilter.swift](../NaviAstra/Core/Location/LocationFilter.swift), [OffRouteDetector.swift](../NaviAstra/Navigation/Engine/OffRouteDetector.swift) |
| Ruch, ranking i ETA | [NavigationSession+Traffic.swift](../NaviAstra/Navigation/NavigationSession+Traffic.swift), [RouteTrafficMonitor.swift](../NaviAstra/Traffic/RouteTrafficMonitor.swift) |
| Tempo jazdy i postęp | [NavigationSession+Progress.swift](../NaviAstra/Navigation/NavigationSession+Progress.swift) |
| Kategorie zdarzeń | [TrafficProvider.swift](../NaviAstra/Traffic/TrafficProvider.swift) |
| Routing offline na iOS | [OfflineRoutingStore.swift](../NaviAstra/Navigation/OfflineRoutingStore.swift), [OfflineRoutingEngine.swift](../NaviAstra/Navigation/OfflineRoutingEngine.swift) |

Dokument powstał przez przegląd kodu i oficjalnych opisów Valhalli. Nie wykonano przejazdu, zapytań z rzeczywistą lokalizacją ani weryfikacji dostępności usług i świeżości ich danych.

## 13. Znaki i widok podczas jazdy

Znaki na trasie wymagają powiązania z geometrią drogi OSM i zgodności podejścia kierowcy. Kod uwzględnia kierunki `forward` / `backward`, orientację znaku i jednokierunkowość drogi. Niepewne kierunki są pomijane w ostrzeżeniach. Znaki informacyjne bez znaczenia dla przejazdu nie trafiają do banera nawigacji. Znane polskie kody mają nazwy opisowe; kod pozostaje w szczegółach. Dane mapy nadal mogą pokazywać znaki jako kontekst otoczenia.

Kamera samochodowa ustawia pozycję na 86% wysokości odsłoniętej mapy, z zachowaniem minimalnego odstępu od panelu. Etykiety ulic nie wyświetlają stałego dymka obecnej drogi. Pokazują nazwę drogi po manewrze i do dwóch ulic pobocznych przed kierowcą, także przy jeździe prosto, o ile pozwala na to zbliżenie, prędkość i miejsce na ekranie. Jest to własna implementacja inspirowana prezentacją Apple Maps; wewnętrzny algorytm Apple nie jest udostępniony.


## 14. Planowanie na godzinę wyjazdu lub przyjazdu

Żądanie drogowe zawsze zawiera `date_time`:

| Wybór użytkownika | Parametr | Ustalenie strefy czasowej |
|---|---|---|
| Wyjazd teraz | `type = 0` | Nie wymaga dodatkowego geokodowania |
| Wyjazd o godzinie | `type = 1`, `value = YYYY-MM-DDTHH:mm` | Strefa początku podróży |
| Przyjazd do godziny | `type = 2`, `value = YYYY-MM-DDTHH:mm` | Strefa celu podróży |

Strefę czasową aplikacja uzyskuje przez odwrotne geokodowanie MapKit. Brak wyniku kończy planowanie komunikatem błędu. Na iOS preferowanie offline lub wykryty brak sieci blokują planowanie na wskazaną godzinę; dostępny pozostaje wyjazd teraz.

Valhalla otrzymuje czas jako część zadania drogowego. Nie oznacza to, że dany serwer ma kompletną prognozę ruchu. W podglądzie podróży na inną godzinę aplikacja nie odświeża bieżącego ruchu TomTom, żeby aktualne korki nie opisywały innej pory podróży. Podczas nawigacji przeliczenia z aktualnej pozycji korzystają domyślnie z wyjazdu teraz.

## 15. Wyznaczanie i przeliczanie trasy bez internetu

Na iOS dostawca może uruchomić lokalną Valhallę z aktywną paczką grafu `.tar`. Zapisane kafle mapy są osobnymi danymi i nie wystarczają do wyznaczania drogi.

1. Jeśli użytkownik preferuje offline albo system zgłasza brak sieci, `/route` trafia od razu do lokalnego silnika.
2. W pozostałych przypadkach aplikacja próbuje serwera HTTPS.
3. Po błędzie połączenia, DNS lub timeoutu próbuje wykonać to samo żądanie lokalnie.
4. Błąd HTTP, parametrów lub niepoprawnej odpowiedzi nie powoduje takiej zamiany.

Lokalny silnik otrzymuje ten sam JSON z profilem, preferencjami i wykluczeniami. Wymaga aktywnej paczki obejmującej przebieg całej drogi i ewentualnego objazdu. Nie pobiera brakujących fragmentów grafu przez internet i nie łączy automatycznie kilku paczek. Brak paczki lub pokrycia kończy się błędem. Paczka oznaczona jako przeznaczona tylko dla pojazdów silnikowych jest dopuszczana przez kod w trybie `.car`.

Zwykłe planowanie i przeliczanie korzystają z tego samego dostawcy. Automatyczny dobór ładowarek wymaga internetu; przy preferowaniu offline lub wykrytym braku sieci aplikacja prosi o wyłączenie EV i ręczne dodanie postojów. Wyszukiwanie nowych miejsc, dane ruchu i planowanie na godzinę pozostają usługami sieciowymi. Instrukcja instalacji paczek znajduje się w [OFFLINE_ROUTING.md](OFFLINE_ROUTING.md).

## 16. Przebieg żądania od wyboru celu do mapy

```text
Początek + cel + przystanki + ustawienia
                 ↓
Świeży GPS lub ręczny początek; dojazd do POI
                 ↓
Profil pojazdu + czas podróży + kierunek startu
                 ↓
Valhalla: serwer HTTPS lub lokalny graf na iOS
                 ↓
Geometria + odcinki + manewry + dystans + czas
                 ↓
Wybór wariantu i podgląd na mapie
                 ↓
Nawigacja: dopasowanie GPS, ETA i dane ruchu
                 ↓
Zjazd / zamknięcie → przeliczenie z aktualnej pozycji
```

Przykładowy JSON dla zwykłego auta bez przystanków, z wyjazdem teraz i unikaniem opłat:

```json
{
  "locations": [
    { "lat": 52.2297, "lon": 21.0122 },
    { "lat": 52.4064, "lon": 16.9252, "preferred_side": "either" }
  ],
  "costing": "auto",
  "costing_options": {
    "auto": {
      "maneuver_penalty": 12.0,
      "use_highways": 1.0,
      "use_living_streets": 0.0,
      "service_penalty": 30.0,
      "use_tolls": 0.0,
      "shortest": false
    }
  },
  "date_time": { "type": 0 },
  "units": "kilometers",
  "directions_options": { "language": "pl-PL" },
  "alternates": 2,
  "prioritize_bidirectional": true,
  "turn_lanes": true,
  "roundabout_exits": true,
  "admin_crossings": true
}
```

Współrzędne w przykładzie ilustrują strukturę, nie są wynikiem wykonanego zapytania. Kierunek startu, punkty wykluczeń i omijane obszary są dodawane tylko wtedy, gdy są dostępne lub ustawione.

Odpowiedź zawiera trasę główną i opcjonalne alternatywy. Aplikacja dekoduje geometrię polyline6, łączy odcinki kolejnych etapów, przelicza kilometry na metry i zapisuje manewry oraz informacje o trasie. Odrzuca wynik bez prawidłowej geometrii, dodatniego skończonego dystansu lub poprawnego czasu. W zwykłym planowaniu błąd usuwa podgląd i pokazuje komunikat; przy nieudanym przeliczeniu podczas jazdy pozostaje poprzednia trasa z komunikatem błędu.

### Jak interpretować wynik

- „Najszybsza” oznacza najlepszy czas wśród otrzymanych i porównanych wariantów, w granicach dostępnych danych.
- „Unikaj” opłat, autostrad i promów jest preferencją profilu. Nie gwarantuje braku takich odcinków.
- „Najkrótsza” zmienia profil obliczania w Valhalli oraz ranking wariantów w aplikacji na dystans. Dotyczy też wykonalnych planów EV i objazdów.
- Brak danych TomTom nie oznacza pustej drogi. Dane ruchu nie są bezpośrednio wgrywane do grafu Valhalli.
- Obsługa parametru przez klienta nie potwierdza obsługi ani świeżości danych konkretnego serwera lub paczki offline.


## 17. Ranking i ocena wariantów

Preferencję można wybrać w „Profile i preferencje” → „Dojazd i wybór trasy”. Starsze zapisane ustawienie `shortest = true` pozostaje preferencją najkrótszej trasy. Brak nowego pola w zapisanej konfiguracji zachowuje tryb najszybszy.

| Preferencja | Kryterium porównania |
|---|---|
| Najszybsza | Pozostały czas; w początkowym wyborze czas Valhalli, w porównaniu podczas jazdy ETA z ruchem |
| Najkrótsza | Dystans; serwer otrzymuje również `shortest = true` |
| Zrównoważona | Znormalizowane koszty czasu, dystansu, manewrów, znanej nawierzchni i pokrycia ruchem |
| Wygodna | Te same znormalizowane składowe z większą wagą manewrów |

Koszt manewrów jest umowną wagą w sekundach rankingu: zawracanie 45, ostry skręt 18, zwykły skręt lub wjazd na rondo 8, łagodny skręt, zjazd, wybór odnogi lub włączenie do ruchu 4. Początek, cel, jazda prosto i wyjazd z tego samego ronda nie dodają tej wagi. Heurystyka nie jest pomiarem opóźnienia i nie zmienia `expectedTravelTime`.

Dla znanej nierównej lub nieutwardzonej nawierzchni waga wynosi 30 jednostek za kilometr. Częściowa lub brakująca informacja o nawierzchni wyłącza tę składową dla całego porównywanego zestawu, aby nie nagradzać wariantów z uboższymi danymi. Kierowca nadal może użyć unikania dróg gruntowych w żądaniu do silnika.

`RouteScore` przechowuje osobno czas, dystans, znane opóźnienie ruchu i koszt manewrów. Koszt nawierzchni jest opcjonalny. Koszt opłat pozostaje nieznany. Od P1 ocena jakości danych ruchu korzysta ze świeżego pokrycia pomiarami; nie jest statystyczną wiarygodnością przejazdu ani prawdopodobieństwem przyjazdu na czas. Tryb ECO, historia ruchu, personalizacja ETA i rzeczywiste krzywe ładowania pojazdów nie należą do tego zakresu zmian.

Podobieństwo tras jest mierzone kierunkowo w komórkach co około 50 m, z tolerancją 15 m oraz zgodnością kierunku do 30°. Dla długich tras limit 4000 komórek zwiększa odstęp. Wynik to przybliżony wspólny dystans podzielony przez długość krótszej geometrii. Próg 80% nie gwarantuje zgodności krawędzi OSM. Gdy dostawca poda tylko podobne drogi, użytkownik może otrzymać jeden wariant.

W trakcie jazdy nadal obowiązują warunki jakości danych i minimalna oszczędność czasu przed automatycznym przełączeniem. Wygoda nie powoduje automatycznej zmiany na wolniejszą drogę podczas trwającej nawigacji. Generowanie nowych kandydatów na podstawie korków poza otrzymanymi alternatywami nie jest jeszcze zaimplementowane.

Zakres P0 sprawdzono przez pięć regresji algorytmów uruchomionych na macOS w wydzielonym zestawie z rzeczywistym kodem obliczeń oraz kompilację zestawu testowego iOS z pominięciem istniejących błędów w niezmienionych `TransitousTests.swift` i `NaviAstraTests.swift`. Nie wykonano przejazdu ani zapytań z rzeczywistą lokalizacją. W środowisku nie ma zainstalowanego runtime’u symulatora iOS. Integracja działającego serwera z wykluczaniem geometrii pozostaje niezweryfikowana w ruchu rzeczywistym.

Parametry wykluczeń są opisane w [API Valhalli](https://valhalla.github.io/valhalla/api/route/api-reference/#other-request-options). Zakres pól zdarzeń pochodzi z [TomTom Orbis Incident Details](https://docs.tomtom.com/traffic-api/documentation/tomtom-orbis-maps/v2/traffic-incidents/incident-details), a klasy FRC i ograniczenia geometrii przepływu z [TomTom Flow Segment Data](https://docs.tomtom.com/traffic-api/documentation/tomtom-maps/v1/traffic-flow/flow-segment-data).


## 18. Rozwinięcie P1 w wersji 1.1.71

P1 dodaje lokalną diagnostykę i odtwarzanie rankingu, 120 scenariuszy syntetycznych, wspólny map matching z oceną niejednoznaczności, `TrafficCoverage`, jakość danych ETA, kontekst wjazdu/wyjazdu z parkingu, tekstowe prowadzenie po pasach i dynamiczny moment komunikatów. Koszty rankingu zrównoważonego i wygodnego są normalizowane. Brak danych nie jest interpretowany jako zerowy koszt, a jakość ETA nie jest zmyślonym przedziałem „± kilka minut”.

Szczegóły działania, wagi, instrukcja diagnostyki i granice benchmarków znajdują się w [ROUTING_P1.md](ROUTING_P1.md). [Raport 120 scenariuszy syntetycznych](benchmarks/p1-synthetic-baseline.json) jest oddzielony od przyszłego zbioru rzeczywistych przejazdów.
