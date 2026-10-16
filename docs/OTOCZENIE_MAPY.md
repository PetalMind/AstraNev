# Otoczenie mapy iOS

Mapa ma cztery wizualne poziomy: krajobraz, zabudowa, transport oraz trasa i zdarzenia. Niższe poziomy są spokojniejsze. iOS korzysta z następujących źródeł:

- OpenFreeMap / OpenMapTiles: mapa bazowa, woda, etykiety i POI; budynki i szczegóły kolei także wtedy, gdy Planet v4 nie jest skonfigurowany.
- MapTiler Planet v4: lasy i zieleń, zastępcze budynki 2D i 3D od z15/z16, szczegóły kolei od z17, parkingi i miejsca parkingowe, ścieżki, powierzchnie piesze, drzewa, liniowe bariery, wyposażenie ulic i tematyczne warstwy POI.
- MapTiler Buildings: klasyfikacja budynków, kolory elewacji i dachów, wysokości oraz rzeczywiste punkty wejść.
- Istniejący `DetailedRoadDataProvider`: szczegółowe jezdnie, podział na pasy i strzałki. Źródło otoczenia nie zastępuje tego dostawcy.

Nie dodajemy zapytań Overpass o lasy, budynki, chodniki, parkingi ani inne obiekty otoczenia. MapLibre zarządza pobieraniem i pamięcią podręczną kafli wektorowych.

## Stopniowanie szczegółów

| Zbliżenie | Widok |
| --- | --- |
| poniżej 10 | Uogólnione lasy `forest`; pozostała mapa bazowa |
| 10–14 | Szczegółowa granica lasu `wood`; od z12 parki, ogrody i główne obszary krajobrazu |
| 15 | Obrysy budynków 2D, powierzchnie parkingów, ścieżki piesze i rowerowe jako wstęgi, pojedyncze drzewa i mniejsza zieleń |
| 16 | Budynki 3D przy włączonym ustawieniu i kamerze 3D; szersze wstęgi ścieżek, polygonowe strefy piesze i subtelna faktura lasu |
| 17 | Podwójne szyny i podkłady, miejsca parkingowe, neutralne symbole przejść i spokojna faktura utwardzonych stref pieszych |
| 18 | Schody, wejścia, sygnalizatory, liniowe i punktowe krawężniki, bariery ochronne, mury, ogrodzenia i uspokojenia ruchu |
| 18,5 | Ławki, latarnie, fontanny i słupki |

Zieleń Planet v4 ma cztery spokojne rodziny: las; park/ogród; trawa/łąka; zieleń szczególna (m.in. ogródki działkowe, pola golfowe i wrzosowiska). Pola i mokradła zachowują stonowane kolory mapy bazowej. Woda i małe cieki pozostają statyczne, a małe cieki pojawiają się później niż rzeki.

Jezdnia ma kolor `#E8E9EC` w dzień i `#26282D` w nocy. Powierzchnie piesze mają `#F4F1EC` / `#313238`, a ich obramowanie `#D5D3CF` / `#42434A`. Drogi rowerowe stają się wyraźniejsze w istniejącym kontekście rowerowym. Przy prowadzeniu samochodowym detale są osłabione.

Wypełnione wstęgi ścieżek mają szerokość kartograficzną zależną od zbliżenia, nie szerokość geodezyjną. Geometria pochodzi z kafli; nie tworzymy bocznych chodników na podstawie samej osi jezdni. `paved=false` daje stonowany odcień ścieżki nieutwardzonej, bez przypisywania konkretnego materiału. Podwójne szyny, podkłady i faktura kostki są symbolami kartograficznymi, nie inwentaryzacją terenu. Faktura płyt na powierzchniach MapTiler wymaga `paved=true`.

