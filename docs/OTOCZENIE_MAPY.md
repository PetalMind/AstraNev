# Otoczenie mapy iOS

Od iOS **1.1.139 (141)** otoczenie zawiera 62 gotowe modele Kenney CC0:
domy, bloki, wieżowce, obiekty przemysłowe, drzewa, dwie ławki, latarnię,
sygnalizator i słupek. Modele są dostępne od z15; podczas nawigacji mają niższe
progi rozmiaru na ekranie, a dalszy plan wykorzystuje uproszczone siatki.
Siatki są dołączone do aplikacji i zastępują tylko zgodne obiekty danych mapy.
[Źródła, sposób dopasowania, podgląd i ograniczenia](ENVIRONMENT_MODELS.md).
Opis własnych brył poniżej dotyczy również ich prezentacji zapasowej.

Mapa ma cztery wizualne poziomy: krajobraz, zabudowa, transport oraz trasa i zdarzenia. Niższe poziomy są spokojniejsze. iOS korzysta z następujących źródeł:

- OpenFreeMap / OpenMapTiles: mapa bazowa, woda, etykiety i POI; budynki i szczegóły kolei także wtedy, gdy Planet v4 nie jest skonfigurowany.
- MapTiler Planet v4: lasy i zieleń, zastępcze budynki 2D i 3D od z15, szczegóły kolei od z17, parkingi i miejsca parkingowe, ścieżki, powierzchnie piesze, drzewa, liniowe bariery, wyposażenie ulic i tematyczne warstwy POI.
- MapTiler Buildings: klasyfikacja budynków, kolory elewacji i dachów, wysokości oraz rzeczywiste punkty wejść.
- Istniejący `DetailedRoadDataProvider`: szczegółowe jezdnie, podział na pasy i strzałki. Źródło otoczenia nie zastępuje tego dostawcy.

Nie dodajemy zapytań Overpass o lasy, budynki, chodniki, parkingi ani inne obiekty otoczenia. MapLibre zarządza pobieraniem i pamięcią podręczną kafli wektorowych.

## Sterowanie gotowością i szczegółowością

Aktualizacje otoczenia, boisk, wyposażenia i POI przechodzą przez wspólną kolejkę `NaviAstraMapStyle` z odstępem co najmniej 350 ms, zwiększanym do 700 ms przy oszczędzaniu energii lub wysokiej temperaturze urządzenia. W tych warunkach budżety modeli wyposażenia i drzew maleją odpowiednio do 96 i 64; pozostałe obiekty zachowują reprezentację uproszczoną. Kolejka odczytuje najnowszy widok i ustawienia także podczas gestu, zamiast przechwytywać je osobno dla każdego renderera. Wstrzymanie lub zamknięcie mapy anuluje oczekujące zadania. W kompilacji Debug kategoria logów `MapDetails` zapisuje rzeczywisty czas aktualizacji, najwyżej raz na 10 sekund; nie jest to pomiar FPS.

`MapDetailPolicy` ocenia rozmiar obiektu po projekcji do ekranu, uwzględniając perspektywę. `MapEnvironmentModelPolicy` ustala osobne progi nawigacji i przeglądania: modele wyposażenia wchodzą od 1,8/2,8 punktu, a raz wybrane zachowują się do 1,3/2 punktów; pełny detal wymaga 14/16 punktów. Odrębne progi wejścia i wyjścia ograniczają migotanie. Obiekty spoza budżetu i daleki plan otrzymują własne symbole, również wtedy, gdy część pobliskich punktów jest już modelem. Oryginalne symbole są zastępowane dopiero po opublikowaniu źródła zastępczego. Drzewa zachowują niezależność od przełącznika POI. Sondy źródłowe pozostają przezroczyste i są wykluczone z nadawania wyglądu.

Przez maksymalnie 15 sekund zachowywane są ostatnio zaobserwowane obiekty z otoczenia widoku, aby chwilowo niepełny zestaw kafli nie usuwał ich natychmiast. Pamięć jest ograniczona obszarem widoku i liczbą obiektów. Gotowa geometria wyposażenia i boisk jest używana ponownie. Linie boisk zanikają przy zbyt małej wielkości ekranowej; powierzchnia pojawia się płynnie między z17,2 a z17,8, z wejściem do aktywnej reprezentacji od z17,5. Zestaw POI zawiera też punkty dla kolejnego przybliżenia, a widoczność kontroluje filtr warstwy.

