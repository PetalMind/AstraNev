# Wyznaczanie tras samochodowych w NaviAstra

Stan dokumentacji: 5 października 2026 r., wersja aplikacji 1.1.48 (build 50).

Dokument opisuje działanie wynikające z kodu aplikacji. Nie potwierdza aktualności danych ani konfiguracji działającego serwera tras. Dotyczy trybu samochodowego; ogólny opis wszystkich trybów znajduje się w [ROUTING.md](ROUTING.md).

## 1. Na jakiej podstawie powstaje trasa

NaviAstra przekazuje początek, cel, punkty pośrednie i preferencje do serwera **Valhalla**, który oblicza przebieg drogi, manewry, dystans i podstawowy czas przejazdu. Aplikacja porównuje warianty według czasu przejazdu zwróconego przez Valhallę. Podczas jazdy może korygować czas i wybór wariantu na podstawie danych **TomTom**, a przy zgłoszonym zamknięciu poprosić Valhallę o objazd.

| Źródło / element | Do czego służy |
|---|---|
| Valhalla i graf drogowy jej serwera | Obliczenie drogi możliwej do przejechania samochodem, wariantów, manewrów i czasu bazowego |
| OpenStreetMap przez Overpass | Ustalenie dojazdu do POI, parkingów i parametrów stacji ładowania |
| GPS urządzenia | Początek podróży, kierunek jazdy, postęp i wykrywanie zjazdu z trasy |
| Preferencje kierowcy | Ograniczenie korzystania z opłat, autostrad, promów i dróg gruntowych |
| TomTom, jeśli skonfigurowany i dostępny | Prędkości ruchu i zdarzenia; korekta ETA, porównywanie istniejących wariantów, wykrywanie zamknięć |
| Parametry EV podane przez użytkownika | Planowanie ładowania i jego szacowanego czasu |

Domyślnym adresem routingu jest `https://valhalla1.openstreetmap.de`. Można skonfigurować własny serwer. Klient wymaga HTTPS; dla domyślnego hosta rozdziela żądania odstępem co najmniej 1,1 s. Zwykłe żądanie trasy ma timeout 15 s. Wyznaczanie trasy wymaga połączenia z serwerem; ten mechanizm nie oblicza nowych tras offline na urządzeniu.

Mapa wyświetlająca drogę i silnik wyznaczający trasę pełnią różne role. Użycie MapKit do renderowania na macOS nie zmienia samochodowego dostawcy tras na Apple.

## 2. Co bierze pod uwagę silnik drogowy

