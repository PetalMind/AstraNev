# Analiza UI/UX planowania podróży w NaviAstra

Stan analizy: 13 października 2026 r., wersja 1.1.78, build 80.

## Ocena ogólna i zakres

Obecny edytor planu jest odłączony od mapy, istniejącej wyszukiwarki i podglądu trasy. Zmusza użytkownika do wypełnienia rozbudowanego formularza przed zobaczeniem wyniku. Najważniejsza praca — wybór punktów i sprawdzenie przebiegu podróży — jest mniej dostępna niż ustawienia dodatkowe.

Analiza obejmuje aktualne źródła edytora, wyboru miejsc, listy i szczegółów planów, zapis i rozpoczęcie podróży oraz porównanie z działającymi w kodzie mechanizmami głównej aplikacji. Nie obejmuje oględzin uruchomionego interfejsu iPhone’a. Dokładne położenie systemowego pola `.searchable`, zachowanie klawiatury, kontrast i układ przy powiększonym tekście wymagają osobnego potwierdzenia podczas działania aplikacji. Brak mapy, brak podglądu przed zapisem i opisane zależności kodu są potwierdzone w źródłach.

## 1. Nawigacja i spójność wizualna

Obecny przebieg uruchomiony z ekranu Podróże:

`Mapa → arkusz Podróże → kolejny arkusz edycji → kolejny arkusz wyboru miejsca`.

Uruchomienie z podglądu trasy pomija listę Podróże, ale nadal przechodzi do odrębnego formularza i kolejnego wyboru miejsca. Edytor wykorzystuje `Form`, a lista i szczegóły `List`. Nie wykorzystuje panelu mapy, geometrii trasy ani komponentów `NavigationBottomSheet` i `NavigationGlassSurface` obecnych w podstawowym planowaniu. Sam wybór komponentów systemowych jest poprawny; ich zastosowanie do całego procesu planowania powoduje utratę kontekstu mapy i zmianę sposobu obsługi.

Źródła: [edytor i prezentacja arkuszy](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:79>), [formularz](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:207>), [główny panel trasy](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Routing/UI/ContentView+RoutePlanning.swift:187>), [powierzchnie aplikacji](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/App/UI/NavigationChrome.swift:6>).

Apple zaleca ograniczenie nakładanych arkuszy, ponieważ zamknięcie jednego i powrót do kolejnego utrudnia orientację. Jest to dodatkowe uzasadnienie uproszczenia przepływu, obok porównania z istniejącym interfejsem NaviAstra. [Apple HIG — Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets?changes=_1_1).

## 2. Najważniejsze problemy funkcjonalne

### A. Brak wyboru punktów na mapie — priorytet wysoki

`TripPlacePicker` przyjmuje zapisane miejsca, bieżący punkt, tekst i callback wyboru. Nie ma mapy, przycisku wyboru na mapie ani przekazania takiego żądania do głównego widoku. Dotyczy to startu, celu i punktów pośrednich.

Aplikacja ma już wybór startu na mapie, centralny marker, pobranie adresu wybranego punktu oraz obsługę wyboru POI. Ten mechanizm nie został połączony z nowym szkicem planowanej podróży.

Źródła: [uproszczony wybór miejsca](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:320>), [istniejący wybór startu](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Maps/UI/ContentView+MapPanels.swift:718>), [tryb wyboru na mapie](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Maps/UI/ContentView+MapPanels.swift:966>).

### B. Wpisywanie adresu ma niepełny przepływ — priorytet wysoki

W kodzie istnieje pole generowane przez `.searchable`. Nie można więc uznać, że wyszukiwanie adresów nie zostało zaimplementowane w ogóle. Brakuje jednak wyraźnego, stale widocznego pola, rozpoznawalnego z głównej wyszukiwarki, oraz obsługi, która zapewnia podobne doświadczenie.

Picker oczekuje na końcowy rezultat `SearchEngine.search`. Nie wykorzystuje jego callbacku z częściowymi wynikami. Przy dostępnej pozycji GPS silnik może po znalezieniu adresów obliczać macierz dojazdu. Wyniki w pickerze są ustawiane dopiero po zakończeniu całego wywołania, choć ekran nie prezentuje tych czasów dojazdu. Użytkownik czeka na dodatkową pracę, zamiast móc od razu wybrać znaleziony adres.

