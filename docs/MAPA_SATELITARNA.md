# Mapa satelitarna w iOS

W Ustawieniach → Wygląd i zawartość mapy → Mapa bazowa dostępna jest opcja „Satelitarna”. Wybór zapisuje się w istniejącym ustawieniu `mapBase`.

## Źródła i koszt

- Świat: [EOX::Maps](https://maps.eox.at/), mozaika Sentinel‑2 cloudless 2016. Warstwa `s2cloudless_3857` jest udostępniona na [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), także do zastosowań komercyjnych. Nowsze roczniki EOX nie są zamiennikami na tych samych warunkach. Parametry i atrybucję potwierdza [WMTS GetCapabilities](https://tiles.maps.eox.at/wmts/1.0.0/WMTSCapabilities.xml).
- Polska: [ortofotomapa GUGiK](https://www.geoportal.gov.pl/pl/dane/ortofotomapa-orto/). GUGiK pozwala podłączać WMS i WMTS w dowolnym obsługującym je oprogramowaniu; ortofotomapa jest bezpłatna i możliwa do dowolnego wykorzystania.

Te publiczne serwisy nie wymagają klucza API, konta ani płatnej subskrypcji. Nie zapewniają SLA; EOX stosuje ograniczanie liczby żądań. Nie korzystamy ze skrobania stron ani prywatnych adresów Google/Bing.

## Renderowanie

`SatelliteMapStyle` dodaje rastry do istniejącego stylu MapLibre. Globalne kafle WMTS mają adres `https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg` i maksymalne powiększenie źródła z14. Przy większym zbliżeniu MapLibre powiększa te same piksele; nie powstają nowe szczegóły.

Od z12 nad mozaiką pojawiają się polskie zdjęcia WMS z usług `StandardResolution` i `HighResolution`. Żądania GetMap używają WMS 1.3.0, `LAYERS=Raster`, `CRS=EPSG:3857`, `BBOX={bbox-epsg-3857}`, 256 × 256 pikseli oraz PNG z `TRANSPARENT=TRUE`. Warstwa wysokiej rozdzielczości znajduje się nad standardową. Granice źródeł odpowiadają zakresowi opublikowanemu w metadanych GUGiK. Przezroczyste braki pokrycia odsłaniają mozaikę globalną, również przy granicy Polski. Źródła polskie kończą się na z19.

Fotografie zastępują kartograficzne powierzchnie, budynki 3D i dekoracje otoczenia. Pozostają nazwy miejsc, POI oraz niezależne warstwy tras, ruchu, pogody, komunikacji i znacznik pozycji. Napisy bazowe mają jasny kolor i ciemną obwódkę. Powrót do Standard przywraca poprzednią widoczność i kolory warstw, bez przeładowania stylu i resetowania kamery. Zdjęcia nie są przemalowywane na nocną paletę.

## Ograniczenia i atrybucja

Globalne zdjęcia pochodzą z 2016 roku i mają rozdzielczość około 10 m. Daty i szczegółowość polskich zdjęć zależą od miejsca. Nie jest to podgląd na żywo. Brak zdjęć lub awaria usługi nie stanowi informacji o wyglądzie terenu.

Nowe źródła są dodawane w czasie działania, więc nie należą do istniejących paczek map offline opartych na OpenFreeMap Liberty. Mapa satelitarna wymaga internetu; MapLibre może ponownie wykorzystać własny cache wcześniej oglądanych kafli.

Atrybucja EOX/Copernicus, link do CC BY 4.0 i GUGiK znajdują się pod przyciskiem informacji na mapie oraz w Ustawieniach → Dane i prywatność → Źródła mapy i licencje. Metadane źródeł MapLibre również zawierają atrybucję. Kontrolki i opis ograniczeń są po polsku.
