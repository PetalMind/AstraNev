# Ceny paliw w szczegółach POI

`PaliwoMapaFuelPriceProvider` odczytuje publiczne dane używane przez
[paliwomapa.pl](https://paliwomapa.pl). Integracja nie zapisuje nic w serwisie.

Źródła sprawdzone 30 września 2026:

- `https://paliwomapa.pl/stacje.json`: katalog OSM, 8534 obiekty w odczytanym pliku;
  obsługiwane są tablica oraz obiekt z `elements`, współrzędne `lat/lon` lub `center`.
- Konfiguracja `window.PM_SUPABASE_CONFIG` w HTML strony: publiczny adres Supabase
  i klucz `sb_publishable_…`, taki sam jak w przeglądarce.
- `GET /rest/v1/app_docs?select=doc_id,data&collection_name=eq.prices&parent_path=is.null&doc_id=eq.ID&limit=1`:
  jeden zatwierdzony dokument ceny dla stacji. Nagłówek `apikey` zawiera publiczny
  klucz strony. Nie odczytujemy zgłoszeń oczekujących, kont ani danych kierowców.
- Pola cen: `pb95`, `pb98`, `on`, `on_plus`, `lpg`; daty: `ud_<paliwo>` z fallbackiem
  do `updated` wyłącznie przy braku pola. `updated_at` rekordu nie jest datą ceny.
  Obsługiwane są ISO 8601, obiekt `seconds` i liczba milisekund Unix.
- `closed=true`: komunikat o zamknięciu zamiast cen.

Dopasowanie wymaga zgodnego ID i typu OSM (jeśli dostępny) oraz odległości do 250 m.
Ceny źródłowe używają samego numeru OSM, więc kolizje numerów w katalogu są odrzucane.
Dla pozostałych POI wymagamy odległości do 80 m i identycznej znormalizowanej nazwy,
marki lub operatora. Dopasowanie wielu stacji jest odrzucane. Nazwy ogólne takie jak
„Stacja paliw” nie wystarczają. Brak dopasowania nie oznacza zerowej ceny.

Sekcja pojawia się w średnim i pełnym widoku szczegółów stacji, pod przyciskami akcji.
Używa kolorów semantycznych aplikacji, jej akcentu, zaokrąglonych kart i adaptacyjnej
siatki. Każde paliwo ma własną datę i oznaczenie wieku; brak ceny jest jawny.
Pięć dni oznacza świeżość zgłoszenia, a nie gwarancję ceny przy dystrybutorze.
Link źródłowy prowadzi do konkretnej stacji przez `?stacja=ID`.

Katalog jest buforowany w pamięci przez 24 godziny, ceny przez 15 minut (do 100 stacji).
Współdzielone żądania zapobiegają powtórnym pobraniom przy zmianie wysokości panelu.
„Odśwież” omija bufor cen; błędy HTTP i dekodowania mają osobny stan i ponowienie.
Nie utrwalamy cen jako statycznego snapshotu w aplikacji.

To adapter do obecnego źródła strony, bez gwarancji stabilności zewnętrznego API.
Zmiana domeny API, klucza publicznego lub schematu wymaga aktualizacji providera.
Odczyt publicznego endpointu i katalogu potwierdzono na żywo; nie uruchamiano
aplikacji w symulatorze ani na urządzeniu.

## Szybkie dodawanie tankowania podczas postoju

W aktywnej aplikacji mapa sprawdza pozycję użytkownika dla wybranego pojazdu
spalinowego lub PHEV, w trybie samochodu. Katalog jest wspólny z cenami POI;
przesuwanie mapy nie wpływa na rozpoznanie stacji. Pozycja musi mieć wiek do 30 s
oraz dokładność do 30 m. Postój wymaga prędkości do 1,5 m/s i co najmniej 15 s
kolejnych pomiarów przy stacji w promieniu 70 m. Nieznana prędkość może być
zastąpiona przemieszczeniem między świeżymi pomiarami. Ruch wykryty między
pomiarami także blokuje sugestię. Po rozpoznaniu stosujemy promień wyjścia 120 m.

Ikonka przy nagłówku mapy otwiera formularz z nazwą i lokalizacją stacji oraz
wybranym pojazdem i paliwem. Kilka pasujących stacji wymaga wyboru użytkownika.
Stacje z kolizją numerów OSM są pomijane, ponieważ źródło cen używa numeru bez typu.
Dzisiejsza cena (według dnia w Europe/Warsaw, bez dat przyszłych) uzupełnia puste
pole. Starsza lub niedatowana cena wymaga użycia przycisku „Użyj tej ceny”.
Odświeżenie nie nadpisuje ręcznie wpisanej ceny. Stacja oznaczona jako zamknięta,
brak ceny i błąd pobierania pozostawiają ręczne wprowadzenie danych. Źródło nie
ma cen ładowania EV. Zapis wymaga potwierdzenia użytkownika.

Podczas nawigacji wykorzystywany jest świeży GPS nawigacji. Poza nią aplikacja
wykonuje pojedyncze dokładniejsze odczyty co około 60 s, a w pobliżu stacji co
około 20 s. Dodatkowe odczyty ustają w tle i podczas otwarcia formularzy/paneli.
Po zapisie sugestia jest wyciszona do opuszczenia okolicy stacji.

Ukończony przejazd przecinający datę tankowania może zasilić oba okresy paliwowe.
Dzielimy tylko ciągłe, zaakceptowane odcinki śladu GPS według czasu; odcinki
między próbkami dzielimy proporcjonalnie do czasu. Luki, skoki pozycji i przerwane
przejazdy nie są doliczane. Cały przejazd mieszczący się w okresie nadal używa
zapisanego dystansu. Przebieg licznika zachowuje pierwszeństwo.

### Wskazanie stacji na mapie

W szczegółach stacji paliw na mapie przycisk „Dodaj tankowanie” otwiera formularz dla tego konkretnego miejsca. Nazwa, współrzędne i identyfikator stacji pochodzą z wybranego POI, niezależnie od bieżącej pozycji GPS. Cena podlega tym samym regułom daty raportu i ręcznej edycji co przy automatycznym rozpoznaniu postoju. Bez pojazdu spalinowego lub hybrydowego można dodać go w tym samym oknie, zachowując stację. Na macOS formularz otwiera się po zamknięciu szczegółów miejsca.
