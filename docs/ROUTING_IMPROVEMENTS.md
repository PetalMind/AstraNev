# Ulepszenia wyznaczania tras w iOS

Zmiany dotyczą aktywnej aplikacji iOS i jej współdzielonej logiki. Wersja macOS pozostaje zamrożona.

## Stan weryfikacji

Kod aplikacji przeszedł kompilację podczas przygotowania testów. Poprawiono wykryte błędy kompilacji nowych i istniejących testów krytycznych. Nie potwierdzono jednak ich wykonania: kolejne przebiegi zatrzymywał konflikt bazy Xcode, a następnie oczekiwanie na Swift Package Managera, również po skopiowaniu zależności do osobnego katalogu. Własny zawieszony przebieg zatrzymano. Testy wymagają ponownego uruchomienia po ustabilizowaniu środowiska; opisane poniżej zachowanie nie jest deklaracją zaliczenia testów ani walidacji drogowej.

## Wybór trasy

„Najszybsza” wybiera najmniejsze dostępne ETA, a „Najkrótsza” najmniejszy dystans. Historia kierowcy zmienia rekomendację wyłącznie w nowym profilu „Polecana dla mnie”, którego bazą jest profil zrównoważony. Uczenie i przeglądanie historii pozostają niezależne od wybranego profilu.

Ranking komfortu stosuje stałe koszty: bazowy czas, 10 sekund za kilometr i umowny koszt manewrów oraz znanej nawierzchni. Profil wygodny podwaja koszt komfortu. Nie zmienia to prezentowanego ETA. Brak porównywalnych danych wyłącza dane kryterium dla całego zestawu. Pokrycie pomiarami ruchu ma niewielki, ograniczony koszt niepewności, bez udawania prawdopodobieństwa przyjazdu na czas.

Rekomendacja zrównoważona i osobista może wydłużyć czas względem najszybszej o najwyżej 15% i 5 minut oraz dystans o najwyżej 20% i 5 km. Wygodna ma limity 25% i 10 minut oraz 30% i 10 km. W każdym przypadku obowiązuje mniejszy limit. Pozostałe warianty pozostają dostępne do ręcznego wyboru.

Profile komfortu mogą generować dodatkowe drogi przez osobne opcje kosztowania Valhalli. Wszystkie żądania zachowują profil pojazdu, ograniczenia, przystanki i czas planowania. Opcjonalne wyszukiwanie online ma wspólny budżet 6 sekund i limit dwóch żądań; błąd dodatkowego wariantu nie odrzuca poprawnej trasy podstawowej. Opisy wariantów pokazują rzeczywiste różnice czasu i manewrów.

Offline można wyznaczyć najwyżej jeden dodatkowy wariant znanej drogi dla profilu osobistego. Natywny silnik offline nie zapewnia natychmiastowego przerwania obliczeń, więc budżet czasowy nie stanowi dla niego twardego limitu.

## Ruch, blokady i przeliczanie

Porównanie TomTom działa także w podglądzie wyjazdu „Teraz”. Nie nadpisuje ręcznego wyboru. Warunkiem zmiany jest świeże, porównywalne pokrycie wszystkich analizowanych korytarzy: co najmniej 50%, przy różnicy pokrycia do 10 punktów procentowych. Błąd zapytania zachowuje aktualną trasę. Podgląd przyszłego wyjazdu nie używa bieżącego ruchu jako prognozy na przyszłość.

Karty i opisy wariantów pokazują to samo ETA z ruchu, które służy do porównania. Cały zestaw pomiarów podglądu wygasa wspólnie po 120 sekundach od najstarszego pomiaru i nie zmienia bazowego czasu trasy ani modelu aktywnej nawigacji. Ręcznie wybrana trasa również dostaje świeże ETA, ale wybór pozostaje bez zmian. Potwierdzone zamknięcie ręcznie wybranej trasy wywołuje osobny komunikat.

Istotne pogorszenie czasu podczas jazdy (co najmniej 2 minuty i 15% bazowego ETA) pozwala ponownie szukać kandydatów z bieżącej pozycji, najwyżej co pięć minut. Zmiana aktywnej trasy nadal wymaga odpowiedniej oszczędności, możliwości kontynuacji zgodnie z kierunkiem oraz aktualności zapytania. Zmiana planu i ręczny wybór anulują stare porównania.

Wyszukiwanie online może dodatkowo poprosić o jeden wariant omijający konkretny świeżo zmierzony korek, z zachowaniem dostępu do początku, końca i wymaganych przystanków. Korek nie staje się zgłoszeniem zamknięcia drogi. Dodatkowy wariant podlega temu samemu porównaniu co pozostałe trasy; jest pomijany w trybie offline.

