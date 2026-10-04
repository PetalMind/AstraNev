# Analiza UX/UI szczegółów POI i wdrożone poprawki

Data: 3 października 2026. Wersja po zmianach: 1.1.8, build 10.

## Zakres i podstawa oceny

Analiza obejmuje panel wyboru i szczegółów miejsca na mapie, trzy poziomy jego wysokości, kolejność informacji, akcje, ładowanie danych i wspólne komponenty kart POI. Podstawą są aktualny kod SwiftUI, obsługa wyboru miejsca, model danych oraz dostawcy szczegółów i zdjęć. Nie jest to ocena wykonana ze zrzutów uruchomionej aplikacji. Widoczność konkretnej liczby wierszy zależy od urządzenia, długości nazwy i adresu, rozmiaru tekstu oraz dostępnych danych.

Najważniejsze pliki: `ContentView+RootView.swift`, `ContentView+MapPanels.swift`, `NavigationChrome.swift`, `ContentView+PlaceActions.swift`, `PlaceDetailsView.swift`, `PlaceDetailsHeader.swift`, `PlaceDetailsAttributesSection.swift`.

## Jak panel uruchamiał się przed zmianą

Na iOS dotknięcie POI na mapie prowadzi do `presentMapPlaces`. Jeden wynik otwiera szczegóły; wiele wyników otwiera listę wyboru. Obie ścieżki ustawiają `.medium`. Wybranie konkretnego miejsca z listy ponownie ustawia `.medium`.

To panel przyczepiony do mapy, zbudowany przez `NavigationBottomSheet`, a nie systemowa modalna karta iOS. Wysokość rozwinięta wynika z mniejszej wartości: 88% wysokości obszaru mapy albo przestrzeni pozostałej pod nagłówkiem z dodatkowym odstępem. Wysokość średnia była wyliczana z 58% tej wysokości, z dolnym ograniczeniem wynikającym z wysokości zwiniętej. Nie oznaczało to 58% całego ekranu.

| Tryb | Treść przed zmianą | Dostępność akcji |
| --- | --- | --- |
| Zwinięty (`peek`) | Jednowierszowa nazwa i skrót dojazdu; przy wielu wynikach liczba miejsc | Dotknięcie treści otwiera średni panel. Główna akcja trasy znika. |
| Średni (`medium`) | Nazwa, kategoria, dojazd; dostępne zdjęcie 144 pt; adres, godziny i skrót parkingu; akcje dodatkowe; ceny paliw dla stacji; kontakt; status pobierania | Wyznaczanie trasy jest przypięte na dole. „Stąd” i serce są w przewijanej treści. |
| Rozwinięty (`expanded`) | Nazwa, kategoria, dojazd; dostępne zdjęcie 220 pt; akcje, paliwo, kontakt; następnie grupa szczegółów z adresem, kategorią, godzinami, kontaktem, udogodnieniami i parkingiem; stan danych i źródło | Główna akcja pozostaje przypięta na dole. |

Pierwsze informacje są częściowo dostępne z wyniku wyszukiwania lub kafla mapy. Szczegóły, czas dojazdu i zdjęcia są uzupełniane asynchronicznie. Przy aktywnej nawigacji karta opisuje szacowany objazd, a główna akcja brzmi „Dodaj przystanek”. Zdjęcia są wtedy pomijane. Gdy pozycja lub tryb transportu nie pozwala na oszacowanie dojazdu, panel pokazuje jego niedostępność.

Na macOS ta sama ścieżka używa systemowego arkusza z `NavigationStack` i pełnej karty w `ScrollView`. Kod deklaruje detenty `.medium` i `.large`, ale nie wiąże ich wyboru z `selectedMapPlaceDetent`. Nie należy utożsamiać jego zachowania z trzema własnymi poziomami panelu iOS.

Wyszukiwarka oraz lista miejsc w pobliżu mają jeszcze inną ścieżkę: `PlaceSearchResultRow` rozwija pełną kartę wewnątrz listy. Nie otwiera przy tym opisywanego panelu mapy. Poprawki wspólnych komponentów obejmują również te karty, ale ich mechanizm otwierania pozostaje taki sam.

## Najważniejsze problemy i ich wpływ

### 1. Zdjęcie miało wyższy priorytet niż adres i godziny

