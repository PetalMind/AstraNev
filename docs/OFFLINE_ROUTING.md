# Mapy i wyznaczanie tras offline

Na iOS mapa i graf drogowy są przechowywane osobno. MapLibre zapisuje kafle OpenFreeMap; lokalna Valhalla 3.6.3 (Valhalla Mobile 0.6.3) wyznacza trasy z nieskompresowanego archiwum grafu `.tar`. Zapisanie samej mapy nie uruchamia trasowania offline.

## Użycie

W Ustawieniach → Mapy offline → Dane drogowe i trasy offline można:

- pobrać region z publicznego katalogu Librescoot;
- pobrać własną paczkę z adresu HTTPS;
- zaimportować lokalny plik `.tar`;
- wybrać aktywną paczkę;
- włączyć wyznaczanie tras na urządzeniu również przy dostępnym internecie.

Bez internetu dostawca tras korzysta z aktywnej paczki. W razie błędu połączenia podczas zapytania do serwera próbuje lokalnej Valhalli. Nie zastępuje odpowiedzi o braku trasy ani błędów parametrów wynikiem z innego silnika. Te same ustawienia profilu, omijania i manewrów trafiają do serwera i lokalnego silnika. Lokalnie obliczone trasy nie otrzymują odnośnika do serwerowego pobierania szczegółów.

Silnik, instalacja i usuwanie paczek działają w jednym aktorze poza głównym wątkiem. Archiwum jest mapowane do pamięci bez rozpakowywania. Usunięcie paczki zamyka jej silnik przed usunięciem pliku. Paczki są wyłączone z kopii iCloud. Import weryfikuje strukturę TAR, sumy nagłówków, rozmiary wpisów i obecność grafu, a następnie możliwość inicjalizacji silnika. Pliki z katalogu są dodatkowo weryfikowane SHA-256, jeśli GitHub udostępnia sumę.

## Zakres danych

Katalog Librescoot zawiera wybrane regiony Europy i tylko grafy dla pojazdów silnikowych. Nie obejmuje Polski. Profile pieszy i rowerowy wymagają własnej paczki z tymi danymi. Aktywna paczka musi zawierać cały przebieg trasy wraz z ewentualnym objazdem; kilka archiwów nie jest automatycznie łączonych. Granice ramki mapy nie są dowodem pokrycia grafu drogowego.

Wyznaczanie i przeliczanie tras drogowych korzysta z tego samego dostawcy. Wyszukiwanie nowych miejsc, dane bieżącego ruchu, komunikacja publiczna, automatyczny dobór ładowarek i planowanie na wskazaną godzinę wymagają internetu. Przy planowaniu na godzinę aplikacja potrzebuje strefy czasowej lokalizacji z usługi geokodowania. Dla offline można wskazać cel pinezką lub zapisanym miejscem i wybrać wyjazd teraz.

## Przygotowanie własnej paczki, np. dla Polski

Należy zbudować graf Valhalla 3.6.3 z aktualnego ekstraktu OpenStreetMap. Oficjalny proces obejmuje `valhalla_build_config`, `valhalla_build_admins`, `valhalla_build_timezones`, `valhalla_build_tiles` i `valhalla_build_extract`. Graf powinien mieć wszystkie potrzebne profile oraz zapas terenu dla objazdów. Nie wystarczy zmienić rozszerzenia pliku `.osm.pbf`, `.mbtiles` lub paczki MapLibre na `.tar`.

Przygotowane archiwum można zaimportować z Plików albo umieścić na swoim serwerze HTTPS i pobrać jego URL w aplikacji. Budowa i publikacja paczek nie odbywają się automatycznie z telefonu; do pobierania grafów dla dowolnej ramki potrzebna jest usługa dystrybucji zgodnych kafli lub regionalnych archiwów.

Źródła:

- https://github.com/Rallista/valhalla-mobile
- https://github.com/librescoot/valhalla-tiles
- https://valhalla.github.io/valhalla/building/
- https://www.openstreetmap.org/copyright

## Walidacja w środowisku deweloperskim

Kompilacja iOS potwierdza integrację SDK i lokalnego dostawcy. Kompilacja macOS potwierdza zachowanie serwerowego trasowania na tej platformie. Brak runtime'u symulatora iOS nie pozwala uznać kompilacji za potwierdzenie uruchomienia lokalnej Valhalli. Przed wydaniem należy zweryfikować trasę i przeliczenie na urządzeniu z prawdziwą paczką oraz brak połączenia z siecią.
