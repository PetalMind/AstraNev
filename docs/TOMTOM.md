# TomTom w NaviAstra iOS

Stan opisany na podstawie bieżącego kodu: 27 października 2026 r.; iOS 1.1.137 (139). Dokument dotyczy aplikacji iOS. Opisuje implementację w repozytorium, a nie potwierdzone działanie konta TomTom, jego limitów lub usług na urządzeniu.

## 1. Do czego używamy TomTom

TomTom dostarcza **bieżące dane o ruchu drogowym**. Korzystamy z niego do rysowania ruchu na mapie, odczytywania prędkości na pobliskiej drodze i wybranych odcinkach trasy, pobierania zdarzeń, korygowania przewidywanego czasu przyjazdu (ETA), porównywania wariantów podczas jazdy oraz wykrywania zamknięć wymagających objazdu.

| Obszar | Zastosowanie TomTom |
|---|---|
| Mapa | Rastrowe kafle przepływu ruchu i zdarzeń, własne znaczniki oraz kolory zmierzonych odcinków trasy |
| Bieżące warunki | Prędkość ruchu przy pozycji, prędkość w warunkach swobodnych, zamknięcie odcinka i pobliskie utrudnienia |
| Nawigacja samochodem | Korekta pozostałego czasu, ostrzeżenia i wybór szybszego z dostępnych wariantów |
| Zamknięcie drogi | Dane zdarzenia są podstawą żądania objazdu do Valhalli |
| Zapisane plany samochodowe | Uzupełnienie szacowanego czasu bieżącym ruchem, gdy proponowany wyjazd jest za mniej niż godzinę |
| Ocena jakości ETA | Obliczenie pokrycia drogi świeżymi pomiarami; brak danych pozostaje widoczny |

Nie korzystamy z TomTom Navigation SDK ani TomTom Routing API. Własny adapter Swift pobiera dane przez HTTPS. **Valhalla wyznacza geometrię trasy, manewry i czas bazowy**, a NaviAstra nakłada na otrzymane warianty dane TomTom. Nie zapisujemy tego feedu do grafu ani kafli live traffic Valhalli.

TomTom nie dostarcza nam mapy bazowej, wyszukiwarki miejsc, adresów, limitów prędkości ani kamer drogowych. Mapa bazowa korzysta z MapLibre i OpenFreeMap; wyszukiwanie z Photon, MapKit i UUG, a limity i kamery z OSM oraz mechanizmów Valhalli. Średnia prędkość ruchu TomTom nie jest prawnym limitem prędkości ani pomiarem prędkości naszego pojazdu.

## 2. Z których usług i endpointów korzystamy

Wszystkie poniższe adresy mają host `api.tomtom.com`. Klucz w przykładach oznaczono jako `<KLUCZ>`; dokument nie zawiera rzeczywistych danych dostępowych.

| Usługa | Żądanie używane w kodzie | Cel |
|---|---|---|
| Flow Segment Data — klasyczne Traffic API | `GET /traffic/services/4/flowSegmentData/absolute/16/json?key=<KLUCZ>&point=<lat>,<lon>&unit=kmph` | Pomiar ruchu dla odcinka najbliższego wskazanemu punktowi |
| Orbis Traffic Incident Details v2 | `GET /maps/orbis/traffic/incidents/details?apiVersion=2&bbox=<minLon>,<minLat>,<maxLon>,<maxLat>&timeValidity=present` | Strukturalne dane aktualnych zdarzeń w zadanym obszarze |
| Orbis Raster Flow Tiles v2 | `GET /maps/orbis/traffic/flow/raster/tile/{z}/{x}/{y}?apiVersion=2&key=<KLUCZ>&style=<light albo dark>&tileSize=256` | Obraz ruchu w widocznym obszarze mapy |
| Orbis Raster Incident Tiles v2 | `GET /maps/orbis/traffic/incidents/raster/tile/{z}/{x}/{y}?apiVersion=2&key=<KLUCZ>&style=<light albo dark>&tileSize=256` | Obraz zdarzeń w widocznym obszarze mapy |

Integracja łączy klasyczny endpoint Flow Segment Data z endpointami Orbis v2. Nie używamy wektorowych kafli ruchu, OpenLR ani historycznego lub prognostycznego feedu TomTom.

### Pomiar przepływu

Adapter `TomTomTrafficProvider` dekoduje:

| Pole | Jak je wykorzystujemy |
|---|---|
| `currentSpeed` | Bieżąca średnia prędkość ruchu; kolor odcinka i czas przejazdu |
| `freeFlowSpeed` | Prędkość w warunkach swobodnych; punkt odniesienia dla koloru |
| `confidence` | Jakość pomiaru; wartości poniżej 0,5 są odrzucane przy dopasowaniu do trasy, brak wartości sam w sobie nie odrzuca próbki |
| `roadClosure` | Zamknięcie odcinka; prezentacja i ocena ETA/wiarygodności |
| `coordinates.coordinate` | Geometria potrzebna do dopasowania pomiaru do naszej trasy |
| `frc` | Klasa drogi, używana także przy wyborze gęstości kolejnych próbek |

Pomiar z ujemną prędkością albo niedodatnim `freeFlowSpeed` jest odrzucany. Jeśli otrzymana linia ma co najmniej dwa punkty i leży ponad 80 m od punktu zapytania, adapter również ją odrzuca. Zapisany `updatedAt` oznacza czas odczytu przez aplikację, nie źródłowy czas pomiaru TomTom.

API udostępnia także `currentTravelTime` i `freeFlowTravelTime`, ale nasz parser nie odczytuje tych pól. Czas korekty liczymy z prędkości i długości dopasowanego odcinka. Znaczenie pól oraz przesunięcie geometrii zależne od zoomu opisuje [dokumentacja Flow Segment Data](https://docs.tomtom.com/traffic-api/documentation/tomtom-maps/v1/traffic-flow/flow-segment-data).

### Szczegóły zdarzeń

Klucz jest wysyłany w nagłówku `TomTom-Api-Key`; wersja w `TomTom-Api-Version: 2`. Wysyłamy też `Accept: application/json` i `Accept-Language: pl-PL`. Nagłówek `Attributes` wybiera następujące dane:

```text
incidents(type,geometry(type,coordinates),properties(id,events(description,code,iconCategory),delayInSeconds,iconCategory,magnitudeOfDelay,roadNumbers,startTime,endTime,numberOfReports,lastReportTime,probabilityOfOccurrence))
```

Zachowujemy identyfikator, geometrię, kategorię, skalę utrudnienia, opóźnienie, numery dróg, wszystkie szczegóły `events`, czas początku i końca oraz dostępne informacje o zgłoszeniach. Zdarzenia przyszłe i wygasłe są odrzucane. Wyniki z kilku obszarów są łączone po identyfikatorze; przy braku ID adapter tworzy zastępczy identyfikator z kategorii i końców geometrii.

Model obsługuje m.in. wypadek, korek, roboty, zamkniętą drogę lub pas, mgłę, deszcz, oblodzenie, wiatr, podtopienie i unieruchomiony pojazd. Rozpoznaje też starsze wartości objazdu i zbiorczego utrudnienia. Samo istnienie kategorii w modelu nie gwarantuje jej dostępności w odpowiedzi konkretnej usługi.

Prosimy o polskie opisy, jednak TomTom dopuszcza angielski tekst, gdy nie ma tłumaczenia. Obecny parser zachowuje opis dostawcy bez własnego tłumaczenia. Polskie etykiety kategorii są w aplikacji, ale nagłówek języka nie gwarantuje polskiego tekstu każdego szczegółu. Schemat, nagłówki i tę zasadę opisuje [Orbis Incident Details v2](https://docs.tomtom.com/traffic-api/documentation/tomtom-orbis-maps/v2/traffic-incidents/incident-details).

## 3. Jak pobieramy dane

### Wokół bieżącej pozycji

`snapshot(near:incidentRadiusMeters:)` równolegle pobiera jeden pomiar przepływu oraz zdarzenia z prostokąta wokół pozycji. Sesja stosuje promień pomocniczy 3,5 km do wyliczenia tego prostokąta; nie jest to ścisłe filtrowanie wyników do koła.

Jeżeli jedna usługa odpowie, a druga zawiedzie, zachowujemy dostępną część wraz z komunikatem o brakujących danych. Gdy obie zawiodą, odświeżenie kończy się błędem.

### Wzdłuż wybranej trasy

`RouteTrafficMonitor` wyznacza korytarz przed pojazdem, odpowiadający około 25 minutom pozostałej jazdy. Horyzont ogranicza do końca trasy i maksymalnie 18 km, 35 km albo 100 km, zależnie od oszacowanej średniej prędkości.

Zapytania o zdarzenia obejmują fragmenty trasy długości do 8 km, z nakładaniem 1 km i marginesem 900 m po bokach przy wyliczaniu prostokąta. Obszary są prostokątami obejmującymi geometrię, a nie dokładnym buforem wokół każdej drogi.

Przepływ próbkujemy w punktach trasy. Odstępy zależą od dostępnej klasy FRC, oznaczenia autostrady i prędkości bazowej. Typowy zakres to 350 m–4 km. Część budżetu jest przeznaczona na okolice manewrów i znanych zdarzeń, a ograniczenie liczby punktów zachowuje próbki rozłożone po całym korytarzu.

| Kontekst | Maksymalna liczba próbek przepływu w jednym zestawie |
|---|---:|
| Podgląd trasy | 40 |
| Zwykła nawigacja na pierwszym planie | 64 |
| Wykryty problem na pierwszym planie | 96 |
| Nawigacja w tle | 24 |
| Szacowanie zapisanej podróży | 24 |

To budżet próbek przepływu, nie łączny limit wszystkich żądań. Osobno dochodzą zapytania o zdarzenia, pobliski snapshot, porównania alternatyw i kafle mapy. Adapter wykonuje najwyżej cztery żądania równolegle w danej grupie obszarów albo próbek. Nie jest to globalny limit całej aplikacji. Żądania JSON mają timeout 12 s i akceptują odpowiedzi HTTP 2xx.

### Kiedy odświeżamy

| Dane / działanie | Warunek lub interwał w kodzie |
|---|---|
| Ruch wokół pozycji | Na pierwszym planie zwykle co 90 s; przy oszczędzaniu energii lub wysokiej temperaturze co 120 s |
| Zdarzenia w korytarzu | Zależnie od polityki energii, zwykle co 90 s lub 120 s; na pierwszym planie zamknięcie do 3 km przed autem skraca interwał do 20 s |
| Przepływ na trasie | Co 180 s lub po zmianie identyfikatora trasy |
| Porównanie wariantów podczas jazdy | Nie częściej niż co 180 s |
| Ręczne odświeżenie | Przycisk „Odśwież ruch”; nadal obowiązują warunki trybu i brak równoległego odświeżenia tego samego rodzaju |
| Zwykłe przeglądanie mapy | Polityka energii wyłącza automatyczne zapytania JSON; możliwe jest odświeżenie na żądanie |
| Nawigacja w tle | Pobieramy korytarz trasy; nie pobieramy pobliskiego snapshotu ani warstw usuniętej z widoku mapy |

Wywołania zależą od stanu sesji i aktualizacji lokalizacji; nie są gwarancją wykonania dokładnie co podaną liczbę sekund. Wymuszenie odświeżenia nie omija własnego interwału przepływu dla tej samej trasy. Pobieraniem i cache'em kafli zajmuje się MapLibre; powyższe interwały JSON nie sterują odświeżaniem rastra.

Sesja dopuszcza ruch dla auta oraz odczyt na żądanie w stanie bez aktywnej podróży. Automatyczne porównanie wariantów i objazd zamknięcia są ograniczone do samochodowej nawigacji. Ruch nie jest odświeżany dla podglądu z inną godziną wyjazdu lub przyjazdu niż „teraz”.

## 4. Co pokazujemy na mapie i w interfejsie

W ustawieniach **Ruch drogowy → Bieżące warunki** można sprawdzić stan usługi, pobliskie prędkości, liczbę utrudnień i czas aktualizacji oraz wymusić odświeżenie. Ustawienie widoczności warstwy mapy również nazywa się „Ruch drogowy”.

**Wyłączenie warstwy na mapie nie wyłącza pobierania danych przez sesję ani ich wpływu na ETA.** Steruje prezentacją mapy.

Raster przepływu korzysta z wariantu `light` lub `dark`, stosownie do wyglądu. W obecnym rendererze iOS raster przepływu pozostaje także podczas nawigacji. Raster zdarzeń jest wtedy usuwany, a zdarzenia prezentujemy własnymi znacznikami. Podczas prowadzenia znaczniki TomTom są filtrowane do istotnych kategorii, dopasowanych do trasy i położonych do 12 km przed kierowcą.

Zmierzona część wybranej trasy dostaje kolor z relacji `currentSpeed / freeFlowSpeed`: od swobodnego ruchu, przez spowolnienie, do silnego korka; zamknięcie ma osobny kolor. Niezmierzone fragmenty zachowują kolor bazowy trasy. Nie oznacza to potwierdzenia swobodnego ruchu. Przejechany fragment jest wygaszany.

Dokumentacja kafli: [Orbis Raster Flow Tiles](https://docs.tomtom.com/traffic-api/documentation/tomtom-orbis-maps/v2/traffic-flow/raster-flow-tiles) oraz [Orbis Raster Incident Tiles](https://docs.tomtom.com/traffic-api/documentation/tomtom-orbis-maps/v2/traffic-incidents/raster-incident-tiles).

## 5. Jak dane wpływają na trasę

### Dopasowanie do drogi

Punkt blisko trasy nie wystarcza do potwierdzenia zamknięcia. Wymagamy ciągłego pokrycia geometrii i zgodności przebiegu; numery dróg są dodatkowym sprawdzeniem, gdy można je porównać. Dla zamknięć tolerancja pokrycia wynosi 10 m, dla pozostałych zdarzeń 20 m. Zdarzenie punktowe może być dopasowane jako kontekst, ale nie jako zamknięcie wymagające objazdu.

Pomiar przepływu dla obliczeń wymaga pokrycia przy tolerancji 10 m. Kolorowanie korzysta z osobnego przygotowania geometrii: zagęszcza ją co około 15 m i dopuszcza 30 m tolerancji. Odcinki przeznaczone tylko do prezentacji nie zawierają prędkości dla ETA. Kolor na mapie nie jest więc równoważny kwalifikacji danych do obliczeń.

Adapter pozostawia kierunek geometrii jako nieznany. Nie mamy wspólnych identyfikatorów krawędzi TomTom/OSM ani potwierdzonego poziomu jezdni. Równoległe drogi, przeciwne jezdnie, mosty i estakady pozostają źródłem niejednoznaczności.

### Czas przyjazdu

`RoadRouteETA` bierze czas bazowy z odcinków Valhalli. Dla świeżego, dopasowanego pomiaru wylicza czas z długości i bieżącej prędkości; dolicza tylko dodatnią różnicę względem bazowego oszacowania. TomTom nie skraca czasu poniżej tej podstawy.

Opóźnienie zdarzenia jest doliczane przed pojazdem, jeśli miejsce zdarzenia nie leży w przedziale już objętym pomiarem przepływu. Zapobiega to prostemu podwójnemu liczeniu. Zamknięcie w pomiarze lub dopasowanym zdarzeniu oznacza nieskończony koszt wariantu. Interfejs podczas szukania objazdu może nadal pokazywać skończony czas bazowy; nie potwierdza on przejezdności.

Oprócz TomTom na ETA wpływają istniejące mechanizmy aplikacji, m.in. obserwowane tempo jazdy i postoje ładowania. Nie cały wyświetlany czas jest wynikiem TomTom.

### Szybszy wariant

Podczas nawigacji samochodem porównujemy warianty już otrzymane od Valhalli. Mechanizm jest wyłączony przy preferencji najkrótszej trasy. Wymaga możliwości kontynuowania wariantu z bieżącej pozycji i kierunku, udanych zapytań o zdarzenia, co najmniej 75% odpowiedzi na próbki oraz świeżego pokrycia minimum 50% każdego porównywanego korytarza. Pokrycie kandydata nie może być gorsze o więcej niż 10 punktów procentowych.

Wariant wskazany przez wspólny ranking musi oszczędzać co najmniej `max(120 s, 15% pozostałego czasu obecnej trasy)`. Zmiana może być ogłoszona głosowo. Zwykły początkowy podgląd nie jest automatycznie sortowany według TomTom. Nie jest to pełne przeszukiwanie wszystkich dróg pod kątem korków.

### Objazd zamknięcia

Automatyczne przeliczenie uruchamia świeże zdarzenie kategorii `roadClosed`, dopasowane do trasy, ponad 100 m przed autem i wewnątrz horyzontu monitorowania. Zamknięty pas ani samo słowo „zamknięcie” w opisie nie wystarczają. Flaga `roadClosure` w pomiarze przepływu wpływa na ETA i ocenę danych, ale ten mechanizm automatycznego objazdu wymaga zdarzenia.

`RoadClosureAvoidance` przygotowuje obszary wykluczeń z geometrii zdarzenia. Przekazujemy je do Valhalli jako `exclude_polygons` i sprawdzamy, czy odpowiedź omija te obszary. Szczegóły oraz ograniczenia opisuje [dokumentacja tras samochodowych](CAR_ROUTING.md).

### Zapisane podróże

`TripPlanningService` najpierw liczy trasę Valhallą. Gdy proponowany wyjazd samochodem jest za mniej niż godzinę, osobno pobiera bieżący ruch na całej geometrii, z budżetem 24 próbek przepływu. Nie jest to prognoza ruchu na zaplanowaną godzinę. Brak klucza albo brak dopasowanych pomiarów pozostawia czas silnika tras z odpowiednią informacją. Wykryte zamknięcie powoduje błąd odświeżenia z komunikatem o konieczności wyboru innej trasy, zamiast automatycznego objazdu planu.

## 6. Świeżość, błędy i ograniczenia danych

Sesja przechowuje bieżący snapshot i zestawy danych w pamięci. Pobliskie dane są publikowane do 180 s od odczytu, zdarzenia korytarza do 120 s, a przepływ trasy do 240 s. ETA dodatkowo sprawdza wiek poszczególnych pomiarów i zdarzeń. Nie mamy własnej trwałej bazy surowego feedu TomTom do pracy offline; zapisany plan może zachować wynikowe oszacowanie czasu.

Stan usługi rozróżnia brak konfiguracji, pobieranie, dostępność i błąd. Snapshot może być częściowy. Ocena `TrafficCoverage` liczy faktyczne pokrycie świeżymi pomiarami; jakości ETA nie przedstawiamy jako skalibrowanego prawdopodobieństwa przyjazdu o czasie. Brak danych nie dowodzi braku korków. Karta bieżących warunków potrafi pokazać pustą listę zgłoszeń obok informacji o częściowym błędzie, dlatego sam licznik nie potwierdza kompletności danych.

Publiczny schemat Incident Details nie dokumentuje kontroli policyjnych jako osobnej kategorii. Nie zgadujemy ich z tekstu ani numerycznych kodów REST; kody SDK TPEG nie są mapowaniem kodów tego API. Dane o liczbie zgłoszeń pochodzą od TomTom. NaviAstra nie wysyła zgłoszeń użytkowników do TomTom i nie podłącza tutaj Waze ani HERE. Szczegóły: [zdarzenia drogowe](ROAD_EVENTS.md).

## 7. Klucz i konfiguracja

1. Na nowym stanowisku skopiuj `Config/Secrets.example.xcconfig` do `Config/Secrets.local.xcconfig`.
2. Uzupełnij lokalnie `TOMTOM_API_KEY` kluczem z dostępem do używanych usług Traffic.
3. Dostarcz ten lokalny plik także w środowisku budowania; jest wykluczony z Git.
4. Zbuduj aplikację iOS. Zarówno Debug, jak i Release korzystają z `Config/App.xcconfig`, który włącza lokalny plik.

Podczas budowania klucz trafia do pola `TomTomAPIKey` w Info.plist. `TrafficCredential.read()` odczytuje go z bundle, usuwa zewnętrzne białe znaki i odrzuca pustą lub nierozwiniętą wartość `$(...)`. `AppDependencies` przekazuje go sesji nawigacyjnej.

Klucz nie jest śledzony w źródłach, ale **jest częścią gotowej aplikacji iOS**. Nie należy traktować go jako sekretu ukrytego przed odbiorcą aplikacji. Nie ma edytora klucza w ustawieniach i nie odczytujemy wcześniejszych wartości z pęku kluczy. Zmiana konfiguracji wymaga nowego buildu.

## 8. Co wysyłamy do TomTom i co zużywa limit

Zapytania przepływu wysyłają współrzędne bieżącej pozycji albo punktów geometrii trasy. Zapytania o zdarzenia wysyłają prostokąty wokół pozycji lub korytarza. Żądania kafli wskazują oglądany obszar przez `z/x/y`. Wysyłamy też klucz; dla zdarzeń znajduje się w nagłówku, dla przepływu i kafli w URL.

Adapter nie wysyła nazwy celu, nazw zapisanych planów, ulubionych ani całego pliku historii GPS. Punkty i obszary zapytań mogą jednak ujawniać położenie oraz fragmenty planowanej drogi. Połączenia idą bezpośrednio z urządzenia do TomTom; w tej integracji nie ma własnego serwera pośredniczącego.

Na liczbę żądań składają się: kafle mapy, pobliskie odczyty, wiele próbek i obszarów korytarza, osobne pomiary każdego porównywanego wariantu oraz odświeżenia zapisanych planów. Podane budżety nie są taryfą ani limitem konta. Kod nie odczytuje salda, wykorzystania pakietu lub cennika TomTom. Nie zawiera też osobnej obsługi ponawiania z opóźnieniem dla HTTP 429; odpowiedź jest traktowana jako błąd HTTP. Faktyczne uprawnienia, limity i koszty zależą od konta oraz jego umowy i nie zostały ustalone w tym przeglądzie.

## 9. Gdzie znajduje się implementacja

| Plik | Odpowiedzialność |
|---|---|
| [TrafficProvider.swift](../NaviAstra/Traffic/TrafficProvider.swift) | Endpointy, żądania, dekodowanie, wspólne modele i odczyt klucza |
| [RouteTrafficMonitor.swift](../NaviAstra/Traffic/RouteTrafficMonitor.swift) | Korytarz, próbki, dopasowanie oraz osobne odcinki obliczeniowe i prezentacyjne |
| [TrafficRoadIdentity.swift](../NaviAstra/Traffic/TrafficRoadIdentity.swift) | Numery dróg i jawny model kierunku geometrii |
| [TrafficCoverage.swift](../NaviAstra/Traffic/TrafficCoverage.swift) | Pokrycie, jakość danych ETA i budżety próbek |
| [NavigationSession+Traffic.swift](../NaviAstra/Navigation/NavigationSession+Traffic.swift) | Odświeżanie, łączenie danych, wybór wariantu i `RoadRouteETA` |
| [NavigationSession+Routing.swift](../NaviAstra/Navigation/NavigationSession+Routing.swift) | Reakcja na potwierdzone zamknięcie i żądanie objazdu |
| [RouteGeometry.swift](../NaviAstra/Navigation/Domain/RouteGeometry.swift) | Kolorowanie zmierzonych fragmentów trasy |
| [MapLibreView.swift](../NaviAstra/Maps/MapLibreView.swift) | Renderer iOS: kafle, linie przepływu i znaczniki zdarzeń |
| [EnergyPolicyEngine.swift](../NaviAstra/Core/Energy/EnergyPolicyEngine.swift) | Warunki automatycznego odświeżania i praca w tle |
| [TripPlanningService.swift](../NaviAstra/Trips/TripPlanningService.swift) | Bieżący ruch w szacowaniu zapisanych planów |
| [ContentView+Settings.swift](../NaviAstra/Settings/UI/ContentView+Settings.swift) | Bieżące warunki i ręczne odświeżenie |
| [AppDependencies.swift](../NaviAstra/App/AppDependencies.swift) | Wstrzyknięcie klucza do sesji |
| [App.xcconfig](../Config/App.xcconfig), [Secrets.example.xcconfig](../Config/Secrets.example.xcconfig), [NaviAstra-iOS-Info.plist](../Config/NaviAstra-iOS-Info.plist) | Konfiguracja podczas budowania |

Dokumentacja powiązana: [routing](ROUTING.md), [trasy samochodowe](CAR_ROUTING.md), [zdarzenia](ROAD_EVENTS.md), [nawigacja w tle](BACKGROUND_NAVIGATION.md), [planowane podróże](PLANNED_TRIPS.md).

W razie rozbieżności opisów szczegółowych powyższe ustalenia wynikają z bieżącego kodu. Przykładowo renderer iOS pozostawia raster przepływu podczas prowadzenia; starszy opis ogólny w `ROUTING.md` sugeruje usunięcie całego rastra ruchu. Ten dokument nie zmienia zachowania aplikacji.

## Uzupełnienia i kaskada źródeł w iOS 1.1.136

`CombinedTrafficProvider` zachowuje TomTom jako źródło pomiarów prędkości, kafli przepływu i główne źródło zdarzeń. Jeśli odpowiedź o zdarzeniach jest dostępna i zawiera dane, nie pobiera tego samego obszaru z GDDKiA. Brak wyników, niedostępność lub brak klucza uruchamia uzupełnienie z oficjalnego biuletynu. Zgłoszenia użytkowników stanowią odrębne, niepotwierdzone obserwacje; nie są zamieniane w pomiary ruchu. Klient TomTom współdzieli aktywne identyczne żądania, ma cache 30 s dla Flow Segment Data i 60 s dla zdarzeń, najwyżej cztery pobrania równocześnie oraz wspólną przerwę po 429/503 zgodną z `Retry-After`.

| Źródło | Dane i rzeczywisty zakres | Dostęp, aktualność i ograniczenia |
| --- | --- | --- |
| TomTom | Pomiar prędkości/ETA oraz zdarzenia objęte odpowiedzią usługi | Istniejący klucz aplikacji; nie włączano płatnego planu ani nie dodawano karty. To limit bezpłatnego planu, nie nieograniczona bezpłatność. |
| GDDKiA | Oficjalne komunikaty na zarządzanych drogach krajowych; punkt przybliżonego środka odcinka | [Zbiór Otwarte Dane](https://dane.gov.pl/pl/dataset/2752), licencja CC0 1.0 według metadanych; [oficjalna specyfikacja i link XML](https://www.gov.pl/web/gddkia/dane-xml). Bez klucza i opłat. Publiczny serwer podczas sprawdzania 27.10.2026 nie odpowiedział w limicie czasu. Adapter jest podłączony, ale nie potwierdzono bieżącego odbioru. |
| Zapis lokalny | Wypadek, zagrożenie, obserwacja korka, roboty lub kontrola policyjna wskazane przez użytkownika | Wyłącznie urządzenie, JSON w Application Support; 30 minut ważności. Brak wysyłania i konta. |
| Opcjonalne wspólne zgłoszenia | Obserwacje innych użytkowników przy skonfigurowanej własnej usłudze | Klient i referencyjny serwer są w repozytorium. Usługa nie została wdrożona; w zainstalowanej konfiguracji jest wyłączona. Nie jest to działająca społeczność. |

Aktualna [strona cenowa TomTom](https://docs.tomtom.com/pricing) podaje 20 tys. bezpłatnych żądań Flow Segment Data miesięcznie, 2,5 tys. Incident Details oraz 200 tys. kafli ruchu/zdarzeń. Warunki konkretnego konta i planu mogą się różnić i zmieniać; aplikacja nie odczytuje zużycia całego konta, a cache nie stanowi gwarancji zmieszczenia wszystkich instalacji w limicie. Zachowany klucz nie został ujawniony ani zapisany w śledzonych plikach.

Biuletyn GDDKiA jest pobierany najwyżej co 5 minut i współdzieli równoczesne żądania. Klient wysyła tylko żądanie całego publicznego pliku, bez pozycji urządzenia. Waliduje datę `gen` (nie starszą niż 24 godziny i nie późniejszą o ponad 5 minut), zakres współrzędnych, początek i koniec zdarzenia. Odrzuca wygasłe i przyszłe wpisy, DTD/encje XML oraz pliki przekraczające 3 MB. Awaria nie nadaje starej kopii nowego czasu aktualizacji. Nie znamy gwarantowanego SLA ani opublikowanego stałego limitu żądań tej usługi. [KPD](https://kpd.gddkia.gov.pl/index.php/pl/profil-datex/) wymaga osobnej rejestracji/certyfikatu i nie zostało przedstawione jako gotowy dodatkowy pomiar prędkości.

Punkt z GDDKiA nie staje się fikcyjną linią zamknięcia. Te komunikaty pozostają kontekstem na mapie, bez automatycznego przeliczania trasy lub korygowania ETA. Niepotwierdzone zgłoszenia lokalne/wspólne również nie korygują ETA i nie uruchamiają objazdów. Kontrola policyjna nigdy nie stanowi zamknięcia drogi. Deduplikacja zachowuje geometrię, opóźnienie i termin z wiarygodniejszego pierwotnego rekordu; nie sumuje opóźnień ani nie przedłuża ważności innym źródłem. Wymaga wspólnego numeru drogi, kategorii/przyczyny, bliskiego punktu i zgodnych czasów; sama bliskość nie łączy kontroli. Lokalny i udostępniony wpis o tym samym losowym UUID zgłoszenia są łączone.

Awaria TomTom nie usuwa prawidłowych danych dodatkowego źródła. Jeśli żaden dostawca nie zwróci aktualnych zdarzeń, karta informuje o braku danych zamiast deklarować brak utrudnień. Komunikat o pustej poprawnej odpowiedzi mówi tylko o dostępnych zgłoszeniach w obszarze, nie o gwarantowanej przejezdności.

### Zgłaszanie i prywatność

Formularz „Zgłoś zdarzenie lub kontrolę” znajduje się w karcie ruchu. Wymaga pozycji GPS nie starszej niż minuta i dokładności do 50 m, sprawdzanych także przy zapisie. Domyślny zapis jest lokalny i wygasa po 30 minutach. Ponowienie nieudanej wysyłki korzysta z tego samego lokalnego wpisu. Usunięcie lokalnego wpisu nie usuwa opublikowanego zgłoszenia, które wygasa po swoim terminie; interfejs wyjaśnia tę różnicę.

Udostępnienie wymaga jawnego przycisku oraz własnego publicznego adresu HTTPS `ROAD_REPORTS_SERVER_URL`. Wysyłane są jedynie rodzaj, losowy UUID zgłoszenia, punkt zaokrąglony do 0,001° i czas. Nie są przesyłane konta, identyfikatory urządzeń, tekst użytkownika ani historia trasy. Odczyt wspólnych zgłoszeń stosuje prostokąt zaokrąglony do siatki 0,05°, cache minutowy i współdzielenie identycznych aktywnych żądań. [Kod i kontrakt własnej usługi](../tools/road-reports/README.md) opisują HTTPS, limity, moderację i pozostałą konfigurację. Nie zamówiono hostingu, nie utworzono płatnej usługi i nie wysłano żadnego rzeczywistego zgłoszenia do publicznego backendu.

## Weryfikacja wydania 27.10.2026

Podpisany build iOS dla iPhone (Dominik) zakończył się `BUILD SUCCEEDED`. `devicectl` potwierdził instalację 1.1.136 (138), uruchomienie aplikacji i jej działający proces. Aktualizacja została wykonana bez odinstalowywania. iOS zmienił ścieżkę kontenera, a metadane potwierdziły pozostawienie istniejących plików z wcześniejszych dni, m.in. bazy nauki jazdy i danych aplikacji. Nie pobierano prywatnej historii GPS.

Wykonano oddzielną weryfikację krytycznej logiki na produkcyjnych strukturach i parserach: kalendarze/strefy, polskie święta, wiosenna i jesienna zmiana czasu, godziny nocne, słoneczne, następna zmiana statusu, odrzucanie nieobsługiwanych warunków Wikidata i obcych współrzędnych, walidacja kolejności punktów i polyline6, daty i geometria GDDKiA, wygasanie, zapis/usuwanie lokalnych wpisów oraz deduplikacja z zachowaniem pojedynczego opóźnienia. Publiczny odczyt Wikidata potwierdził rzeczywisty harmonogram jednej polskiej placówki. Lokalny test protokołu serwera potwierdził precyzję, idempotencję, limity, walidację i usuwanie wygasłych rekordów.

`build-for-testing` oznacza kompilację pakietu, nie uruchomienie testów. Brak zainstalowanego runtime symulatora uniemożliwia ich uruchomienie w tym środowisku. Zastane `TransitousTests.swift` i `NaviAstraTests.swift` mają niezwiązane błędy kompilacji (izolacja aktora, nieaktualne sygnatury i mutujące wywołania wewnątrz makr); podczas kompilacji pozostałych krytycznych zestawów zostały wyłączone wyłącznie argumentem polecenia, bez usuwania lub edycji tych plików. macOS nie był budowany ani rozwijany.

## Aktualizacja iOS 1.1.137 (139)

Przycisk „Zgłoś” przy mapie otwiera wyłącznie listę rodzajów zdarzenia. Wybór zapisuje lokalną obserwację od razu, z aktualną zaakceptowaną pozycją GPS (dokładność do 50 m, wiek do 60 s) i bieżącym czasem. Nie wymaga wpisywania danych, potwierdzania zapisu ani wyboru udostępniania. Polskie potwierdzenie lub błąd pojawia się pod obszarem prowadzenia. Rozbudowany panel pozostaje dostępny do zarządzania wpisami.

Podpisana kompilacja iOS oraz kompilacja pakietu krytycznych testów zakończyły się powodzeniem. `devicectl` odczytał z „iPhone (Dominik)” wersję 1.1.137 (139), potwierdził udaną instalację i start procesu 22402; kolejny odczyt wykazał ten proces jako aktywny. Wszystkie 430 ścieżek istniejących w Application Support przed aktualizacją pozostało obecnych po niej. Nie odinstalowywano aplikacji ani nie usuwano historii. Nie wykonano rzeczywistego przejazdu weryfikacyjnego ani pełnego uruchomienia testów na symulatorze (brak runtime).
