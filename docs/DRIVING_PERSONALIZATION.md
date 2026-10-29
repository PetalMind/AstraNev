# Personalizacja tras bez ML

Wersja aplikacji: 1.1.137 (build 139), iOS. Profil powstaje ze statystyk przejazdów i deterministycznego rankingu. Nie używa modeli ML.

## Obsługa w aplikacji

W Ustawienia → Nawigacja → Personalizacja tras można włączyć uczenie, skróty, preferowane drogi i dojazd do celu. Uczenie lokalne jest domyślnie włączone. Aktualizacja do formatu profilu 3 włącza je jednorazowo także dla istniejącej instalacji; późniejsze ręczne wyłączenie pozostaje respektowane. Zezwolenie na dopasowanie na serwerze nie zmienia się. Ekran pokazuje liczbę dopasowanych i oczekujących przejazdów, wzorce tras, skróty, własne wybory/ominięcia odcinków oraz preferowany dojazd. Można usuwać poszczególne preferencje lub cały profil.

„Zapamiętaj tę trasę” jest dostępne po kwalifikującym się przejeździe i w szczegółach historii. Potwierdzenie wzmacnia preferencję bez czekania na kolejne powtórzenia. Automatyczne uczenie nie wymaga potwierdzania przejazdów ani korzystania z tej opcji. Co najmniej trzy podobne, wiarygodne wybory mogą zmienić propozycje; jeden lub dwa przejazdy nie tworzą preferencji.

Automatycznie analizowane są ukończone przejazdy autem, minimum 60 sekund i 500 metrów, bez punktów pośrednich, ładowarek ani przerw w GPS. Przejazdy z aktualnym zamknięciem lub opóźnieniem co najmniej 120 s dopasowanym do pierwotnej trasy oraz po automatycznej zmianie trasy z powodu ruchu lub zamknięcia pozostają obserwacjami; nie tworzą automatycznej preferencji bez ręcznego potwierdzenia. Zmiana ustawień uczenia w trakcie jazdy unieważnia automatyczne wykorzystanie tego przejazdu. Ręczne zapamiętanie historii jest świadomym wyborem użytkownika.

## Zapis i dopasowanie

Istniejący `TripTraceRecorder` zapisuje zaakceptowane lokalizacje co kilka sekund. Zapis jest ograniczony do 12 000 punktów; długie ślady są stopniowo upraszczane z zachowaniem granic przerw. Historia zachowuje surowe ślady dla maksymalnie 300 ostatnich podróży z ostatniego roku, a starsze podsumowania pozostają dostępne.

`DrivingRouteMatcher` używa `trace_attributes` Valhalli. Na iOS wykorzystuje lokalny silnik i zainstalowaną paczkę dróg. Bez dostępnej paczki lub przy niedostępnym dopasowaniu `DrivingTraceLearning` analizuje zaakceptowany GPS lokalnie. Nie wywołuje serwera, wymaga ciągłości, co najmniej 10 punktów, 60 sekund i 500 metrów; odrzuca luki ponad 30 sekund i nierealne skoki. Jawnie niepewne dopasowanie grafu nie jest zastępowane słabszą analizą. Opcjonalne dopasowanie na skonfigurowanym serwerze wymaga osobnego włączenia „Zezwalaj na dopasowanie na serwerze”. Wtedy wysyłane są współrzędne konkretnego analizowanego śladu, a nie archiwum przejazdów.

Wynik dopasowania grafu zawiera kierunkowe odcinki drogi, geometrię, długości i dostępne nazwy. Lokalna analiza bez grafu przechowuje oznaczone `trace:` odcinki geometrii obserwacji, bez przypisywania im identyfikatorów OSM ani nazw dróg. Powtórzenia porównuje kierunkowo z tolerancją 25 m. Preferowany identyfikator to OSM way + węzeł początkowy + węzeł końcowy. Jeżeli serwer nie zwraca tych danych, identyfikator grafu jest dodatkowo związany z usługą, zbiorem danych i końcami geometrii. Identyfikator grafu nie jest przedstawiany jako globalny identyfikator OSM. Niedopasowane punkty, nieciągłości i niepewne wyniki nie tworzą preferencji.

`DrivingProfileStore` przechowuje dane w lokalnym `DrivingLearning/NavigationLearning.sqlite`. Historia odcinków i ustawienia są zapisywane w jednej transakcji SQLite. Archiwum uczenia obejmuje do 300 przejazdów z ostatniego roku. Kolejka zawiera maksymalnie 10 śladów po maksymalnie 2000 punktów. Wyłączenie uczenia usuwa kolejkę i anuluje dopasowanie. Usunięcie przejazdu usuwa również jego wkład w profil. Reset stosuje `secure_delete` SQLite. Na iOS plik ma ochronę do pierwszego odblokowania urządzenia.

