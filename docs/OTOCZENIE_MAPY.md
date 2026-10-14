# Otoczenie mapy iOS

Mapa ma cztery wizualne poziomy: krajobraz, zabudowa, transport oraz trasa i zdarzenia. Niższe poziomy są spokojniejsze. iOS korzysta z trzech niezależnych źródeł:

- OpenFreeMap / OpenMapTiles: mapa bazowa, woda, etykiety i POI; budynki i szczegóły kolei także wtedy, gdy Planet v4 nie jest skonfigurowany.
- MapTiler Planet v4: lasy i zieleń, budynki 2D i 3D od z15/z16, szczegóły kolei od z17, parkingi i miejsca parkingowe, ścieżki, powierzchnie piesze, drzewa, liniowe bariery i wyposażenie ulic.
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

Przy skonfigurowanym Planet v4 budynki wykorzystują `height` i `height_min`, pomijając obiekty podziemne. Mapa bazowa kończy swoje budynki na z15, aby geometrie obu dostawców nie nakładały się. Bez konfiguracji Planet v4 pozostają `render_height`, `render_min_height` i `hide_3d` OpenFreeMap. Są to wysokości przybliżone dostawców, bez lokalnego zgadywania kondygnacji; nie jest to model fotogrametryczny. Brak dodatniej wysokości pozostawia obrys 2D. Dotychczasowe ustawienia 3D, elewacje, dachy i dekoracyjne oświetlenie korzystają z wybranego źródła budynków. Osobny tileset MapTiler Buildings pozostaje poza tym zakresem.

Budynki mają cztery spokojne warianty palety: ciepły beż, jasny krem, chłodną szarość i szarość z błękitem. Dachy są ciemniejsze od elewacji, bryły bardziej kryjące, a krawędzie delikatnie zaokrąglone. Wariant koloru i faktury pozostaje stabilny na podstawie identyfikatora obiektu, a przy jego braku — wysokości dostawcy. Jawny kolor OSM jest zachowany jako subtelna domieszka. Okna mają cienkie ramy, wnęki, parapety i refleksy, a dachy spokojne szwy zamiast mocnej kratki. Faktury są dekoracyjnym stylem kartograficznym: nie określają rzeczywistego materiału, kondygnacji, układu okien ani zamieszkania budynku. Nocą wybrane okna otrzymują ciepłe światło; podczas prowadzenia krycie i detale są osłabione. Wspólna paleta `MapBuildingAppearance.swift` utrzymuje spójność Planet v4 i mapy bazowej.

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

Parkingi podziemne, dachowe, wielopoziomowe i garaże nie są przedstawiane jako odkryta nawierzchnia. Miejsca dla osób z niepełnosprawnością i miejsca ładowania otrzymują delikatny odcień na podstawie `parking_space`. Nie generujemy dekoracyjnej siatki miejsc na całym parkingu. Dostęp prywatny nie jest interpretowany jako publiczny; warstwy przedstawiają geometrię, a nie uprawnienie do parkowania.

Kolej zachowuje podział `brunnel` na tory naziemne, mostowe i tunelowe. Podkłady i odsunięte szyny powstają z osi toru dostawcy. Tory nieużywane są słabsze, porzucone mają pojedynczą przerywaną linię, a tunele nie otrzymują powierzchniowych podkładów. Obiekty w budowie są pomijane. Od z17 szczegóły OpenFreeMap ustępują Planet v4, aby nie rysować dwóch zestawów torów. Metro, kolej jednoszynowa i kolej linowo-terenowa zachowują dotychczasową prezentację OpenFreeMap, ponieważ nie włączamy ich do nowych klas `railway`.

Ścieżki naziemne i mostowe mają oddzielne warstwy. Filtry respektują `brunnel`; podziemne, wewnętrzne i budowane ścieżki są pomijane. Dane poziomów pozostają danymi dostawcy, bez lokalnego przesuwania obiektów. Punktowe obiekty respektują kolizje symboli i przełącznik POI; przejścia pozostają elementem fizycznej mapy także przy ukrytych POI. Zieleń, jej faktury i punkty drzew są pod wodą i ciekami, ponieważ wielokąty parków lub lasów mogą obejmować zbiornik bez otworu w geometrii. Woda korzysta z tej samej palety, linii brzegowej i spokojnej faktury w obu motywach. Parkingi są pod drogami, a oznaczenia naziemne pod mostami. Trasa, zdarzenia i etykiety zachowują pierwszeństwo.

## Ograniczenia danych, których nie wolno zgadywać