Picker przekazuje jedynie bieżącą lokalizację i zapisane miejsca. Nie przekazuje wybranego startu planu, obszaru mapy, środka transportu i preferencji szkicu. Kontekst domyślnie zakłada auto. Nie ma też obsługi wysłania zapytania z dodatkowym wyszukiwaniem dokładnego adresu, dostępnej w głównej wyszukiwarce.

Źródła: [wyszukiwanie w pickerze](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:351>), [częściowe wyniki i dodatkowe obliczenia](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Search/SearchEngine.swift:149>), [pełne pole i wysłanie zapytania](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Search/UI/DestinationSearchSheet.swift:435>), [kontekst głównej wyszukiwarki](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Search/SearchStore.swift:90>).

### C. Nie ma podglądu i wyboru rzeczywistej trasy przed zapisem — priorytet wysoki

Formularz nie pokazuje geometrii, dystansu, obliczonego wyjazdu ani alternatyw. „Wariant” jest wyborem preferencji, nie wyborem obejrzanej trasy. Zachowanie wcześniej wybranego wariantu działa tylko dla szkicu utworzonego z istniejącego podglądu. Po zmianie punktów jest wyłączane.

Przeliczenie następuje po zapisaniu planu. Metoda `calculate` zwraca wybrany wariant i informację o dopasowaniu, choć jej sesja ma dostęp do wszystkich opcji. Edytor nie może obecnie wyświetlić tych opcji i pozwolić użytkownikowi wybrać konkretnego przebiegu.

Źródła: [preferencje zamiast podglądu](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:249>), [zapis przed przeliczeniem](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:297>), [wynik obliczania](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/TripPlanningService.swift:143>).

### D. Punkty pośrednie są trudne do obsługi — priorytet wysoki

Postoje są oddzielone od startu i celu inną sekcją. Pokazują tylko nazwę, bez adresu, numeru w trasie, jawnej zmiany miejsca i widocznego uchwytu kolejności. Kod deklaruje `.onMove`, ale w tym widoku nie ma przycisku edycji ani jawnego trybu edycji. Dostępność konkretnego gestu zależy od platformy; możliwość zmiany kolejności nie jest czytelna w samym interfejsie.

Dodawanie po prostu dopisuje miejsce do tablicy. Nie stosuje limitu ośmiu punktów ani blokady duplikatów z głównego planowania.

„Postój” i „przystanek transportu publicznego” wymagają odrębnej obsługi. Nowy picker nie ma wyszukiwania przystanków i linii z głównej wyszukiwarki. Silnik komunikacji nie obsługuje obecnie dowolnych punktów pośrednich; interfejs nie powinien obiecywać takiej możliwości. Przystanek można wykorzystać jako start lub cel, przekazując jego lokalizację do szkicu.

Źródła: [postoje w edytorze](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:240>), [dodanie do szkicu](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:277>), [limity i duplikaty w głównej trasie](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Navigation/NavigationSession+RouteEditing.swift:141>), [wyszukiwanie komunikacji](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Search/UI/DestinationSearchSheet.swift:371>).

### E. Zmiana transportu usuwa dane szkicu — priorytet wysoki

W pierwotnym interfejsie wybór komunikacji usuwał postoje i zerował ich czas. Obecny edytor zachowuje punkty w szkicu i opisuje ograniczenie trybu przy trasie.

Należy zachować punkty w szkicu, oznaczyć ograniczenie wybranego trybu i ustalić jawne zachowanie przy zapisie. Eksplorowanie opcji transportu nie powinno samo kasować wprowadzonych miejsc.

Źródło: [reakcja na zmianę transportu](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:286>).

### F. Zapis daje niepełną informację o powodzeniu — priorytet wysoki

Plan zostaje zapisany lokalnie, następnie formularz czeka na routing i uprawnienia powiadomień, a na końcu jest zamykany. `refresh` przechwytuje błędy i zapisuje je w planie, więc formularz zamknie się także wtedy, kiedy trasy nie obliczono. Zapis planu i wyliczenie wyjazdu mają różne wyniki, lecz użytkownik nie dostaje bezpośredniego podsumowania obu.

Podczas oczekiwania wyłączone są przyciski i gest zamknięcia, ale pola formularza nadal są edytowalne. Kolejne zmiany nie trafiają do obiektu utworzonego wcześniej w `save` i mogą zostać utracone po zamknięciu.

Źródła: [zapis formularza](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:297>), [przechwytywanie błędu obliczania](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/TripPlanningService.swift:92>).