`MapBuildingFallbackRenderer` porównuje konkretne obrysy Planet z zaobserwowanymi obrysami Buildings, z zachowaniem otworów dziedzińców. Pojedynczy gotowy budynek nie wyłącza zastępstwa dla całego ekranu. Maska fasad oraz światła latarni korzystają ze wspólnej pamięci siatki budynków i skwantowanego początku współrzędnych; sam mały ruch kamery nie wymusza każdorazowej wymiany buforów. Efekty nadal mają osobne przebiegi GPU. Fasady stopniowo ograniczają okna według wielkości ekranowej i nachylenia, bez nagłego poszerzania całego zbioru na z18. Szczegółowe drogi pokazują dostępną pamięć podręczną od razu, a opóźnienie dotyczy tylko nowego pobrania.

### Odzyskiwanie szczegółowych jezdni

Nawierzchnie, pasy i strzałki `DetailedRoadRenderer` powstają z zapisanej geometrii i tagów OSM; nie wymagają osobnej bitmapy nawierzchni w aplikacji. Świeżość danych pozostaje ograniczona do 24 godzin, a podczas niedostępności Overpass lokalna geometria może służyć jako zastępstwo wizualne do 30 dni. Nie uczestniczy w wyznaczaniu trasy, ocenie przejezdności ani ograniczeń. Pamięć zachowuje dotychczasowe limity obszarów i wierzchołków. Nakładające się fragmenty cache mogą pokryć część nowego kadru, ale częściowy wynik zawsze wymaga pobrania brakującego obszaru.

Ruch kamery nie anuluje rozpoczętego, ograniczonego czasowo pobrania. Po jego zakończeniu renderer sprawdza najnowszy kadr. Daleki horyzont mapy 3D nie wyłącza detalu całej mapy: zapytanie obejmuje wtedy bliski plan, z promieniem do 1,5 km wokół środka kamery. Wyłączenie renderowania lub zejście poniżej zoomu 16 nadal zatrzymuje pracę. Przy ustawionym limicie całej operacji wspólny transport Overpass dzieli pozostały czas między serwery, zamiast zużywać go na powtórny timeout pierwszego hosta.

Audyt z 27 października 2026 potwierdził na urządzeniu zachowane obszary z 14–17 października, odrzucane wcześniej przez siedmiodniowy limit podczas problemów z pobieraniem. Konfiguracja Planet v4 była obecna w zbudowanej aplikacji, a kod geometrii odpowiadał głównej kopii projektu. Samo odnowienie cache nie gwarantuje dostępności nowego obszaru przy awarii obu publicznych serwerów. Kontrola źródeł produkcyjnych odtworzyła odzyskiwanie dziesięciodniowych danych, scalanie częściowego pokrycia oraz przejście do zapasowego hosta po timeoutcie w ramach wspólnego budżetu.

## Stopniowanie szczegółów

| Zbliżenie | Widok |
| --- | --- |
| poniżej 10 | Uogólnione lasy `forest`; pozostała mapa bazowa |
| 10–14 | Szczegółowa granica lasu `wood`; od z12 parki, ogrody i główne obszary krajobrazu |
| 15 | Obrysy budynków 2D; przy kamerze 3D budynki, drzewa i wyposażenie kwalifikowane rozmiarem na ekranie; powierzchnie parkingów, ścieżki piesze i rowerowe jako wstęgi, pojedyncze drzewa i mniejsza zieleń |
| 16 | Szersze wstęgi ścieżek, polygonowe strefy piesze i subtelna faktura lasu |
| 17 | Podwójne szyny i podkłady, miejsca parkingowe, neutralne symbole przejść i spokojna faktura utwardzonych stref pieszych |
| 18 | Schody, wejścia, sygnalizatory, liniowe i punktowe krawężniki, bariery ochronne, mury, ogrodzenia i uspokojenia ruchu |
| 18,5 | Symbole 2D ławek, latarni, fontann i słupków; modele 3D mogą być widoczne wcześniej |