Profil nie jest synchronizowany z iCloud: ten opcjonalny element wymaga konfiguracji kontenera i uprawnień iCloud, których obecny projekt nie ma.

## Preferencje i ranking

Własny wariant wymaga wspólnego wjazdu i późniejszego powrotu na pierwotną trasę. Wariant musi mieć minimum 500 metrów (dla analizy lokalnej: co najmniej 500 m ciągłego odsunięcia o minimum 60 m od propozycji i powrót w granicę 35 m), punkty połączenia muszą być oddalone o minimum 200 metrów, a dłuższy postój wyklucza automatyczne zapamiętanie wariantu. Jedno i dwa użycia nie nadają mu dodatniej pewności. Powtórzenia podnoszą pewność. Ręczne potwierdzenie jest osobnym faktem (`userConfirmed`), ustawia początkowy poziom dowodów co najmniej 0,72 i minimalną wagę rankingu 0,15, ale nie oznacza 100% pewności.

Wzorce tras grupują podobne kierunkowe odcinki dla pobliskiego początku i celu. Dojazdy są grupowane niezależnie od początku podróży, co pozwala rozpoznać wspólny końcowy odcinek z różnych miejsc. Kontekst zawiera dzień tygodnia, dwugodzinny przedział i dostępny, świeży pomiar poziomu ruchu. Brak pomiaru ruchu pozostaje brakiem danych.

Ranking łączy istniejący wynik czasu/dystansu/komfortu/ruchu z podobieństwem przejazdu, preferencjami odcinków, dojazdem i skrótami. Waga automatycznej personalizacji wynosi 0 przed trzema przejazdami, 0,20 od trzech i 0,25 od dziesięciu. Dodatni wpływ nadal wymaga powtarzanego wzorca i wiarygodnego wyboru; same częste przejazdy proponowaną drogą są słabym sygnałem. Wskazówki dla Valhalli obejmują wnętrze powtarzanego odstępstwa, aby krótki własny wariant na długiej trasie nie zniknął pomiędzy równomiernie próbkowanymi punktami. Ręcznie potwierdzony wariant może uzyskać wagę co najmniej 0,15. Preferencja „Najkrótsza” zachowuje ścisły wybór według dystansu. Znacznie wolniejszy wariant — ponad najszybszy czas + max(180 sekund, 20%) — nie otrzymuje premii. Świeże, aktywne zamknięcia ze znaną geometrią wykluczają wariant z porównania.

Personalizacja nie zmienia ETA, dystansu ani manewrów. Wykorzystywana jest w planowaniu, przeliczeniu, rankingu wykonalnych wariantów EV i porównaniu ruchu. Automatyczna zmiana na szybszą trasę nadal wymaga rzeczywistej przewagi ETA i odpowiedniego pokrycia pomiarami.

Zapamiętane geometrie nie są odtwarzane jako gotowe trasy nawigacyjne. Silnik może wygenerować do dwóch dodatkowych wariantów przez punkty z historii, ale Valhalla ponownie wyznacza drogę według aktualnego profilu i ograniczeń. Punkty te mają typ `via`, więc nie stają się postojami użytkownika. Brak poprawnego wariantu historycznego nie blokuje zwykłego planowania. Automatyczne planowanie ładowania EV nie dodaje historycznych punktów; personalizacja jedynie porządkuje wykonalne plany.

Średnie czasy opisują zarejestrowane przejazdy. Oszczędność względem nieprzejechanej alternatywy pozostaje niedostępna, ponieważ porównanie z ETA dostawcy nie byłoby pomiarem. Diagnostyka zapisuje końcową kolejność osobno od wyniku bazowego. Odtworzenie diagnostyki zachowuje zapisaną kolejność, nie rekonstruuje dawnego profilu uczenia.

## Dowody i wygaszanie

`PreferenceEvidence` zapisuje źródło (`LearningReason`), przejazd, czas obserwacji lub działania, kontekst, znane propozycje, wybrany wariant, odcinki wybrane i pominięte oraz rzeczywiste wartości pewności przed i po zmianie, jeżeli można je wyliczyć. Dane są zapisywane atomowo w tabeli `preference_evidence` razem z przejazdami i ustawieniami. Profil jest odbudowywany z zachowanych obserwacji i działań; usunięcie przejazdu usuwa jego wkład oraz powiązane dowody. Usunięcia preferencji mają osobne zdarzenia diagnostyczne, a pełny reset usuwa cały dziennik.