### G. Część widocznych ustawień nie wpływa na komunikację — priorytet średni

Preferencje wariantu, promów i nawierzchni pozostają widoczne również przy komunikacji. Jej obliczanie otrzymuje start, cel i datę, a nie te drogowe preferencje. Przy tworzeniu planu z listy preferencje są też inicjalizowane od wartości domyślnych, podczas gdy plan utworzony z mapy kopiuje bieżące ustawienia.

Należy pokazywać ustawienia zgodne z transportem i zachować wspólne źródło obsługiwanych preferencji aplikacji.

Źródła: [ustawienia dla wszystkich trybów](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:249>), [inicjalizacja preferencji](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:187>), [obliczanie komunikacji](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Navigation/NavigationSession+RoutePreview.swift:71>).

### H. Rozpoczęcie podróży zmienia start bez podglądu — priorytet średni

„Rozpocznij teraz” przelicza trasę z aktualnej pozycji i uruchamia nawigację, nawet jeśli zapisano inny start. Jest to przydatne zachowanie, ale wyświetlany wcześniej czas i przebieg dotyczą zapisanego startu. Szczegóły powinny jasno informować o rozpoczęciu z aktualnego miejsca oraz udostępniać podgląd zapisanej trasy.

Źródło: [rozpoczęcie z bieżącego miejsca](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/ContentView+PlannedTrips.swift:43>).

## 3. Hierarchia edytora

Obecna kolejność zaczyna się od opcjonalnej nazwy. Start i cel są prostymi przyciskami, potem pojawiają się transport i import z kalendarza. Termin obejmuje od razu powtarzanie i do siedmiu przełączników dni. Punkty pośrednie są dalej, a ustawienia i cztery przypomnienia wydłużają formularz. Brakuje głównego wyniku planowania: obejrzanej i policzonej trasy.

Docelowy układ na iPhonie:

| Położenie | Zawartość | Cel |
| --- | --- | --- |
| Tło | Mapa z trasą i oznaczeniami punktów | Stały kontekst przestrzenny |
| Nagłówek panelu | „Zaplanuj podróż”, czytelny powrót | Orientacja w zadaniu |
| Początek panelu | Obsługiwane środki transportu | Określenie sposobu podróży |
| Główna karta | Start → ponumerowane punkty pośrednie → cel | Cały przebieg w jednym miejscu |
| Wiersz terminu | „Wyjazd” / „Przyjazd do” oraz polska data i godzina | Jasna intencja czasu |
| Wynik | Dostępne warianty, dystans, czas i obliczony wyjazd/przyjazd | Świadomy wybór trasy |
| Ustawienia dodatkowe | Bufor, czas postojów, przypomnienia, powtarzanie i preferencje | Dostęp do obsługiwanych opcji bez dominowania nad trasą |
| Dół panelu | Podsumowanie stanu i „Zapisz plan” | Główna akcja dostępna bez przewijania całego formularza |

Panel powinien korzystać z materiałów i tokenów NaviAstra oraz zwijać się, aby odsłonić mapę. ETA i ostrzeżenia wymagają czytelnej powierzchni zgodnej z istniejącym systemem.

Import z kalendarza powinien być osobnym sposobem rozpoczęcia planu albo dodatkową akcją. Opcjonalna nazwa może znajdować się przy zapisie. Powtarzanie powinno pokazywać krótki opis harmonogramu; wybór dni może używać kompaktowych przycisków zamiast siedmiu pełnych wierszy.

## 4. Wybór miejsca i powrót do szkicu

Start, cel i punkt pośredni powinny korzystać ze wspólnego komponentu wyboru, z tytułem odpowiednim do roli. Ekran powinien od razu pokazywać pole „Wpisz adres lub nazwę miejsca”, akcję „Wybierz na mapie” oraz grupy: bieżący punkt, Dom/Praca i ulubione, ostatnie miejsca. Przy odpowiednim transporcie powinien udostępniać istniejące wyszukiwanie przystanków.

Wyniki powinny pokazywać nazwę, pełny adres i miejscowość oraz wyraźne „Wybierz”. Wyniki miejsc muszą pojawiać się przed zakończeniem opcjonalnych obliczeń dojazdu. Błąd wyszukiwania powinien proponować ponowienie; wolna usługa ETA nie może blokować wyboru poprawnie znalezionego adresu.

