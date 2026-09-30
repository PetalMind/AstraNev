# Paleta barw NaviAstra — Slate & Signal

Dokument opisuje semantyczny system kolorów aplikacji oraz kartografię MapLibre. Wartości pochodzą ze wspólnych tokenów i odpowiadają stanowi kodu na 30 września 2026 r.

## Zasady systemu

- **Mapa jest neutralna.** Niska saturacja i różnice jasności budują obraz bazowy; kolor sygnalizuje trasę, wybraną rzecz albo stan.
- **Kolor ma stałe znaczenie.** Fiolet oznacza markę i wybór, niebieski trasę, cyan bieżącą pozycję, a zielony, żółty, pomarańczowy i czerwony stany ruchu lub alerty.
- **Hierarchia trasy zależy od trybu mapy.** W dzień aktywna trasa jest ciemniejsza od białych dróg. W nocy trasa jest jaśniejsza od przygaszonych dróg. Podczas prowadzenia główne drogi MapLibre dodatkowo ciemnieją.
- **Kolor nie jest jedynym nośnikiem informacji.** Wykorzystujemy także szerokość i wzór linii, obrys, ikonę, kształt markera i osobne badge'e.
- **Kolor linii transportowej opisuje przewoźnika.** Opóźnienie lub punktualność jest oddzielnym stanem i badge'em.

Główne tokeny znajdują się w `NaviAstra/App/ColorPalette.swift`, a systemowy `AccentColor` wskazuje kolor marki. Renderery mapy korzystają z tych samych wartości.

## Marka, nawigacja i pozycja

| Rola | Dzień | Noc | Zastosowanie |
| --- | --- | --- | --- |
| Marka, CTA i zaznaczenie | `#8B2FE0` | `#C08BFF` | AccentColor, główne akcje, wybrany POI i aktywne zaznaczenie. |
| Aktywna trasa — domyślny przebieg | `#1E5FE0` | `#5AA2FF` | Jedyny mocny niebieski przebiegu trasy; ma kontrastowy obrys. Odcinki transportu publicznego zachowują kolor przewoźnika. |
| Trasa alternatywna | `#8592A0` | `#5D6B78` | Cieńsza, przygaszona linia; w podglądzie dodatkowo przerywana. |
| Bieżąca pozycja | `#00B8D9` | `#22D3EE` | Wyłącznie „ja”; biały pierścień, ciemny zewnętrzny obrys/cień. |
| Dokładność GPS | ten sam cyan co pozycja | ten sam cyan co pozycja | Halo z kryciem 15%. |
| Trasa piesza | `#3F4E5C` | `#B5C2CD` | Linia kropkowana/przerywana; odróżnia się też kształtem kreski. |
| Trasa rowerowa | `#00A37A` | `#2BD9A8` | Zielona linia z jasnym obrysem i subtelnym wzorem. |
| Fallback koloru transportu | `#8592A0` | — | Neutralna wartość tylko wtedy, gdy GTFS/Transitous nie podaje koloru. |

Początek i cel odróżnia przede wszystkim kształt: `A`/okrąg dla początku, pin lub flaga dla celu. Początek nie ma własnego fioletu ani czerwieni. Jeśli początek trasy jest bieżącą pozycją, pozostaje cyanowym znacznikiem „ja”.

## Ruch i stany

| Znaczenie | Kolor | Dodatkowe kodowanie |
| --- | --- | --- |
| Płynnie | `#2BB673` | Cienka linia. |
| Wolniej | `#F5C227` | Średnia szerokość. |
| Korek | `#FF8A1F` | Grubsza linia. |
| Duży korek / ruch zatrzymany | `#E5383B` | Gruba, przerywana linia. |
| Zamknięcie | `#7A1F2B` | Ikona zakazu i zakreskowana/przerywana geometria. |
| Sukces | `#2BB673` | Zapis, dotarcie i prawidłowy stan. |
| Ostrzeżenie | `#F5A524` | Warunki, roboty i stan wymagający uwagi. |
| Zagrożenie | `#E5383B` | Wypadek i poważne zagrożenie. |
| Informacja | `#3B82F6` | Informacyjny stan bez alarmu ani opóźnienia. |
| Czerwień znaku drogowego | `#D10A14` | Wyjątek dla realistycznego rysunku znaku; nie jest ogólnym tokenem Danger. |

