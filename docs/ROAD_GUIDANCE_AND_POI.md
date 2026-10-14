# Znaki, ostrzeżenia i POI w aplikacji iOS

Znaki drogowe, zdarzenia drogowe i miejsca mają osobne źródła danych. Wspólna polityka `MapDisplayPriorityEngine` ustala ich znaczenie podczas jazdy oraz progi zbliżenia mapy. Obiekt staje się ostrzeżeniem dopiero po przypisaniu do drogi i kierunku aktywnej trasy.

## Droga i kierunek ostrzeżenia

- Znaki OSM zachowują geometrię drogi, identyfikator drogi i oznaczony kierunek. Znaki `traffic_sign:forward` i `traffic_sign:backward` na tym samym węźle są rozdzielane.
- Fotoradary na węzłach OSM korzystają z kierunku i powiązania z drogą. Relacje pomiarów korzystają z punktów `from` i `to`; ostrzeżenie jest liczone względem miejsca pomiaru, nawet gdy urządzenie stoi obok jezdni.
- Drogi bez oznaczonego limitu prędkości także uczestniczą w dopasowaniu. Dzięki temu droga serwisowa nie przejmuje ostrzeżenia z pobliskiej drogi ekspresowej.
- Zgodność geometrii sprawdzana jest również przed i za punktem. Trasa przecinająca drogę nie przejmuje jej znaków. Bliższa, inna droga wyklucza dopasowanie do sąsiedniej jezdni.
- CANARD dostarcza lokalizacje oraz końce pomiarów, ale nie udokumentowany kierunek pomiaru. Sam punkt w pobliżu trasy nie wystarcza. Brak potwierdzonej drogi lub kierunku pozostawia punkt w trybie przeglądania bez ostrzeżenia podczas jazdy. Aplikacja nie zakłada pomiaru w obu kierunkach.
- Odcinkowy pomiar otrzymuje początek i koniec według kierunku przejazdu. Podróż rozpoczęta wewnątrz pomiaru zachowuje jego koniec, jeśli wspólna geometria i kierunek drogi potwierdzają odcinek.
- Starszy bufor danych trasy jest odświeżany: klucz pamięci podręcznej ma wersję `road-safety-v7`.

Panel, oznaczenia mapy i głos podczas prowadzenia wymagają świeżego GPS, pewnego dopasowania do bieżącej trasy i zgodnego kierunku ruchu. Jeśli dostępne są geometrie dróg, sprawdzana jest także droga pod rzeczywistą pozycją GPS. Niepewne dopasowanie, jazda inną drogą lub przeciwny kierunek wstrzymują te ostrzeżenia.

## Priorytety podczas jazdy

Najwyższy priorytet mają zamknięcia i wypadki, następnie STOP, pierwszeństwo, zakaz wjazdu, ograniczenia pojazdu i zmiany limitu, potem pomiary i pozostałe istotne zdarzenia. Odległość ostrzeżenia zależy od aktualnej prędkości. Panel i głos korzystają z tej samej listy nadchodzących alertów.

Limit ze znaku nie obowiązuje przed jego minięciem. Potwierdzony B-33 po minięciu przejmuje stały HUD na tej samej drodze. B-34, koniec zakazów i późniejsza strefa kończą używanie poprzedniego znaku; dalszy limit pochodzi z danych drogi. Kody ze wskazanym parametrem, np. `PL:B-33[70]`, są odczytywane. Wejście do strefy wyświetla komunikat przez około trzy sekundy. Ograniczenie prędkości i wskazanie jej przekroczenia pozostają w dotychczasowym HUD.

Oznaczenia podczas jazdy nie tworzą stosu ikon w jednym miejscu. Wygrywa priorytet zdarzenia, a pozycja pojazdu, następny manewr i cel mają zarezerwowane miejsce. Podczas przeglądania pozostają rozwijane grupy punktów drogowych.

## Miejsca i tryby mapy

| Tryb | Zasada |
| --- | --- |
| Przeglądanie | Kategorie użytkownika, widoczność według zoomu, grupowanie ważnych POI przy zoomie 10–12 |
| Podgląd trasy | Paliwo, ładowanie i parkingi w początkowym korytarzu trasy, do 20 km |
| Prowadzenie samochodu | Paliwo, ładowanie i parkingi w najbliższych 5 km korytarza trasy; ważne ostrzeżenia przed pojazdem |
| Dojazd do celu | Parkingi i ładowarki według istniejącego kontekstu dojazdu |

Przy zoomie poniżej 10 zwykłe POI są ukryte. Przy 10–12 pozostają ważne atrakcje i lotniska, od 12 paliwo i ładowarki, od 13 parkingi i noclegi, od 14 gastronomia, sklepy i zdrowie. Ranga dostawcy ogranicza liczbę obiektów przy oddaleniu. Grupę POI rozwija dotknięcie; przy dalszym zbliżeniu powracają pojedyncze symbole. Logotypy sklepów pojawiają się od zoomu 17. Kolizje zwykłych symboli uwzględniają priorytet kategorii.

Korytarz POI służy prezentacji. Dostępność wjazdu i koszt objazdu ustala router z rzeczywistymi punktami dostępu. Dotychczasowy panel miejsca zachowuje dostępne szczegóły, zapisywanie miejsca i dodawanie postoju. Brak godzin otwarcia, oceny lub innej informacji nie jest uzupełniany fikcyjną wartością.

Skróty jazdy obejmują paliwo, parking, EV i MOP. MOP wyszukuje obiekty OSM `highway=services` oraz `highway=rest_area`. Pozostałe kategorie nadal można wybrać w panelu wyszukiwania. Ranking po drodze korzysta z rzeczywistego dodatkowego czasu dojazdu dla maksymalnie 25 kandydatów. Wariant z macierzą tras zachowuje także obliczony czas i dystans dojazdu. Wyniki bez wyceny objazdu mają jawny stan niedostępnej wyceny.

## Szczegóły drogowe

W ustawieniach mapy sekcja „Szczegóły drogowe” udostępnia znaki, sygnalizację, kamery, ograniczenia wysokości i masy, zakazy dla ciężarówek, przejścia dla pieszych, progi i przejazdy kolejowe. Szczegóły są wyświetlane przy zoomie 17+, a pomiary od zoomu 12. Podczas prowadzenia punkty z przeglądania ustępują ostrzeżeniom dopasowanym do trasy. Przełączniki mapy i ustawienia głosu zachowują osobne działanie.

Nie ma danych o aktualnym kolorze świateł. Ograniczenia wysokości i masy są informacją o drodze; nie stanowią gwarancji trasy dopuszczalnej dla kampera lub ciężarówki. Proponowane w opisie przyszłe profile wymiarów pojazdu wymagają obsługi takich ograniczeń w routerze. Obecne zmiany nie deklarują tej nieistniejącej funkcji.

## Weryfikacja krytyczna

`RoutingCriticalTests` obejmuje pomiary i znaki na równoległych drogach, przeciwny kierunek, brak danych kierunku, rozpoczęcie podróży w odcinku pomiarowym, niepewny i nieaktualny GPS oraz zmianę limitu dopiero po minięciu znaku. Nie dodano testów pojedynczych zmian układu ani przełączników.