Samochód korzysta z profilu `auto`. Według [dokumentacji Valhalli](https://valhalla.github.io/valhalla/api/route/api-reference/) profil szuka trasy o krótkim czasie, uwzględniając także koszt skrzyżowań i manewrów. Nie gwarantuje bezwzględnie najkrótszego czasu ani dystansu.

Graf serwera reprezentuje połączenia dróg oraz ich zasady dostępu, kierunki i ograniczenia skrętów. Ich poprawność zależy od danych i sposobu przygotowania grafu. Podstawowe prędkości zależą m.in. od tagów OSM i domyślnych wartości klas dróg; `speed` używane do obliczeń i `speed_limit` do prezentacji są odrębnymi polami. Szczegóły opisuje [dokumentacja prędkości Valhalli](https://valhalla.github.io/valhalla/concepts/speeds/).

NaviAstra ustawia `shortest = false`, `maneuver_penalty = 12`, `service_penalty = 30` i `use_living_streets = 0`. Jeżeli unikanie autostrad jest wyłączone, przekazuje `use_highways = 1`; włączenie unikania ustawia 0. Pozostałe wagi pozostawia profilowi i konfiguracji serwera. Nie sprawdza daty aktualizacji jego grafu ani dostępności jego danych historycznego i bieżącego ruchu.

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

Zwykła trasa nie jest optymalizowana pod cenę paliwa, sumę opłat ani koszt całej podróży. „Unikaj opłat” nie oblicza kwoty, którą kierowca zapłaci.

## 5. Punkty pośrednie i warianty

Można dodać do ośmiu punktów pośrednich. Zwykłe wyznaczanie odwiedza je w bieżącej kolejności. Dla miejsc POI również rozwiązuje punkty dojazdu.

Osobna akcja optymalizacji korzysta z `/optimized_route`, zachowuje początek i cel, sprawdza zwrócone indeksy, zmienia kolejność przystanków i ponownie wyznacza trasę. Nie uruchamia się automatycznie przy każdym planowaniu. Jej timeout wynosi 25 s.

Bez punktów pośrednich aplikacja prosi o dwie alternatywy, więc może otrzymać do trzech tras łącznie. Nie musi otrzymać wszystkich. Dla trasy z punktami pośrednimi wysyła `alternates = 0`. Początkowy wybór zwykłej trasy porównuje czas bazowy zwrócony przez Valhallę. Od wersji 1.1.48 dostawca zwraca gotowe warianty bez dodatkowego zapytania Overpass o światła. Poprzednie zapytanie wykonywało się po odpowiedzi Valhalli i mogło opóźniać pokazanie trasy, również przy objazdach i wielokrotnych obliczeniach EV. Aplikacja nie porównuje obecnie wariantów według liczby świateł; preferencje dróg wynikają z opcji profilu samochodowego opisanych powyżej. Użytkownik może wybrać inny wariant. Planowanie EV stosuje dodatkowy ranking opisany poniżej.

Zmiana planu anuluje poprzednią pracę. Kontrola generacji żądania chroni przed nadpisaniem nowej trasy spóźnioną odpowiedzią.

## 6. Jak ruch wpływa na trasę

TomTom wymaga skonfigurowanego klucza. Brak konfiguracji, błąd pobierania i brak świeżych danych mają osobne stany; brak informacji nie dowodzi braku korków.

NaviAstra pobiera dane w okolicy pozycji oraz w korytarzu pozostałej trasy. Horyzont korytarza odpowiada do 25 minutom jazdy, z limitem dystansu zależnym od średniej prędkości: 18 km poniżej 45 km/h, 35 km poniżej 85 km/h, 100 km przy wyższej prędkości. Obejmuje najwyżej pozostałą długość trasy.

Zdarzenia są pobierane w obszarach wzdłuż drogi. Dopasowanie liniowego zdarzenia wymaga ciągłego wspólnego odcinka z trasą i zgodności osi drogi do 30°. Tolerancja wynosi 10 m dla zamknięć i 20 m dla innych zdarzeń; wymagane nakładanie to co najmniej mniejsza z wartości 30 m i 80% długości zdarzenia. Punktowe zamknięcie bez geometrii odcinka nie uruchamia objazdu ani komunikatu o zamknięciu trasy. Próbki przepływu również wymagają dopasowania osi drogi. Przepływ ruchu jest próbkowany w maksymalnie 20 punktach; na dłuższej trasie nie stanowi ciągłego pomiaru każdego odcinka. Próbka z podaną pewnością poniżej 0,5 jest pomijana. Bliskość geometrii sama nie gwarantuje poprawnego rozróżnienia równoległych jezdni.

Odświeżanie zależy od stanu nawigacji, pracy w tle i polityki energii. Dla korytarza na pierwszym planie standardowy odstęp wynosi co najmniej 60 s podczas jazdy lub 90 s w podglądzie. Zdarzenie do 10 km pozwala na odstęp co najmniej 30 s, zależny od polityki energii; zamknięcie do 3 km ustawia 20 s. Próbki przepływu są pobierane ponownie po 180 s lub zmianie trasy. Dane korytarza o zdarzeniach wygasają po 120 s, o przepływie po 240 s, pobliski snapshot po 180 s.

### Wybór szybszego wariantu podczas jazdy

Aplikacja porównuje już dostępne warianty Valhalli najwyżej raz na 180 s. Sprawdza możliwość kontynuowania wariantu z obecnej pozycji i kierunku. Wymaga udanego pobrania zdarzeń, co najmniej 75% żądanych próbek przepływu oraz dopasowanych odcinków ruchu.

Przełączenie wymaga oszczędności co najmniej:

`max(120 sekund, 15% pozostałego czasu obecnej trasy)`

Przykład: przy pozostałych 20 minutach oszczędność musi wynosić co najmniej 3 minuty. Przy 8 minutach — co najmniej 2 minuty. Mechanizm działa podczas nawigacji, nie sortuje automatycznie zwykłych wariantów w początkowym podglądzie według TomTom.

TomTom nie zastępuje silnika trasowania i aplikacja nie zapisuje jego feedu do grafu Valhalli. Porównanie wariantów nie jest pełnym przeszukiwaniem wszystkich możliwych dróg z uwzględnieniem korków.

## 7. Czas przejazdu i przewidywany przyjazd

Początkowy czas pochodzi z Valhalli. Podczas jazdy wspólny model `RoadRouteETA` liczy pozostały czas na podstawie czasów manewrów przypisanych do odcinków geometrii. Dla brakujących zakresów używa proporcji czasu bazowego całej drogi.

Po co najmniej 45 s ruchu i przejechaniu ponad 25 m aplikacja uwzględnia obserwowane tempo podróży. Porównuje średnią prędkość zaplanowaną i zaobserwowaną, ogranicza ich iloraz do 0,65–1,8 i stosuje 55% wynikającej korekty. Ta korekta dotyczy wyświetlanego postępu; porównanie alternatyw używa domyślnego mnożnika 1.

Świeże prędkości TomTom zwiększają czas na zmierzonych zakresach, gdy przejazd wychodzi wolniejszy od bazowego. Nie skracają go poniżej tego oszacowania. Opóźnienie zdarzenia jest doliczane tylko przed kierowcą i poza odcinkami już pokrytymi pomiarem przepływu, aby nie liczyć go dwukrotnie. Pozostałe postoje ładowania zwiększają ETA.

Zamknięcie na pozostałej drodze oznacza nieskończony koszt w ocenie wariantu. Podczas szukania objazdu interfejs zachowuje skończony czas bazowy. Wyświetlany wówczas czas nie potwierdza przejezdności zamkniętej drogi.

## 8. Kiedy powstaje nowa trasa

### Zjazd z wyznaczonej drogi

`OffRouteDetector` wymaga jednocześnie dokładności GPS do 45 m, odległości od trasy większej niż `max(40 m, 1,5 × dokładność GPS)` oraz pewności dopasowania poniżej 0,25. Dodatkowo kurs musi różnić się od drogi o co najmniej 55° albo pewność musi spaść poniżej 0,1.

Dowód zjazdu musi obejmować co najmniej trzy różne pomiary przez minimum 2 s. Między automatycznymi próbami musi minąć więcej niż 20 s. Nowa trasa zaczyna się w aktualnej pozycji i zachowuje pozostałe punkty planu. Rozpoznawanie pozostałych przystanków korzysta z postępu po starej geometrii; zwykły próg wynosi ponad 50 m przed kierowcą, z wyjątkiem punktów oznaczonych jako priorytetowe.

### Zamknięcie drogi

Automatyczny objazd uruchamia świeże zdarzenie kategorii zamknięcia, dopasowane do trasy, ponad 100 m przed kierowcą i wewnątrz horyzontu monitorowania. Nie wystarcza słowo „zamknięcie” w opisie ani samo zamknięcie pojedynczego pasa.

Aplikacja przekazuje omijane współrzędne jako `exclude_locations`, a następnie odrzuca wariant przechodzący bliżej niż 30 m od któregoś z tych punktów. Jest to kontrola punktów geometrii; nie stanowi dowodu ominięcia całego fizycznego obszaru zamknięcia. Po błędzie zachowuje dotychczasową trasę i pokazuje komunikat, a próbę dla danego zdarzenia może ponowić po 60 s.

## 9. Planowanie samochodem elektrycznym

EV jest opcjonalne. Korzysta z zadeklarowanych przez użytkownika: zasięgu przy pełnym naładowaniu, procentu baterii, zużycia kWh/100 km, maksymalnej mocy ładowania auta i typów złączy. Dostępny zasięg wynosi:

`zasięg pełny × procent baterii / 100`

Planner używa 80% dostępnego zasięgu jako limitu odcinka, zachowując margines 20%. Przykładowo deklarowane 400 km i 50% baterii dają 200 km dostępnego zasięgu i 160 km limitu pierwszego odcinka.

Sprawdza do trzech tras bazowych. Dla dłuższych dróg szuka stacji OSM w korytarzu 3 km, z limitem 1000 wyników. Kandydat musi mieć dodatnią znaną moc i opisane złącza; odrzucane są stacje oznaczone jako niedostępne lub niepubliczne. Przy wybranych złączach wymagana jest zgodność, a `ccs` uwzględnia też `type2_combo`. Nieznana dostępność nie musi wykluczać stacji i nie jest potwierdzeniem wolnego stanowiska.

Wyszukiwanie zachowuje ograniczoną liczbę sekwencji, do trzech planów na wariant bazowy, z maksymalnie dziesięcioma ładowaniami w sekwencji. Dla wybranych stacji ponownie oblicza rzeczywisty dojazd Valhallą i kontroluje wykonalność odcinków. Ranking końcowy porównuje czas jazdy wraz z ładowaniem, zwracając do trzech wyników. Nie gwarantuje globalnie najlepszego planu.

Czas ładowania bierze mniejszą z mocy auta i stacji. Szacowana pojemność baterii wynika z zasięgu i zużycia. Model przyjmuje 85% mocy do 60% SOC, 65% między 60 a 80% i 35% powyżej 80%, oraz 5 minut na obsługę postoju. To ogólna heurystyka, bez krzywej konkretnego samochodu, temperatury baterii i czasu kolejki. Wstępny wybór sekwencji używa uproszczonej oceny; dokładniejszy model ładowania stosowany jest po trasowaniu.

Brak poprawnych parametrów lub wykonalnego zestawu stacji kończy się błędem planowania EV.

## 10. Czego aplikacja obecnie nie uwzględnia

| Czynnik | Granica obecnej implementacji |
|---|---|
| Pogoda, śnieg, temperatura | Nie są osobnymi parametrami obliczenia trasy ani zużycia EV; niektóre zagrożenia mogą być zdarzeniami TomTom |
| Godzina planowanego wyjazdu auta | Żądanie drogowe nie przekazuje `date_time`; nie zapewnia planowania przyszłych korków na wybraną godzinę |
| Ograniczenia czasowe | Odpowiedź może raportować ich obecność; bez daty podróży nie należy deklarować pełnej oceny na konkretną godzinę |
| Wymiary i masa pojazdu | Brak profilu ciężarówki i przekazywania gabarytów auta |
| Strefy emisji i uprawnienia do wjazdu | Brak przekazywania klasy emisji, zezwoleń i indywidualnej kwalifikacji kierowcy |
| Ceny paliwa, energii i opłat | Nie są kryterium rankingu trasy samochodowej |
| Rzeczywisty SOC i zużycie auta | Brak telemetrii pojazdu; EV bazuje na konfiguracji użytkownika |
| Wolne miejsca parkingowe i kolejki do ładowarek | Brak potwierdzenia na żywo |
| Fotoradary i ostrzeżenia drogowe | Służą prowadzeniu i ostrzeganiu; aplikacja nie stosuje ich jako własnego kryterium unikania drogi |

Informacja o limicie prędkości, pasach lub ostrzeżeniu w interfejsie nie oznacza automatycznie, że została użyta jako osobny czynnik wyboru trasy przez aplikację. Serwer może uwzględniać część cech w swoim modelu, ale jego aktualnej konfiguracji ten przegląd nie weryfikuje.

## 11. Przykład całego procesu

Kierowca wybiera sklep jako cel i włącza unikanie opłat. NaviAstra ustala świeży początek GPS i próbuje znaleźć dojazd na parking sklepu. Wysyła do Valhalli współrzędne, profil `auto` oraz `use_tolls = 0`, prosząc o alternatywy, jeśli nie ma przystanków. Wybiera wariant według czasu zwróconego przez Valhallę, pokazując jego czas bazowy.

Po rozpoczęciu jazdy dopasowuje GPS do drogi i aktualizuje ETA. Dostępny ruch TomTom może zwiększyć czas. Gdy inny otrzymany wariant można kontynuować z obecnej pozycji i daje wymaganą oszczędność przy wystarczających danych, aplikacja może przełączyć trasę. Świeże zamknięcie przed autem uruchamia osobne żądanie objazdu. Włączony tryb EV dodaje ocenę zasięgu i postojów ładowania.

## 12. Podstawa w kodzie

| Zakres | Pliki źródłowe |
|---|---|
| Wybór dostawcy i endpointu | [AppDependencies.swift](../NaviAstra/App/AppDependencies.swift), [NavigationSessionDependencies.swift](../NaviAstra/Navigation/Engine/NavigationSessionDependencies.swift) |
| Parametry żądań i odpowiedzi Valhalli | [ValhallaRouteProvider.swift](../NaviAstra/Navigation/ValhallaRouteProvider.swift) |
| Początek i początkowy wybór wariantu | [NavigationSession+RoutePreview.swift](../NaviAstra/Navigation/NavigationSession+RoutePreview.swift) |
| Routing, kierunek, EV i objazdy | [NavigationSession+Routing.swift](../NaviAstra/Navigation/NavigationSession+Routing.swift) |
| Preferencje i model ładowania | [Models.swift](../NaviAstra/Navigation/Models.swift) |
| Dojazd do POI | [POIAccessResolver.swift](../NaviAstra/Places/POIAccessResolver.swift) |
| Filtr GPS i wykrywanie zjazdu | [LocationFilter.swift](../NaviAstra/Core/Location/LocationFilter.swift), [OffRouteDetector.swift](../NaviAstra/Navigation/Engine/OffRouteDetector.swift) |
| Ruch, ranking i ETA | [NavigationSession+Traffic.swift](../NaviAstra/Navigation/NavigationSession+Traffic.swift), [RouteTrafficMonitor.swift](../NaviAstra/Traffic/RouteTrafficMonitor.swift) |
| Tempo jazdy i postęp | [NavigationSession+Progress.swift](../NaviAstra/Navigation/NavigationSession+Progress.swift) |
| Kategorie zdarzeń | [TrafficProvider.swift](../NaviAstra/Traffic/TrafficProvider.swift) |

Dokument powstał przez przegląd kodu i oficjalnych opisów Valhalli. Nie wykonano przejazdu, zapytań z rzeczywistą lokalizacją ani weryfikacji dostępności usług i świeżości ich danych.

## 13. Znaki i widok podczas jazdy

Znaki na trasie wymagają powiązania z geometrią drogi OSM i zgodności podejścia kierowcy. Kod uwzględnia kierunki `forward` / `backward`, orientację znaku i jednokierunkowość drogi. Niepewne kierunki są pomijane w ostrzeżeniach. Znaki informacyjne bez znaczenia dla przejazdu nie trafiają do banera nawigacji. Znane polskie kody mają nazwy opisowe; kod pozostaje w szczegółach. Dane mapy nadal mogą pokazywać znaki jako kontekst otoczenia.

Kamera samochodowa ustawia pozycję na 86% wysokości odsłoniętej mapy, z zachowaniem minimalnego odstępu od panelu. Etykiety ulic nie wyświetlają stałego dymka obecnej drogi. Pokazują nazwę drogi po manewrze i do dwóch ulic pobocznych przed kierowcą, także przy jeździe prosto, o ile pozwala na to zbliżenie, prędkość i miejsce na ekranie. Jest to własna implementacja inspirowana prezentacją Apple Maps; wewnętrzny algorytm Apple nie jest udostępniony.