Przy skonfigurowanym MapTiler główne budynki pochodzą z zestawu Buildings i wykorzystują `height` i `height_min`, pomijając obiekty podziemne. Mapa bazowa kończy swoje budynki na z15, aby geometrie obu dostawców nie nakładały się. Bez konfiguracji Planet v4 pozostają `render_height`, `render_min_height` i `hide_3d` OpenFreeMap. Są to wysokości przybliżone dostawców, bez lokalnego zgadywania kondygnacji; nie jest to model fotogrametryczny. Brak dodatniej wysokości pozostawia obrys 2D. Dotychczasowe ustawienia 3D, elewacje, dachy i dekoracyjne oświetlenie korzystają z wybranego źródła budynków. Gdy szczegółowe kafle Buildings nie udostępniają widocznych budynków, pozostaje zastępcza geometria Planet v4. Oba zestawy nie są stale rysowane jeden na drugim.

`BuildingVisualResolver` dobiera paletę wyłącznie z własnego `class/subclass` obrysu: handel, supermarket, hotel, biuro, medycyna, edukacja, religia, sport, przemysł i budynki publiczne mają odrębne, stonowane odcienie dnia i nocy. Nieznana i mieszkalna zabudowa zachowuje neutralne beże/szarości. `facade_color` i `roof_color` są domieszką rzeczywistych danych do tej palety; niepoprawny kolor wraca do palety funkcjonalnej. Obrysy mają spójną barwę, dachy są ciemniejsze, a wysokości nie są zwiększane dla wyróżnienia atrakcji.

POI pojedynczego najemcy nie zmienia klasy ani koloru całego budynku. Galeria może mieć obrys handlowy i kilka niezależnych sklepów, aptek oraz restauracji. Nie wykonujemy przestrzennego przypisania POI do całego obrysu bez potwierdzenia w danych.

Okna są dekoracją proceduralną, a nie informacją o rzeczywistych oknach czy obecności mieszkańców. `MapBuildingFacadeLayer` rysuje je w osobnej warstwie Metal na ścianach obrysów używanego źródła budynków. Nie nakłada wzoru okien na dach. Własna maska głębokości uwzględnia ściany, dachy, wklęsłe obrysy i otwory dziedzińców, aby zasłonięte okna nie prześwitywały przez budynki.

Warstwa fasad znajduje się bezpośrednio nad ostatnią bryłą lub warstwą koloru dachu, pod późniejszymi etykietami miejsc i nakładkami nawigacji. Nie jest kotwiczona do pierwszego symbolu: strzałki kierunku jazdy w stylu Liberty występują przed budynkami i takie zakotwiczenie pozwalałoby bryłom przykryć światła. Odświeżanie geometrii nie wymaga pełnego załadowania pozostałych źródeł mapy. Końcowe odświeżenie jest zaplanowane również wtedy, gdy mapa przestaje rysować kolejne klatki, z ograniczeniem do jednego odświeżenia na sekundę.

`BuildingVisualResolver` dobiera rozstaw i udział zapalonych okien dla zabudowy mieszkalnej, biur, hoteli, handlu i obiektów publicznych. Magazyny, hale, garaże, budynki gospodarcze i obiekty sakralne lub zabytkowe nie dostają standardowej siatki. Nieznane większe budynki mają oszczędny profil neutralny. Kondygnacje wynikają z dostępnych poziomów albo z dekoracyjnego podziału istniejącej wysokości; nie zwiększa to bryły budynku. Identyfikator budynku i pozycja ściany wyznaczają stały układ świateł.

Detal działa przy włączonych budynkach 3D, nachyleniu większym niż 35° i zoomie od 17,5. Do z18 obejmuje wybrane większe budynki; od z18 pojawia się pełniejsza siatka oraz minimalna poświata przy podstawie ścian. W dzień okna pozostają słabym rytmem fasady. Światła i miękkie halo działają wyłącznie na ciemnej mapie, a tryb automatyczny wykorzystuje istniejące obliczenie położenia Słońca. Detal maleje poza środkiem ekranu i podczas nawigacji. Mapa satelitarna oraz zatrzymane renderowanie wyłączają warstwę.

Geometria powstaje po zmianie widoku lub danych kafli, zamiast przy każdej klatce. Instancjonowanie obejmuje całe ściany; siatkę okien oblicza shader. Limity obejmują 240 budynków w masce, maksymalnie 90 budynków z detalem oraz prywatne tekstury o dłuższym boku do 2048 pikseli. Nie dodajemy fizycznego oświetlenia, animowanego migania, atlasu materiałów ani modelowania kształtu dachów nieobsługiwanego przez obecną bryłę MapLibre.

