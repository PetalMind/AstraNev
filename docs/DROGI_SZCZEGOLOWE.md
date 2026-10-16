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
  │                     DetailedRoadTopology
  │                     korytarze + obszary węzłów
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

Powierzchnie i położenie separatorów powstają w metrach w lokalnym układzie geograficznym. Nawierzchnia jest sumą przekrojów segmentów i zaokrąglonych połączeń, normalizowaną operacjami CoreGraphics osobno dla każdego poziomu, mostu i sposobu renderowania. Wynik zachowuje wewnętrzne pierścienie, w tym wyspy rond. Obramowanie powstaje dopiero z końcowej powierzchni, dzięki czemu granice odcinków nie tworzą poprzecznych szwów. Samoprzecięcie offsetu może wyłączyć niebezpieczne oznaczenie, ale nie usuwa nawierzchni. Linie są przycinane do lokalnych masek w komórkach 64 m; krawędzie dodatkowo do obrysu powierzchni. Długie osie są przycinane do widoku przed budową przekrojów, z zachowaniem interpolacji szerokości i przesunięcia.

Separatory zachowują ciągłość na zgodnych połączeniach dwóch odcinków. Przy złożonym skrzyżowaniu lub niepewnych danych wygaszają się przed jego środkiem. Linie są schematycznym podziałem na pasy, bez deklarowania prawnych zakazów ich przekraczania. `lane_markings=no` pozostawia nawierzchnię i wyłącza oznaczenia. Strzałki pojawiają się tylko przy rzeczywistym końcu odcinka OSM, a nie na sztucznym końcu części ograniczonej widokiem mapy lub przy każdym nowo wykrytym wlocie. Nie wskazują bieżącego pasa samochodu.

`bridge`, `tunnel`, `covered` i `layer` są osobnymi informacjami. Ujemny `layer` nie oznacza tunelu, a dodatni nie oznacza mostu. Tunele i lokalizacje podziemne pozostają w mapie bazowej. Etykiety, zdarzenia i trasa zachowują pierwszeństwo.

Renderer iOS ogranicza nawierzchnię i oznaczenia od góry pierwszą warstwą etykiet, budynków 3D albo nakładek nawigacji. Reguła działa również w stylu bez warstwy `transportation` oraz po późniejszym dodaniu nakładki. Poziomy nawierzchni nie mogą przesunąć asfaltu ponad tę granicę. Nawierzchnia i jej obramowanie mają wygładzone krawędzie oraz maksymalną nieprzezroczystość 0,995: pozostają w przebiegu mieszania, aby nie zapisywać współpłaszczyznowej głębokości przecinającej trasę lub napisy przy pochylonej kamerze. Nie zmienia to geometrii jezdni ani wyznaczania trasy.

Przed etykietami i nakładkami nawigacji wspólny styl iOS instaluje `MapOverlayDepthLayer`. Warstwa jednym trójkątem Metal przywraca odległą głębokość, zachowując kolor mapy oraz bufor szablonu używany do maskowania kafli. Chroni napisy i trasę również przed głębokością zapisaną przez tekstury wody, roślinności i nawierzchni: w MapLibre 6.29 warstwa `fill-pattern` zapisuje głębokość także przy małej nieprzezroczystości. Tekstury, kolory i budynki 3D pozostają na mapie; napisy i nawigacja są komponowane nad gotowym otoczeniem. Warstwa jest instalowana ponownie przy zmianie stylu.

## Ciągła nawierzchnia i obszary skrzyżowań

`DetailedRoadTopology` rozdziela oś drogi, jej przekrój, profile wlotów i wspólną powierzchnię węzła. Identyfikatory węzłów OSM z odpowiedzi Overpass pozostają w surowych danych. Pozwalają dzielić długą drogę także przy wlocie położonym w jej środku. Starsze zapisy L1 bez identyfikatorów nadal działają: używają współrzędnych z dokładnością dopasowania 0,1 m. Różne poziomy i oznaczenia mostu są rozpatrywane oddzielnie; sam geometryczny krzyż osi nie tworzy połączenia. Wyjątkiem jest wspólny identyfikator OSM na końcu drogi: zachowuje połączenie dojazdu z mostem. Dojazdy pozostają kompletne na obu poziomach, a lokalne maski usuwają wewnętrzne obramowania na przejściu.

Wolne końce można wizualnie dopasować na odległości do 1,25 m tylko przy wzajemnym najbliższym dopasowaniu, zgodnej klasie i dostępnej nazwie/numerze drogi oraz przeciwnych, niemal współliniowych stycznych. Dopasowanie nie obejmuje rond, równoległych jezdni ani różnych poziomów. Nie zmienia grafu routera.