- Przejścia `street_furniture.class=street`, `subclass=crossing` są rysowane jako białe pasy na płaszczyźnie mapy, zgodnie z prezentacją MapTiler Streets v4. Orientacja pochodzi z `direction`, a wielkość rośnie ze zbliżeniem. Proporcje pasów są kartograficzne: dane nie zawierają pomiaru szerokości przejścia. Przezroczyste przerwy odsłaniają nawierzchnię. Zebra jest pod budynkami, etykietami i trasą, pozostaje widoczna przy ukrytych POI i nie uczestniczy w kolizjach etykiet.
- `street_furniture.class=access_control`, `subclass=entrance` wskazuje podstawowy punkt wejścia. Nie traktujemy go jako dokładnej inwentaryzacji wejść do budynków.
- W zweryfikowanym schemacie nie ma `leaf_type`, nawet w `wood` i `tree`. Lasy mają neutralną fakturę, a pojedyncze drzewa neutralny symbol korony. Bazowy renderer jest gotowy na liściaste, iglaste i mieszane tekstury, gdy zgodne źródło dostarczy rzeczywisty atrybut; Planet v4 obecnie go nie dostarcza.
- Nie ma geometrii powierzchni dotykowych (`tactile_paving`). Nie rysujemy ich na podstawie samego punktu przejścia lub krawężnika.
- Planet v4 nie podaje `footway=sidewalk` ani `sidewalk=left/right/both` i nie przenosi pól `foot`/`bicycle` do `pathway`. Renderujemy rzeczywiste `footway`, ale nie oznaczamy każdej z nich jako chodnika przy jezdni. Jawne wspólne dopuszczenie pieszych i rowerów może zostać rozpoznane w bazowym OpenMapTiles z pól `foot` i `bicycle`; nie wyprowadzamy go z klasy `path` w MapTiler.

Te ograniczenia dotyczą dostępności danych, nie ukrytych przełączników. Dodanie pozornych oznaczeń byłoby sprzeczne z zasadą przedstawiania rzeczywistego otoczenia.

## Konfiguracja i atrybucja

Pole Info.plist `DetailedEnvironmentTileJSONURL` jest niezależne od `DetailedRoadTileJSONURL`. Wartość pochodzi z `DETAILED_ENVIRONMENT_TILEJSON_URL` w lokalnej konfiguracji iOS. `Secrets.local.xcconfig` jest ignorowany przez Git i zawiera klucz udostępniony przez Stworcę; klucz nie trafia do dokumentacji ani kodu źródłowego.

Przykład bez rzeczywistego klucza:

```xcconfig
MAPTILER_API_KEY = YOUR_MAPTILER_API_KEY
DETAILED_ENVIRONMENT_TILEJSON_URL = https:/$()/api.maptiler.com/tiles/v4/tiles.json?key=$(MAPTILER_API_KEY)
```

Zapis `https:/$()/` zapobiega interpretacji `//` jako komentarza xcconfig. Bez poprawnego adresu nie powstaje dodatkowe źródło i OpenFreeMap pozostaje mapą bazową. Przycisk informacji na mapie otwiera jednym dotknięciem polski widok atrybucji z oficjalnym logo MapTiler i linkami do autorów danych. MapLibre korzysta również z atrybucji TileJSON; dodatkowo linki do MapTiler, OpenFreeMap, OSM i MapLibre znajdują się w Ustawieniach → Dane i prywatność → Źródła mapy i licencje. Podpisy są po polsku, a nazwy własne zachowują oryginalne brzmienie.

## Offline i pliki

Warstwy bazowe korzystają z istniejących paczek offline. Źródło MapTiler dodawane w czasie działania nie jest automatycznie częścią paczki pobieranej z adresu Liberty. Pełne pobieranie tych szczegółów offline wymaga stylu zawierającego dodatkowe źródło lub osobnego mechanizmu; samo dodanie klienta tego nie zapewnia.

- `MapEnvironmentStyle.swift`: bazowe powierzchnie, kolej, woda i etykiety.
- `MapTilerEnvironmentStyle.swift`: niezależne źródło Planet v4 i jego warstwy.
- `MapCrosswalkAppearance.swift`: pasy przejść, pochylenie, obrót, kolory i skala zależna od zbliżenia.
- `MapLibreStyle.swift`: integracja z motywem, gęstość detali i budynki.

Zmiany dotyczą iOS. Nie zmieniają wyznaczania tras, dopasowania GPS ani prowadzenia po pasach i nie rozwijają zamrożonej aplikacji macOS.

Źródła: [Wymagania atrybucji MapTiler](https://docs.maptiler.com/guides/map-design/attribution/add-attribution/), [MapTiler Planet v4](https://docs.maptiler.com/schema/planet-v4/), [OpenMapTiles](https://openmaptiles.org/docs/schema/), [MapLibre Style Spec](https://maplibre.org/maplibre-style-spec/layers/).