Fotografia pojawiała się nad informacjami potrzebnymi do decyzji o dojeździe. W średnim panelu 144 pt obrazu, podpis i odstępy konkurowały o miejsce z uchwytem o wysokości 60 pt oraz przypiętym przyciskiem trasy. Zdjęcie pojawiało się dopiero po załadowaniu, więc dodatkowo przesuwało adres i godziny. Ikona kategorii także znikała po pobraniu zdjęcia.

Wdrożenie: zdjęcia, Look Around i logo są dostępne w rozwiniętym widoku, po informacjach o miejscu. Ikona POI pozostaje w nagłówku. Zdjęcie nie zmienia już układu pierwszego widoku. Panel nadal pokazuje tylko dostępny materiał; brak zdjęcia nie tworzy dużej pustej karty.

### 2. Rozwinięcie zmieniało położenie podstawowych informacji

Średni widok miał adres i godziny w skrócie, a pełny przenosił je za zdjęcie i akcje do sekcji „Miejsce” i „Godziny”. Kategoria była powtarzana w pełnej sekcji. Kontakt pojawiał się jako szybkie przyciski i ponownie jako linki.

Wdrożenie: nazwa, kategoria, dojazd, adres i godziny mają wspólną pozycję w obu prezentacjach. Pełny widok dokłada informacje poniżej. Usunięto powtórzoną kategorię, osobną kopię adresu i drugą grupę tych samych linków kontaktowych. Numer telefonu pozostaje widoczny i możliwy do skopiowania w pełnej karcie.

### 3. Rozwijanie panelu było słabo sygnalizowane

Uchwyt umożliwia przeciąganie i zmianę poziomu po dotknięciu, ale jego funkcja nie jest opisana wizualnie. Przycisk zamknięcia zajmuje miejsce, w którym inny wariant wspólnego panelu pokazuje strzałkę. Przeciągnięcie treści w górę w trybie średnim przewija ją; mechanizm przejęcia gestu dla rozwinięcia działa z treści tylko w trybie zwiniętym.

Wdrożenie: średnia karta ma przycisk „Wszystkie szczegóły”, który ustawia `.expanded`. Zwinięty nagłówek dostał strzałkę w górę. Mechanizm gestów pozostał wspólny z innymi panelami.

### 4. Akcje miały nieczytelną hierarchię

Przypięta główna akcja była dobrym rozwiązaniem. Serce znajdowało się jednak daleko od nazwy, w przewijanym pasku z innymi akcjami. „Stąd” miało bardzo krótki opis, wymagający interpretacji. W trakcie nawigacji pasek sprowadzał się do samego serca.

Wdrożenie: Ulubione są przy nazwie; zachowano potwierdzenie usuwania, animację i informację zwrotną. Akcja początku trasy ma nazwę „Trasa stąd”. W nawigacji nie powstaje osobny pasek z jednym sercem. „Wyznacz trasę” / „Dodaj przystanek” pozostają przypięte na dole średniego i pełnego panelu. Zwinięty panel nadal służy przede wszystkim do oglądania mapy i powrotu do szczegółów.

### 5. Zwijanie usuwało instancję szczegółów

Przejście do `peek` zastępowało `PlaceDetailsView` inną gałęzią widoku. Jego lokalny stan był usuwany, a ponowne rozwinięcie mogło ponownie uruchamiać ładowanie i zerować rozwinięcie godzin. Cache dostawcy ograniczał żądania, ale nie zachowywał całego stanu interfejsu.

Wdrożenie: szczegóły pozostają zamontowane przy zwinięciu. Ich obszar ma wtedy wysokość zero, jest przycięty, nie odbiera dotknięć i jest ukryty dla dostępności. Zamknięcie panelu nadal usuwa kartę. Wybór innego miejsca nadal tworzy stan odpowiadający jego tożsamości.

### 6. Procentowa wysokość nie uwzględniała stałego kosztu uchwytu i stopki

Przy maksymalnej wysokości 600 pt stary średni panel miał 348 pt. Z tej przestrzeni trzeba jeszcze odjąć uchwyt, stopkę i odstępy. To wyliczenie z kodu, nie pomiar z urządzenia.