Wybranie mapy musi zachować cały szkic, odsłonić mapę i wskazać rolę punktu. Użytkownik przesuwa mapę lub wybiera POI, widzi adres i potwierdza „Użyj jako start”, „Użyj jako cel” lub „Dodaj punkt”. Powrót odtwarza ten sam edytor z wszystkimi danymi.

Ważne ograniczenie integracji: istniejące `applyRouteOrigin` i `confirmRouteOriginMapSelection` zapisują bezpośrednio do głównego `NavigationStore`. Nie należy podłączać ich bez zmian do nowego edytora. Wspólny wybór punktu powinien zwracać miejsce i źródło wyboru, a odbiorca decydować, czy zmienić szkic planu, czy bieżącą trasę. Edycja planu nie może naruszać aktywnej nawigacji.

## 5. Lista i szczegóły podróży

Na liście „Zaplanowane” najważniejsze są dzień, rodzaj terminu i rekomendowany wyjazd. Obecna karta nie podpisuje głównej godziny jako wyjazdu lub przyjazdu, a dla planu wyjazdu powtarza godzinę. Należy grupować najbliższe terminy według dni i odróżnić „Przyjazd do” od „Wyjazd”. Stan „Obliczam”, „Nie obliczono” lub „Ostatni szacunek” powinien być widoczny przy wyniku.

Obecna zakładka „Regularne” filtruje tę samą listę nadchodzących terminów. Powinna prezentować definicję powtarzania: rzeczywiste dni, godzinę i relację, podczas gdy „Zaplanowane” pokazuje konkretne wystąpienia. Nie wymaga to dodawania nieobsługiwanych opcji wstrzymywania lub automatycznego uczenia.

W szczegółach obecnie najpierw występują pola trasy, potem termin, potem szacunki i dopiero działania. Zalecana kolejność: termin i rekomendowany wyjazd, podgląd mapy, przebieg, informacje o ostatnim obliczeniu, przypomnienia i pozostałe ustawienia. Główne działania — podgląd, edycja i rozpoczęcie — powinny być łatwo dostępne. Usuwanie i pominięcie terminu powinny mieć mniejszą wagę wizualną i jednoznaczny opis skutku.

Źródło: [lista i szczegóły](</Volumes/Zewnetrzny/Projekty programowanie/Github/NaviAstra/NaviAstra/Trips/PlannedTripsView.swift:17>).

## 6. Zakres przebudowy

1. Wprowadzić utrzymywany poza arkuszem szkic planu, aby przetrwał wybór punktu na mapie i powrót.
2. Połączyć istniejące mechanizmy wyszukiwania adresów, zapisanych miejsc, historii, przystanków i wyboru na mapie przez callback działający na szkicu.
3. Dodać podgląd tras i wyniku obliczeń przed zapisem, korzystając z istniejącego silnika oraz odrębnej sesji obliczającej.
4. Przebudować edytor na panel mapy z czytelną kartą przebiegu, terminem i stałą akcją zapisu.
5. Uporządkować postoje, limity, duplikaty, zmianę transportu i prezentację obsługiwanych preferencji.
6. Oddzielić stan zapisu lokalnego od powodzenia routingu i ustawienia przypomnień. Zapewnić czytelny wynik oraz możliwość ponowienia bez utraty danych.
7. Uporządkować listę i szczegóły zgodnie z hierarchią terminu, trasy i działań.

Do zachowania: lokalny zapis, istniejący routing, świadome przeliczanie wariantów, lokalne powiadomienia, polski język, zapisane strefy czasowe oraz brak ML i synchronizacji z iCloud. Zakres nie wymaga tworzenia kolejnego silnika routingu ani dodawania fikcyjnych prognoz.

Raport jest analizą i propozycją przebudowy; nie dokumentuje wykonanej zmiany interfejsu.

## Realizacja dla iOS

W wersji 1.1.80 (build 82) wdrożono dla iOS nowy ekran mapy i panelu, niezależny szkic, wybór adresów i przystanków, wybór punktów na mapie, podgląd wariantów przed zapisem, jawne opcje punktów pośrednich, zachowanie danych przy zmianie transportu, czytelny wynik zapisu oraz nową listę i szczegóły podróży. Szczegóły implementacji i granice walidacji znajdują się w `docs/PLANNED_TRIPS.md`, w sekcji „Nowy interfejs iOS”. Pierwotna analiza powyżej dotyczyła wcześniejszego edytora.