Zieleń Planet v4 ma cztery spokojne rodziny: las; park/ogród; trawa/łąka; zieleń szczególna (m.in. ogródki działkowe, pola golfowe i wrzosowiska). Pola i mokradła zachowują stonowane kolory mapy bazowej. Woda i małe cieki pozostają statyczne, a małe cieki pojawiają się później niż rzeki.

Jezdnia ma kolor `#E8E9EC` w dzień i `#26282D` w nocy. Powierzchnie piesze mają `#F4F1EC` / `#313238`, a ich obramowanie `#D5D3CF` / `#42434A`. Drogi rowerowe stają się wyraźniejsze w istniejącym kontekście rowerowym. Przy prowadzeniu samochodowym detale są osłabione.

Wypełnione wstęgi ścieżek mają szerokość kartograficzną zależną od zbliżenia, nie szerokość geodezyjną. Geometria pochodzi z kafli; nie tworzymy bocznych chodników na podstawie samej osi jezdni. `paved=false` daje stonowany odcień ścieżki nieutwardzonej, bez przypisywania konkretnego materiału. Podwójne szyny, podkłady i faktura kostki są symbolami kartograficznymi, nie inwentaryzacją terenu. Faktura płyt na powierzchniach MapTiler wymaga `paved=true`.

Przy skonfigurowanym MapTiler główne budynki pochodzą z zestawu Buildings i wykorzystują `height` i `height_min`, pomijając obiekty podziemne. Mapa bazowa kończy swoje budynki na z15, aby geometrie obu dostawców nie nakładały się. Bez konfiguracji Planet v4 pozostają `render_height`, `render_min_height` i `hide_3d` OpenFreeMap. Są to wysokości przybliżone dostawców, bez lokalnego zgadywania kondygnacji; nie jest to model fotogrametryczny. Brak dodatniej wysokości pozostawia obrys 2D. Dotychczasowe ustawienia 3D, elewacje, dachy i dekoracyjne oświetlenie korzystają z wybranego źródła budynków. Gdy szczegółowe kafle Buildings nie udostępniają widocznych budynków, pozostaje zastępcza geometria Planet v4. Oba zestawy nie są stale rysowane jeden na drugim. Dopasowanie zastępczego obrysu sprawdza rzeczywiste przecięcie powierzchni, wszystkie zajęte komórki przestrzenne i otwory dziedzińców, zamiast wyłącznie punktu środkowego. Raz zastąpiony obrys nie powraca wskutek przejściowego braku szczegółowego kafla, dopóki pozostaje w pamięci obserwacji.

`BuildingVisualResolver` dobiera paletę wyłącznie z własnego `class/subclass` obrysu: handel, supermarket, hotel, biuro, medycyna, edukacja, religia, sport, przemysł i budynki publiczne mają odrębne, stonowane odcienie dnia i nocy. Nieznana i mieszkalna zabudowa zachowuje neutralne beże/szarości. `facade_color` jest domieszką rzeczywistych danych do tej palety; niepoprawny kolor wraca do palety funkcjonalnej. Dach i ściany należą do tej samej natywnej bryły i korzystają ze wspólnej palety oraz oświetlenia silnika mapy. Wysokości nie są zwiększane dla wyróżnienia atrakcji.

POI pojedynczego najemcy nie zmienia klasy ani koloru całego budynku. Galeria może mieć obrys handlowy i kilka niezależnych sklepów, aptek oraz restauracji. Nie wykonujemy przestrzennego przypisania POI do całego obrysu bez potwierdzenia w danych.

Okna są dekoracją proceduralną, a nie informacją o rzeczywistych oknach czy obecności mieszkańców. `MapBuildingFacadeLayer` rysuje je w osobnej warstwie Metal na ścianach obrysów używanego źródła budynków. Nie nakłada wzoru okien na dach. Własna maska głębokości uwzględnia ściany, dachy, wklęsłe obrysy i otwory dziedzińców, aby zasłonięte okna nie prześwitywały przez budynki.

