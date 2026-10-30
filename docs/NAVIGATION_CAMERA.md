# Kamera nawigacji iOS — Nurt

Dokument opisuje kamerę NaviAstra iOS Nurt, wdrażaną od wersji 1.1.147,
analizę poprzedniego zachowania oraz źródła projektu. Aktualizacja profilu perspektywy: 30 października 2026.
Nurt jest autorskim połączeniem planowania kontekstu trasy, stabilizacji
perspektywy i wspólnego zegara kamery oraz znacznika pozycji. Płynność i kadrowanie wcześniejszych wersji sprawdzono w syntetycznych przejazdach na fizycznym
iPhonie Dominik; zakres, wersje i ograniczenia pomiarów opisano poniżej.
Te pomiary nie stanowią weryfikacji nowego profilu z wersji 1.1.163.

Kontrola nowego profilu, 30 października 2026: aplikacja iOS i zmieniony silnik
kamery skompilowały się dla symulatora. Istniejący zbiorczy test kamery rozszerzono
o zbliżenie po dopasowaniu do paneli, pochylenie i odstęp znacznika. Pierwszą
sesję zatrzymał brak importu `Speech` w teście głosu; import uzupełniono.
Ponowne uruchomienie zakończono przed uzyskaniem blokady, zajętej przez inną
sesję testową. Testy kamery nie zostały wykonane. Symulator uruchomił scenariusz,
ale mapa nie została poprawnie narysowana; częściowa telemetria i zrzuty
w `build/camera-qa/chase-view/` nie potwierdzają pełnej jakości wizualnej profilu.

## Audyt wcześniejszego zachowania

Wcześniejszy `NavigationCameraEngine` wyznaczał punkt przed samochodem z wzoru
`65 + prędkość × 6`, ograniczonego do 65–320 m. Bliskość manewru zmniejszała
ten zasięg maksymalnie o połowę. Zoom, pochylenie i zasięg miały osobne okna
reakcji: odpowiednio 300, 250 i 350 m. Kierunek wynikał z cięciwy trasy
o długości 30–120 m. Na ciasnym łuku kierunek takiej cięciwy mógł wyprzedzać
rzeczywiste położenie samochodu.

| Element | Stan przed Nurt | Konsekwencja wynikająca z kodu |
| --- | --- | --- |
| Prędkość | Bez osobnego filtra wejścia do planera | Hamowanie od razu zmieniało żądany zoom i zasięg. |
| Zoom bazowy | Od 18,0 na postoju do 15,2 przy 150 km/h; dodatkowo do 0,9 przy manewrze | Duże przybliżenie przy wolnej jeździe, niezależne od szerokości skrzyżowania. |
| Pochylenie | Bazowo 35–58°; redukcja przy manewrze do 14° | Inna dynamika niż zmiana zoomu i zasięgu. |
| Wygładzanie | Stałe czasowe: cel 0,30 s, zoom 0,50 s, pitch 0,55 s, obrót 0,25 s | Brak osobnych limitów szybkości zmiany zoomu, pochylenia i obrotu. |
| Kotwica samochodu | Kontroler nadpisywał ją na 68% wysokości dostępnego obszaru | Stabilne miejsce znacznika, ale bez reakcji na kontekst manewru. |
| Dopasowanie trasy | Odległość od pozycji do jednego punktu przed nią | Boczne wybrzuszenie łuku, ronda lub nawrotu nie uczestniczyło w obliczeniu zoomu. |
| Aktualizacja renderera | Kolejna intencja zwykle oczekiwała na zakończenie natywnej animacji | Kamera mogła reagować później niż znacznik animowany przez `CADisplayLink`. |
| Wyjście ze skrętu | Brak pamięci uwagi w silniku kamery | Zmiana następnego manewru mogła szybko zmieniać żądaną perspektywę. |

