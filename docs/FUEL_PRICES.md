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
