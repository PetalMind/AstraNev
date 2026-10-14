# Szczegółowe drogi na mapie iOS

Warstwa automatycznie pokazuje nawierzchnię, podział na pasy i zweryfikowane strzałki przy dużym zbliżeniu. Pobieranie, normalizacja, geometria oraz prezentacja są oddzielnymi etapami:

```text
DetailedRoadDataProvider
  ├── OverpassDetailedRoadProvider → surowe OSM (L1)
  │                                  ↓
  │                          DetailedRoadNormalizer
  │                                  ↓
  │                          NormalizedDetailedRoad
  │                                  ↓
  │                     DetailedRoadGeometryCache (L2)
  │                                  ↓
  │                     powierzchnie / linie / punkty
  └── TileDetailedRoadProvider → gotowe warstwy MVT
                                     ↓
                          DetailedRoadRenderer / MapLibre
```

## Model pasów i walidacja

`RoadDirectionality` rozróżnia drogę dwukierunkową, jednokierunkową zgodną z geometrią, jednokierunkową przeciwną, ruch odwracalny i nieznany kierunek. Jawne `oneway=no` ma pierwszeństwo nad domyślną jednokierunkowością autostrady lub ronda. `oneway=-1` odwraca fizyczną kolejność atrybutów pasów i orientację strzałek. Ruch odwracalny, naprzemienny oraz warunkowy nie dostaje stałych separatorów ani strzałek.

Przy kompletnym opisie wymagamy zgodności `lanes = lanes:forward + lanes:backward + lanes:both_ways`. Pasy wspólne pozostają osobną grupą między kierunkami. Suma niespójna, ujemna albo przekraczająca limity powoduje użycie mapy bazowej. Sama liczba trzech pasów nie oznacza automatycznie podziału 2+1. Przy `driving_side=left` odwracamy kolejność grup.

Każdy pas przechowuje swój kierunek, numer w grupie, szerokość na początku i końcu oraz zweryfikowane wskazania skrętu. Fizyczny porządek pasów w modelu zawsze oznacza lewo → prawo wzdłuż osi OSM.

Liczba pól `turn:lanes:*` musi odpowiadać liczbie pasów tej grupy. Puste pole i `none` oznaczają brak strzałki. Nieznany token lub niewłaściwa liczba pól wyłącza strzałki dla całej grupy; nie naprawiamy danych automatycznie. Niesufiksowany `turn:lanes` jest używany tylko przy pewnej jednokierunkowości. Na drodze dwukierunkowej wymagamy pól kierunkowych. `turn:lanes:both_ways` opisuje wspólną grupę; przy wystarczającej jakości danych prezentujemy wskazanie dla obu kierunków.

## Szerokości i oś drogi

Hierarchia szerokości:

1. Poprawne `width:lanes` lub kierunkowe `width:lanes:forward`, `width:lanes:backward`, `width:lanes:both_ways`.
2. Warianty `:start` / `:end`, także kierunkowe; szerokość płynnie zmienia się na całej długości odcinka. Zero na jednym końcu pozwala odwzorować pojawianie się lub zanik pasa.
3. `width` z kompletnym modelem kierunków i bez sygnałów dodatkowych części jezdni. Podział wymaga również wiarygodnego zakresu szerokości pasa.
4. Znana liczba pasów i umowna szerokość pojedynczego pasa. Pełne `width` nie jest automatycznie dzielone na pasy, jeśli może zawierać np. pasy rowerowe, parkowanie albo pobocza.
5. Sama klasa drogi daje jedynie szacowaną nawierzchnię, bez separatorów i strzałek.

Liczba pól szerokości musi być zgodna z liczbą pasów. Niespójny opis pozostaje w mapie bazowej. Puste pola mogą korzystać z heurystyki, ale obniżają jakość danych. Szerokość zbyt mała do wiarygodnego podziału daje samą nawierzchnię.

`placement=middle_of:N`, `left_of:N`, `right_of:N` przesuwają całą jezdnię względem osi OSM. Dla dróg dwukierunkowych obsługujemy `placement:forward` i `placement:backward`. Numerowanie niesufiksowanego `placement` odnosi się do kierunku geometrii OSM, również przy `oneway=-1`. `placement:start` i `placement:end` pozwalają płynnie przesuwać oś. Wartość `transition` bez poprawnie opisanych obu końców oraz niepoprawne numery pasów zachowują mapę bazową.

## Jakość i zabezpieczenia geometrii

`RoadGeometryConfidence` ma poziomy `exact`, `derived`, `estimated` i `invalid`. `exact` oznacza kompletny opis wymiarów i kierunków w źródle, a nie dokładność geodezyjną OSM.

- `exact`: nawierzchnia, separatory i strzałki z poprawnych danych skrętu.
- `derived`: nawierzchnia i neutralne separatory, bez strzałek.
- `estimated`: sama nawierzchnia.
- `invalid`: mapa bazowa; lokalny normalizator odrzuca taki odcinek, a warstwy MVT filtrują go po atrybucie.

Powierzchnie i położenie separatorów powstają w metrach w lokalnym układzie geograficznym. Obrót, pochylenie i zbliżenie kamery zachowują ich położenie. Offsety mają limit miter 2,5, wykrywają ostre kąty i stosują rzeczywiste ścięcie narożnika z obu sąsiadujących normalnych. Pierścienie powierzchni i linie są sprawdzane pod kątem samoprzecięć. Niebezpieczna geometria, pętle lub przekroczenie budżetu kontroli powodują zachowanie prostszego wyglądu. Kontrola używa komórek przestrzennych, aby uniknąć nieograniczonego porównywania każdej pary segmentów.