To audyt kodu, a nie pomiar częstości szarpnięć ani ocena konkretnego nagrania.
Przed zmianą istniały już wygładzanie, zatrzymanie obrotu przy prędkości poniżej
0,8 m/s, tryb ręczny, podgląd trasy i obsługa słabego GPS.

## Paddingi i dostępne miejsce

`ContentView+RootView` mierzy górne elementy i dolny panel. Górny margines
uwzględnia dolną krawędź nagłówka względem mapy, górny bezpieczny obszar i 20 pt.
Dolny margines podczas nawigacji obejmuje panel oraz 8 pt. Przy pełnym panelu
samochodowym pomiar obejmuje cały dolny stos elementów. Po bokach pozostaje
24 pt. Są to istniejące pomiary UI, zachowane przez Nurt.

Wartości `CameraPadding.navigation` — góra 85, lewo/prawo 40, dół 220 — są
wartościami planera. Adapter iOS zastępuje je rzeczywistym pomiarem w
`fittingViewport`. Nie należy traktować 85/220 pt jako stałych zasłonięć ekranu.

Kotwica jest liczona wewnątrz obszaru między panelami. Zwiększenie technicznego
paddingu górnego przesuwa środek kamery do żądanej pozycji znacznika. Funkcja
zachowuje dolny obszar wyłączenia, ogranicza górny tak, aby pozostały co najmniej
24 pt, i w miarę dostępnego miejsca utrzymuje 56 pt odstępu od dolnej krawędzi.
Przy bardzo małym obszarze odstęp jest ograniczony do połowy jego wysokości.
Przeciąganie panelu aktualizuje kadr bez dodatkowego opóźnienia animacji.
Zmiana detentu i dosiadanie po puszczeniu palca korzystają na zegarze renderera
z tej samej sprężyny SwiftUI co panel: odpowiedź 0,38 s, tłumienie 0,86.
Osobny sygnał śledzenia palca odróżnia gest od istniejącego `isDragging`,
który obejmuje również animowane dosiadanie. Nie ma aktualizacji stanu SwiftUI
na każdą klatkę. Ustawienie Ogranicz ruch stosuje nowy obszar od razu.

## Konkurencja i źródła

Publiczna dokumentacja SDK opisuje udostępnione mechanizmy. Nie dowodzi,
że konsumencka aplikacja danej firmy używa identycznych parametrów.

