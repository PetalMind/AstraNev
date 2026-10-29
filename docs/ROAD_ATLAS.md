# Atlas krytycznej geometrii dróg iOS

Atlas używa rzeczywistych funkcji normalizacji, topologii, nawierzchni i strzałek z aplikacji iOS. Driver pomija wyłącznie zewnętrzną osłonę `#if os(iOS)` i kompiluje algorytmy jako narzędzie diagnostyczne CoreGraphics. Nie buduje zamrożonej aplikacji macOS.

## Zakres

- 36 082 syntetyczne układy geometrii: wszystkie liczby 1–12 pasów w macierzy przejść i rozwidleń, obie strony rozwidleń, wybrane kąty od 5° do 175°, skrzyżowania T/X, ronda, krótkie łączniki, przesunięcia osi, równoległe jezdnie, poziomy, braki danych oraz duża krzywizna.
- 3697 wariantów kontraktu źródła: 14 klas dróg, osiem profili danych, pięć stanów kierunkowości, obie strony ruchu, oznaczenia włączone/wyłączone, zmiany każdej pary klas, kombinacje kierunków wlotów, wszystkie pary poziomów −3…5, każde poprawne przesunięcie względem pasa 1…12 i osie do 80 km przecinające widok.
- Wszystkie 1023 niepuste zbiory dziesięciu obsługiwanych wskazań strzałek; ścieżki są wspólne z natywnym rendererem.
- Opcjonalne rzeczywiste obszary z pamięci podręcznej urządzenia, zachowane w archiwum wejść.

Każdy wariant otrzymuje osobną grafikę dzienną i nocną. Jest to jawna, skończona macierz obsługiwanych parametrów. Współrzędne, krzywizny i błędy dowolnych danych OSM mają nieskończenie wiele kombinacji; atlas nie stanowi dowodu poprawności każdej możliwej geometrii.

## Odtworzenie

Wymagane są Xcode ze Swift/CoreGraphics, Python 3 oraz Shapely 2. Polecenia uruchamiaj z katalogu repozytorium:

```sh
python3 scripts/road-atlas/run.py --scope all --output /tmp/naviastra-road-atlas
python3 scripts/road-atlas/audit.py /tmp/naviastra-road-atlas
```

`--real-cache /ścieżka/v2.json` dodaje autentyczne obszary z L1. `--source-dir /ścieżka/do/źródeł` pozwala odtworzyć wcześniejszą wersję algorytmów. `--scope geometry` i `--scope contracts` rozdzielają dłuższe przebiegi. Podkatalog kontraktów można dołączyć do głównej galerii przez `audit.py <atlas> --include <atlas>/contracts`.

Wynik zawiera `index.html` z filtrowaniem i stronicowaniem, grafiki SVG, `geometry/*.json`, niezależny `audit.json`, sumy SHA-256 w `provenance.json`, kopie źródeł w `sources/` oraz skompresowane sceny wejściowe `scenes.json.gz`. Czas w rekordzie obejmuje diagnostyczną budowę topologii i geometrii; nie jest pomiarem czasu klatki iPhone'a.

## Warunki akceptacji

Niezależna kontrola Shapely sprawdza poprawność wielokątów, oczekiwaną liczbę węzłów, liczbę przyjętych dróg, ciągłość separatorów przy zmianach klasy, niezalaną centralną wyspę ronda i pokrycie osi w granicach zapytania (tolerancja 8 cm). Dla rozwidleń dodatkowo wyznacza niezależne obwiednie obu odnóg i odrzuca separatory w ich wspólnym obszarze. Brak całej powierzchni również oznacza błąd. Kontrola strzałek sprawdza ich granice z uwzględnieniem grubości kreski.

Grafiki są rzutem geometrii, nie zrzutami MapLibre. Do akceptacji wizualnej potrzebna jest również kompilacja iOS i kontrola obrazu na urządzeniu: kolejność warstw, etykiety, pochylenie, motyw i zachowanie przy zmianie kadru. Sam wynik „bez wykrytych luk” nie oznacza pełnej oceny wyglądu.

W kompilacji Debug zmienna procesu `NAVIASTRA_MAP_AUDIT_CAMERA=lat,lon,zoom` ustawia powtarzalny kadr 14,5…20 bez zapisywania ustawień i bez zmiany pozycji GPS. Opcjonalny czwarty parametr `lat,lon,zoom,pitch` ustawia pochylenie 0–60° podczas kontroli modeli 3D. `NAVIASTRA_MAP_AUDIT_CONTEXT=driving` pozwala sprawdzić reguły szczegółowości renderera podczas prowadzenia; nie rozpoczyna podróży ani nie symuluje GPS. Brak zmiennych zachowuje zwykłą kamerę i kontekst aplikacji. W Release ten kod nie istnieje.

## Wynik przebiegu z 14 października 2026

Dla iOS 1.1.109 (111): 39 791 scen geometrii i kontraktu źródła, w tym 12 autentycznych obszarów z pamięci urządzenia, oraz 1023 kombinacje strzałek. Końcowa niezależna kontrola: **40 814 wariantów, 0 wykrytych problemów**. Sumy kontrolne sześciu źródeł algorytmów zgadzały się z końcowym kodem. Kompilacja iOS i `git diff --check` zakończyły się poprawnie. Aplikację zainstalowano i uruchomiono na iPhonie Dominik, zapisując natywny kadr ronda; później przywrócono zwykłą kamerę. Grafiki dzienne/nocne atlasu pozostają rzutami geometrii, a kontrola natywna dotyczy zapisanych kadrów.