Sesja nawigacji przechwytuje do pięciu rzeczywiście pokazanych wariantów przed startem, rekomendację oraz ręcznie wybrany wariant. Po ukończeniu przejazdu propozycje są dopasowywane do dróg; brak poprawnego dopasowania pozostaje brakiem wiedzy. Liczniki `offeredCount`, `chosenCount` i `avoidedCount` odnoszą się do odrębnych przejazdów, więc obecność odcinka w kilku wariantach nie mnoży okazji. Ominięcie wynika z wiarygodnego odstępstwa lub świadomego wyboru innego wariantu; niewybrana opcja nie oznacza automatycznie niechęci.

Zwykła częstotliwość przejazdów jest słabym sygnałem: siła zaczyna się od 0,15. Świadomy wybór mimo alternatywy oraz powtarzane odstępstwa dają silniejszy sygnał. Potwierdzenie jest przechowywane osobno od pewności. Ranking używa `confidence × strength × relevance × recency`; `relevance` obejmuje podobieństwo kierunkowych odcinków i kontekst bieżącej podróży.

Aktualność dowodu wynosi 1 przez pierwsze 30 dni, a następnie maleje ciągle według `exp(-ln(2) × (wiek_dni - 30) / 120)`. Po 365 dniach wynosi 0. Wygaszanie obejmuje poszczególne obserwacje, więc pojedynczy nowy przejazd nie odświeża całej starej historii. Nowe, świadome ręczne potwierdzenie jest nowym dowodem użytkownika. Dane nadal podlegają dotychczasowej retencji; wygaszanie nie wymaga natychmiastowego usuwania rekordów.

`AlternativePathPreference` rozróżnia skrót dystansowy, czasowy, wariant komfortowy oraz nieokreślony własny wariant. Skrót dystansowy wymaga przynajmniej 50 metrów i 5% poprawy względem dopasowanego odcinka pierwotnej propozycji (stosowany jest większy próg). Skrót czasowy wymaga porównywalnego zarejestrowanego czasu alternatywy; ETA nie jest takim pomiarem. Bez danych potwierdzających oszczędność czasu lub komfort dłuższa droga jest „Własnym wariantem”. Różne przebiegi między tymi samymi punktami wjazdu i wyjazdu mają oddzielne identyfikatory oparte na sekwencji odcinków.

Preferowany dojazd przechowuje kierunek przyjazdu i punkt wejścia. Kierunek przeciwny lub różniący się o co najmniej 90° nie otrzymuje premii. Dodatkowa wskazówka dojazdu jest odrzucana, jeżeli wymaga nadmiernego cofania lub objazdu; działa też ogólny limit pogorszenia ETA. Podczas przeliczania kierunek jest oceniany z bieżącego punktu na trasie.

Migracja formatu 1.1.76 zachowuje przejazdy, potwierdzenia i usunięcia. Dawne konteksty czterogodzinne są przeliczane z dat przejazdów na dwugodzinne. Dawne liczniki propozycji, których nie zapisano, nie są odtwarzane z częstotliwości przejazdu. Import ma osobny powód diagnostyczny i nie udaje nowego przejazdu.

W istniejącej diagnostyce routingu dodano aktualny rozmiar SQLite (z plikami pomocniczymi, jeżeli istnieją), liczby przejazdów, śladów, odcinków, dopasowanych propozycji, wzorców i dowodów. Zapis decyzji zawiera rzeczywistą wagę personalizacji i składowe pewności, siły, dopasowania oraz aktualności. Dziennik pokazuje ostatnie powody zmian. Nie wysyła tych danych poza urządzenie.

## Weryfikacja

Regresje krytyczne obejmują zachowanie ETA i ograniczeń routingu, wygaszanie, odróżnienie częstotliwości od świadomego wyboru, rzeczywiste propozycje i wybory, cofnięcie wpływu usuniętego przejazdu, kierunek dojazdu, klasyfikację i rozdzielanie własnych wariantów oraz migrację starego profilu. Krytyczna weryfikacja obejmuje także pełny przepływ kolejka → analiza lokalna bez zgody na sieć → SQLite → ponowny odczyt → trzy powtórzenia → wskazówki i zmianę rankingu. Samodzielny program kontrolny uruchamia produkcyjny silnik, geometrię, ranking i SQLite z zastępczymi modelami otoczenia; nie uruchamia zamrożonej aplikacji macOS. Pakiet testów iOS jest kompilowany przez Xcode; pełne uruchomienie na symulatorze wymaga zainstalowanego runtime. Dotychczasowa kompilacja aplikacji iOS sprawdzała integrację. Nie wykonano rzeczywistego przejazdu ani dopasowania śladu do produkcyjnej paczki lub serwera.