Neutralny wariant koloru bryły pozostaje stabilny na podstawie identyfikatora, a przy jego braku — wysokości dostawcy. Osobna cienka warstwa dachu zachowuje jego paletę i dostępny `roof_color`; dawny powtarzany wzór okien oraz szwów dachów nie jest nakładany na bryłę. Okna i nocne oświetlenie pozostają dekoracją kartograficzną. Nie określają rzeczywistego materiału, kondygnacji, układu okien ani zamieszkania. `roof_shape` jest dostępne w źródle, ale obecne `MLNFillExtrusionStyleLayer` nie modeluje połaci ani kopuł. Nie zastępujemy ich zgadywaną geometrią.

## Funkcja i ważność POI

`MapPOIVisualRenderer` łączy rzeczywiste punkty z Planet v4 (`poi_shopping`, `poi_food`, `poi_tourism`, `poi_culture`, `poi_healthcare`, `poi_accommodation`, `poi_education`, `poi_sport`, usługi `poi_public` oraz lotniska `poi_station`) z zapasowymi punktami OpenMapTiles. Usuwa pobliskie duplikaty tej samej kategorii i nazwy, preferując Planet. Warstwy o pustym filtrze służą wyłącznie ładowaniu kafli źródłowych. Punkty źródłowe nie są wyświetlane drugi raz. Przystanki i stacje pozostają w istniejącym `TransitStopRenderer`.

| Ważność | Minimalne zbliżenie | Przykłady |
| --- | --- | --- |
| `landmark` | 13,5 | Zamki, pałace, pomniki, stanowiska archeologiczne; atrakcje o jawnie wysokiej randze dostawcy |
| `major` | 15 | Centra handlowe, szpitale, uniwersytety, stadiony, lotniska |
| `normal` | 16,5 | Supermarkety, hotele, muzea, restauracje, atrakcje |
| `minor` | 18 | Małe sklepy, kawiarnie, apteki, usługi i pozostałe lokalne detale |

To ważność kartograficzna oparta na klasie i dostępnej randze, a nie pomiar popularności. Tematyczne warstwy Planet nie mają pola `rank`, więc nie otrzymują sztucznej rangi na podstawie nazwy lub marki. Istniejące progi stacji paliw, parkingów i ładowarek oraz filtr istotności względem trasy pozostają zachowane.

Wspólna warstwa symboli rozstrzyga kolizje, daje pierwszeństwo ważniejszym obiektom, zachowuje kolor kategorii, polską nazwę (jeżeli dostawca ją podaje), kliknięcia i istniejące logotypy sklepów. Edukacja i sport mają osobne symbole. Brak nazwy pozostawia ikonę z polską nazwą kategorii w szczegółach miejsca. Wybrany POI otrzymuje delikatne halo i wyraźny pierścień we własnym kolorze, bez oznaczania całego budynku jako konkretnego sklepu. Identyfikatory Planet nie są dekodowane jak identyfikatory OSM z OpenMapTiles.

Odświeżanie danych następuje po zmianie widoku lub wyrenderowaniu kafli, z ograniczeniem częstotliwości i do 1200 punktów. Zmiana samego filtra ważności uwzględnia połówkowe poziomy zbliżenia. Nie powstaje nowe zapytanie sieciowe o każdy POI; kafle i cache obsługuje MapLibre.

## Dyscypliny sportowe i modele boisk

