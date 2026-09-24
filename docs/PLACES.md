# Miejsca, sklepy i godziny otwarcia

Ten dokument opisuje, skąd NaviAstra bierze informacje o POI (punktach zainteresowania), jak łączy wyniki różnych źródeł, jak pobiera szczegóły i jak interpretuje godziny otwarcia. Dane nie są utrzymywane przez NaviAstra: aplikacja wyświetla informacje udostępnione przez zewnętrznych dostawców i społeczność OpenStreetMap.

## Źródła według sposobu znalezienia miejsca

| Sposób | Źródło wyniku lub obiektu | Co dzieje się dalej |
| --- | --- | --- |
| Wyszukiwanie tekstowe miejsca, marki lub kategorii | Photon (domyślnie `https://photon.komoot.io/api/`) oraz Apple MapKit. Dla zapytań rozpoznanych jako marka lub kategoria dochodzi lokalne wyszukiwanie OSM przez Overpass. | Wyniki są łączone, porządkowane, deduplikowane i pokazywane w wyszukiwarce. Szczegóły POI są pobierane z OSM po otwarciu karty, chyba że zostały już pobrane razem z wynikiem OSM. |
| Dotknięcie POI na mapie iOS | Widoczny obiekt z wektorowych kafli OpenFreeMap; MapLibre odczytuje m.in. nazwę, kategorię, markę i dostępny identyfikator OSM. | Karta próbuje potwierdzić lub odnaleźć ten obiekt w OSM i pobrać jego tagi. |
| Wybór POI na mapie macOS | Apple MapKit wyszukuje punkty zainteresowania wokół wskazanego obszaru mapy. Wynik może zawierać adres, telefon i stronę. | Karta zachowuje dostępne dane Apple i próbuje uzupełnić je danymi OSM. |
| Wyszukiwanie przystanku lub punktu po trasie | OpenStreetMap przez Overpass. Dotyczy m.in. stacji paliw, jedzenia, parkingów, parkingów P+R i ładowarek EV. | Dane tagów z odpowiedzi służą do filtrowania i opisu kandydatów; pełne szczegóły POI trafiają również do cache. |

Domyślne adresy usług Overpass i Photon można zastąpić wartościami `UserDefaults` pod kluczami `overpassServer` i `photonServer`. Jeśli wartość nie jest ustawiona, kod używa domyślnego adresu podanego wyżej dla Photona oraz `https://overpass-api.de/api/interpreter` dla Overpass.

## Wyszukiwanie sklepów i innych POI

`SearchEngine` rozpoznaje rodzaj zapytania. Dla zwykłego wyszukiwania miejsca uruchamia Photon i MapKit równolegle. Dla zapytań o markę lub kategorię uruchamia także `POISearchProvider`, który pyta Overpass o obiekty OSM w pobliżu wybranego obszaru. Photon dostaje język `pl`, limit 20 wyników i — jeśli jest dostępna — kategorię OSM jako filtr. MapKit dostaje zapytanie tekstowe, a przy znanej pozycji także region wyszukiwania o wymiarach około 10 × 10 km.

Wyszukiwanie OSM używa tagów wynikających z rozpoznanej kategorii. Dla obszaru wokół pozycji promień jest rozszerzany tylko wtedy, gdy poprzedni obszar nie zwrócił wyników: dla marki 5, 15 i 50 km, a dla kategorii 3, 10 i 30 km. Wyszukiwanie wzdłuż aktywnej trasy używa korytarza o szerokości 1,5 km. Cała ekspansja ma wspólny limit czasu 12 sekund.

Usługi publikują niepuste wyniki w miarę kończenia kolejnych żądań. Silnik scala najpierw identyczne identyfikatory OSM lub trwałe identyfikatory Apple Maps. Gdy nie ma wspólnego ID, porównuje nazwę, markę, operatora, kategorię, numer adresowy i odległość. Samo podobieństwo nazwy nie wystarcza do połączenia dwóch oddziałów; różne numery lokalu blokują takie dopasowanie. Do wyniku dopasowanego z innego źródła aplikacja może dołączyć brakujący adres, kontakt lub strefę czasową.

Wstępny ranking uwzględnia zgodność nazwy, marki i operatora z zapytaniem, kategorię, kompletność identyfikatora oraz (jeśli Photon ją zwrócił) jego ocenę istotności. Odległość rozstrzyga wyniki o podobnej trafności. Dla wyszukiwania po trasie silnik nadal porównuje czas objazdu macierzą Valhalla; do obliczenia zachowuje szerszą pulę kandydatów, a następnie pokazuje do 8 wyników. Szacowanie może być niedostępne, gdy router nie zwróci czasu.

Wyniki Photon są przede wszystkim wynikami geokodera: zawierają nazwę/adres, położenie i — gdy jest dostępny — identyfikator obiektu OSM. Photon nie jest źródłem godzin otwarcia w tym przepływie. Godziny w karcie pochodzą z tagu `opening_hours` OSM albo z danych już dołączonych do wyszukiwania OSM.

