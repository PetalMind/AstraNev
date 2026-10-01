# Oceny miejsc — Mangrove

Status: wyświetlanie ocen zostało tymczasowo wyłączone na prośbę użytkownika.
Karty miejsc nie tworzą `PlaceRatingSummary`, więc nie pobierają opinii Mangrove.
Kod integracji pozostaje w projekcie do ewentualnego ponownego włączenia.
Poniższy opis dokumentuje zachowaną implementację.

NaviAstra odczytuje oceny społeczności Mangrove dla punktów POI: restauracji,
sklepów, zabytków, rozrywki i innych miejsc. Publiczny odczyt nie wymaga klucza,
konta ani płatnej subskrypcji. Dostępność opinii zależy od społeczności; nie ma
gwarancji, że konkretne miejsce posiada oceny.

## Źródła i wybór dostawcy

Analiza z 30 września 2026:

- Mangrove udostępnia otwartą bazę opinii i publiczne API. Regulamin dopuszcza
  komercyjne wykorzystanie oraz wskazanie bazy Mangrove jako źródła zbiorczej oceny.
  Domyślna licencja: CC BY 4.0; importowane rekordy mogą mieć CC BY-SA 4.0.
  https://mangrove.reviews/terms
  https://docs.mangrove.reviews/
- Google Places udostępnia oceny i opinie w rozliczanych wariantach API, z limitami
  bezpłatnego użycia. Nie jest bezwarunkowo bezpłatną bazą. Standardowe zasady
  wymagają Google Map przy prezentowaniu danych na mapie; obowiązują także
  odrębne zasady EOG. Nie dodajemy tej integracji do obecnych map NaviAstra.
  https://developers.google.com/maps/documentation/places/web-service/usage-and-billing
  https://developers.google.com/maps/documentation/places/web-service/policies
- Foursquare oferuje plany i rozliczenie za użycie API Pro/Premium. Pole rating
  istnieje w danych, ale nie stanowi otwartej, bezwarunkowo darmowej bazy opinii.
  https://foursquare.com/pricing/
  https://docs.foursquare.com/data-products/docs/places-pro-and-premium

## Implementacja

`PlaceRatingProvider.swift` pobiera `/reviews?sub=geo:LAT,LON?q=NAZWA&u=100`.
Zapytania są kodowane przez URLComponents. Odczyt odbywa się przy otwarciu karty
miejsca, niezależnie od pobierania godzin otwarcia i zdjęć. Nie wysyłamy lokalizacji
użytkownika — do usługi trafiają nazwa i współrzędne wybranego miejsca.

API dopuszcza dopasowanie opinii bez nazwy oraz rozszerza promień o niepewność
współrzędnych autora. Dlatego dodatkowo wymagamy lokalnie:

- odległości do 100 metrów,
- zgodności identyfikatora OSM, gdy oba rekordy go posiadają (wersja obiektu jest
  pomijana), lub dokładnej zgodności nazwy po usunięciu interpunkcji, wielkości
  liter i akcentów,
- prawidłowej oceny 0–100; działania na opiniach nie są ocenami miejsca.

Pobieramy kolejne strony po 200 rekordów. Zwracane są najnowsze wersje opinii;
do średniej przyjmujemy najnowszą ocenę każdej tożsamości DID lub klucza autora.
Gdy nie można pobrać całego zestawu (błąd lub więcej niż 20 pełnych stron),
pokazujemy niedostępność, bez średniej z niekompletnego zestawu.

Standard Mangrove definiuje pięć gwiazdek jako wartości 0, 25, 50, 75, 100.
Konwersja: `gwiazdki = 1 + średnia / 25`.
https://mangrove.reviews/standard

Wyniki, także brak ocen, przechowujemy wyłącznie w pamięci przez 15 minut,
maksymalnie dla 128 zapytań. Błędy nie są zapisywane w pamięci podręcznej.
Karta rozróżnia pobieranie, brak ocen i błąd z możliwością ponowienia. Gwiazdki
mają częściowe wypełnienie i opis dla VoiceOver. Link do Mangrove wskazuje źródło
zbiorczej oceny, a link do licencji uwzględnia rekordy CC BY-SA 4.0.

To integracja wyświetlania istniejących ocen. Nie publikuje opinii w imieniu
użytkownika ani nie tworzy konta lub klucza podpisującego.

## Weryfikacja

Publiczne API zwróciło prawdziwą opinię dla `Argentino` pod współrzędnymi
46.0040648, 8.9514821 z oceną 25 (2/5 według standardu). Zapytanie dla Sukiennic
w Krakowie zwróciło pusty zestaw, co potwierdza potrzebę stanu „Brak ocen”.
Nie dodano testów jednostkowych ani testów nawigacji dla tej zmiany.
Kontrola składni zmienionych plików, `git diff --check` oraz kompilacja Debug
schematu `NaviAstraMac` bez podpisywania zakończyły się powodzeniem. Nie
uruchamiano aplikacji ani nie weryfikowano wyglądu na iOS.
