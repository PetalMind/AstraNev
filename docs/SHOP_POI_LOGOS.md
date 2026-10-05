# Logotypy sklepów na mapie

Opcja „Loga sklepów” znajduje się w Ustawienia → Mapa → Kategorie miejsc.
Jest domyślnie włączona i zapisywana w UserDefaults (`shopLogosEnabled`).
Wyłączenie przywraca standardowe symbole sklepów bez zmiany kategorii POI.

Na iOS logotyp zastępuje ikonę dokładnego obiektu w istniejącej warstwie
OpenMapTiles, zachowując jego etykietę, położenie i obsługę wyboru. Klucz
obejmuje `osm_id` (lub identyfikator feature w standardowym schemacie OpenMapTiles), nazwę, klasę i podklasę. Pobierane są maksymalnie 32 widoczne
sklepy od poziomu zbliżenia 14, z pierwszeństwem punktów blisko środka mapy.
Wyniki wyszukiwania również korzystają z logotypów. Przy identyfikatorach feature
odwracamy kodowanie OpenMapTiles (node × 10, way × 10 + 1, relation × 10 + 4),
a dostawca szczegółów weryfikuje obiekt przez położenie i nazwę/kategorię.
Źródło schematu: https://github.com/openmaptiles/openmaptiles/blob/master/layers/poi/poi.sql

Na macOS widoczne sklepy są pobierane przez MKLocalPointsOfInterestRequest
po zbliżeniu mapy (rozpiętość długości geograficznej poniżej 0,06°). Logotypy
są nakładane jako własne adnotacje na bazową mapę Apple; natywne etykiety i POI
pozostają dostępne. Adnotacje przekazują dokładny wynik Apple Maps do widoku
szczegółów. Punkty bez logo zachowują natywne symbole.

Wspólny dostawca szczegółów dopasowuje konkretny obiekt OSM. Logotyp pochodzi
z `brand:wikidata` lub `operator:wikidata` → Wikidata P154 → Wikimedia Commons.
Nie przypisujemy marek przez zgadywanie na podstawie nazwy. Brak identyfikacji,
logo, możliwości ponownego wykorzystania obrazu lub połączenia pozostawia
standardową ikonę. Korzystamy z istniejącego resolvera zdjęć/logotypów.

Pobieranie po zmianie obszaru jest opóźnione o 400–500 ms. Kolejki map są
szeregowe, a wspólny magazyn ogranicza jednoczesne pobieranie do dwóch zadań.
Pamięć obrazów miejsc jest ograniczona do 256 wpisów, obrazów marek do 64,
a kolejka mapy do 48 miejsc. Brak wyniku jest zapamiętywany na pięć minut.
Pobrane obrazy korzystają również z systemowego URLCache. Zadania widoku są
anulowane po zmianie obszaru, wyłączeniu opcji lub usunięciu mapy.

Autor, licencja i odnośnik do pliku są zapisywane lokalnie i udostępniane
w Ustawienia → Dane i prywatność → Logotypy sklepów. Pobierane są logotypy
z licencją pozwalającą na ponowne wykorzystanie: domena publiczna, CC0,
CC BY lub CC BY-SA. Znaki towarowe pozostają własnością ich właścicieli.
