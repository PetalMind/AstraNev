# Modele samochodów w aplikacji iOS

Analiza i wdrożenie: 26 października 2026.

## Stan zastany i wybór

W „Ustawienia → Twój znacznik” były trzy auta: kompakt, sedan i SUV.
`NavigationMarkerArtwork.makeMesh` budował je z tej samej parametrycznej
karoserii i kabiny. Różniły się głównie długością, szerokością i wysokością.
Zapisane dawniej kombi było mapowane na sedan. Modele nie reprezentowały marek
ani danych pojazdu z ekranu „Paliwo i pojazdy”. Chodzi o wygląd pozycji na mapie.

Renderer projektuje trójwymiarową geometrię na przezroczyste obrazy 160 × 160 px,
wyświetlane zwykle na powierzchni 64 × 64 punktów. Uwzględnia kierunek,
pochylenie mapy, oświetlenie dzienne/nocne i wybrany lakier. Duże modele
fotorealistyczne mają w tym zastosowaniu niewielką przewagę wizualną, a wymagają
większego pakietu, obsługi tekstur i dodatkowego importera lub silnika.

Sprawdzone źródła pierwotne:

| Paczka | Bezpłatna zawartość i licencja podana przez autora | Ocena dla iOS |
| --- | --- | --- |
| [Kenney Car Kit](https://kenney.nl/assets/car-kit) | Strona podaje 45 plików i CC0; pobrane archiwum zawiera wersję 3.1, modele OBJ/MTL, GLB i FBX oraz `License.txt`. | Wybrana: spójne, lekkie modele aut, osobne sylwetki i koła, atlas kolorów możliwy do przeliczenia na kolory ścian. Nie wymaga dodatkowej biblioteki. |
| [Quaternius Cars Pack](https://quaternius.com/packs/cars.html) | 8 modeli, OBJ/FBX/Blend; strona konkretnej paczki wskazuje CC0 i wykorzystanie osobiste/komercyjne. | Alternatywa. W tym wdrożeniu nie pobierano ani nie dołączano plików Quaternius. Licencji tej paczki nie należy rozszerzać na inne paczki autora. |
| [Kenney Racing Kit](https://kenney.nl/assets/racing-kit) | 110 plików, CC0; zestaw zawiera również elementy toru. | Alternatywa o tematyce wyścigowej; liczba plików nie oznacza liczby samochodów. Car Kit lepiej odpowiada katalogowi codziennych aut. |

[CC0](https://creativecommons.org/publicdomain/zero/1.0/) pozwala kopiować,
modyfikować i rozpowszechniać te zasoby, również komercyjnie, bez wymaganej
atrybucji. Zachowujemy informację o autorze, oryginalne potwierdzenie licencji
w aplikacji i odsyłacz na ekranie wyboru. Nie używamy oznaczeń marek samochodów.

## Wdrożony katalog

| Wybór po polsku | Identyfikator zapisu | Model źródłowy |
| --- | --- | --- |
| Kompakt | `compact` | `hatchback-sports.obj` |
| Sedan | `sedan` | `sedan.obj` |
| SUV | `suv` | `suv.obj` |
| Sedan sportowy | `sportsSedan` | `sedan-sports.obj` |
| SUV luksusowy | `luxurySUV` | `suv-luxury.obj` |
| Van | `van` | `van.obj` |
| Wyścigowy | `race` | `race.obj` |

Dotychczasowe identyfikatory i kolory pozostają czytelne. Dawny `estate` nadal
przechodzi na sedan: nie przypisujemy mu innego rodzaju nadwozia pod nazwą kombi.
Wybór auta i koloru jest zapisywany przez istniejący `MapStore`.
Katalog nie dodaje profili tras, nie zmienia GPS, ETA ani przypisania pojazdu
w module paliwa. Rowery, pieszy i komunikacja zachowują dotychczasowe modele.

## Pochodzenie i odtworzenie plików

- Autor: Kenney, https://kenney.nl.
- Paczka: Car Kit 3.1; data wewnątrz archiwum: 2 kwietnia 2026.
- Oficjalne archiwum: https://kenney.nl/media/pages/assets/car-kit/1a312ec241-1775131960/kenney_car-kit.zip.
- SHA-256 archiwum: `fac7dacac5c7874348cf19729af3ef205f3d366493edaf0a827d93f4fdf3d0c4`.
- Oryginalny plik licencji: `NaviAstra/Resources/Vendor/NavigationCars/kenney-car-kit-license.txt`.
- Importer: `scripts/navigation-markers/import-kenney.swift` (Foundation, CoreGraphics, ImageIO dostarczane z Xcode).

Po pobraniu, sprawdzeniu sumy i rozpakowaniu tej wersji paczki:

```sh
swift scripts/navigation-markers/import-kenney.swift \
  /sciezka/do/rozpakowanego/car-kit \
  NaviAstra/Resources/Vendor/NavigationCars
```

Importer przelicza osie OBJ (góra +Y, przód +Z) na osie renderera (góra +Z,
przód +Y), zachowuje kolejność wierzchołków i centruje kotwicę na podłożu.
Długość każdej sylwetki jest normalizowana do 3,8 jednostki podglądu, aby uniknąć
przycinania przy pochyleniu mapy. Rozmiary nie są wymiarami rzeczywistych aut.
Kolory atlasu są próbkowane we współrzędnych UV. Ściany karoserii otrzymują
znacznik wybranego lakieru; opony, szyby, lampy i akcenty zachowują kolory paczki.
W modelu wyścigowym pomarańczowe obręcze pozostają niezależne od lakieru.
Importer jest dopasowany do atlasu i triangulowanych OBJ wersji 3.1;
przy aktualizacji paczki trzeba ponownie sprawdzić materiał i orientację.

W aplikacji znajduje się siedem przetworzonych siatek JSON o łącznym rozmiarze
około 0,83 MB; pojedynczy model ma 1952–2474 trójkąty. Nie dodajemy całego
archiwum, tekstur ani bibliotek obsługujących GLB/FBX. JSON zawiera wierzchołki,
indeksy trójkątów i kolory. System plików zsynchronizowany z Xcode dołącza
zasoby do aplikacji; renderer korzysta z nazw `kenney-*.json` w `Bundle.main`.

Renderer sprawdza strukturę danych, skończoność współrzędnych, indeksy i zakresy
kolorów. Brak lub błędny zasób zostawia dotychczasowy model awaryjny i wpis
w logu. Te same zasoby i projekcja obsługują ekran wyboru oraz mapę.
Obrazy mają dotychczasowy budżet pamięci podręcznej 12 MiB; pomalowane siatki
mają dodatkowy limit 12 wariantów. Modele nie wykonują żądań sieciowych.

## Weryfikacja i ograniczenia

Podgląd wszystkich siedmiu modeli wykonano rzeczywistym kodem
`NavigationMarkerArtwork`: dzień/noc, z góry, pochylenia 45° i 60°, przód i tył,
czarny lakier oraz obrazy w rozmiarze 48 px. Osobny arkusz obejmuje wszystkie
sześć kolorów każdego auta. Sprawdzono, że przód auta jest
zgodny z kierunkiem renderera. [Arkusz podglądu](images/navigation-cars-kenney-preview.png) i
[arkusz kolorów](images/navigation-cars-kenney-colors-preview.png).

Kompilacja docelowej aplikacji iOS obejmuje zasoby i zmienione ekrany.
Sam arkusz nie potwierdza płynności na urządzeniu ani zachowania podczas jazdy.
Nie dodano testów jednostkowych dla tej zmiany wizualnej.
