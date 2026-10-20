# Changelog

## [1.1.133] - 2026-10-20

### Fixed

- Obliczaj godziny otwarcia pobliskich miejsc z lokalną strefą czasową i kodem kraju, także dla punktów położonych dalej od bieżącej lokalizacji.
- Preferuj bogatsze godziny i tagi OpenStreetMap, zachowując Apple Maps jako ograniczony czasowo fallback.
- Zachowuj pełne godziny otwarcia punktów InPost zamiast pomijać harmonogramy inne niż całodobowe.
- Dopasowuj dokładne adresy GUGiK po numerze i ulicy bez wymogu wpisania miejscowości.
- Ogranicz czas oczekiwania wyszukiwania na dostawców oraz uwzględniaj kolejkę i ponowienia w limicie zapytań Overpass.

## [1.1.132] - 2026-10-20

### Fixed

- Zachowuj najwyższy poziom spowolnienia przy łączeniu sąsiednich odcinków ruchu.
- Pokazuj polskie nazwy dni w preferencjach tras oraz polski zapis ETA i dystansu w widżecie aktywnej nawigacji i wskazówkach AR.
- Stosuj polski zapis liczb, odległości i współrzędnych na ekranach trasy, parkowania i map offline; odrzucaj nieprawidłowe wartości ETA i dystansu.
- Nie pokazuj błędu po anulowaniu wyboru paczki offline, tłumacz błędy paczek na czytelne komunikaty i zapisuj szczegóły techniczne w logu.
- Nie pozwalaj nadpisywać nieodczytanych danych ulubionych, historii, parkowania, paliwa ani preferencji jazdy.
- Zwiększ cel dotykowy przy czyszczeniu wyszukiwanego miejsca w planowaniu podróży.