Zamknięcia z pomiarów Flow i listy Incidents tworzą wspólny model. Ta sama geometria decyduje o nieprzejezdności, jakości danych i objazdach. Objazd uwzględnia wszystkie nadal świeże, znane blokady; wynik przechodzi sprawdzenie przecięć. Blokada zaczynająca się za pojazdem jest istotna, jeśli nadal obejmuje drogę przed nim. Dane wygasają zgodnie z czasem obserwacji.

Detektor zjazdu uwzględnia także trwałą jazdę w przeciwnym kierunku blisko linii trasy, z wymaganiem wiarygodnego GPS i kolejnych spójnych próbek. Korekta ETA porównuje rzeczywisty i planowany czas tych samych przejechanych odcinków. Po zmianie trasy odrzuca dawne dopasowanie tempa.

## Energia EV

Podczas aktywnej podróży szacowany zasięg maleje o zmierzony przebyty dystans i jest zachowywany przy przeliczeniu trasy. Zmiana preferencji dróg nie przywraca początkowej baterii. Zmiana wpisanego poziomu baterii lub jego ponowne potwierdzenie ustanawia nowy punkt odniesienia. Sam przejazd przez zaplanowaną ładowarkę nie oznacza doładowania.

Wyłączenie i ponowne włączenie planowania EV podczas tej samej podróży zachowuje zużycie, w tym dystans przejechany przy wyłączonym planowaniu.

Ustawienia EV pokazują szacowany poziom i zasięg oraz pozwalają potwierdzić wskazanie samochodu po ładowaniu. To model odległościowy, bez telemetrii baterii, pogody i rzeczywistej krzywej zużycia. Luki pomiaru GPS pozostają ograniczeniem oszacowania.

Moc ładowania jest przypisana do złącza. Wybrane Type 2 nie otrzymuje mocy CCS z tej samej stacji. Gdy przy kilku złączach znana jest wyłącznie moc ogólna, aplikacja nie przypisuje jej arbitralnie do wybranego złącza. Aliasy CCS i `type2_combo` są równoważne. Pozostają walidacja rzeczywistego dojazdu do ładowarek, margines zasięgu oraz szacowany spadek mocy przy wysokim poziomie baterii.

## Komunikacja i zapisane plany

Podgląd, odświeżanie i późniejsze połączenia zachowują ręczny początek podróży. Ranking zna czas zapytania: uwzględnia oczekiwanie przed rozpoczęciem podróży, a dla przyjazdu na godzinę także dogodny termin wyjazdu. Kontynuacja jazdy tym samym pojazdem nie jest traktowana jako ryzykowna przesiadka.

Preferencje wariantu komunikacji, dodatkowy bufor przesiadki i profil pieszy/wózka trafiają do dostawcy i są zapisywane wraz z planem. Starsze plany dostają dotychczasowe wartości domyślne.

Planowanie bliskiego wyjazdu porównuje ruch na wariantach. Potwierdzona blokada może wywołać jedno ponowne wyznaczenie z poligonami omijania. Zapisany przebieg jest zachowywany, chyba jest zamknięty albo zmiana oszczędza co najmniej 2 minuty i 10% czasu. Użytkownik otrzymuje informację o zmianie.

## Pomiary z rzeczywistych przejazdów

Historia przejazdu samochodowego zachowuje przewidywane ETA co minutę i po zmianie trasy, maksymalnie 1440 obserwacji (starsze próbki są przerzedzane). Same obserwacje jakości nie zawierają współrzędnych ani nazw celu. Dotychczasowy zapis śladu GPS pozostaje osobną częścią historii.

W diagnostyce można odtworzyć pomiary z ukończonych przejazdów z pokryciem zapisu co najmniej 80% i wyeksportować JSON. Raport porównuje historyczne przewidywania z rzeczywistym czasem przyjazdu oraz pokazuje liczbę przeliczeń. Przerwane przejazdy nie są traktowane jako dotarcie do celu. Zmiana celu lub postojów w trakcie jazdy unieważnia pomiar jakości tego przejazdu, aby nie przypisywać zmiany planu błędowi ETA. Różnica czasu nadal obejmuje nieplanowane postoje, a liczba przeliczeń nie dowodzi, że były zbędne. Dane do kalibracji zbierają się dopiero podczas rzeczywistych podróży; nie zastępujemy ich wynikami syntetycznymi.