## Wybór POI z mapy

Na iOS aplikacja odczytuje POI, które są już widoczne w warstwach MapLibre. Z kafla wykorzystuje kategorię (`subclass` lub `class`), nazwę, markę i — jeśli kafel ją zawiera — `osm_id`. Gdy kilka punktów leży pod dotknięciem, karta pozwala wybrać właściwy obiekt.

Na macOS wybór POI wywołuje `MKLocalSearch` wokół wskazanego miejsca i wybiera punkty, których pozycje ekranowe są blisko dotknięcia. MapKit może dostarczyć trwałe ID, strefę czasową, telefon i adres URL strony internetowej. Dostępne metadane są zachowywane, jeśli późniejsza odpowiedź OSM nie zawiera ich odpowiedników.

## Pobieranie szczegółów z OpenStreetMap

Szczegóły są uzupełniane dopiero dla karty POI. Najpierw karta pokazuje dostępne dane wyszukiwania lub mapy, a w tle wykonuje żądanie do `OpenStreetMapPlaceDetailsProvider`.

1. Aplikacja tworzy tożsamość miejsca z dostępnym ID OSM lub MapKit, nazwą, kategorią, marką, operatorem, adresem i współrzędnymi. Dla znanego obiektu OSM klucz cache opiera się na typie i identyfikatorze (`node`, `way` albo `relation`); MapKit ma osobny klucz trwałego ID. Gdy stabilnego ID brak, klucz obejmuje źródło, znormalizowaną nazwę/kategorię i współrzędne.
2. Jeżeli odpowiedź wyszukiwania Overpass zawierała już tagi obiektu, aplikacja od razu zapisuje wybrane szczegóły do tego samego cache. Nie trzeba wtedy ponownie pobierać tego obiektu.
3. Gdy znany jest typ i ID OSM, żądanie Overpass wskazuje ten konkretny obiekt. Gdy ID nie ma, aplikacja pobiera nazwane obiekty w promieniu 100 m i ocenia kandydatów po zgodności nazwy, marki/operatora, kategorii, adresu i odległości. Rozbieżny numer budynku odrzuca kandydata. Dla POI z kafla OpenFreeMap wymagane jest również zgodne numeryczne ID, zgodna nazwa i odległość do 100 m; dla pozostałych dopasowań odległość nie może przekroczyć 40 m.
4. Overpass zwraca JSON z tagami (`out center tags`). Aplikacja odrzuca błędy HTTP, niepoprawną odpowiedź i odpowiedź zawierającą komunikat `remark` jako brak wiarygodnego wyniku.

Z tagów OSM budowany jest model `PlaceDetails`:

| Pole karty | Tag OSM |
| --- | --- |
| Nazwa | `name`, z fallbackiem do `brand` lub nazwy już widocznej w karcie |
| Marka i operator | `brand`, `operator` |
| Kategoria | pierwszy dostępny z `amenity`, `shop`, `tourism`, `leisure`, `office`, `craft` |
| Adres | `addr:full` albo złożenie ulicy, numeru, dzielnicy, kodu pocztowego i miejscowości |
| Godziny otwarcia | `opening_hours` |
| Telefon i strona | `contact:phone` / `phone` oraz `contact:website` / `website` |
| Dostępność i udogodnienia | `wheelchair`, `parking`, `drive_through`; dla parkingów także dedykowane tagi opłat, dostępu, godzin, limitu postoju, pojemności i stron ulicy |

Pola nieobecne w OSM pozostają puste. Aplikacja nie uzupełnia ich przez zgadywanie ani przez odpytywanie strony sklepu.

## Godziny otwarcia i ich interpretacja

Godziny pochodzą z tekstowego tagu OSM `opening_hours`. Dla parkingu mogą być również dostępne osobne `opening_hours` ogólne oraz tagi godzin dla poszczególnych stron ulicy (`parking:left:opening_hours`, `parking:right:opening_hours`, `parking:both:opening_hours`). Karta parkingu prezentuje te warunki w sekcji parkowania, zamiast powielać ogólne godziny POI.

`PlaceOpeningHours` zachowuje oryginalny tekst i deleguje interpretację składni OSM do lokalnie dołączonej biblioteki `opening_hours.js`. Biblioteka obsługuje reguły dni tygodnia, przedziały przekraczające północ, wyjątki i dni świąteczne, okresy sezonowe, reguły `open` / `off` oraz godziny związane ze wschodem i zachodem słońca. Współrzędne miejsca i — gdy OSM je udostępnił — kod kraju są przekazywane parserowi do reguł geograficznych i świątecznych. Parser oraz SunCalc są zasobami lokalnymi, więc samo obliczenie nie wymaga dodatkowego żądania sieciowego.