Warstwa fasad znajduje się bezpośrednio nad ostatnią bryłą budynku, pod późniejszymi etykietami miejsc i nakładkami nawigacji. Nie jest kotwiczona do pierwszego symbolu: strzałki kierunku jazdy w stylu Liberty występują przed budynkami i takie zakotwiczenie pozwalałoby bryłom przykryć światła. Odświeżanie geometrii nie wymaga pełnego załadowania pozostałych źródeł mapy. Końcowe odświeżenie jest zaplanowane również wtedy, gdy mapa przestaje rysować kolejne klatki, z ograniczeniem do jednego odświeżenia na sekundę.

`BuildingVisualResolver` dobiera rozstaw i udział zapalonych okien dla zabudowy mieszkalnej, biur, hoteli, handlu i obiektów publicznych. Magazyny, hale, garaże, budynki gospodarcze i obiekty sakralne lub zabytkowe nie dostają standardowej siatki. Nieznane większe budynki mają oszczędny profil neutralny. Kondygnacje wynikają z dostępnych poziomów albo z dekoracyjnego podziału istniejącej wysokości; nie zwiększa to bryły budynku. Identyfikator budynku i pozycja ściany wyznaczają stały układ świateł.

Detal działa przy włączonych budynkach 3D, nachyleniu większym niż 35° i zoomie od 17,5. Do z18 obejmuje wybrane większe budynki; od z18 pojawia się pełniejsza siatka oraz minimalna poświata przy podstawie ścian. W dzień okna pozostają słabym rytmem fasady. Światła i miękkie halo działają wyłącznie na ciemnej mapie, a tryb automatyczny wykorzystuje istniejące obliczenie położenia Słońca. Detal maleje poza środkiem ekranu i podczas nawigacji. Mapa satelitarna oraz zatrzymane renderowanie wyłączają warstwę.

Geometria powstaje po zmianie widoku lub danych kafli, zamiast przy każdej klatce. Instancjonowanie obejmuje całe ściany; siatkę okien oblicza shader. Limity obejmują 240 budynków w masce, maksymalnie 90 budynków z detalem oraz prywatne tekstury o dłuższym boku do 2048 pikseli. Nie dodajemy fizycznego oświetlenia, animowanego migania, atlasu materiałów ani modelowania kształtu dachów nieobsługiwanego przez obecną bryłę MapLibre.

