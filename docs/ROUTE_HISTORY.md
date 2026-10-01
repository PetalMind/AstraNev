# Historia tras

Historia jest dostępna z przycisku **Historia** w panelu ostatnich miejsc. Widoki **Trasy**, **Heatmapa** i **Wyszukiwania** rozdzielają przebyte podróże od wyborów celów. Filtry transportu i okresu (całość, ostatnie 7, 30 lub 365 dni) dotyczą listy, statystyk i heatmapy. Starsze wpisy bez rodzaju transportu są widoczne przy filtrze wszystkich sposobów podróży.

## Zapis

`NavigationSession` rozpoczyna zapis po uruchomieniu nawigacji i kończy go przy dotarciu do celu lub przerwaniu. `LocalDataStore` zapisuje zakończony rekord atomowo w `Application Support/NaviAstra/trips.json`. Zapis nie działa poza aktywną nawigacją. Bieżąca, niezakończona sesja pozostaje w pamięci — zamknięcie procesu przed zakończeniem nie zapisuje częściowej podróży.

Nowe rekordy zawierają rodzaj transportu, próbkowany przebieg GPS (współrzędne, czas, opcjonalna prędkość i początek odcinka) oraz maksymalną wiarygodną prędkość. Istniejące statystyki dystansu, czasu w ruchu, przeliczeń, dotarcia i oceny prowadzenia są zachowane. Nowe pola mają wartości domyślne przy odczycie starszych rekordów; przebiegów brakujących w historii nie rekonstruujemy z planowanego routingu.

Ślad korzysta z zaakceptowanych przez filtr lokalizacji pomiarów o dokładności do 50 metrów. Kolejny punkt jest zachowywany po przynajmniej 3 sekundach i przesunięciu o 8 metrów albo po 10 sekundach. Pogorszenie dokładności, luka powyżej 30 sekund lub nieciągłość pozycji rozdzielają odcinki. Prędkość jest dostępna tylko dla nieujemnego pomiaru z dokładnością prędkości do 5 m/s. Pomiar początkowy może poprzedzać rozpoczęcie nawigacji o najwyżej 15 sekund.

Dane podróży są lokalne. Mapy tła w historii korzystają z MapKit i mogą wymagać internetu. Usunięcie podróży usuwa także jej ślad i wkład do statystyk oraz heatmapy. Ekran historii pokazuje błędy zapisu i odczytu repozytorium.

## Statystyki i odtwarzanie

Podsumowanie obejmuje liczbę podróży, łączny dystans, czas podróży, czas w ruchu, średnią ważoną czasem w ruchu i liczbę dotarć. Szczegóły zawierają mapę zapisanego przebiegu, maksymalną prędkość, czas poza ruchem, przeliczenia, różnicę względem planowanego czasu dla zakończonych przejazdów oraz istniejącą ocenę prowadzenia. Wiarygodne pomiary prędkości tworzą wykres. Brakująca prędkość jest oznaczana jako niedostępna.

Odtwarzanie ma pauzę, suwak czasu i tempa 1×, 5×, 20× i 100×. Marker interpoluje współrzędne między sąsiednimi pomiarami w jednym odcinku; nie łączy luk. Przy braku pomiarów w danym czasie marker znika i pojawia się informacja o luce. Odtwarzanie kończy się przy opuszczeniu ekranu albo przejściu aplikacji w tło.

**Wyznacz trasę ponownie** to osobna akcja istniejącego planowania z zapisanym celem i punktami pośrednimi. Nie gwarantuje identycznego przebiegu jak zapis GPS.

## Heatmapa

Mapa agreguje ślady GPS w siatce Web Mercator o początkowym rozmiarze 250 metrów projekcji; rzeczywisty rozmiar zależy od szerokości geograficznej. Promienie obszarów są korygowane dla szerokości geograficznej. Siatka jest powiększana, gdy liczba obszarów przekroczy 1000, aby ograniczyć koszt renderowania dużych archiwów.

Intensywność oznacza liczbę różnych podróży z pomiarem w danym obszarze. Każda podróż liczy się raz na obszar, niezależnie od liczby pomiarów i długości postoju. Żółty oznacza pojedynczą podróż, czerwony największą liczbę w aktualnym filtrze. To przybliżona mapa własnej aktywności, a nie dane o ruchu drogowym lub podróżach innych użytkowników. Starsze rekordy bez śladu GPS nie są uwzględniane; widok podaje liczbę podróży z dostępnym śladem.