Strefa czasowa pochodzi najpierw z wyniku MapKit. Jeśli POI ma tylko dane OSM, aplikacja odpytuje `MKReverseGeocodingRequest` dla współrzędnych i zachowuje strefę w pamięci dla tego miejsca. Jeżeli strefy nie da się ustalić, karta pokazuje tekst godzin bez statusu otwarcia, żeby nie pomylić czasu telefonu z czasem lokalnym sklepu. Status i tygodniowy rozkład są liczone w kalendarzu miejsca; interfejs przypomina, że dane mogą różnić się w święta.

W panelu stacji paliw przy trasie godziny są także używane w filtrach „otwarte teraz” i „całodobowe”. Filtr „otwarte teraz” przepuszcza tylko kandydatów, których zapis dał się zinterpretować jako otwarte i dla których strefa czasowa jest znana; brak strefy, godzin lub poprawnej interpretacji nie jest traktowany jako potwierdzenie otwarcia.

Dołączony `opening_hours.js` jest wydaniem 3.14.0 na licencji LGPL-3.0-only; SunCalc jest na licencji BSD 2-Clause. Informacje i teksty obu licencji są w zasobach aplikacji w katalogu `NaviAstra`.

## Cache, odświeżanie i błędy

Szczegóły są przechowywane lokalnie w pliku `Application Support/NaviAstra/place-details-cache.json`. Cache ma osobne okresy świeżości: identyfikacja, kategoria i adres — 30 dni; kontakt — 7 dni; dostęp i parkowanie — 3 dni; godziny otwarcia — 12 godzin. Zapisane pola zachowują czas pobrania swojej grupy, a wpis po terminie może zostać pokazany od razu podczas odświeżania. Cache ogranicza się do 1000 najnowszych pozycji. Identyczne aktywne żądania są współdzielone. Wynik „nie znaleziono pasującego obiektu” jest pamiętany przez 5 minut, aby nie powtarzać bezskutecznie tej samej próby.

Jeżeli odświeżenie się nie powiedzie, karta zachowuje dane już dostępne i pokazuje błąd z możliwością ponowienia. Brak tagu oznacza brak informacji w źródle, a nie stan przeciwny: brak `opening_hours` nie znaczy, że sklep jest zamknięty; brak tagu opłaty nie znaczy, że parking jest bezpłatny.

## Ograniczenia i prywatność żądań

OpenStreetMap jest edytowaną społecznościowo bazą, więc kompletność i aktualność godzin, adresów oraz kontaktu zależą od jej danych. Photon i publiczny Overpass mogą być czasowo niedostępne lub limitować ruch. W repozytorium nie ma własnego katalogu sklepów, synchronizacji z sieciami handlowymi ani danych o bieżącym działaniu placówki.

Zapytanie tekstowe i przybliżony obszar wyszukiwania trafiają do używanych usług wyszukiwania. Przy dociąganiu szczegółów Overpass dostaje identyfikator i typ obiektu OSM, jeśli są dostępne; w przeciwnym razie dostaje współrzędne do pobrania obiektów w pobliżu. Dopasowanie nazwy, operatora, kategorii i adresu odbywa się w aplikacji po pobraniu odpowiedzi. Aplikacja nie wysyła do Overpass nazwy sklepu jako części zapytania o szczegóły. Gdy wynik OSM nie ma strefy czasowej, współrzędne wybranego POI mogą zostać wysłane do odwrotnego wyszukiwania MapKit, aby ustalić lokalny czas.

Najważniejsze miejsca w kodzie:

- `NaviAstra/Search/SearchEngine.swift` — rozpoznanie intencji wyszukiwania, łączenie wyników oraz zapytania POI do Overpass;
- `NaviAstra/Search/SearchProvider.swift` — Photon i Apple MapKit;
- `NaviAstra/Maps/MapLibreView.swift` i `NaviAstra/Maps/MacMapView.swift` — wybór POI na mapach iOS/macOS;
- `NaviAstra/Places/PlaceDetailsProvider.swift` — tożsamość miejsca, dopasowanie obiektu OSM, pobranie tagów i cache;
- `NaviAstra/Places/PlaceOpeningHours.swift` — adapter parsera składni OSM, kalendarz lokalny i tygodniowe przedziały;
- `NaviAstra/Places/PlaceTimeZoneResolver.swift` — ustalanie strefy miejsca przez MapKit;
- `NaviAstra/opening_hours.js` i `NaviAstra/suncalc.js` — lokalne zasoby parsera i obliczeń słońca;
- `NaviAstra/THIRD_PARTY_NOTICES.txt` — informacje o licencjach dołączonych bibliotek;
- `NaviAstra/Places/PlaceDetailsView.swift` — prezentacja szczegółów oraz godzin;
- `NaviAstra/Places/NearbyPlaceProvider.swift` — pobliskie kategorie i POI wyszukiwane wzdłuż trasy.