| Źródło pierwotne | Potwierdzone zachowanie | Wniosek projektowy |
| --- | --- | --- |
| [Mapbox Navigation iOS v3](https://docs.mapbox.com/ios/navigation/guides/map-and-camera/navigation-camera/) | Viewport z uwzględnieniem nakładek, kierunek zależny od kursu i geometrii, fragment za manewrem, łączenie bliskich manewrów, opcjonalne spłaszczanie widoku przy manewrze. | Kadrować fragment drogi wraz z wyjściem ze skrzyżowania. |
| [Google Maps — Immersive Navigation, 12 marca 2026](https://blog.google/products-and-platforms/products/maps/ask-maps-immersive-navigation/) | Szerszy podgląd trasy, inteligentny zoom i przezroczyste budynki mają pomagać przygotować się do skrętów i zmiany pasa. Brak opublikowanych progów algorytmu. | Przygotowywać kadr przed decyzją kierowcy. |
| [Google Navigation SDK iOS](https://developers.google.com/maps/documentation/navigation/ios-sdk/camera) | Tryby śledzenia, podglądu i ręczny; śledzenie standardowo ustawia widok za pozycją pod kątem 45°. Gest przełącza w tryb ręczny. | Utrzymać czytelne przejścia między prowadzeniem i ręcznym oglądaniem mapy. |
| [Google Maps SDK — padding](https://developers.google.com/maps/documentation/ios-sdk/configure-map) | Padding wpływa na wizualny środek, projekcję, kamerę i kontrolki. | Traktować zasłonięcia UI jako część kadrowania. |
| [Apple Maps](https://www.apple.com/maps/) | Apple opisuje perspektywę 3D na poziomie drogi przy złożonym skrzyżowaniu oraz szczegóły pasów i przejść. Nie publikuje parametrów kamery. | Dobierać perspektywę do czytelności; pełne spłaszczenie każdego manewru nie jest uniwersalną regułą. |
| [Waze — odpowiedź zespołu z 15 maja 2024](https://waze.uservoice.com/forums/59223-waze-suggestion-box/suggestions/36538759-readd-the-autozoom-disable-funtion) | Zespół potwierdził możliwość wyłączenia automatycznego zoomu. Późniejsze komentarze użytkowników nie ustalają zachowania wszystkich wersji. | Automatyka powinna zachowywać przewidywalny kadr i respektować ręczne sterowanie. |

Nurt nie odtwarza niepublicznych algorytmów tych aplikacji. Autorski jest dobór
i połączenie mechanizmów w NaviAstra; nie potwierdzono globalnej unikatowości.

## Planowanie Nurt

`MapCameraController` przekazuje postęp po geometrii trasy, prędkość, kurs,
odległości do dwóch kolejnych manewrów oraz ich kontekst. Predykcja pozycji
obejmuje maksymalnie 2 s od próbki i jest wyłączona przy słabym GPS. Dystans
jest ograniczony do długości trasy. Odległości do manewrów są liczone względem
tej samej przewidywanej pozycji, aby kontekst i położenie kamery były zgodne.

Silnik używa monotonicznego czasu `systemUptime`. Krok filtra mieści się
w zakresie 0–1 s; powtórzony czas nie przesuwa ponownie wygładzanego stanu.

### Uwaga na manewr i krzywiznę

Uwaga ma zakres 0–1 i wspólnie steruje zasięgiem, zoomem, pochyleniem oraz
kotwicą. Jest większą z uwagi na manewr i uwagi na zakrzywienie drogi.

- Złożoność: rondo 1, zjazd 0,8, pozostałe manewry `abs(kąt) / 120`, ograniczone do 0–1.
- Okno manewru: 14 s przy prędkości co najmniej 5 m/s, ograniczone do 100–420 m. Dla zjazdu: 20 s i 100–700 m.
- Bliskość jest przekształcana funkcją `smoothstep`, aby wejście w okno było łagodne.
- Krzywizna wynika z różnicy kierunków bliskiego i dalszego odcinka. Różnica 85° osiąga pełny wkład krzywizny, równy 0,7.
- Stała czasowa narastania uwagi wynosi 0,65 s, wygaszania 3,6 s.
- Zmiana indeksu manewru przy uwadze powyżej 0,25 utrzymuje ją przez 1,8 s; w tym czasie może jeszcze wzrosnąć.

Fazy `cruising`, `approachingManeuver`, `junction` i `recovering` opisują stan
silnika. Parametry kadru wynikają z ciągłej uwagi. Faza skrzyżowania wymaga
odległości poniżej `max(55 m, prędkość × 4 s)` i złożoności większej niż 0,45.

### Zasięg, kotwica i kierunek

Prędkość ma filtr o stałej 1,4 s przy przyspieszaniu i 3 s przy hamowaniu.
Słaby GPS zachowuje ostatnią filtrowaną wartość. Od wersji 1.1.163 bazowy zasięg spokojnej jazdy to
`50 m + prędkość × 6 s`, ograniczony do 60–270 m. Krótszy korytarz pozwala
utrzymać bliższy widok zza pojazdu również po dopasowaniu do paneli. Uwaga
skraca go maksymalnie o 55%. W oknie istotnego manewru uwzględniany jest także odcinek za nim:
`25 m + prędkość × 2 s`, ograniczony do 35–80 m. Drugi manewr odległy od
pierwszego o mniej niż `max(65 m, prędkość × 6 s)` rozszerza ten kontekst
o kolejne 35 m. Para wjazd na rondo–zjazd jest łączona również poza progiem
bliskich manewrów, aby wcześniej przygotować widok łuku; wyjątek nie dotyczy
wyjazdu i kolejnego zakrętu za rondem. Dla manewrów pozostaje szerszy limit
`70 m + prędkość × 9 s`, ograniczony do 80–380 m, aby zbliżenie podczas
spokojnej jazdy nie usuwało wyjazdu z ronda ani drugiego bliskiego skrętu. Kontekst jest dołączany
płynnie przez `smoothstep`, od 1,35 do 1,0 długości okna manewru. Zapobiega to
skokowi horyzontu przy pojedynczej próbce GPS na granicy okna.

Kotwica samochodu zmienia się od 82% wysokości dostępnego obszaru przy spokojnej
jeździe do 72% przy pełnej uwadze. Znacznik pozostaje niżej, nad panelem,
z zachowaniem dotychczasowego odstępu 56 pt. Jej stała czasowa wynosi 1,2 s. Dotychczasowe
68% pozostaje rozwiązaniem zapasowym dla intencji samochodowej bez geometrii
kadrowania; kontroler nie nadpisuje nim już planu Nurt.

Kierunek bliski pochodzi z odcinka od aktualnej pozycji do punktu 7–21 m
przed samochodem. Dalszy kierunek obejmuje odcinek od 5 m do 40–140 m przed pozycją. Kamera
dodaje 30% różnicy między nimi, z limitem od 18° przy zerowej uwadze do 8° przy
pełnej. Przy zmierzonej prędkości poniżej 0,8 m/s lub słabym GPS utrzymuje
ostatni kierunek kamery. Wygładzanie obrotu korzysta z najkrótszej drogi przez
granicę 0°/360°.

### Zoom i pochylenie

Wartości między punktami tabeli są interpolowane liniowo.

| Prędkość, km/h | Bazowy zoom | Bazowe pochylenie |
| --- | --- | --- |
| 0 | 18,0 | 52° |
| 20 | 17,8 | 54° |
| 40 | 17,55 | 56° |
| 60 | 17,25 | 58° |
| 90 | 16,8 | 60° |
| 120 | 16,4 | 60° |
| 150 | 16,1 | 60° |

Uwaga dodaje do zoomu maksymalnie 0,65 i odejmuje od pochylenia do 14°.
Planer ogranicza zoom do 14,8–18,2, a pochylenie jazdy do 38–60°.
Kamera zachowuje perspektywę zza pojazdu także przy skręcie; mały obszar
między panelami nadal może ją spłaszczyć. Wybrany przez użytkownika tryb 2D
pozostaje płaski, a podgląd całej trasy zachowuje dotychczasowe kadrowanie. Przy słabym GPS
odejmuje 0,25 zoomu i ogranicza zasięg do 120 m. Stan dojazdu do celu wyznacza
45 m zasięgu, zoom 17,7, pochylenie 22° oraz kotwicę 62%.

| Wielkość | Stała czasowa filtra | Limit zmiany w planerze |
| --- | --- | --- |
| Cel kontekstu | 0,30 s | Bez dodatkowego limitu |
| Zoom | 1,4 s przy przybliżaniu, 2,8 s przy oddalaniu | 0,45 poziomu/s |
| Pochylenie | 1,1 s | 14°/s |
| Obrót | 0,5 s | 55°/s |
| Kotwica | 1,2 s | Bez dodatkowego limitu |

Są to stałe odpowiedzi filtrów wykładniczych, nie czasy ukończenia animacji.
Pierwsze wejście w nawigację ma od 1.1.155 wspólny budżet animacji 0,28 s,
a ponowne centrowanie 0,75 s. Zmiana paddingu lub nadejście dokładnego
dopasowania do trasy w trakcie startu aktualizuje natywną animację wyłącznie
w pozostałej części tego budżetu. Nie oddaje niedokończonego zbliżenia
z podglądu trasy do limitera jazdy 0,45 poziomu/s i nie restartuje pełnego
czasu. Synchroniczne callbacki MapLibre nie mogą ponownie wejść w aplikowanie
tego samego intentu. Podane wartości opisują budżet animacji, a nie czas
ładowania kafli lub obliczania trasy.

W trakcie tego krótkiego przejścia odświeżanie dekoracyjnych warstw, modeli
3D, elewacji i dodatkowych adnotacji jest odroczone. Już narysowane modele
pozostają na mapie; aktualizacja pozycji i kamery trwa dalej. Przebudowa
szczegółów wraca po zakończeniu przejścia. Osobna generacja odroczenia
chroni przed wznowieniem starej trasy po nowej komendzie lub geście.
Odroczenie dotyczy tylko startu z pozycją śledzenia i gotowym viewportem.

## Dopasowanie geometrii i renderowanie

Plan przekazuje 13 próbek od pozycji do końca horyzontu oraz dokładny punkt
manewru, jeżeli mieści się on w tym horyzoncie. `fittingViewport` analizuje
odchylenia boczne, drogę przed użytkownikiem i ewentualny fragment za nim.
Wykorzystuje 42% dostępnej szerokości na każdą stronę, 78% miejsca przed kotwicą
i 65% miejsca za nią. Przeliczenie skali uwzględnia świat o kaflu 512 pt używany
przez [MapLibre](https://maplibre.org/maplibre-native/docs/book/design/coordinate-system.html).
Dopasowanie może obniżyć zoom, minimalnie do 10.

Przy małej wysokości obszaru pochylenie jest dodatkowo ograniczone do
`max(0, (wysokość − 80 pt) × 0,22)`. Wybrany przez użytkownika płaski tryb
kamery zachowuje 0°. Zasłonięcia i geometria mogą zatem zmienić wynik względem
tabeli planera.

W ciągłym śledzeniu kamera i znacznik dostają pozycję z tej samej klatki
`NavigationPuckEngine`. Częstotliwość istniejącego `CADisplayLink` wynika z polityki energii:
zwykle 60 klatek/s w nawigacji, 30 przy ograniczeniach energii lub temperatury,
z wstrzymaniem w tle. Nie jest to gwarancja rzeczywistej wydajności urządzenia.
Perspektywa samochodowa korzysta po dopasowaniu kadru ze sprężyny drugiego
rzędu z tłumieniem krytycznym. Nowa próbka GPS zmienia cel sprężyny i zachowuje
jej prędkość. Nie kończy obrotu po 0,85 s przed kolejną próbką GPS 1 Hz.
Limity renderera to 0,45 poziomu zoomu/s, 14° pochylenia/s i 55° obrotu/s;
limity przyspieszenia wynoszą odpowiednio 1,5/s², 45°/s² i 150°/s².
Wywołanie MapLibre dla klatki ma czas animacji równy zero. Po przerwie ponad
0,25 s prędkości sprężyn są zerowane, a krok całkowania ograniczony do 0,05 s.

Start, centrowanie i podgląd trasy zachowują osobne przejścia. Po ich ukończeniu
adapter podejmuje ciągłe śledzenie także wtedy, gdy nie nadeszła nowa intencja.
Po natywnym starcie lub centrowaniu przez 0,5 s wygasza wyłącznie pozostałą
różnicę pozycji, używając funkcji smoothstep piątego stopnia. Nowy ruch
znacznika jest kopiowany od razu. Zmiana panelu, trasy, komendy albo gest
anuluje tę korektę; zwykłe śledzenie nie ma dodatkowego filtra pozycji.
Gest użytkownika przerywa śledzenie i czyści przejście. Aktualizacje szczegółów
mapy z callbacku zmiany regionu są ograniczone do co 0,1 s, a cięższe odświeżenia
z callbacków zakończenia zmiany regionu i bezczynności do co 1 s.
Podczas animacji panelu `NavigationCameraViewportTransition` odtwarza jego
prezentację niezależnie od próbek GPS. Dopasowanie jest przeliczane dla tej
geometrii i pozycji znacznika w bieżącej klatce. Dodatkowy limit zoomu bierze
pod uwagę aktualny kierunek kamery, zanim sprężyna osiągnie kierunek docelowy.
Oba dopasowania poprzedzają limiter perspektywy, więc nie powodują skokowego
zoomu. Przy niezmienionym panelu przesunięcie kotwicy jest interpolowane.
Zegar kamery respektuje politykę renderowania i stan aplikacji.

Indeks geograficzny używany do rozmieszczania modeli 3D nie jest już
przebudowywany przez zmianę kąta lub pochylenia kamery. Zachowuje klucz
pozycji, zoomu i tożsamości źródeł oraz dotychczasowe odświeżanie co 2 s.

## Ograniczenia i weryfikacja

Nurt planuje perspektywę samodzielnych tras samochodowych. Pieszy, rower
i komunikacja zachowują własne polityki; korzystają ze wspólnych struktur
intencji i mechanizmów adaptera iOS.

Dopasowanie geometrii jest lokalnym przybliżeniem płaszczyzny, z marginesami,
a nie pełnym rozwiązaniem projekcji perspektywicznej MapLibre. Próbkowanie
13 punktów nie gwarantuje objęcia każdego szczegółu bardzo złożonego odcinka.
Drugi manewr może pozostać poza kadrem, jeśli wykracza poza bazowy horyzont.
Wskaźnik uwagi nie jest ogranicznikiem przyspieszenia obrotu; tę rolę pełni
osobna sprężyna renderera. Dopasowanie viewportu następuje po wygładzaniu
planera, a następnie podlega wygładzaniu perspektywy. Przy nagłej zmianie
rozmiaru panelu wymaga to sprawdzenia, czy podczas oddalania kamery kontekst
manewru pozostaje widoczny.

Walidacja zmian kamery:

- Cztery zbiorcze scenariusze Swift Testing przeszły w izolowanym pakiecie
  produkcyjnej logiki z minimalnymi modelami danych. Obejmują prostą,
  skręt 90°, nawrót, rondo, dwa bliskie skręty, postój, słaby GPS,
  podtrzymanie kadru, przeglądanie, centrowanie i różne proporcje ekranu.
- Test renderera obejmuje 30/60 Hz z GPS 1 Hz, zachowanie prędkości po zmianie
  celu, limity zmian, obrót przez 0°/360°, padding i powrót po przerwie.
  Przekazanie pozycji sprawdzono z początkowym błędem 20 m, poruszającym się
  znacznikiem, anulowaniem korekty oraz przejściem przez południk ±180°.
- Wcześniejsze `build-for-testing` kamery na iOS Simulator oraz kompilacja
  sprężyny renderera zakończyły się powodzeniem. Pełny istniejący zestaw
  testów zawierał niezwiązane błędy w `TransitousTests.swift` (izolacja aktora)
  i `NaviAstraTests.swift` (nieaktualne API i makra z mutującymi metodami).
  Zestaw kamery wydzielono argumentem Xcode, bez trwałego wyłączania innych testów.
- Zainstalowano runtime iOS 27.1 (24A94232), udostępniający model iPhone Duo.
  Przed wykonaniem nagrań Stworca polecił budować wyłącznie na fizycznym
  iPhonie Dominik. Kompilacja symulatora została zatrzymana, a symulator
  wyłączony. Dalsze kompilacje, instalacje i przejazdy dotyczą fizycznego
  iPhone’a Dominik (iPhone 15, iOS 27.2).

### Pomiary na fizycznym iPhonie

Kontrola odbyła się bez ręcznego sterowania. Scenariusze Debug podawały GPS
1 Hz i zmieniały rzeczywisty stan panelu. Sprawdzono serię zrzutów zakrętów,
ronda, rozwijania/zwijania panelu i powrotu do śledzenia. Narzędzie Xcode na tym
urządzeniu zgłasza brak obsługi nagrywania ekranu, dlatego nie uzyskano filmu.

W porównaniu tego samego ronda w wersji 1.1.152 (154), starsza interpolacja
wykazała 4 pauzy obrotu co najmniej 0,1 s (łącznie 0,97 s), a sprężyna 0.
Obserwowany czas skręcania był porównywalny: 9,80 i 9,83 s. Maksymalna szybkość
zoomu spadła z 2,08 do 0,46 poziomu/s; maksymalny obrót nie spadł (52,66 wobec
55,03°/s), choć jego 95. percentyl zmalał z 46,98 do 37,53°/s.

Pierwsza kontrola wykryła również problemy, które poprawiono w 1.1.153 (155):

- Skok kontekstu na granicy okna manewru: na rondzie maksymalne wyjście
  punktu kadrowania zmalało z 94,58 do 43,77 pt po wprowadzeniu płynnego
  dołączania kontekstu i dopasowaniu do bieżącego kierunku.
- Skok panelu: zamiast jednorazowego przesunięcia znacznika o 181,14 pt w 66 ms
  kamera przechodzi przez wartości pośrednie przez około 0,35 s. Największa
  zmiana między porównywalnymi próbkami wyniosła 72,55 pt w 67 ms.
- W ośmiu sprawdzonych klatkach zakrętów i ronda przy detentach oraz ich zmianie
  strzałka była w całości nad panelem. Wcześniejsza klatka zakrętów pokazywała
  częściowo zasłoniętą strzałkę podczas zwijania.

W 1.1.154 (156) dodatkowo połączono kontekst wjazdu na rondo ze zjazdem przed
wejściem w łuk. W końcowym przejeździe ronda zebrano 417 próbek:
34 zawierały odległy punkt poza kadrem, maksymalne przekroczenie wyniosło
20,72 pt (wcześniej 94,58 pt), bez nieprawidłowych projekcji i bez zasłonięcia
modelowanego obrysu znacznika. W 9,05 s zmierzonych fragmentów skręcania
nie wykryto pauz obrotu ≥0,1 s. Obejrzane klatki zjazdu i panelu zachowały
widoczną strzałkę. Pakiet 1.1.154 (156) zainstalowano na iPhonie Dominik
i po przejazdach uruchomiono ponownie bez zmiennych scenariusza Debug.

Telemetria jest próbkowana najwyżej co 50 ms i zawiera luki. Nie jest pomiarem
każdej klatki ani gwarancją 60 FPS. Projekcja pozycji nie jest rzeczywistą ramką
ikony, a interpolowany viewport jest modelem prezentacji panelu. Zrzuty
potwierdzają kadrowanie wybranych momentów. Pojedyncze dalsze punkty horyzontu
mogą przejściowo wyjść poza kadr przy gwałtownej zmianie prędkości syntetycznego
GPS; ograniczenie szybkości zoomu celowo unika skokowej korekty. Nie należy
utożsamiać wyjścia odległego punktu z zasłonięciem samochodu.

Źródła pomiarów, zrzuty i logi kompilacji są lokalnie w ignorowanym katalogu
`build/camera-qa/`. Końcowe kompilacje dla fizycznego iPhone’a przeszły. Nowych
asercji panelu dodanych do zbiorczego testu nie uruchamiano jako osobnej sesji
Swift Testing; ich zachowanie zweryfikowano w aplikacji na urządzeniu.

Dodatkowa kontrola startu, 30 października 2026: na iPhonie Dominik
wersja 1.1.157 (159) zakończyła natywne przejście po 0,314 s przy budżecie
0,28 s. Scenariusz przechodził z podglądu całej trasy do aktualnej pozycji
GPS, rozwijając panel 0,1 s po starcie. Retargetowania kończyły się w tym
samym budżecie. W poprzedniej próbie 1.1.156 (158), przed odroczeniem
przebudowy szczegółów mapy, callback zakończenia następował po 1,283 s.
Są to dwa pojedyncze pomiary na urządzeniu, a nie percentyle wydajności.
Kadry z 5. i 6. sekundy scenariusza potwierdziły ustalone zbliżenie
i widoczną strzałkę nad rozwiniętym panelem. Logi `device-startup-v159`
i odpowiadające im zrzuty zachowano w `build/camera-qa/`. Po kontroli
uruchomiono aplikację bez zmiennych scenariusza testowego.

Główne miejsca implementacji: `Navigation/NavigationCameraEngine.swift`,
`Navigation/NavigationCameraRenderSmoother.swift`, `Navigation/CameraPlanning.swift`, `Maps/MapCameraController.swift`,
`Maps/MapLibreView.swift` i `Maps/MapLibreCameraAnimator.swift` w katalogu
`NaviAstra`. Pomiary zasłonięć znajdują się w `App/UI/ContentView+RootView.swift`.

## Automatyczna kontrola wizualna w iOS Debug

`IOSDebugDrivingScenario` podaje syntetyczne próbki GPS co sekundę do
produkcyjnego kontrolera i renderera. Nie uruchamia usług lokalizacji,
zapisu historii ani rzeczywistej podróży. Mapa pobiera zwykłe kafle. Scenariusz
jest aktywny wyłącznie po ustawieniu zmiennych środowiskowych procesu:

| Zmienna | Działanie |
| --- | --- |
| `NAVIASTRA_CAMERA_REPLAY=turns` | Cztery skręty 90°, w tym dwa oddalone o 65 m; prędkość 11 m/s. |
| `NAVIASTRA_CAMERA_REPLAY=roundabout` | Dojazd, 270° ronda o promieniu 28 m i wyjazd; na rondzie 6 m/s. |
| `NAVIASTRA_CAMERA_REPLAY_START_METERS` | Początkowy postęp na trasie; domyślnie 0 m. |
| `NAVIASTRA_CAMERA_REPLAY_DELAY` | Czas na załadowanie mapy przed ruchem; domyślnie 6 s. |
| `NAVIASTRA_CAMERA_REPLAY_PANELS=1` | Zmiany panelu peek → medium → expanded z produkcyjną animacją, co 4 s od ósmej sekundy sceny. |
| `NAVIASTRA_CAMERA_REPLAY_STARTUP=1` | Podgląd całej trasy, start po 4 s z aktualnym GPS i rozwinięcie panelu 0,1 s później. Domyślny ruch od 8 s. |
| `NAVIASTRA_CAMERA_REPLAY_RECENTER=1` | Tryb ręczny w 40. sekundzie sceny i powrót do śledzenia 3 s później. |
| `NAVIASTRA_CAMERA_REPLAY_LEGACY_TWEEN=1` | W tym samym scenariuszu włącza wcześniejszą interpolację renderera trwającą do 0,85 s. Służy do porównania renderowania; planer Nurt pozostaje ten sam. |

Obie trasy zawierają czterosekundowy postój. Zmiany panelu odpowiadają
przełączeniom przyciskiem; nie udają ciągłego przeciągania palcem.
`NavigationCameraVisualAudit` zapisuje do katalogu Documents aplikacji plik
`naviastra-camera-audit.csv`: rzeczywistą kamerę MapLibre, położenie znacznika
w punktach ekranu, zasłonięcia oraz punkty kontekstu poza widocznym kadrem.
Rejestracja działa tylko w tym scenariuszu Debug. Zrzuty z fizycznego iPhone’a
uzupełniają pomiary o wybrane kadry. W konsoli wariantu startup znaczniki
`CAMERA_START` pokazują retargetowanie i ukończenie przejścia natywnego;
czas wykonania callbacku może zawierać obciążenie wątku głównego.