Separatory kończą się przed węzłami odcinka. Linie są schematycznym podziałem na pasy, bez deklarowania prawnych zakazów ich przekraczania. `lane_markings=no` pozostawia nawierzchnię i wyłącza oznaczenia. Strzałki pojawiają się tylko przy rzeczywistym końcu odcinka OSM, a nie na sztucznym końcu części ograniczonej widokiem mapy. Nie wskazują bieżącego pasa samochodu.

`bridge`, `tunnel`, `covered` i `layer` są osobnymi informacjami. Ujemny `layer` nie oznacza tunelu, a dodatni nie oznacza mostu. Tunele i lokalizacje podziemne pozostają w mapie bazowej. Etykiety, zdarzenia i trasa zachowują pierwszeństwo.

## MapLibre i płynność

Lokalna geometria korzysta z trzech zbiorczych `MLNShapeSource`: powierzchnie jako wielokąty, separatory jako linie i strzałki jako punkty. Dla strzałek używamy `MLNSymbolStyleLayer` z obrotem i pochyleniem zgodnym z mapą. Poszczególne elementy są cechami w tych zbiorach, nie indywidualnymi adnotacjami widoku mapy.

Nawierzchnia pojawia się między zbliżeniem 16 i 17, separatory między 16,8 i 18, a strzałki między 17,3 i 18,2. Motyw dzienny/nocny i zmiana stylu nie wymagają ponownego pobrania danych ani zbudowania geometrii.

Zapytania Overpass obejmują zaokrąglony obszar z marginesem. Pobieranie zaczyna się po 650 ms, a kolejne rozpoczęcia są rozdzielone minimum 10 sekundami. Nieaktualna praca jest anulowana. Awaria uruchamia ponowienie po 60 sekundach, a poprzednia poprawna geometria pozostaje do przygotowania nowej. Obliczenia działają poza głównym wątkiem, obiekty MapLibre są tworzone partiami. Obszar, dane wejściowe, liczba cech, wierzchołków i sprawdzeń geometrii mają limity.

## Pamięć podręczna i offline

L1 przechowuje surowe drogi OSM na dysku: 24 godziny świeżości, do siedmiu dni podczas niedostępności sieci, maksymalnie 32 obszary i 120 000 wierzchołków. L2 przechowuje gotową geometrię w pamięci: maksymalnie osiem wpisów i 300 000 wierzchołków. Klucz zawiera rewizję danych, obszar i wersję algorytmu. Kolory oraz styl linii są niezależne od obu poziomów.

W trybie Overpass szczegóły offline dotyczą wcześniej zachowanych obszarów. Ekran pobierania map offline nadal pobiera dotychczasowy styl bazowy. Pełne pakiety szczegółowych dróg wymagają integracji dodatkowego źródła z procesem tworzenia pakietów.

## Kontrakt własnych kafli MVT

Dostawca jest wstrzykiwany jako `DetailedRoadDataProvider`. Domyślnie działa `OverpassDetailedRoadProvider`. Opcjonalny klucz iOS Info.plist `DetailedRoadTileJSONURL` z poprawnym adresem HTTPS wybiera `TileDetailedRoadProvider`; w tym trybie MapLibre pobiera i buforuje kafle natywnie, a pętla Overpass jest pomijana. W projekcie nie ustawiono adresu serwera kafli.

TileJSON powinien udostępniać trzy warstwy źródłowe:

| Warstwa | Geometria | `kind` |
|---|---|---|
| `road_surface` | Polygon / MultiPolygon | `casing`, `surface` |
| `road_lanes` | LineString / MultiLineString | `edge`, `separator`, `center`, `sharedBoundary` |
| `road_arrows` | Point | `arrow` |

Atrybuty wspólne: `kind`, `level` (od -3 do 5), `roadClass`, `renderLevel`, `bridge`, `covered`, `confidence`, `directionality`, `laneType`, `direction`. Strzałki dodatkowo: `turnType` (zweryfikowane wartości posortowane i połączone średnikami), `bearing` (stopnie zgodnie z ruchem wskazówek zegara od północy) i `arrowScale` (względny rozmiar). Nazwy enumów odpowiadają modelowi Swift. Serwer musi wygenerować i zweryfikować gotową geometrię zgodnie z tym kontraktem; klient nie odtwarza pasów z osi drogi zawartej w MVT.

Samo przygotowanie klienta nie tworzy infrastruktury serwerowej, danych regionalnych ani pełnych pakietów offline. Te etapy pozostają kolejnym etapem opisanej architektury.

## Pliki

- `DetailedRoadProvider.swift`: surowe dane OSM, transport Overpass i L1.
- `DetailedRoadDataProvider.swift`: protokół, dostawca MVT, wybór źródła i L2.
- `NormalizedDetailedRoad.swift`: kierunkowość, pasy, szerokości, położenie osi, jakość i walidacja.
- `DetailedRoadGeometry.swift`: bezpieczne powierzchnie, linie i punkty strzałek.
- `DetailedRoadRenderer.swift`: trzy źródła, warstwy, symbole i cykl życia mapy.
- `MapLibreView.swift`: integracja z mapą iOS.

Funkcja nie zmienia wyznaczania trasy ani dopasowania GPS. Dotyczy wyłącznie iOS.