Incydenty używają wspólnych tokenów `Warning` i `Danger`; nie utrzymujemy osobnego odcienia czerwieni dla każdego źródła. Zamknięcie ma własny ciemny burgund wyłącznie dlatego, że dodatkowo otrzymuje ikonę zakazu i wzór kreskowany. Stan przewoźnika lub opóźnienie transportu publicznego pokazujemy osobnym badge'em, więc czerwona linia GTFS nadal oznacza wyłącznie linię przewoźnika.

## Powierzchnie interfejsu

| Element | Dzień | Noc |
| --- | --- | --- |
| HUD aktywnej nawigacji i AR | `#0B121B` | `#0B121B` |
| Panel eksploracji / wyboru POI | Szkło z białym tintem ok. 88% | Szkło z tintem `#0B121B` ok. 80% |
| Tekst główny | `#141B22` | `#F2F5F8` |
| Tekst drugorzędny | `#5B6875` | `#9AA8B5` |
| Element nieaktywny | `#B7C0C8` | `#4A5866` |

Panel manewru, ETA, odległość i nazwa ulicy mają stabilne, nieprzezroczyste tło. Materiał/szkło służy wyszukiwarce, chipom i kontrolkom mapy, których czytelność nie przenosi krytycznej informacji. Przy ograniczeniu przezroczystości szkło przechodzi na nieprzezroczystą powierzchnię. W trybie eksploracji panele używają materiału; ciemny HUD jest charakterystyczny dla aktywnej nawigacji i AR.

## Baza kartograficzna MapLibre

| Warstwa | Dzień | Noc |
| --- | --- | --- |
| Tło | `#EEF1F3` | `#0E1620` |
| Zabudowa i budynki | `#E2E7EA` | `#1A2531` |
| Parki i podstawowe pokrycie zielenią | `#D3E6D0` | `#1B3630` |
| Woda | `#BCD9EA` | `#12324A` |
| Drogi lokalne | `#FFFFFF` | `#26343F` |
| Drogi główne — eksploracja | `#FFFFFF` z obrysem `#C3CCD2` | `#3A4B58` |
| Drogi główne — aktywna nawigacja | `#FFFFFF` z obrysem `#C3CCD2` | `#2F3D49` |
| Etykiety | `#2B3640` | `#C5D0D8` |

Podczas aktywnej nawigacji MapLibre przyciemnia drogi bazowe i ich etykiety, aby aktywna trasa pozostała najczytelniejsza. W eksploracji zachowuje jaśniejsze drogi główne. Dekoracyjne wzory lasu i fal wody dodają teksturę, ale nie wprowadzają nowego kodu znaczeniowego. MacOS używa bazowej kartografii MapKit; wspólne tokeny dotyczą tam tras, markerów, alertów i własnych warstw.

## Źródła w kodzie

- `NaviAstra/App/ColorPalette.swift` i `NaviAstra/Assets.xcassets/AccentColor.colorset/Contents.json` — tokeny i akcent marki.
- `NaviAstra/App/UI/NavigationChrome.swift` — szkło, stabilna powierzchnia manewru i HUD.
- `NaviAstra/Maps/MapLibreStyle.swift` — kolorystyka bazowej mapy i jej uspokojenie podczas prowadzenia.
- `NaviAstra/Maps/iOS/RouteLayerRenderer.swift`, `NaviAstra/Maps/macOS/MacRouteRenderer.swift`, `NaviAstra/Maps/MapLibreView.swift` — kolor, grubość, obrysy i wzory tras.
- `NaviAstra/Traffic/TrafficProvider.swift` i `NaviAstra/Traffic/RouteTrafficMonitor.swift` — kolory ruchu, alerty i zamknięcia.
- `NaviAstra/Maps/PlacePOIMapMarker.swift`, `NaviAstra/Maps/MacMapView.swift`, `NaviAstra/Maps/RoadSignView.swift` — wybrane POI, bieżąca pozycja i realistyczne znaki.
- `NaviAstra/Transit/GTFS/GTFSDatabase.swift`, `NaviAstra/Transit/Transitous/TransitousMapper.swift` — kolory przewoźników i dane transportu.
