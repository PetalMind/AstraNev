# Dane bezpieczeństwa drogowego w Polsce

NaviAstra łączy OpenStreetMap z publiczną mapą urządzeń CANARD/GITD:
https://www.canard.gitd.gov.pl/cms/pl/o-nas/mapa-urzadzen

CANARD nie wymaga klucza ani abonamentu. Stopka serwisu udostępnia treści bezpłatnie,
niezależnie od celu wykorzystania, na licencji Creative Commons Uznanie Autorstwa 4.0.
Atrybucja i odnośnik do źródła są dostępne w ustawieniach, a podpisy punktów identyfikują źródło.

## Zakres danych

- CANARD: pomiar punktowy, dwa końce odcinkowego pomiaru prędkości, rejestracja czerwonego światła.
- OpenStreetMap: dodatkowe urządzenia kontroli, kamery monitoringu, lokalizacje sygnalizacji i dane drogowe.
- Lokalizacja sygnalizacji nie oznacza dostępu do bieżącego koloru światła.
- CANARD nie podaje w używanym zbiorze limitu prędkości ani kierunku kontroli.
  Końce odcinka otrzymują etykiety początku/końca według kolejności na wybranej trasie.
  Nie jest to potwierdzenie kierunku działania urządzenia.

## Pobieranie i awarie

Publiczna strona zawiera trzy tablice JSON skompresowane LZ-String w base64.
To źródło publicznej mapy, bez osobno dokumentowanego kontraktu API.
Zmiana formatu, niepoprawne współrzędne lub niepełny zestaw tablic oznaczają błąd pobierania.
Dekoder ogranicza rozmiar wejścia, słownika i wyniku.

Cały polski zbiór CANARD jest współdzielony przez mapę i nawigację, przechowywany lokalnie
przez maksymalnie 24 godziny i filtrowany do aktualnego widoku lub trasy.
Równoległe żądania korzystają z jednego pobierania; po błędzie obowiązuje przerwa 60 sekund.
Pobieranie CANARD dotyczy jedynie obszaru Polski i punktów kontroli.

Gdy jedno źródło zawiedzie, aplikacja zachowuje wyniki drugiego i pokazuje stan
częściowej dostępności z nazwą brakującego źródła. Mapa i aktywna trasa ponawiają próbę
po 60 sekundach. Zmiana trasy lub widoku unieważnia poprzednie zadanie.
Wygasły zbiór CANARD nie jest przedstawiany jako aktualnie dostępny.

Urządzenia obu źródeł są łączone przestrzennie. Dla wspólnego urządzenia zachowywane
są istniejące metadane OSM dotyczące limitu i kierunku kontroli.

## Weryfikacja zbioru

Zbiór pobrany 30 września 2026 zawierał 495 rekordów pomiaru punktowego,
137 rekordów pomiaru odcinkowego oraz 169 rekordów czerwonego światła:
938 punktów po rozdzieleniu końców odcinków. Liczby opisują ten konkretny odczyt,
nie gwarantują kompletności wszystkich urządzeń w Polsce.
