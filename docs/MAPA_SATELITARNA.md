# Mapa satelitarna w iOS

W Ustawieniach → Wygląd i zawartość mapy → Mapa bazowa dostępna jest opcja „Satelitarna”. Wybór zapisuje się w istniejącym ustawieniu `mapBase`.

## Źródła i koszt

- Świat: [EOX::Maps](https://maps.eox.at/), mozaika Sentinel‑2 cloudless 2016. Warstwa `s2cloudless_3857` jest udostępniona na [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), także do zastosowań komercyjnych. Nowsze roczniki EOX nie są zamiennikami na tych samych warunkach. Parametry i atrybucję potwierdza [WMTS GetCapabilities](https://tiles.maps.eox.at/wmts/1.0.0/WMTSCapabilities.xml).
- Polska: [ortofotomapa GUGiK](https://www.geoportal.gov.pl/pl/dane/ortofotomapa-orto/). GUGiK pozwala podłączać WMS i WMTS w dowolnym obsługującym je oprogramowaniu; ortofotomapa jest bezpłatna i możliwa do dowolnego wykorzystania.

Te publiczne serwisy nie wymagają klucza API, konta ani płatnej subskrypcji. Nie zapewniają SLA; EOX stosuje ograniczanie liczby żądań. Nie korzystamy ze skrobania stron ani prywatnych adresów Google/Bing.

## Renderowanie

`SatelliteMapStyle` dodaje rastry do istniejącego stylu MapLibre. Globalne kafle WMTS mają adres `https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg` i maksymalne powiększenie źródła z14. Przy większym zbliżeniu MapLibre powiększa te same piksele; nie powstają nowe szczegóły.

Od z12 nad mozaiką pojawiają się polskie zdjęcia WMS z usług `StandardResolution` i `HighResolution`. Żądania GetMap używają WMS 1.3.0, `LAYERS=Raster`, `CRS=EPSG:3857`, 1024 × 1024 pikseli oraz PNG z `TRANSPARENT=TRUE`, na kaflu MapLibre o rozmiarze 512. Źródło polskie kończy się na z20. Granice odpowiadają opublikowanym metadanym GUGiK. Przezroczyste braki pokrycia odsłaniają mozaikę globalną, również przy granicy Polski. Nie zmniejszamy rozdzielczości zdjęć ani poziomu szczegółów pochylonej kamery.

Fotografie zastępują kartograficzne powierzchnie, budynki 3D i dekoracje otoczenia. Pozostają nazwy miejsc, POI oraz niezależne warstwy tras, ruchu, pogody, komunikacji i znacznik pozycji. Napisy bazowe mają jasny kolor i ciemną obwódkę. Powrót do Standard przywraca poprzednią widoczność i kolory warstw, bez przeładowania stylu i resetowania kamery. Zdjęcia nie są przemalowywane na nocną paletę.

## Ograniczenia i atrybucja

Globalne zdjęcia pochodzą z 2016 roku i mają rozdzielczość około 10 m. Daty i szczegółowość polskich zdjęć zależą od miejsca. Nie jest to podgląd na żywo. Brak zdjęć lub awaria usługi nie stanowi informacji o wyglądzie terenu.

Nowe źródła są dodawane w czasie działania, więc nie należą do istniejących paczek map offline opartych na OpenFreeMap Liberty. Mapa satelitarna wymaga internetu; MapLibre może ponownie wykorzystać własny cache wcześniej oglądanych kafli.

Atrybucja EOX/Copernicus, link do CC BY 4.0 i GUGiK znajdują się pod przyciskiem informacji na mapie oraz w Ustawieniach → Dane i prywatność → Źródła mapy i licencje. Metadane źródeł MapLibre również zawierają atrybucję. Kontrolki i opis ograniczeń są po polsku.

## Przyspieszenie w iOS 1.1.138 (140)

Poprzedni widok pobierał dwie pełne warstwy PNG dla każdego polskiego kafla, także gdy dolna była całkowicie zasłonięta. W próbce publicznego obszaru Warszawy oba adresy zwróciły identyczny obraz po 1 543 109 bajtów; każde udane żądanie trwało 2,34–2,81 s. Pierwsza odpowiedź Standard zwróciła przejściowe 404. Powtórzone pobieranie nie przyspieszało u dostawcy. Dotychczasowy domyślny ambient cache MapLibre miał 50 MiB, czyli około 16 takich par bez uwzględnienia pozostałych zasobów.

`SatelliteTilePipeline` wystawia jeden raster przez lokalny `URLProtocol`; zarezerwowany host `.invalid` nigdy nie jest wywoływany w sieci. Najpierw pobiera obraz HighResolution. Jeśli jest całkowicie nieprzezroczysty, przekazuje jego oryginalne bajty i pomija zasłonięty Standard. Przezroczyste miejsca są uzupełniane Standard bezstratnie w PNG. Kolorowy podkład zachowuje RGB także pod szarym obrazem z alfą. Poprawny fragment High jest zachowywany, gdy uzupełnienie zawiedzie.

Jeśli High nie kończy się w 3 s, rusza dodatkowo Standard. Wcześniej dostępny podkład może być pokazany jako tymczasowy obraz; pierwotne pobieranie High trwa dalej. Krótka ważność podkładu pozwala MapLibre odebrać pełny obraz z tego samego zadania, bez ponownego pobierania High. Normalnie aktywne są najwyżej 4 zadania kafli; wolne uzupełnienia i trwające poprawienie jakości mają wspólny limit 6 żądań HTTP oraz najwyżej 4 zadania poprawiania jakości. Nie zwiększa to poprzedniego domyślnego limitu połączeń Foundation. 429/503 zatrzymują kolejne żądania zgodnie z Retry-After. Anulowanie ostatniego odbiorcy zatrzymuje jego pracę; identyczne aktywne pobrania są współdzielone. Przetwarzanie PNG odbywa się poza głównym wątkiem.

Pamięć podręczna obrazów ma limit 32 MiB, a istniejący ambient cache MapLibre 256 MiB. Obrazy są ważne najwyżej 24 godziny, krócej przy ograniczeniach odpowiedzi źródła; no-store/no-cache nie są nadpisywane. Pakiety offline nie są usuwane ani poszerzane. Powrót do tych samych zdjęć wykorzystuje cache. Ponowne ustawianie niezmienionego stylu nie przepisuje wszystkich warstw i etykiet.

Końcowy pomiar narzędzia kontrolnego na Macu, na produkcyjnej logice przez rzeczywisty URLProtocol: zimny kafel 2,44 s, ponowny odczyt 1,01 ms. Oryginalne bajty PNG były identyczne. W osobnej próbie kontrolnej z domyślnym timeoutem testowej sesji odpowiedź źródła trwała aż 34,22 s; aplikacja ma własny limit czasu zasobu 15 s. Zmienność usługi nie pozwala uczciwie wyliczyć stałego przyspieszenia pierwszego pobrania. To pomiar pojedynczego kafla i lokalnego cache, nie czas wyrenderowania całego kadru na iPhonie. Próba porównania czterech kafli trafiła na przejściowe 404, więc nie wyliczamy z niej przyspieszenia całego widoku. W pełni pokrytym kaflu pominięcie drugiego identycznego obrazu zmniejsza transfer zdjęć o 50%; przy mieszanym pokryciu nadal mogą być potrzebne oba obrazy.

Kontrola bez zewnętrznej sieci obejmuje niezmienione bajty, współdzielenie żądań i cache, składanie pokrycia i kolory RGB, wadliwe uzupełnienie, szybki podkład przy wolnym High i późniejszą pełną jakość bez drugiego pobrania High, anulowanie oraz ograniczenie równoległości. Publiczny GUGiK i EOX pozostają bez klucza i płatnego API; ich dostępność i czas pierwszej odpowiedzi nie są gwarantowane. [GUGiK opisuje](https://www.geoportal.gov.pl/pl/dane/ortofotomapa-orto/) także ograniczenie szczegółowości gotowych WMTS przy dużym zbliżeniu, dlatego optymalizacja zachowuje oryginalne zdjęcia WMS. [EOX](https://maps.eox.at/) udostępnia usługę bez gwarancji dostępności.

Podpisana kompilacja iOS zakończyła się `BUILD SUCCEEDED`. `devicectl` potwierdził instalację 1.1.138 (140) na „iPhone (Dominik)”, start procesu 22459 oraz jego dalszą obecność. Aktualizacja bez odinstalowania zachowała wszystkie 431 ścieżek Application Support, w tym bazę uczenia, historię, zapisane miejsca i plany. Nie odczytywano prywatnych śladów GPS. Nie wykonano pomiaru całego kadru w interfejsie telefonu ani rzeczywistego przejazdu.

## Odzyskiwanie po błędzie kafla

W używanym MapLibre 6.29.0 błąd pobrania kończy żądanie kafla. Ponowienie zależy od zmiany jego zapotrzebowania; ruch kamery nie gwarantuje ponowienia każdego nadal widocznego kafla. Ponadto raster z błędem jest oznaczany jako załadowany, dlatego samo `fullyRendered` nie wykrywa tej sytuacji. Potwierdzają to [TileLoader](https://github.com/maplibre/maplibre-native/blob/ios-v6.29.0/src/mln/tile/tile_loader_impl.hpp) i [RasterTile](https://github.com/maplibre/maplibre-native/blob/ios-v6.29.0/src/mln/tile/raster_tile.cpp). Jest to uzasadniona kodem przyczyna pozostających pustych fragmentów; nie odtworzono jej podczas przejazdu na urządzeniu.

Renderer iOS obserwuje faktyczne zdarzenia `.error` wyłącznie źródeł satelitarnych. Po 2 s odbudowuje wadliwe źródło z nowym identyfikatorem. Kolejne błędy mają przerwy 5, 15, 30, 60 i najwyżej 120 s. Seria błędów nie przesuwa pierwszego terminu; poprawne zakończenie konkretnego kafla usuwa jego oczekujące ponowienie. Po dłuższej przerwie bez błędów opóźnienie wraca do 2 s. Zdarzenia poprzednich generacji i anulowane żądania nie rozpoczynają nowych prób.

Adresy kafli pozostają stałe, więc prawidłowe obrazy nadal korzystają z cache. Odtworzenie zachowuje kolejność rastrów względem istniejących warstw ruchu, pogody i opisów; nie przeładowuje całego stylu, kamery ani trasy. Ponowienia są wstrzymywane przy nieaktywnym renderowaniu i braku sieci. Powrót aplikacji lub dostępności sieci wznawia tylko oczekujące błędy. Zmiana stylu i usunięcie widoku anulują zadania poprzedniego renderera.

Cztery krytyczne scenariusze sprawdzają terminy i ograniczenie częstotliwości, serie błędów i sukces poszczególnych kafli, stare identyfikatory oraz wznowienie i reset. Przypadki obliczeniowe uruchomiono bez sieci na produkcyjnej polityce ponowień. Nie zastępuje to pomiaru kompletności kadru ani sprawdzenia gestów i przejazdu na iPhonie. Publiczne GUGiK i EOX nadal mogą być niedostępne lub nie mieć pokrycia dla danego obszaru.