Planet v4 rozróżnia dyscypliny w polu `class` warstwy punktowej `poi_sport` (m.in. `soccer`, `basketball`, `tennis`). Obrysy `leisure` mają tylko ogólną klasę `pitch`, bez pola dyscypliny. Dlatego sam prostokątny obrys ani nazwa obiektu nie służą do rozpoznawania sportu. Źródło: [oficjalny schemat Planet v4](https://docs.maptiler.com/schema/planet-v4/#poi_sport).

`MapSportKind` definiuje odrębne symbole, polskie podpisy i kolory dla piłki nożnej, koszykówki, tenisa, siatkówki, piłki ręcznej oraz pozostałych rozpoznawanych dyscyplin. Sportowe punkty pojawiają się od z17 lub wcześniej, jeżeli obiekt ma wyższą ważność. Obiekty bez nazwy otrzymują podpis dyscypliny. Sporty nieobsługiwane i brak informacji zachowują ogólne oznaczenie; `multi` i kilka sportów rozdzielonych średnikami oznaczają obiekt wielofunkcyjny. Istniejące przełączniki POI, filtr atrakcji, kolizje i kliknięcia pozostają wspólne z pozostałymi miejscami.

`MapSportSurfaceRenderer` od z17,5 dodaje stonowane powierzchnie, a od z18 stopniowo ujawnia schematyczne linie piłki nożnej, koszykówki, tenisa, siatkówki i piłki ręcznej. Wymaga pojedynczego punktu sportowego wewnątrz pojedynczego, niemal prostokątnego obrysu boiska. Pomija obrysy z otworami, fragmenty przy granicy kafla, niejednoznaczne przypisania i geometrię, w której linie wychodziłyby poza boisko. Orientacja i rozmiar wynikają z obrysu dostawcy. Linie są symbolem kartograficznym dyscypliny, a nie inwentaryzacją rzeczywistych oznaczeń, bramek ani koszy. Dla pozostałych sportów dostępne są symbole punktowe bez zgadywanej geometrii.

Bez jednoznacznego dopasowania pozostaje pierwotna powierzchnia `leisure` i dostępny symbol sportu. Mapa satelitarna i zatrzymanie renderowania wyłączają modele powierzchniowe. Tryb nocny ma własną paletę, a nawigacja osłabia detal. Dane pochodzą z już ładowanych kafli; odświeżanie jest ograniczone do raz na sekundę i 250 obrysów w otoczeniu widoku. Bez skonfigurowanego Planet pozostają rozpoznawalne sportowe POI mapy bazowej. Nie dodajemy zapytań Overpass ani nowych płatnych usług.

## MapTiler Planet v4: rzeczywiste warstwy

Schemat zweryfikowano w oficjalnej dokumentacji Planet v4. Natywne kafle szczegółowych warstw kończą się na z15; większe zbliżenia powiększają tę geometrię, a nie dostarczają nowych pomiarów. `forest` występuje tylko do natywnego z9, dlatego przełączenie na `wood` następuje na z10. Bazowa geometria lasu i jej faktura są wtedy ukryte, aby nie poszerzały szczegółowej granicy `wood`.

| Warstwa | Wykorzystanie |
| --- | --- |
| `parking` | Wielokąty parkingów (`subclass=parking`) i własne geometrie miejsc (`subclass=parking_space`) |
| `pathway` | Linie `footway`, `cycleway`, `path`, `steps`, `pedestrian` i pozostałych ścieżek |
| `pedestrian` | Wielokąty stref pieszych, placów oraz powierzchni ścieżek |
| `forest`, `wood` | Uogólniony las poniżej z10 i szczegółowa geometria od z10; neutralna faktura od z16 |
| `grass`, `leisure` | Cztery rodziny zieleni oraz tereny rekreacyjne i sportowe |
| `building` | Obrysy od z15 i bryły od z16 na podstawie `height` / `height_min` |
| `railway` | Szczegóły `rail`, `tram`, `light_rail`, `narrow_gauge`, `preserved`, `disused`, `abandoned` od z17 |
| `tree` | Punkty pojedynczych drzew, bez wymyślania ich lokalizacji |
| `traffic_control` | Liniowe krawężniki (z rozróżnieniem `lowered=true`), bariery ochronne i poręcze, mury, ogrodzenia oraz uspokojenia ruchu |
| `street_furniture` | Przejścia, wejścia, ławki, latarnie, fontanny, sygnalizatory, słupki i punktowe krawężniki |

Parkingi podziemne, dachowe, wielopoziomowe i garaże nie są przedstawiane jako odkryta nawierzchnia. Miejsca dla osób z niepełnosprawnością i miejsca ładowania otrzymują delikatny odcień na podstawie `parking_space`. Na rzeczywistych polach `subclass=parking_space`, `parking_space=disabled` od z18,5 pojawia się dodatkowo symbol wózka, z pełną widocznością od z19. Symbol rośnie ze zbliżeniem, leży na płaszczyźnie mapy pod mostami i budynkami oraz pozostaje widoczny przy ukrytych POI. Nie generujemy dekoracyjnej siatki miejsc na całym parkingu. Dostęp prywatny nie jest interpretowany jako publiczny; warstwy przedstawiają geometrię, a nie uprawnienie do parkowania.

Kolej zachowuje podział `brunnel` na tory naziemne, mostowe i tunelowe. Podkłady i odsunięte szyny powstają z osi toru dostawcy. Tory nieużywane są słabsze, porzucone mają pojedynczą przerywaną linię, a tunele nie otrzymują powierzchniowych podkładów. Obiekty w budowie są pomijane. Od z17 szczegóły OpenFreeMap ustępują Planet v4, aby nie rysować dwóch zestawów torów. Metro, kolej jednoszynowa i kolej linowo-terenowa zachowują dotychczasową prezentację OpenFreeMap, ponieważ nie włączamy ich do nowych klas `railway`.

Ścieżki naziemne i mostowe mają oddzielne warstwy. Filtry respektują `brunnel`; podziemne, wewnętrzne i budowane ścieżki są pomijane. Dane poziomów pozostają danymi dostawcy, bez lokalnego przesuwania obiektów. Punktowe obiekty respektują kolizje symboli i przełącznik POI; przejścia pozostają elementem fizycznej mapy także przy ukrytych POI. Zieleń, jej faktury i punkty drzew są pod wodą i ciekami, ponieważ wielokąty parków lub lasów mogą obejmować zbiornik bez otworu w geometrii. Woda korzysta z tej samej palety, linii brzegowej i spokojnej faktury w obu motywach. Parkingi są pod drogami, a oznaczenia naziemne pod mostami. Trasa, zdarzenia i etykiety zachowują pierwszeństwo.

## Ograniczenia danych, których nie wolno zgadywać

- Przejścia `street_furniture.class=street`, `subclass=crossing` są rysowane jako białe pasy na płaszczyźnie mapy, zgodnie z prezentacją MapTiler Streets v4. Orientacja wykorzystuje `direction` dostawcy oraz lokalną oś jezdni z warstwy `road`. Kąt etykiety jest dopasowany do osi pionowych pasków ikony, aby nie obracać zebry o 90° względem jezdni; przejścia ukośne zachowują kąt dostawcy. Brak poprawnego `direction` jest uzupełniany wyłącznie przy jednoznacznej geometrii jezdni w odległości do 4 m, z pominięciem mostów, tuneli, innych poziomów i dróg w budowie. Niejednoznaczne przejścia bez kierunku nie otrzymują stałego kąta 0° i są pomijane do czasu pojawienia się danych. Wielkość rośnie ze zbliżeniem. Proporcje pasów są kartograficzne: dane nie zawierają pomiaru szerokości przejścia. Przezroczyste przerwy odsłaniają nawierzchnię. Zebra jest pod budynkami, etykietami i trasą, pozostaje widoczna przy ukrytych POI i nie uczestniczy w kolizjach etykiet.
- `street_furniture.class=access_control`, `subclass=entrance` wskazuje podstawowy punkt wejścia. Nie traktujemy go jako dokładnej inwentaryzacji wejść do budynków.
- W zweryfikowanym schemacie nie ma `leaf_type`, nawet w `wood` i `tree`. Lasy mają neutralną fakturę, a pojedyncze drzewa neutralny symbol korony. Bazowy renderer jest gotowy na liściaste, iglaste i mieszane tekstury, gdy zgodne źródło dostarczy rzeczywisty atrybut; Planet v4 obecnie go nie dostarcza.
- Nie ma geometrii powierzchni dotykowych (`tactile_paving`). Nie rysujemy ich na podstawie samego punktu przejścia lub krawężnika.
- Planet v4 nie podaje `footway=sidewalk` ani `sidewalk=left/right/both` i nie przenosi pól `foot`/`bicycle` do `pathway`. Renderujemy rzeczywiste `footway`, ale nie oznaczamy każdej z nich jako chodnika przy jezdni. Jawne wspólne dopuszczenie pieszych i rowerów może zostać rozpoznane w bazowym OpenMapTiles z pól `foot` i `bicycle`; nie wyprowadzamy go z klasy `path` w MapTiler.

Te ograniczenia dotyczą dostępności danych, nie ukrytych przełączników. Dodanie pozornych oznaczeń byłoby sprzeczne z zasadą przedstawiania rzeczywistego otoczenia.

## Konfiguracja i atrybucja

Pole Info.plist `DetailedEnvironmentTileJSONURL` jest niezależne od `DetailedRoadTileJSONURL`. Adres Buildings (`/tiles/buildings/tiles.json`) jest wyprowadzany z tego samego zaufanego hosta i klucza co Planet v4, bez nowego pola ustawień. Wartość Planet pochodzi z `DETAILED_ENVIRONMENT_TILEJSON_URL` w lokalnej konfiguracji iOS. `Secrets.local.xcconfig` jest ignorowany przez Git i zawiera klucz udostępniony przez Stworcę; klucz nie trafia do dokumentacji ani kodu źródłowego.

Przykład bez rzeczywistego klucza:

```xcconfig
MAPTILER_API_KEY = YOUR_MAPTILER_API_KEY
DETAILED_ENVIRONMENT_TILEJSON_URL = https:/$()/api.maptiler.com/tiles/v4/tiles.json?key=$(MAPTILER_API_KEY)
```

Zapis `https:/$()/` zapobiega interpretacji `//` jako komentarza xcconfig. Bez poprawnego adresu nie powstaje dodatkowe źródło i OpenFreeMap pozostaje mapą bazową. Przycisk informacji na mapie otwiera jednym dotknięciem polski widok atrybucji z oficjalnym logo MapTiler i linkami do autorów danych. MapLibre korzysta również z atrybucji TileJSON; dodatkowo linki do MapTiler, OpenFreeMap, OSM i MapLibre znajdują się w Ustawieniach → Dane i prywatność → Źródła mapy i licencje. Podpisy są po polsku, a nazwy własne zachowują oryginalne brzmienie.

## Offline i pliki

Warstwy bazowe korzystają z istniejących paczek offline. Źródło MapTiler dodawane w czasie działania nie jest automatycznie częścią paczki pobieranej z adresu Liberty. Pełne pobieranie tych szczegółów offline wymaga stylu zawierającego dodatkowe źródło lub osobnego mechanizmu; samo dodanie klienta tego nie zapewnia.

- `MapEnvironmentStyle.swift`: bazowe powierzchnie, kolej, woda i etykiety.
- `MapTilerEnvironmentStyle.swift`: źródła Planet v4 i Buildings oraz ich warstwy.
- `MapBuildingAppearance.swift`: palety brył i dachów oraz `BuildingVisualResolver`.
- `MapPOIVisualRenderer.swift`: ważność, normalizacja, usuwanie duplikatów i podświetlenie POI.
- `MapCrosswalkAppearance.swift`: pasy przejść, normalizacja kierunku względem jezdni, usuwanie duplikatów kafli, pochylenie, obrót, kolory i skala zależna od zbliżenia.
- `MapLibreStyle.swift`: integracja z motywem, gęstość detali i budynki.

Zmiany dotyczą iOS. Nie zmieniają wyznaczania tras, dopasowania GPS ani prowadzenia po pasach i nie rozwijają zamrożonej aplikacji macOS.

Źródła: [Wymagania atrybucji MapTiler](https://docs.maptiler.com/guides/map-design/attribution/add-attribution/), [MapTiler Planet v4](https://docs.maptiler.com/schema/planet-v4/), [MapTiler Buildings](https://docs.maptiler.com/schema/buildings/), [OpenMapTiles](https://openmaptiles.org/docs/schema/), [MapLibre Style Spec](https://maplibre.org/maplibre-style-spec/layers/).
