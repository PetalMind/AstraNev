# Zewnętrzne modele otoczenia mapy iOS

Rozszerzenie: 27 października 2026, iOS **1.1.139 (141)**.

Mapa standardowa w trybie 3D korzysta z **62 gotowych modeli Kenney**. Siatki
z oryginalnych OBJ zastępują wybrane pobliskie bryły proceduralne, zachowując
kamerę mapy, rzeczywiste położenie obiektów, etykiety i trasę. To lekkie modele
stylizowane, a nie fotogrametria ani rekonstrukcja architektury konkretnego miejsca.

## Zawartość i licencje

| Paczka autora | Dołączone modele | Wersja wewnątrz archiwum |
| --- | --- | --- |
| [Nature Kit](https://kenney.nl/assets/nature-kit) | 11 drzew: osiem neutralnych sylwetek i trzy iglaste | 2.1 |
| [City Kit Suburban](https://kenney.nl/assets/city-kit-suburban) | 16 domów o różnych dachach i proporcjach | 2.0 |
| [City Kit Commercial](https://kenney.nl/assets/city-kit-commercial) | 14 budynków wielorodzinnych/usługowych oraz pięć wieżowców | 2.1 |
| [City Kit Roads](https://kenney.nl/assets/city-kit-roads) | Latarnia z zakrzywionym ramieniem i sygnalizator | 2.2 |
| [Holiday Kit](https://kenney.nl/assets/holiday-kit) | Zwykła ławka bez elementów sezonowych | 2.0 |
| [City Kit Industrial](https://kenney.nl/assets/city-kit-industrial) | 11 hal, magazynów i budynków przemysłowych | 2.0 |
| [Building Kit](https://kenney.nl/assets/building-kit) | Smukła kolumna wykorzystana jako neutralny słupek | 1.0 |
| [Graveyard Kit](https://kenney.nl/assets/graveyard-kit) | Zwykła ławka parkowa, bez elementów tematycznych paczki | 5.0 |

Wszystkie powyższe strony autora wskazują **CC0**. Oryginalne potwierdzenia
licencji z archiwów znajdują się w `NaviAstra/Resources/Vendor/EnvironmentModels/`;
informacje o źródłach są także w `NaviAstra/THIRD_PARTY_NOTICES.txt`.
Nie są dołączane całe paczki ani biblioteki importujące GLB/FBX.
Manifest wymienia każdy wykorzystany plik OBJ, proporcje i liczbę trójkątów
pełnej oraz uproszczonej siatki. Katalog obejmuje 46 budynków, 11 drzew i pięć
elementów wyposażenia; każdy ma dwa poziomy geometrii. Zasoby zajmują około
7,4 MiB przed kompresją aplikacji.

## Powiązanie z mapą

- Drzewa zastępują wyłącznie rzeczywiste punkty `tree`. Wariant jest stabilny dla
  identyfikatora/lokalizacji. Neutralne sylwetki nie potwierdzają gatunku;
  wariant iglasty wymaga jawnego `leaf_type=needleleaved`.
- Ławki, latarnie, słupki i sygnalizatory wykorzystują istniejące punkty i reguły
  dopasowania wyposażenia ulic. Wymiary są umowne, chyba że źródło poda poprawne
  wartości. Kotwica latarni i drzew jest przy podstawie, a nie w środku korony
  lub wysięgnika. Soczewki sygnalizatorów są wygaszone. Nocny efekt latarni
  otrzymuje pozycję rzeczywistej soczewki importowanego modelu.
- Budynki wymagają stabilnego ID, znanej dodatniej wysokości, potwierdzonej
  klasy mieszkalnej, usługowej lub przemysłowej oraz prostokątnego obrysu bez
  dziedzińców. Dopuszczalna wysokość wynosi 2,5–90 m, boki obrysu 3–140 m;
  każdy profil ma dodatkowo własny zakres wysokości i liczby kondygnacji.
  Domy mają zakres 3–16 m, a neutralne garaże do 6 m. Jawna liczba kondygnacji
  musi pasować do profilu dekoracyjnego modelu.
  Sprawdzane są kąty, długości przeciwległych
  boków, zakres wymiarów i proporcje względem modelu. Różne fragmenty jednego ID,
  wieloczęściowe obiekty i niezgodne kształty zachowują bryłę dostawcy.
  Tylko zaakceptowane ID z właściwego źródła są wyłączane z natywnej warstwy 3D.
  Nie zastępujemy całej zabudowy i nie dodajemy domów w pustych miejscach.
- Maksymalny obrys i wysokość modelu budynku są dopasowane do geometrii mapy.
  Detale, podziały okien, drzwi i dach pozostają dekoracją pochodzącą z paczki.
  Poprawny `roof_color` w formacie `#RRGGBB` określa kolor dachu; domyślny jest
  stonowany. Proceduralne okna są wyłączane dla zastąpionych budynków.
- Pozostałe obiekty, m.in. ogrodzenia, fontanny, ładowarki, automaty paczkowe
  i znaki, zachowują istniejące renderery. Lasy pozostają powierzchniami;
  nie obsadzamy ich losowo dodatkowymi punktami drzew.

## Renderowanie i wydajność

`MapEnvironmentModelLayer` rysuje prawdziwe trójkąty w Metal. Siatka każdego
rodzaju jest przesyłana raz i współdzielona przez instancje. Oświetlenie uwzględnia
normalne ścian, tryb dzienny/nocny i stonowaną paletę roślinności. Dodatkowy
przebieg samych głębokości obserwowanych budynków i pozostałych brył zapobiega
prześwitywaniu modeli przez natywną zabudowę. Nie dodajemy dynamicznych cieni.

Budynki, drzewa i wyposażenie są dostępne **od z15**. Fizyczne wymiary nie są
powiększane przy oddalaniu kamery. Rozmiar jest liczony po projekcji przestrzennej
bryły, z uwzględnieniem wysokości i perspektywy. `MapEnvironmentModelPolicy`
ustala niższe progi podczas nawigacji:

| Reguła | Nawigacja | Przeglądanie mapy |
| --- | --- | --- |
| Wejście / utrzymanie drzewa lub wyposażenia | 1,8 / 1,3 pkt | 2,8 / 2 pkt |
| Średni / pełny detal wyposażenia | 5 / 14 pkt | 7 / 16 pkt |
| Minimalny rozmiar budynku | 7 pkt | 11 pkt |
| Pełna siatka budynku | 58 pkt | 44 pkt |
| Limit budynków | 72 | 64 |
| Budżet trójkątów budynków | 90 000 | 110 000 |
| Wspólny budżet trójkątów importowanych | 130 000 | 160 000 |

Uproszczone siatki są używane również przy prostym poziomie wyposażenia, zamiast
od razu zastępować model proceduralną bryłą. Wszystkie 62 uproszczone modele
mają łącznie 33 160 trójkątów wobec 152 835 w pełnych siatkach. Są to sumy
katalogu; koszt sceny zależy od liczby instancji. Histereza i stabilizacja
ulepszenia detalu przez 0,65 s ograniczają przełączanie przy ruchu kamery.

Limity wzrosły do **384 obiektów ulicy i 256 drzew**. W trybie ograniczonym:
96 obiektów ulicy, 64 drzewa, 20 budynków / 18 000 trójkątów budynków oraz
30 000 trójkątów wspólnie, wyłącznie uproszczone siatki. Budynki mają rezerwę
35 000 trójkątów (10 000 w trybie ograniczonym), aby wyposażenie nie zajęło
całego budżetu. Odświeżanie jest ograniczone do raz na 0,5 s podczas nawigacji,
0,4 s przy przeglądaniu i 0,9 s przy ograniczonej energii/temperaturze.
Pozostają osobne limity geometrii proceduralnej i dotychczasowa polityka energii
wyłączająca budynki 3D w odpowiednich stanach.

Wyposażenie respektuje przełącznik POI, drzewa pozostają niezależne,
a budynki respektują „Budynki 3D”. Tryb 2D, satelita i wstrzymanie renderowania
ukrywają modele. Brak zasobu, błędny JSON, niedostępny Metal lub nieudana
alokacja zachowują dotychczasową geometrię. Modele są zasobami aplikacji i nie
wykonują żądań sieciowych; dostępność obiektów nadal zależy od danych kafli.

## Odtworzenie zasobów

Oficjalne archiwa i SHA-256 pobranych wersji:

| Katalog importera | Archiwum | SHA-256 |
| --- | --- | --- |
| `nature` | [Nature Kit](https://kenney.nl/media/pages/assets/nature-kit/37ac38a37b-1677698939/kenney_nature-kit.zip) | `fa7974a0d342bfe63c38664ba9f8ec1a4aab8ea25f099bdc56870e33588c4d9d` |
| `suburban` | [Suburban 2.0](https://kenney.nl/media/pages/assets/city-kit-suburban/2c871b7af2-1745479373/kenney_city-kit-suburban_20.zip) | `5869c35cf30b1c87bdb2d197b6d325eebadd2ef08ea27f04797e8e08d77a9a39` |
| `commercial` | [Commercial 2.1](https://kenney.nl/media/pages/assets/city-kit-commercial/a742d900eb-1753115042/kenney_city-kit-commercial_2.1.zip) | `f8b09b081c2bb88bcc126e2dec1cb40fd0dad7e7e591b6c26aaefe96fb35276b` |
| `roads` | [Roads 2.2](https://kenney.nl/media/pages/assets/city-kit-roads/74288c9459-1791628607/kenney_city-kit-roads.zip) | `374a4552115cbd11b4ec5c930ee31a533562dc78a09af249a655d03f7ea3b959` |
| `holiday` | [Holiday 2.0](https://kenney.nl/media/pages/assets/holiday-kit/3976a6496a-1733923970/kenney_holiday-kit.zip) | `fde4d514d7297388d98058e8933ff614e071886f7ce57f9aea4b00d7698dd769` |
| `industrial` | [Industrial 2.0](https://kenney.nl/media/pages/assets/city-kit-industrial/0ec35b139d-1788171848/kenney_city-kit-industrial_2.0.zip) | `5b381164e5760f3830a2dbee43b972deee38b2a695d091b56e238ab2910c96d2` |
| `building-kit` | [Building Kit 1.0](https://kenney.nl/media/pages/assets/building-kit/0de7aaa492-1743244741/kenney_building-kit.zip) | `2740ef5772fb5fb3d7aab881db22d129f6b68afe711b1a79e6d5e9e19cf3eec6` |
| `graveyard` | [Graveyard Kit 5.0](https://kenney.nl/media/pages/assets/graveyard-kit/ba8d4b4517-1760691807/kenney_graveyard-kit_5.0.zip) | `1a93613f2e5675f3310acf49ec9ef13ae7adeb756ac3b205bfb6cc9311a81062` |

Po weryfikacji sum rozpakować paczki do odpowiednich podkatalogów:

```sh
swift scripts/environment-models/import-kenney.swift /sciezka/do/paczek \
  NaviAstra/Resources/Vendor/EnvironmentModels
swift scripts/environment-models/preview.swift \
  NaviAstra/Resources/Vendor/EnvironmentModels \
  docs/images/environment-models-kenney-preview.png
swift scripts/environment-models/preview.swift \
  NaviAstra/Resources/Vendor/EnvironmentModels \
  docs/images/environment-models-coarse-preview.png --coarse
```

Importer normalizuje osie i wymiary, zachowuje trójkąty oraz próbkuje materiały
OBJ/MTL i atlas kolorów. Kotwicę na podłożu i soczewkę lampy zapisuje na podstawie
geometrii źródłowej. Kolory sygnałów zmienia na wygaszone. Uproszczenie grupuje
pobliskie wierzchołki i minimalizuje błąd względem oryginalnych płaszczyzn,
zachowując położenie w obrębie grupy i wysokość podstawy/wierzchołka. Usuwa
zdegenerowane oraz powtórzone trójkąty; nie wybiera losowego podzbioru ścian.

## Weryfikacja na iPhonie

Rozszerzenie **1.1.139 (141)** zainstalowano na tym samym fizycznym iPhonie 15.
Kontrolny kadr z15 przy pochyleniu 55° i `NAVIASTRA_MAP_AUDIT_CONTEXT=driving`
potwierdził **85 rysowanych modeli / 32 251 trójkątów**: 42 budynki (w tym
pięć bloków, 30 domów i siedem obiektów przemysłowych), cztery drzewa,
37 latarni oraz dwa sygnalizatory. Wszystkie korzystały z uproszczonych siatek.
Potwierdzenie obejmuje obraz z urządzenia i log wywołań Metal. Kontekst Debug
zmienia reguły renderera; nie jest przejazdem z aktywną trasą i nie zmienia GPS.
Nie wykonano pomiaru FPS ani zużycia energii podczas jazdy.

Kontrola ponownego uruchomienia ujawniła znikanie modeli pomimo obecności
wywołań rysowania. Renderer synchronizuje flagi widoczności przed ukryciem
natywnych brył. Warstwa modeli używa `nearClippedProjectionMatrix`, zgodnej
z głębokością natywnych ekstrudowanych budynków, konwersji zakresu Z do Metal
oraz jawnego viewport/scissor. Potrzebę macierzy 3D opisuje
[poprawka MapLibre #4364](https://github.com/maplibre/maplibre-native/pull/4364).
Po poprawce świeże uruchomienie przy z16 i pochyleniu 55° potwierdziło obraz
oraz **32 modele / 18 758 trójkątów**: 27 budynków, dwa drzewa, dwie latarnie
i ławkę. Flagi widoczności POI i budynków w warstwie Metal wynosiły 1.

Pierwsza kontrola wcześniejszego katalogu:

27 października 2026, iOS **1.1.138 (140)**, fizyczny **iPhone 15 „iPhone (Dominik)”**.
Potwierdzono jednocześnie obraz z ekranu urządzenia i wywołania rysowania Metal:

| Kadr | Modele faktycznie rysowane | Trójkąty | Kamera |
| --- | --- | --- | --- |
| Potwierdzony punkt drzewa w Warszawie | `tree-rounded` × 1, `street-lamp` × 4 | 850 | z19, pochylenie 55° |
| Potwierdzona ławka w tym samym rejonie | `bench` × 1, `street-lamp` × 1 | 504 | z20, pochylenie 55° |
| Niski dom na Żoliborzu | `house-b` × 1 | 3458 | z19, pochylenie 55° |

Zrzuty i konsola pochodzą z działającej aplikacji; kadry ustawiono zmienną Debug
`NAVIASTRA_MAP_AUDIT_CAMERA=lat,lon,zoom,pitch`, bez zmiany GPS i zapisanych
ustawień mapy. Po kontroli aplikacja jest uruchamiana bez parametrów audytu.
Nie dodano testów jednostkowych.

W początkowych kadrach liczba nowych modeli wynosiła zero. Rzeczywisty kafel
Planet v4 obejmujący sprawdzany fragment parku zawierał tylko jeden punkt `tree`.
Budynki niespełniające warunków dopasowania zachowują bryły dostawcy; ograniczenia
polityki energii mogą dodatkowo wyłączyć budynki 3D.

Podczas kontroli ograniczono analizę pełnych obrysów do pobliskich, dopuszczalnych
ID, pozostawiając wszystkie fragmenty każdego wybranego ID do sprawdzenia.
Niezmienione wykluczenia budynków nie są ponownie nakładane, a pusta warstwa
modeli nie żąda kolejnych identycznych klatek. Pozostają dotychczasowe limity
energii i temperatury. Nie wykonywano pomiaru FPS ani pełnego audytu GPU.

Kompilacja iOS i shaderów zakończyła się poprawnie.
[Arkusz modeli](images/environment-models-kenney-preview.png) i
[wersja uproszczona](images/environment-models-coarse-preview.png) przedstawiają
osobny podgląd geometrii, ze zbliżoną paletą aplikacji.
