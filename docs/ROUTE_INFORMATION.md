# Szczegóły tras Valhalli

Podstawowa odpowiedź `/route` dostarcza flagi opłat, autostrad, promów i ograniczeń czasowych; zachowujemy stan nieznany, jeśli pola brak. Manewry zawierają długość, czas, wszystkie elementy drogowskazów, nazwy początkowe ulic, flagi nawierzchni i bram oraz gotowe instrukcje głosowe. Zapowiedź i skrócona instrukcja są wykorzystywane na odpowiednich etapach istniejącego harmonogramu głosu. Instrukcje głosowe są zachowane w modelu; użytkownik nie widzi osobnej sekcji „Drogowskazy i instrukcje”.

Rozwinięcie „Szczegóły trasy” pobiera `/trace_attributes` z oryginalną polilinią każdej części trasy i `shape_match=edge_walk`. Nie korzystamy z dopasowania do innej trasy. Wyznaczanie trasy i nawigacja nie czekają na wzbogacenie. Żądania korzystają ze wspólnego ograniczenia częstotliwości; zamknięcie widoku i zmiana wariantu anulują pobieranie. Osiem kompletnych odpowiedzi jest przechowywanych w pamięci. Błędy nie są buforowane; można ponowić pobieranie.

Widok prezentuje podział dystansu według nawierzchni, klasy i rodzaju drogi, limitów prędkości, liczby pasów, infrastruktury pieszej i rowerowej oraz trudności szlaków. Każdy odcinek zawiera dodatkowe dostępne atrybuty: mosty, tunele, granice, sygnalizację, obieg ruchu, pobocza, strefę czasową, sieć rowerową, HOV, dane ciężarówek oraz wysokość i maksymalne nachylenie. Brakujące dane są jawnie oznaczone. Prędkość modelu routingu nie zastępuje limitu prędkości.

Profil terenu pochodzi z próbek `elevation_interval=30`. Jeśli serwer odrzuca żądanie z wysokością, ponawiamy bez niej. Przerwy, wartości null i sentinel 32768 nie są łączone na wykresie ani zamieniane na zero. Suma podejść i zejść jest prezentowana wyłącznie przy kompletnym profilu. To szacunek terenu, a nie dokładny pomiar profilu mostów i tuneli. Nieudane części trasy nie przesuwają początku kolejnych części; ich offset pochodzi z oryginalnej geometrii. W P+R dane Valhalli są opisane jako dotyczące części samochodowej.

Publiczny serwer lub własna instancja mogą ograniczać długość śladu albo nie posiadać części danych. Błąd wzbogacania nie usuwa prawidłowej trasy. Informacja o opłacie nie zawiera jej kwoty; dokładne taryfy wymagają innego źródła.

Źródła:
- https://valhalla.github.io/valhalla/api/route/api-reference/
- https://valhalla.github.io/valhalla/api/map-matching/

Walidacja obejmuje kompilację aplikacji, dekodowanie rzeczywistej odpowiedzi `/route` i 40 odcinków oraz 40 próbek wysokości z `/trace_attributes`, pełne wieloelementowe drogowskazy, opcjonalne flagi, nieznane limity, sentinel wysokości, luki profilu i odrzucanie niezgodnych jednostek. Nie wykonywano przejazdu na urządzeniu.