Neutralny wariant koloru bryły wynika z wysokości dostawcy, bez identyfikatora obiektu w kaflu, który może zmieniać się przy zmianie zbliżenia lub źródła. Dach rysuje wyłącznie natywna bryła budynku. Dodatkowa ekstrudowana nakładka, odsunięta o 2 cm, powodowała konflikt głębokości i migotanie między kolorem bryły i dachu podczas ruchu kamery, dlatego została usunięta. Osobny `roof_color` nie jest obecnie nakładany. Bryły wszystkich źródeł mają stałe krycie 1, bez animacji krycia i bez wzoru. Omija to ścieżkę półprzezroczystych ekstrudowanych warstw z dodatkowym przebiegiem głębokości i maski stencil w Metal (znany problem MapLibre #1589). Budynki nie stają się półprzezroczyste podczas nawigacji; ich oświetlenie i kolory nadal wynikają z trybu mapy. Dawny powtarzany wzór okien oraz szwów dachów nie jest nakładany na bryłę. Okna i nocne oświetlenie pozostają dekoracją kartograficzną. Nie określają rzeczywistego materiału, kondygnacji, układu okien ani zamieszkania. `roof_shape` jest dostępne w źródle, ale obecne `MLNFillExtrusionStyleLayer` nie modeluje połaci ani kopuł. Nie zastępujemy ich zgadywaną geometrią.

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
| `building` | Obrysy i bryły od z15 na podstawie `height` / `height_min` |
| `railway` | Szczegóły `rail`, `tram`, `light_rail`, `narrow_gauge`, `preserved`, `disused`, `abandoned` od z17 |
| `tree` | Punkty pojedynczych drzew, bez wymyślania ich lokalizacji |
| `traffic_control` | Liniowe krawężniki (z rozróżnieniem `lowered=true`), bariery ochronne i poręcze, mury, ogrodzenia oraz uspokojenia ruchu |
| `street_furniture` | Przejścia, wejścia, ławki, latarnie, fontanny, sygnalizatory, słupki i punktowe krawężniki |

Parkingi podziemne, dachowe, wielopoziomowe i garaże nie są przedstawiane jako odkryta nawierzchnia. Miejsca dla osób z niepełnosprawnością i miejsca ładowania otrzymują delikatny odcień na podstawie `parking_space`. Na rzeczywistych polach `subclass=parking_space`, `parking_space=disabled` od z18,5 pojawia się dodatkowo symbol wózka, z pełną widocznością od z19. Symbol rośnie ze zbliżeniem, leży na płaszczyźnie mapy pod mostami i budynkami oraz pozostaje widoczny przy ukrytych POI. Nie generujemy dekoracyjnej siatki miejsc na całym parkingu. Dostęp prywatny nie jest interpretowany jako publiczny; warstwy przedstawiają geometrię, a nie uprawnienie do parkowania.

Kolej zachowuje podział `brunnel` na tory naziemne, mostowe i tunelowe. Podkłady i odsunięte szyny powstają z osi toru dostawcy. Tory nieużywane są słabsze, porzucone mają pojedynczą przerywaną linię, a tunele nie otrzymują powierzchniowych podkładów. Obiekty w budowie są pomijane. Od z17 szczegóły OpenFreeMap ustępują Planet v4, aby nie rysować dwóch zestawów torów. Metro, kolej jednoszynowa i kolej linowo-terenowa zachowują dotychczasową prezentację OpenFreeMap, ponieważ nie włączamy ich do nowych klas `railway`.

Ścieżki naziemne i mostowe mają oddzielne warstwy. Filtry respektują `brunnel`; podziemne, wewnętrzne i budowane ścieżki są pomijane. Dane poziomów pozostają danymi dostawcy, bez lokalnego przesuwania obiektów. Punktowe symbole 2D respektują kolizje etykiet i przełącznik POI. Modele 3D ławek i latarni respektują przełącznik POI, ale nie uczestniczą w kolizjach etykiet; przejścia pozostają elementem fizycznej mapy także przy ukrytych POI. Zieleń, jej faktury i punkty drzew są pod wodą i ciekami, ponieważ wielokąty parków lub lasów mogą obejmować zbiornik bez otworu w geometrii. Woda korzysta z tej samej palety, linii brzegowej i spokojnej faktury w obu motywach. Parkingi są pod drogami, a oznaczenia naziemne pod mostami. Trasa, zdarzenia i etykiety zachowują pierwszeństwo.

### Przestrzenne wyposażenie ulic i drzewa na iOS

`MapStreetFurnitureGeometry` definiuje własne, lekkie modele z części w metrach: ławkę z czterema deskami siedziska, dwiema deskami oparcia, nogami i podłokietnikami oraz latarnię z wielokątnym słupem, podstawą, wysięgnikiem i oprawą. `MapStreetFurnitureRenderer` zamienia części na wielokąty z wysokością podstawy i wierzchu. Natywna warstwa `MLNFillExtrusionStyleLayer` renderuje je w przebiegu 3D razem z budynkami, z perspektywą, cieniowaniem i buforem głębokości. Nie są to płaskie obrazki ani pliki modeli pobierane z internetu.

Modele zastępują symbole `bench`, `street_lamp`, `bollard` i `traffic_signals` w trybie 3D mapy standardowej od z15, jeśli ich przestrzenny obrys osiągnie 1,8 punktu podczas nawigacji lub 2,8 punktu podczas przeglądania. Już widoczne modele są utrzymywane odpowiednio do 1,3 lub 2 punktów. Renderer dobiera poziom prosty, średni lub pełny na podstawie wysokości i szerokości modelu w projekcji kamery, a nie płaskiego fragmentu podłoża. Natywną macierz przechwytuje `MapFurnitureProjectionLayer`. Również budynki 3D są dostępne od z15 przy włączonym ustawieniu i kamerze 3D. W trybie 2D pozostają dotychczasowe ikonki. Przełącznik POI steruje modelami wyposażenia ulicy; drzewa zachowują niezależność od POI. Widok satelitarny i wstrzymane renderowanie mapy ukrywają modele. Punkty oczekujące na model zachowują płaskie symbole przy ich zwykłych progach zbliżenia.

Limity wynoszą 384 obiekty ulicy i 256 drzew, dodatkowo ograniczonych kosztem wierzchołków geometrii. W trybie oszczędzania energii i przy wysokiej temperaturze limity są niższe. Gotowe poziomy modeli są buforowane do 30 sekund w pamięci o ograniczonym koszcie; niewidoczne obrysy nie zajmują budżetu aktywnych modeli. Niezmienione zestawy nie przebudowują źródeł. Światło ma osobny limit 64 latarni, albo 24 przy ograniczonej energii, i wolniejszą przebudowę maski. Szczegółowe progi oraz diagnostykę opisuje audyt obiektów.

Słupki mają podstawę, słup z pasem odblaskowym i zwieńczenie; sygnalizatory słup, korpus, daszki i trzy wygaszone soczewki. Nie symulujemy zielonego, żółtego ani czerwonego światła, ponieważ nie ma danych o stanie sygnału. Punkty `tree` otrzymują pień i umowną zaokrągloną koronę z dziesięciu warstw brył; nie przypisujemy gatunku ani typu liści. W trybie 3D koła drzew ustępują modelom po osiągnięciu wymaganego rozmiaru na ekranie. Punkty oczekujące na model pozostają widoczne jako koła; przejście wykorzystuje płynną zmianę przezroczystości i histerezę. W trybie 2D pozostają koła. Ikona sygnalizatora jest zachowana od z18 i płynnie zanika przy pojawianiu się korpusu. Warstwy techniczne pobierania punktów pozostają całkowicie przezroczyste także po ponownym zastosowaniu stylu.

Położenie i rodzaj pochodzą z rzeczywistych punktów Planet. Wygląd, materiały, wymiary (ławka 1,8 m, latarnia 5,91 m) i orientacja modeli są umowne. Szablony są skierowane na północ, niezależnie od obrotu kamery. Nie wykorzystujemy `direction`: schemat dokumentuje je dla przejść, a nie dla ławek czy latarni. Dane nie określają modelu, wysokości, materiału, orientacji ani stanu świecenia tych obiektów. Warstwa `MapStreetLampLightLayer` dodaje nocą jasny rdzeń przy soczewce, poświatę i miękką plamę światła na podłożu. Tryb dnia/nocy oraz obliczenia położenia słońca sterują intensywnością. Maska głębokości wykorzystuje geometrię widocznych budynków oraz najbliższe części modeli drzew, aby światło nie prześwitywało przez ściany, dachy i przestrzenne korony. Części drzew mają osobny budżet maski do 240 części. Efekt jest dekoracją i nie potwierdza działania konkretnej lampy; nie jest pełną symulacją oświetlenia materiałów ani dynamicznych cieni. Brak punktu źródłowego oznacza brak modelu. Opisane bryły proceduralne nie wymagają zewnętrznych zasobów. Pobliskie obiekty mogą korzystać z dołączonych modeli Kenney CC0, zgodnie z [katalogiem modeli](ENVIRONMENT_MODELS.md). Atrybucja map pozostaje w istniejących ustawieniach.

Pełny audyt pozostałych symboli, linii i modeli opisuje [OBIEKTY_MAPY_3D.md](OBIEKTY_MAPY_3D.md).

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
- `MapSurfaceNetworkRenderer.swift` i `MapSurfaceNetworkGeometry.swift`: automatyczne scalanie powierzchni pieszych i dopasowanie pasów przejść do dostępnej geometrii jezdni.
- `MapBuildingAppearance.swift`: palety brył i dachów oraz `BuildingVisualResolver`.
- `MapStreetFurnitureGeometry.swift`, `MapStreetFurnitureRenderer.swift`: umowne bryły ławek i latarni na rzeczywistych punktach mapy.
- `MapPOIVisualRenderer.swift`: ważność, normalizacja, usuwanie duplikatów i podświetlenie POI.
- `MapCrosswalkAppearance.swift`: pasy przejść, normalizacja kierunku względem jezdni, usuwanie duplikatów kafli, pochylenie, obrót, kolory i skala zależna od zbliżenia.
- `MapLibreStyle.swift`: integracja z motywem, gęstość detali i budynki.

Zmiany dotyczą iOS. Nie zmieniają wyznaczania tras, dopasowania GPS ani prowadzenia po pasach i nie rozwijają zamrożonej aplikacji macOS.

Źródła: [Wymagania atrybucji MapTiler](https://docs.maptiler.com/guides/map-design/attribution/add-attribution/), [MapTiler Planet v4](https://docs.maptiler.com/schema/planet-v4/), [MapTiler Buildings](https://docs.maptiler.com/schema/buildings/), [OpenMapTiles](https://openmaptiles.org/docs/schema/), [MapLibre Style Spec](https://maplibre.org/maplibre-style-spec/layers/).


## Automatyczne połączenia powierzchni pieszych (iOS)

Od z18 `MapSurfaceNetworkRenderer` zastępuje liniowe wstęgi chodników i ścieżek scalonymi powierzchniami z aktualnie załadowanych kafli Planet. Nie wykonuje dodatkowych zapytań sieciowych. `MapSurfaceNetworkGeometry` generuje wspólny zewnętrzny obrys, zachowuje otwory powierzchni pieszych i rozdziela warstwy, kondygnacje oraz mosty. Kolory klas ścieżek, rozróżnienie utwardzenia i oznaczenia schodów pozostają zachowane. Szerokości osiowych ścieżek są kartograficzne (2–3,2 m, zależnie od klasy), a nie pomiarowe; rzeczywiste obszary piesze zachowują obrysy dostawcy.

Szczeliny do 0,65 m mogą zostać domknięte tylko między wzajemnie najbliższymi, niemal współliniowymi, niepołączonymi końcówkami tej samej klasy, nawierzchni i poziomu. Łączenie nie przechodzi przez dostępną powierzchnię jezdni. Wspólne wierzchołki źródłowe oraz przecięcie osi ścieżki z rzeczywistym obszarem pieszym budują spójne komponenty. Równoległe ścieżki i bliskie odgałęzienia nie są łączone na podstawie samej odległości ani nakładania się ich umownych szerokości. Nie zmienia to grafu wyznaczania tras ani uprawnień dostępu.

Dostępne powierzchnie `DetailedRoadRenderer` służą do przycinania ścieżek na styku z jezdnią. Przy punktach przejść z ustalonym kierunkiem generowane są wielokąty białych pasów, przycięte do ciągłej powierzchni danej jezdni. Wysepki i otwory w asfalcie pozostają wolne od farby. Szerokość całego przejścia w poprzek jezdni wynika z tej powierzchni; szerokość korytarza pieszego (3 m) i rytm pasów są symbolami kartograficznymi. Punkt przejścia bez dostępnej powierzchni jezdni pozostaje dotychczasowym symbolem. Przejścia na mostach i innych poziomach nie otrzymują geometrii wywnioskowanej z jezdni naziemnej.

Obliczenia geometrii wykonują się poza głównym wątkiem, z anulowaniem po zmianie danych lub stylu. Wynik jest publikowany w całości; do tego czasu pozostają warstwy źródłowe. Limity złożoności pozostawiają pełną prezentację źródłową zamiast niekompletnej rekonstrukcji. Odtwarzanie powierzchni dotyczy prezentacji iOS, nie gwarantuje pomiarowej zgodności z terenem.


### Styk ścieżki z jezdnią

Naziemne ścieżki, zarówno źródłowe, jak i scalone, są rysowane pod naziemnymi jezdniami. Powierzchnia jezdni zasłania końcówkę ścieżki wchodzącą na asfalt również poniżej z18 i podczas oczekiwania na szczegółową geometrię. Mostowe i tunelowe ścieżki zachowują odrębną kolejność. Przy aktywnym Planet v4 od z15 wyłączane są odpowiadające mu warstwy ścieżek i powierzchni pieszych OpenFreeMap, aby nie nakładać dwóch geometrii. Po przycięciu powierzchni pieszej do szczegółowej jezdni jej obrys nie zamyka się poprzeczną kreską w świetle dojścia; pozostaje obrys samej jezdni. Mapa nie tworzy z tego powodu nowego przejścia dla pieszych.