Bliskie skrzyżowania tworzą wspólny `JunctionRegion` wyłącznie wtedy, gdy łączy je istniejący krótki odcinek, oba końce mają co najmniej trzy wloty i geometria mieści się w ograniczonym obszarze. Długość łącznika wynosi najwyżej 12 m, region ma najwyżej osiem węzłów i 24 m średnicy. Ronda nie są scalane w jeden wypełniony środek. Zamknięte osie są dzielone na łuki, aby zachować jezdnię i centralną wyspę także na rondzie z jednym wjazdem.

Każdy zewnętrzny wlot przekazuje profil: styczną, krawędzie, szerokość, położenia pasów i jakość danych. Korytarz jest skracany dopiero po poprawnym przygotowaniu wspólnej nawierzchni. Obrys powstaje z uporządkowanych profili i krzywych Béziera, zachowując wklęsłe narożniki oraz przestrzeń pomiędzy odnogami. Nie stosujemy wypukłej otoczki zalewającej wyspy. Jeżeli obrys pojedynczego węzła sam się przecina lub nie obejmuje osi dojazdów, zachowujemy pełne korytarze i łączymy ich powierzchnie z małym zaokrąglonym środkiem. Nieudane scalenie klastra pozostawia osobne węzły. Zmiana nazwy lub klasy drogi we wspólnym węźle nie przerywa zgodnych separatorów. Na ostrym rozwidleniu niezależne oznaczenia odnóg są odsunięte poza obszar nakładania ich przekrojów; nie rysujemy na sobie dwóch siatek pasów ani strzałek w ich wspólnej części.

Zgodna kontynuacja osi o zmienionej szerokości dostaje łagodne przejście. Docelowo przejście obejmuje do 24 m na drogach miejskich i do 60 m na autostradach oraz drogach ekspresowych; na krótkich odcinkach dopasowuje się do dostępnego miejsca. Przy wiarygodnych jednokierunkowych profilach różniących się o jeden lub dwa pasy pozostałe separatory biegną dalej, a nadmiarowy prawy pas zanika przy krawędzi. Bez danych wskazujących stronę zmiany jest to reguła wizualna, nie informacja o organizacji ruchu. Pozostałe niezgodności upraszczają oznaczenia. Wygaszanie wykorzystuje cztery pasma przezroczystości z łagodną interpolacją, a nie twarde zakończenie na węźle OSM.

Trajektorie pasów zachowują ich kolejność, respektują znany kierunek ruchu i opisane skręty. Przy łagodnym rozwidleniu preferują skrajny pas, a niepewne skręty miejskie pozostają bez linii. Te trajektorie wspierają dopasowanie separatorów; nie stają się instrukcjami prowadzenia ani nowymi strzałkami. Skomplikowany środek ma wspólną nawierzchnię, delikatne rozjaśnienie i mniej oznaczeń niż dojazdy. Na dobrze opisanym jednokierunkowym rozwidleniu może pojawić się mała, zaokrąglona strefa neutralna, wyłącznie gdy mieści się w bezpiecznej powierzchni węzła. To schematyczna powierzchnia malowana, nie rozpoznanie fizycznej wysepki lub krawężnika.

## MapLibre i płynność

Lokalna geometria korzysta z trzech zbiorczych `MLNShapeSource`: powierzchnie jako wielokąty, separatory jako linie i strzałki jako punkty. Dla strzałek używamy `MLNSymbolStyleLayer` z obrotem i pochyleniem zgodnym z mapą. Poszczególne elementy są cechami w tych zbiorach, nie indywidualnymi adnotacjami widoku mapy.

Nawierzchnia pojawia się między zbliżeniem 16 i 17, separatory między 16,8 i 18, a strzałki między 17,3 i 18,2. Motyw dzienny/nocny i zmiana stylu nie wymagają ponownego pobrania danych ani zbudowania geometrii.

Zapytania Overpass obejmują zaokrąglony obszar z marginesem minimum 60 m. Siatka zapytania jest dopasowana do zbliżenia: 0,002° od 18, 0,004° od 17 i 0,008° poniżej 17. Pobieranie zaczyna się po 650 ms, a kolejne rozpoczęcia są rozdzielone minimum 10 sekundami. Nieaktualna praca jest anulowana. Awaria uruchamia ponowienie po 60 sekundach, a poprzednia poprawna geometria pozostaje do przygotowania nowej. Obliczenia działają poza głównym wątkiem, obiekty MapLibre są tworzone partiami. Obszar, dane wejściowe, liczba cech, wierzchołków i sprawdzeń geometrii mają limity. Budżet najpierw rezerwuje miejsce dla nawierzchni; przy dużej złożoności pomija nadmiarowe oznaczenia i dekoracje, zamiast odrzucać poprawną powierzchnię z powodu samych separatorów.