Wdrożenie: zachowano 58%, dodając preferowane minimum 400 pt dla panelu POI. Minimum jest ograniczone do 80% wysokości rozwiniętej, aby na krótkim ekranie i w poziomie średni tryb nadal różnił się od pełnego. Dla maksymalnej wysokości 600 pt nowy średni panel ma 400 pt. Inne panele nie ustawiają tego minimum i zachowują dotychczasowe wyliczenie.

### 7. Powielone opisy godzin zabierały miejsce

Status otwarcia i osobny wiersz „Godziny otwarcia” były wyświetlane jeden pod drugim. Jednocześnie brak godzin był sygnalizowany głównie w pełnej karcie.

Wdrożenie: status stał się etykietą rozwijanej sekcji godzin. Tygodniowy rozkład i surowy zapis w razie problemów pozostają dostępne po rozwinięciu. Brak danych jest jawnie opisany już w skrócie po zakończeniu pobierania. Godziny i warunki parkingu zachowują osobną prezentację w sekcji parkowania. Parser, strefa czasowa, częstotliwość obliczeń i reguły kwalifikacji otwarcia nie były zmieniane.

### 8. Czytelność przy długich nazwach i większym tekście

Wdrożenie: pełna nazwa i adres mogą rosnąć pionowo. Zwinięta nazwa mieści do dwóch wierszy. Kontakt i akcje układają się pionowo dla rozmiarów tekstu dostępności. Skrót parkingu może zawijać warunki opłat. Najważniejsze nowe przyciski i linki mają obszary co najmniej 44 pt oraz etykiety dostępności. Nie oznacza to gwarancji, że wszystkie informacje zmieszczą się bez przewijania przy dowolnym rozmiarze tekstu.

## Hierarchia po wdrożeniu

| Poziom | Zawartość i cel |
| --- | --- |
| Nagłówek | Nazwa, ikona kategorii, Ulubione; kategoria i rzeczywisty stan oszacowania dojazdu |
| Podstawowe informacje | Adres, status i rozwinięcie godzin albo informacja o ich braku, skrót parkingu; stan pobierania lub błąd z ponowieniem |
| Akcje dodatkowe | Początek trasy, kontakt; w średnim panelu jawne przejście do pełnych szczegółów |
| Informacje zależne od kategorii | Ceny paliw z datami i źródłem; w pełnym panelu operator, udogodnienia, parking i dojazd, informacje przekazane przez listę wyników |
| Materiał wizualny | Zdjęcia, Look Around lub logo, tylko w pełnym panelu i przy dostępnych danych |
| Metadane | Źródło szczegółów i czas pobrania w pełnym widoku |
| Przypięta stopka na iOS | Jedna główna akcja: planowanie trasy albo dodanie przystanku |

## Świadome decyzje i dalsze ograniczenia

Średni tryb pozostaje domyślny: pozwala rozpoznać miejsce i utrzymuje kontekst mapy. Otwieranie pełnej karty dla każdego POI zasłaniałoby mapę także wtedy, gdy źródło ma tylko nazwę i kategorię. Automatyczne dobieranie trybu według ilości dociągniętych danych powodowałoby zmiany wysokości podczas ładowania.

Nie usunięto cen paliw, warunków parkowania, kontaktu, materiałów zdjęciowych ani informacji o źródle. Nie dodano ocen, recenzji ani innych danych tylko dlatego, że byłyby atrakcyjne wizualnie. Sekcja cen zachowuje informacje o wieku i pochodzeniu ceny. Niedostępność dojazdu oraz niepowodzenie odświeżenia pozostają jawne.

Po zmianie nadal możliwe są przesunięcia treści, gdy źródło dostarczy dłuższy adres, kontakt lub godziny. Główna akcja pozostaje od nich niezależna. Na bardzo krótkim ekranie i przy dużym tekście wymagane będzie przewijanie. Listy wyszukiwania zachowują swój nagłówek wyniku nad rozwiniętą kartą; ich przebudowa stanowiłaby osobny zakres.

## Weryfikacja

Sprawdzono składnię zmienionych plików Swift i poprawność diffów. Kompilacja iOS Debug dla `generic/platform=iOS`, bez podpisywania, zakończyła się powodzeniem. Nie dodawano ani nie uruchamiano testów funkcjonalnych dla tej korekty UI. Nie wykonano oceny na uruchomionym urządzeniu ani porównania zrzutów; opisy układu i gestów wynikają z analizy kodu. Weryfikacja nie obejmuje kompilacji targetu macOS.
