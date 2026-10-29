# Personalizowany znacznik pozycji

Ustawienia → Twój znacznik pozwalają wybrać model albo klasyczną strzałkę.
Samochód ma siedem gotowych sylwetek z Kenney Car Kit 3.1: kompakt, sedan, SUV,
sedan sportowy, SUV luksusowy, van i auto wyścigowe. Paczka jest udostępniona
na licencji CC0. Modele są częścią aplikacji iOS i działają bez internetu. Rower i pieszy mają po jednej uproszczonej sylwetce.
Każdy z tych sposobów podróży ma osobny zapis koloru. Dostępne kolory to
niebieski, czarny, biały, czerwony, srebrny i fioletowy.

Klasyczna strzałka ma osobny wybór tych samych sześciu kolorów, widoczny po
wybraniu „Strzałka”. Jej kolor jest zapisywany niezależnie od kolorów modeli;
starszy zapis ustawień bez koloru strzałki zachowuje pozostałe wybory i przyjmuje
niebieską strzałkę. Podgląd oraz mapa używają wybranego koloru.

Wielkość znacznika można zwiększyć. Wybór modelu nie zmienia profilu wyznaczania trasy.
Dotychczasowy przełącznik `transportPositionIconsEnabled` zachowuje znaczenie:
wyłączony pozostawia strzałkę, włączony pokazuje modele. Preferencje wyglądu są
zapisywane lokalnie jako `navigationMarkerAppearance`.

Zapisany wcześniej wariant kombi jest prezentowany jako sedan, a rower sportowy
jako wspólny model roweru. Pozostałe preferencje, w tym kolor i wielkość, zostają
zachowane. Dawne identyfikatory kolorów nadal można odczytać.

Komunikacja korzysta z istniejącego rozpoznawania etapu podróży.
Autobus, tramwaj, pociąg lub prom pojawiają się na odpowiednim etapie oznaczonym
jako jazda pojazdem; dojście i oczekiwanie pokazują pieszego. Brak rozpoznanego
etapu nie implikuje wejścia do pojazdu. Motocykl i skuter nie są dodawane jako
profile trasy ani jako opcje wyglądu nieobsługiwanego sposobu podróży.

## Prezentacja i dane

- `NavigationPuckEngine` nadal wyznacza pozycję prezentacji. Wygląd nie wpływa
  na postęp, wykrywanie zjazdu z trasy, ETA ani dotarcie do celu.
- `NavigationMarkerAppearance` definiuje katalog, kolory, wielkość i zapis.
- `NavigationMarkerPresentation.resolve` wybiera model, orientację i jakość
  na podstawie rzeczywistego stanu nawigacji. Kamera jest uwzględniana osobno.
- `NavigationMarkerArtwork` wczytuje lokalne siatki samochodów Kenney i zawiera
  autorskie bryły pozostałych sposobów podróży oraz projekcję do obrazów 2.5D. Poza pochyleniem są obracane płynnie; w perspektywie ujęcia są
  próbkowane co 5 stopni. Cache obrazów ma budżet kosztu 12 MiB; geometria
  jest współdzielona między ujęciami. Pamięć podręczna pomalowanych siatek mieści
  do 12 wariantów; źródłowe siatki aut są wczytywane raz i współdzielone między
  kolorami. Modele nie wymagają sieci ani silnika 3D.
- `NavigationMarkerNativeView` rysuje model, ring, kierunek i jakość jako
  warstwy natywne. Mapa MapLibre korzysta z tego widoku;
  SwiftUI nie otrzymuje klatek pozycji do ponownego budowania interfejsu.

Kotwica podłoża i środek ringu leżą na współrzędnych użytkownika. Wysokość
modelu przesuwa jego sylwetkę w projekcji, bez przesuwania współrzędnych.
Ring ma cienki, częściowo przezroczysty obrys bez wypełnienia; w perspektywie
spłaszcza się wraz z pochyleniem kamery. Ma stałą wielkość ekranową i nie
reprezentuje promienia dokładności GPS.
Istniejący obszar dokładności na mapie pozostaje oddzielnym elementem.

Model wskazuje kierunek ruchu swoją sylwetką, uzupełnioną delikatnym gradientem
wychodzącym spod jego kotwicy do przodu. Nad modelem nie ma osobnej strzałki.
Klasyczna strzałka pozostaje samodzielną alternatywą. Sektor przy pieszym
prezentuje kierunek telefonu, jeżeli jest dostępny w stanie nawigacji; nie
deklaruje orientacji ciała ani obszaru widoczności. Przerywany obrys i wykrzyknik sygnalizują słabą,
przewidywaną lub nieaktualną pozycję. Po 5 sekundach bez świeżego pomiaru
poświata kierunku jest ukrywana; model zachowuje ostatnią orientację. Po ponad
30 sekundach jest dodatkowo przygaszany. Predykcja pozycji nadal podlega
istniejącemu limitowi silnika. Brak internetu nie jest stanem braku GPS.

Przy małym zoomie model jest zmniejszany z histerezą 13.2/13.8. Podgląd trasy
pokazuje neutralny znacznik faktycznej pozycji, niezależnie od początku planu.
Przy braku kierunku neutralny znacznik ma centralny punkt, bez sugerowania kursu.
Pełne modele dotyczą aktywnej nawigacji i reroutingu. Osobny tryb ciągłej
jazdy bez celu nie jest wprowadzany przez zmianę wyglądu.

Pętla mapy korzysta z istniejącej polityki klatek i jest wyłączana w tle.
Nie ma animacji dekoracyjnych ani implicit animations warstw. Większy kontrast
wzmacnia ring; kolor nie jest jedynym oznaczeniem jakości. Ustawienia używają
wspólnej powierzchni Glass i tego samego renderera co mapa. Przykładowa mapa
w ustawieniach jest jawnie oznaczonym lokalnym podglądem wyglądu.

## Spójność wyglądu i podglądy

Wszystkie sylwetki korzystają z tej samej projekcji, światła i kotwicy podłoża.
Podglądy poniżej używają pochylenia 45°; na mapie perspektywa dostosowuje się do
rzeczywistej kamery. Modele aut zachowują szyby, koła, lampy, spoilery i inne elementy
oryginalnej paczki. Wybrany lakier zmienia karoserię; szkło, opony i światła
zachowują własne kolory. Rowerzysta i pieszy mają neutralne głowy i uproszczone kończyny.

Motyw dzienny ma delikatny cień i ciemniejsze powierzchnie boczne. Motyw nocny
rozjaśnia refleksy, dodaje chłodne światło do materiału oraz subtelną poświatę
krawędzi. Czarny lakier otrzymuje mocniejszy chłodny refleks dla czytelności.
Obrys lokalizacji i poświata kierunku również zmieniają intensywność z motywem;
modele nie otrzymują mocnej białej obwódki.

![Samochody Kenney w rendererze aplikacji](images/navigation-cars-kenney-preview.png)

Arkusz pokazuje siedem aktualnych modeli: dzień i noc przy pochyleniu 45°,
widok z góry, przód przy 60° oraz czarny lakier nocą. Przy każdym powiększeniu
widoczny jest również obraz o wielkości 48 px. To podgląd renderera,
nie zapis przejazdu ani pomiar wydajności iOS.

![Sześć kolorów wszystkich samochodów](images/navigation-cars-kenney-colors-preview.png)

Analiza darmowych paczek, pochodzenie plików, procedura importu i ograniczenia:
[Modele samochodów — źródła i wdrożenie](NAVIGATION_CAR_ASSETS.md).