## Pamięć podręczna i offline

L1 przechowuje surowe drogi OSM na dysku: 24 godziny świeżości, do siedmiu dni podczas niedostępności sieci, maksymalnie 32 obszary i 120 000 wierzchołków. L2 przechowuje gotową geometrię w pamięci: maksymalnie osiem wpisów i 300 000 wierzchołków. Klucz zawiera rewizję danych, obszar i wersję algorytmu. Kolory oraz styl linii są niezależne od obu poziomów.

W trybie Overpass szczegóły offline dotyczą wcześniej zachowanych obszarów. Ekran pobierania map offline nadal pobiera dotychczasowy styl bazowy. Pełne pakiety szczegółowych dróg wymagają integracji dodatkowego źródła z procesem tworzenia pakietów.

## Kontrakt własnych kafli MVT

Dostawca jest wstrzykiwany jako `DetailedRoadDataProvider`. Domyślnie działa `OverpassDetailedRoadProvider`. Opcjonalny klucz iOS Info.plist `DetailedRoadTileJSONURL` z poprawnym adresem HTTPS wybiera `TileDetailedRoadProvider`; w tym trybie MapLibre pobiera i buforuje kafle natywnie, a pętla Overpass jest pomijana. W projekcie nie ustawiono adresu serwera kafli.

TileJSON powinien udostępniać trzy warstwy źródłowe:

| Warstwa | Geometria | `kind` |
|---|---|---|
| `road_surface` | Polygon / MultiPolygon | `casing`, `surface`, opcjonalnie `junction`, `gore` |
| `road_lanes` | LineString / MultiLineString | `edge`, `separator`, `center`, `sharedBoundary` |
| `road_arrows` | Point | `arrow` |

Atrybuty wspólne: `kind`, `level` (od -3 do 5), `roadClass`, `renderLevel`, `bridge`, `covered`, `confidence`, `directionality`, `laneType`, `direction`. Strzałki dodatkowo: `turnType` (zweryfikowane wartości posortowane i połączone średnikami), `bearing` (stopnie zgodnie z ruchem wskazówek zegara od północy) i `arrowScale` (względny rozmiar). Nazwy enumów odpowiadają modelowi Swift. Serwer musi wygenerować i zweryfikować gotową geometrię zgodnie z tym kontraktem; klient nie odtwarza pasów z osi drogi zawartej w MVT.

Opcjonalne `paintOpacity` (0–1) steruje lokalnym wygaszaniem linii. Brak pola oznacza pełną intensywność, więc wcześniejsze kafle zachowują działanie. Nowa topologia jest obliczana lokalnie dla dostawcy Overpass. Gotowe kafle MVT muszą otrzymać odpowiednie powierzchnie i łączniki w procesie generowania po stronie ich dostawcy.

Samo przygotowanie klienta nie tworzy infrastruktury serwerowej, danych regionalnych ani pełnych pakietów offline. Te etapy pozostają kolejnym etapem opisanej architektury.

## Pliki

- `DetailedRoadProvider.swift`: surowe dane OSM, transport Overpass i L1.
- `DetailedRoadDataProvider.swift`: protokół, dostawca MVT, wybór źródła i L2.
- `NormalizedDetailedRoad.swift`: kierunkowość, pasy, szerokości, położenie osi, jakość i walidacja.
- `DetailedRoadTopology.swift`: połączenia, korytarze, profile wlotów, wspólne powierzchnie, łączniki pasów i przejścia szerokości.
- `DetailedRoadGeometry.swift`: powierzchnie, lokalne maski oznaczeń, linie i punkty strzałek.
- `DetailedRoadSurfaceGeometry.swift`: sumowanie przekrojów, pierścienie z otworami i operacje na ścieżkach.
- `DetailedRoadArrowGeometry.swift`: wspólne ścieżki wszystkich 1023 niepustych kombinacji dziesięciu obsługiwanych wskazań.
- `DetailedRoadRenderer.swift`: trzy źródła, warstwy, symbole i cykl życia mapy.
- `MapLibreView.swift`: integracja z mapą iOS.

Funkcja nie zmienia wyznaczania trasy ani dopasowania GPS. Dotyczy wyłącznie iOS.

## Atlas kontrolny

Procedurę odtwarzania macierzy geometrii, niezależnej kontroli i grafik opisuje [ROAD_ATLAS.md](ROAD_ATLAS.md). Atlas zawiera warianty dzienne i nocne. To kontrola krytycznej warstwy mapy; nie zastępuje oceny rzeczywistego renderowania na iPhonie.
