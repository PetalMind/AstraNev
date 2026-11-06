# Wyszukiwanie w NaviAstra iOS — audyt i przebudowa

Stan dokumentu: 30 października 2026 r.
Zakres: wyszukiwanie celu, startu, przystanku pośredniego i zapisanych miejsc oraz wybór miejsca w planie podróży na iOS.

## Cel i podstawa oceny

Wyszukiwanie ma prowadzić od zamiaru do właściwego miejsca bez zgadywania znaczenia przycisków, powtarzających się wpisów i oczekiwania na najwolniejsze źródło danych.
Audyt opiera się na przepływach i implementacji aplikacji oraz oficjalnych opisach Apple Maps, Google Maps i Waze.
Nie stanowi pomiaru przewagi szybkości, trafności ani pokrycia danych nad tymi produktami.
Oględziny interfejsu podczas działania i wyniki weryfikacji należy odróżniać od wniosków wynikających z kodu.

## Problemy i wdrożone zmiany

| Obszar | Przed zmianą | Po zmianie |
| --- | --- | --- |
| Wpisywanie | Każda zmiana frazy usuwała wyniki; kolejne odpowiedzi odbudowywały listę. | Przy dopisywaniu lub skracaniu tej samej frazy poprzednie wyniki pozostają widoczne, przygaszone i nieaktywne do nadejścia aktualnej odpowiedzi. |
| Odpowiedzi źródeł | Silnik już publikował częściowe wyniki, lecz UI odbudowywał listę przy zmianach zapytania. | Zachowano częściową publikację i połączono ją ze stabilną tożsamością oraz oznaczeniem aktualizacji. |
| Tożsamość wiersza | Inny dostawca tego samego miejsca mógł zmienić identyfikator wiersza. | Rejestr tożsamości zachowuje identyfikator rozpoznanego miejsca podczas uzupełniania metadanych. |
| Zatwierdzenie | Przycisk klawiatury uruchamiał kolejne opóźnienie i pozostawiał klawiaturę. | Zatwierdzenie pomija debounce, uruchamia pełne wyszukiwanie i chowa klawiaturę. |
| Wybór miejsca | Główna część wyniku rozwijała szczegóły; wyznaczenie trasy miało osobny mały przycisk. | Dotknięcie wiersza wybiera miejsce. Osobny przycisk informacji rozwija szczegóły. |
| Treść wyniku | Wiersz łączył liczne metadane, źródła, rozwijanie, trasę i ulubione. | Pierwszy poziom pokazuje nazwę, adres, dostępny dojazd i istotne godziny; pełna karta i zapis są w szczegółach. |
| Pusty ekran | Skróty, zapisane miejsca i dwie historie powtarzały te same cele. | Dom, praca i przypięte miejsca są skrótami; dodatkowe zapisane i scalone ostatnie mają osobne, rozwijane listy. |
| Kategorie | Kategorie wymagały przewijania poziomego; brakowało skrótu ładowania. | Siatka udostępnia paliwo, ładowanie, parking, jedzenie, kawę i paczkomaty. |
| Dopasowania lokalne | Wyszukiwanie zapisanych i ostatnich obejmowało głównie nazwę. | Dopasowanie uwzględnia nazwę, adres i wszystkie wpisane słowa, bez wymogu zachowania ich kolejności. |
| Duplikaty | Te same miejsca mogły występować jednocześnie lokalnie i z sieci. | Deduplikacja uwzględnia nazwę i położenie; sam wspólny punkt budynku nie wystarcza do ukrycia innego lokalu. |
| Przystanek pośredni | Zapisane miejsce i wynik sieciowy mogły wykonać różne działania w trybie „Po trasie”. | Wszystkie rodzaje wyników korzystają ze wspólnej decyzji: start, cel, przystanek albo zapis. |
| Kontekst zadania | Wejście „Dodaj przystanek” nadal wyglądało jak zwykłe wyszukiwanie celu. | Arkusz otrzymuje tryb dodawania przystanku, pokazuje odpowiedni tytuł i ukrywa zakres komunikacji. |
| Zamknięcie | Tryb dodawania przystanku mógł pozostać aktywny po anulowaniu arkusza. | Zamknięcie wyszukiwania zeruje `addingWaypoint`. |
| Ulubione | Nowa prezentacja wymagała uzgodnienia oznaczenia zapisu z akcjami edycji. | Serce oznacza rzeczywisty wpis typu ulubione, zgodnie z dopasowaniem używanym przez usuwanie i zmianę nazwy. |
| Zapis miejsca | Tryb zapisu domu, pracy lub ulubionego nie miał jawnego wyjścia. | Pasek „Zapisujesz jako…” ma przycisk „Anuluj”. |
| Komunikacja | Minimalna długość frazy blokowała pojedynczy numer linii. | Jedna cyfra uruchamia wyszukiwanie linii; lokalne dokładne dopasowanie numeru ma pierwszeństwo. |
| Nieaktualna odpowiedź | Samo anulowanie zadania nie gwarantowało unieważnienia opóźnionego callbacku. | Anulowanie unieważnia identyfikator żądania; stara odpowiedź nie może nadpisać aktualnego stanu. |

## Model interakcji

1. Otwarcie wyszukiwania pokazuje pole, aktualny obszar oraz skróty do miejsc i kategorii.
2. Pisanie natychmiast ujawnia dopasowania lokalne; zapytania sieciowe mają debounce 250 ms.
3. „Szukaj” uruchamia zapytanie bez tej zwłoki. Dodatkowe wyszukiwanie adresowe może uzupełnić wyniki.
4. Zmiana obszaru ponawia zapytanie dla wybranego kontekstu: blisko użytkownika, w obszarze mapy lub po aktywnej trasie.
5. Wynik wybiera miejsce zgodnie z zadaniem. Przycisk informacji otwiera szczegóły bez wybierania celu.
6. Wybór celu przekazuje miejsce do istniejącego procesu planowania trasy; sam nie rozpoczyna prowadzenia.
7. Wybór startu zmienia początek trasy. Wybór przystanku dodaje punkt pośredni zamiast zastępować cel.
8. Zamknięcie arkusza przerywa wyszukiwanie i kończy kontekst dodawania przystanku.

Poprzednie wyniki są zachowywane tylko przy pokrewnej frazie i tym samym zakresie.
Nie można ich wybrać, dopóki nie zostaną potwierdzone odpowiedzią dla aktualnego żądania.
Przy całkiem nowej frazie lista jest czyszczona. Błąd nie utrwala nieaktualnych wyników jako bieżących.
Stabilna tożsamość wierszy nie zamraża rankingu: rzeczywiste dane dojazdu mogą zmienić kolejność.

## Hierarchia informacji i dostępność

- Nazwa i adres pozwalają odróżnić podobne miejsca; dopasowane słowa w nazwie są wyróżnione kolorem.
- Dojazd jest informacją uzupełniającą, a brak wyliczenia nie blokuje wyboru miejsca.
- Lista wykorzystuje znane lub zapisane w pamięci podręcznej godziny. Dodatkowe pobieranie szczegółów odbywa się po rozwinięciu karty.
- Ostrzeżenie o zamknięciu przy dojeździe jest pokazywane tylko wtedy, gdy dostępne są godziny i czas podróży.
- Pole i akcje mają polskie etykiety dostępności; opis działania wyniku odpowiada aktualnemu zadaniu.
- Nowy wiersz używa fontów semantycznych, pozwala rozwinąć adres przy dużym tekście i respektuje ograniczenie ruchu.
- Przyciski informacji, czyszczenia, mikrofonu i dodawania zapewniają obszar dotyku co najmniej 44 pkt.
- Komunikaty, liczby, czas podróży i ustawienia regionalne pozostają polskie.

## Wzorce konkurencji i znaczenie dla NaviAstra

| Oficjalnie opisany wzorzec | Zastosowanie w NaviAstra | Korzyść względem poprzedniej wersji |
| --- | --- | --- |
| Apple Maps: wyszukiwanie kategorii bez wpisywania oraz zmiana pobliskiego obszaru na mapie. | Widoczna siatka kategorii i jawny wybór obszaru. | Mniej pisania i czytelniejsze określenie, gdzie aplikacja szuka. |
| Google Maps: kategorie bezpośrednio pod polem oraz ranking łączący trafność, odległość i rozpoznawalność miejsca. | Skróty kategorii; dopasowanie tekstowe, a następnie dostępne rzeczywiste szacunki dojazdu. | Wyniki nie są przedstawiane jako najlepsze wyłącznie na podstawie odległości w linii prostej. |
| Waze: dom, praca, zapisane miejsca, kategorie, głos i kontakty dostępne z wyszukiwania. | Zachowane różne sposoby wejścia, uproszczona historia i jednoznaczne działanie wyniku. | Krótsza droga do częstych celów i mniej niejasności przy dodawaniu przystanku. |

Źródła: [Apple Maps — miejsca w pobliżu](https://support.apple.com/en-me/guide/iphone/iphbaf51b2c0/ios), [Google Maps — wyszukiwanie lokalne na iOS](https://support.google.com/maps/answer/4610185?co=GENIE.Platform%3DiOS&hl=en), [Waze — wyszukiwanie celu na iOS](https://support.google.com/waze/answer/6262563?co=GENIE.Platform%3DiOS&hl=en).

Te odniesienia potwierdzają użyteczne wzorce interakcji, nie dowodzą braków konkurencji.
Wyróżnikiem rozwijanym w NaviAstra jest spójne połączenie lokalnych miejsc, polskich adresów, punktów odbioru i kontekstu trasy.
Ocena przewagi nad innymi aplikacjami wymaga porównania tych samych zadań na urządzeniu i w porównywalnych warunkach sieciowych.

## Odzyskiwanie danych dojazdu

Brak odpowiedzi zbiorczego wyliczenia nie kończy już obsługi wyniku komunikatem „Odległość po drogach i czas niedostępne”.

- Poprawne czasy i odległości pojawiają się od razu. Dla maksymalnie dwóch brakujących wyników wykonywane jest dodatkowe obliczenie pojedynczej rzeczywistej trasy, bez wariantów i dodatkowych profili.
- W trybie offline zbiorcze zapytanie sieciowe jest pomijane. Pojedyncza trasa korzysta z istniejącej obsługi lokalnego pakietu dróg i sieciowego fallbacku aplikacji.
- Dla pozostałych wyników przycisk „Sprawdź dojazd” ponawia obliczenie wybranego miejsca. Podczas próby wiersz pokazuje postęp. Niepowodzenie pozostawia ponowienie oraz wybór miejsca do planowania trasy.
- Ręczna próba korzysta z punktu startowego i środka transportu tego samego zapytania. Poprawny wynik jest zachowywany przy kolejnych odpowiedziach dostawców i uwzględniany w rankingu.
- Zmiana frazy lub zamknięcie wyszukiwania anuluje ręczne próby i odrzuca spóźnione odpowiedzi. Wielokrotne dotknięcie przycisku nie tworzy równoległych prób dla tego samego wyniku.
- Pokazywane są tylko rzeczywiście znane wartości. Brak czasu nie usuwa znanej odległości; dystans w linii prostej nie zastępuje odległości drogowej.
- Sieciowe wyznaczanie pojedynczej trasy ma timeout 6 sekund. To nie jest gwarancja całkowitego czasu operacji: bramka dostawcy i lokalny silnik tras mają odrębny czas wykonania.

## Granice rozwiązania

- Trafność i kompletność zależą od danych MapKit, Photon/OpenStreetMap, źródeł adresowych GUGiK oraz obsługiwanych dostawców punktów odbioru.
- Równoległe odpowiedzi skracają oczekiwanie na użyteczny wynik, ale nie usuwają opóźnień sieci, limitów API ani braków danych.
- Godziny otwarcia i metadane mogą być niepełne lub nieaktualne. Brak danych nie oznacza, że miejsce jest zamknięte.
- Czas dojazdu wymaga dostępnego silnika tras; nie należy zastępować go dystansem geometrycznym opisanym jako czas podróży.
- Wyszukiwanie „Po trasie” wymaga aktywnej geometrii trasy. Sam napis w zapytaniu nie tworzy trasy.
- Kontakty są przeszukiwane po udzieleniu dostępu i tylko w granicach danych dostępnych aplikacji.
- Lista linii zależy od obsługiwanych regionalnych danych GTFS. Wyniki przystanków mogą być uzupełniane przez Transitous; nie oznacza to pełnego katalogu linii w całej Polsce.
- Brak wyniku komunikacji może wynikać z pokrycia lub dostępności źródła; nie potwierdza nieistnienia linii ani przystanku.
- Zmiana listy wyników nie zastępuje osobnej oceny trafności routingu, wejść do obiektów i aktualności rozkładów.

## Odpowiedzialności w kodzie

| Element | Odpowiedzialność |
| --- | --- |
| `SearchEngine`, `SearchProviderBatch`, `SearchRanking` | Źródła, częściowe odpowiedzi, łączenie, ranking i tożsamość wyników. |
| `SearchStore` | Żądania, anulowanie, poprzednie wyniki i publikacja aktualnego stanu. |
| `DestinationSearchSheet` | Pole, zakres, obszar, sekcje, focus i kontekst wyboru. |
| `IOSDestinationResultRow` | Wybór miejsca, zwięzłe metadane i jawne rozwijanie szczegółów. |
| `ContentView+Search`, `ContentView+ViewState` | Przekazanie wyboru do trasy i zakończenie trybu przystanku przy zamknięciu. |
| `IOSTripPlaceSearch`, `IOSTripPlaceSearchModel` | Wybór punktu w szkicu podróży z zachowaniem kontekstu planu. |

## Kryteria kolejnej oceny

Poniższe wartości i scenariusze są kryteriami przyszłego pomiaru, nie deklarowanymi wynikami wdrożenia.

| Miara | Sposób oceny |
| --- | --- |
| Czas do pierwszego użytecznego wyniku | Mediana i 95. percentyl od ostatniego znaku oraz od zatwierdzenia; osobno Wi-Fi, sieć komórkowa, wolna sieć i pamięć podręczna. |
| Trafność | Odsetek poprawnych celów w pierwszych 3 i 8 wynikach dla stałego zestawu polskich adresów, marek, punktów odbioru i nazw z diakrytyką. |
| Liczba działań | Liczba dotknięć od otwarcia wyszukiwania do wyboru domu, kategorii, celu z historii oraz przystanku pośredniego. |
| Stabilność | Liczba zniknięć wiersza i utrat rozwinięcia tego samego miejsca podczas odpowiedzi kolejnych dostawców. |
| Aktualność wyboru | Zero możliwości wybrania starego wyniku po zmianie frazy i zero nadpisań aktualnej listy przez anulowane żądanie. |
| Poprawność kontekstu | Cel, start, zapis i przystanek wykonują właściwe działania dla wyników lokalnych, kontaktów i sieci; anulowanie nie przenosi trybu do kolejnej sesji. |
| Duplikaty | Brak powtórzeń tego samego miejsca bez usuwania odrębnych lokali i automatów w tym samym budynku. |
| Dostępność | Pełny przepływ przez VoiceOver; czytelność przy rozmiarach dostępności, w trybie ciemnym i przy ograniczeniu ruchu. |
| Komunikacja | Jednocyfrowa linia, stacja i przystanek z obsługiwanego GTFS; oddzielna ocena zapytań poza pokryciem. |

## Weryfikacja

- Kompilacja aplikacji iOS oraz uruchomienie `SearchEstimatesCriticalTests` i `SearchTravelRecoveryCriticalTests` na symulatorze iPhone Duo / iOS 27.1 zakończyły się powodzeniem: 17 z 17 testów, w tym końcowa weryfikacja anulowania bez pozostawienia wskaźnika postępu.
- Zakres testów: pierwszeństwo rzeczywistego czasu dojazdu, niepoprawne i brakujące szacunki, odległość geometryczna, częściowe odpowiedzi, zachowanie ETA, liczba zapytań i anulowanie.
- Kompilacje korzystają z wyłącznej blokady `/tmp/codex-global-build.lock`.
- Końcowa kompilacja po poprawkach komunikatów, Dynamic Type i obszarów dotyku: `BUILD SUCCEEDED` (kod 0).
- Kontrola interfejsu była przeglądem kodu. Nie wykonano pełnej obsługi ekranów przez VoiceOver ani oględzin na urządzeniu; w tym środowisku brak dostępnej aplikacji Simulator do sterowania UI.
- Wersja iOS i widżetów po dodaniu odzyskiwania dojazdu: 1.1.168 (170).

Sprawdzono również publiczne usługi na dwóch stałych punktach w Warszawie: zbiorcze wyliczenie zwróciło 511 s / 3,996 km, a pojedyncza trasa 511,474 s / 3,995 km. Różnica mieści się w zaokrągleniu danych. Próba nie korzystała z lokalizacji użytkownika.


## Lokalność kategorii i aktualny punkt startowy

Dodatkowy audyt wykazał, że fraza „stacja benzynowa” trafiała do ogólnego wyszukiwania nazw, bo brakowało jej w słowniku kategorii. Podobnie nazwany odległy obiekt mógł wyprzedzić lokalną stację. Region MapKit i współrzędne Photon są wskazówkami dla dostawcy, więc same nie gwarantowały lokalności wyników. Bez danych z konkretnego uruchomienia nie można przypisać im z pewnością zgłoszonego wyniku 2 godz. 12 min.

- „Stacja benzynowa”, jej odmiany oraz „najbliższa stacja benzynowa” są kategorią paliw. Wynik wymaga kategorii stacji, a nie samej podobnej nazwy lub kontaktu.
- Zapisane miejsca i historia nie omijają filtrowania kategorii i marek: te zapytania przechodzą przez wspólną pulę silnika. Zwykłe nazwy i adresy nadal korzystają z lokalnych podpowiedzi.
- Wspólna pula wszystkich źródeł jest ograniczana przed wyborem pierwszych 8/16 wyników. Kategorie zaczynają od 3 km, marki od 5 km. Dalsze obszary (kategorie 10/20 km, marki 15/30 km) są używane dopiero przy braku miejsc w bliższym obszarze. Częściowe odpowiedzi nie pokazują odległych propozycji w oczekiwaniu na lokalnego dostawcę.
- Jawnie podana miejscowość lub wybrany obszar mapy wyznaczają obszar wyszukiwania. Adresy, współrzędne, konkretne numery automatów paczkowych i wyszukiwanie po trasie zachowują osobne reguły.
- Geometria ogranicza pulę. W jej obrębie rzeczywiste czasy tras nadal służą do porównywania dojazdu. Nie jest obietnicą, że znaleziono absolutnie najszybszy punkt spośród całego katalogu.
- W głównym wyszukiwaniu „Blisko mnie” wymaga zgody lokalizacyjnej oraz prawidłowego pomiaru nie starszego niż 60 sekund. Otwarcie wyszukiwania i brak aktualnego pomiaru uruchamiają odświeżenie lokalizacji; nowy pomiar ponawia zapytanie, które nie miało punktu startowego.
- Domyślny środek mapy i punkt startowy poprzedniego podglądu trasy nie zastępują GPS. Obszar mapy można wybrać jawnie, lecz sam obszar ani środek znalezionego miasta nie tworzą czasu dojazdu.
- Planer podróży zachowuje start szkicu. Zmiana startu, obszaru lub środka transportu unieważnia jego poprzednie wyniki.

Podstawa zachowania dostawców: [Apple MKLocalSearch.Request.region](https://developer.apple.com/documentation/mapkit/mklocalsearch/request/region), [Photon API](https://github.com/komoot/photon/blob/master/docs/api-v1.md).


## Szybsze godziny otwarcia

Wiersze wyników ponownie uruchamiają uzupełnianie samych godzin po krótkiej przerwie 300 ms. Pobieranie ma stabilny klucz miejsca i adresu: zmiana ETA przelicza stan przy przyjeździe, ale nie przerywa pobierania. Rozwinięte szczegóły przekazują uzyskane godziny od razu do wiersza, a rewizja danych odrzuca spóźnione odpowiedzi wcześniejszej próby.

Dane ze strony lub identyfikatora Wikidata mogą być pobierane już podczas ładowania pozostałych szczegółów. Dostawca publikuje godziny po poszczególnych etapach, bez czekania na zakończenie całego wzbogacania. Odczyt stron dopuszcza maksymalnie dwa różne hosty równocześnie, nadal po jednym żądaniu na host; działają reguły robots, limity rozmiaru, timeouty, kontrola adresów, cache i cooldown dostawcy. Anulowanie wyszukiwania nie oznacza awarii strony i nie zakłada blokady hosta.

Nie zmieniono czasu ważności danych ani limitu przeszukiwania katalogu oficjalnego dostawcy (do 12 stron miasta). Nowe godziny otrzymane w wynikach OSM mają własny znacznik czasu; stare sprawdzenie strony lub Wikidata nie może ich wygasić. Sam callback UI nie odmładza zewnętrznych godzin. Status otwarte/zamknięte nadal uwzględnia strefę miejsca i kalendarz; brak lub niewspierany zapis nie staje się informacją o zamknięciu.

Na tym etapie usunięto zależności oczekiwania w kodzie, bez pomiaru urządzenia. Późniejsze obserwacje fizycznego iPhone’a opisano poniżej; nie potwierdzają kompletności godzin wszystkich placówek ani wydajności w sieci komórkowej.


## Wspólna integracja i końcowa weryfikacja

W głównym katalogu połączono poprawki lokalności, dojazdu i godzin z dwoma ukończonymi zakresami: dialogiem pełnych polskich adresów (w tym numerów z literą, doprecyzowania miejscowości i korekty) oraz uproszczeniem komunikatów nawigacji i ustawień. Przeniesiono wyłącznie przyrostowe łatki tych zadań, bez kopiowania ich starszych plików bazowych. Wcześniejsze zmiany głosu, w tym bezpośrednie „wybierz drugi”, pozostają.

Końcowa wersja aplikacji i widżetów to **1.1.172 (174)**; sprawdzono oba zbudowane Info.plist. Po integracji kompilacja Debug iOS oraz **132 testy krytyczne w 13 zestawach zakończyły się powodzeniem** (`TEST SUCCEEDED`). Obejmują cztery zestawy wyszukiwania, godziny miejsc oraz osiem zestawów głosu i wyboru celu. Nie dodawano testów prostych komunikatów UI. Osobna kontrola zakresu interfejsu sprawdziła także gałęzie Release bez optymalizacji; pełnej zoptymalizowanej kompilacji Release po integracji nie wykonywano.

- Wynik testów: `/private/tmp/NaviAstraIntegratedSearchVoice174.xcresult`.
- Log: `/private/tmp/naviastra-integrated-search-voice-174.log`.
- Wszystkie kompilacje używały wspólnej wyłącznej blokady OS. Po zakończeniu Xcode i kompilatorów zamknięto tylko własny pozostający monitor; plik blokady i procesy innych zadań pozostawiono nietknięte.
- Kontrola obu nałożonych łatek oraz `git diff --check` przechodzą. W projekcie Xcode zmieniły się wyłącznie numery wersji czterech konfiguracji iOS/widżetów. Chronione pliki macOS są bez zmian; obiektów A200 nie ma ani w bazie HEAD, ani w bieżącym projekcie.
- Na tym etapie integracji nie instalowano jeszcze połączonej wersji na fizycznym telefonie; późniejszy pomiar opisano poniżej. Nie przeprowadzono odsłuchu mikrofonu/Bluetooth ani osobnego pomiaru w sieci komórkowej. Testy adresów używają kontrolowanych odpowiedzi i nie potwierdzają istnienia miejsc podanych w rozmowie.


## Pomiar na fizycznym iPhonie — 30 października 2026 r.

Wersję 1.1.172 (174) zainstalowano i uruchomiono na iPhonie 15 Dominika. Na wyraźne zlecenie wykonano obserwację interfejsu przez XCTest, z rzeczywistymi usługami aplikacji i lokalizacją urządzenia. Potwierdzono zakres „Blisko mnie”. Nie używano danych testowych ani symulacji GPS, nie rozpoczynano prowadzenia i nie zmieniano celu istniejącego podglądu trasy.

Dla frazy „stacja benzynowa” pierwsza niepusta lista wraz z czasami dojazdu została zaobserwowana po około 12 sekundach od zakończenia automatycznego wpisywania i zatwierdzenia. Lista zawierała 7 wyników. Pierwszy to „Stacja benzynowa”, ul. Gojawiczyńskiej 19 w Łodzi, 6,3 km trasą i około 13 min. Kolejne widoczne wyniki miały czasy 15–18 min; po przewinięciu były również ORLEN przy Tuwima 7 (9,6 km, około 18 min) oraz bp przy Palki 3 (9,9 km, około 19 min).

Na liście nie zaobserwowano żadnych godzin otwarcia przez 46 sekund. Rozwinięcie pierwszego wyniku i dodatkowe 12 sekund obserwacji również ich nie ujawniło. Jest to brak widocznych danych w tej próbie, nie pomiar skutecznego pobrania godzin. Sam fakt pojawienia się ETA nie dowodzi kompletności pobliskich stacji.

Pomiar jest pojedynczą próbą w normalnym stanie pamięci podręcznej, bez jej czyszczenia. Ekran pokazywał Wi-Fi. Odczyty interfejsu wykonywano mniej więcej co sekundę; podane czasy są przybliżonymi momentami pierwszej obserwacji, nie pomiarami samych żądań sieciowych. Wpisanie i zatwierdzenie frazy zajęło automatyzacji dodatkowo około 1,7 s. Powodzenie XCTest oznacza wykonanie obserwacji, nie spełnienie oczekiwań dotyczących trafności i godzin.

Materiały: `/private/tmp/NaviAstraLiveFuelSearch174Run2.xcresult`, `/private/tmp/naviastra-live-fuel-search-174-run2.log`, zrzuty w `/private/tmp/naviastra-live-fuel-search-174-run2-attachments/`.

Porównanie wykonane chwilę później dla „ORLEN”, również w zakresie „Blisko mnie”, ujawniło znacznie bliższe wyniki wyszukiwania marki niż kategorii. Sam wynik marki nie potwierdza jednak typu ani aktualnej działalności obiektu. ORLEN przy Demokratycznej 125 miał 1,5 km trasą / około 5 min, a następne stacje 3,7 km / 8 min i 4,6 km / 9 min. Pierwsze ETA zaobserwowano po około 1,4 s. Nie jest to porównanie szybkości dwóch zimnych zapytań: pamięć podręczna pozostała aktywna. W wynikach ORLEN pojawiał się chwilowo komunikat „Sprawdzam godziny otwarcia…”, lecz przez około 46 s lista nie pokazała godzin; dodatkowe około 12 s w szczegółach pierwszej stacji także ich nie ujawniło.

Wniosek z urządzenia: dane dojazdu są prezentowane, ale ogólne wyszukiwanie stacji nie daje kompletnej puli pobliskich miejsc, a dostępność godzin nie spełnia oczekiwania. Sukces kompilacji i testów z kontrolowanymi odpowiedziami nie wykrywał tych braków danych w rzeczywistym użyciu.

Przegląd kodu wskazuje, że Apple i Photon dla kategorii nadal bazują na tekście zapytania; rzeczywiste pobranie kategorii w promieniu zapewnia tylko Overpass. Jego budżet obejmuje oczekiwanie na wspólną kolejkę OSM. To wyjaśnia możliwy mechanizm pomijania nazw marek, lecz log UI nie dowodzi błędu ani timeoutu konkretnego dostawcy. Wymagany kierunek naprawy: pobieranie pobliskich punktów po kategorii oraz zapewnienie źródła godzin także dla wyników bez strony placówki i identyfikatora Wikidata. W tej sesji pomiarowej nie zmieniano kodu aplikacji.

Materiały porównania: `/private/tmp/NaviAstraLiveOrlenSearch174.xcresult`, `/private/tmp/naviastra-live-orlen-search-174.log`.

Godziny — ograniczenie diagnozy: pobieranie listowe nie uzupełnia brakujących szczegółów OSM; wyniki MapKit nie mają harmonogramu ani `wikidataID`, więc bez cache i odpowiedniej strony placówki mogą pozostać bez godzin. W szczegółach część OSM jest publikowana dopiero po oczekiwaniu na Apple. Zrzut końcowy ORLEN nadal pokazuje „Uzupełnianie informacji…”, dlatego dodatkowych 12 s nie wolno traktować jako zakończonej próby pobierania szczegółów. Z samych obserwacji nie ustalono, czy źródło nie miało danych, odpowiedź była opóźniona, czy nie udało się jej dopasować.

Tymczasowy plik obserwacji UI usunięto z projektu po pomiarach; jego kopie zachowano z materiałami w `/private/tmp/`. Nie zmieniano wersji aplikacji.

Dodatkowy zrzut po zakończeniu obserwacji, o 18:33, pokazał już zakończone ładowanie szczegółów ORLEN: „Godziny otwarcia niedostępne” oraz „Szczegóły miejsca z OpenStreetMap są chwilowo niedostępne”, z przyciskiem „Spróbuj ponownie”. Potwierdza to zgłoszenie niedostępności OSM w tej próbie; nie identyfikuje technicznej przyczyny błędu. Zrzut: `/private/tmp/naviastra-orlen-after-audit.png`.


## Naprawa po pomiarze — wersja 1.1.174 (176)

- Kategorie na iOS otrzymują niezależne wyszukiwanie Apple przez `MKLocalPointsOfInterestRequest` z filtrem kategorii oraz wyszukiwanie Photon `/reverse` z `osm_tag`, bez wymagania dopasowania nazwy do tekstu „stacja benzynowa”. Apple respektuje swój maksymalny promień; pozostałe źródła nadal obsługują wspólne obszary 3/10/20 km.
- Pula do obliczania dojazdu jest wybierana według bliskości we właściwym obszarze, zanim zadziała limit 16 miejsc. Po otrzymaniu tras wyniki są porównywane według rzeczywistego czasu dojazdu. Odległość geometryczna nie jest prezentowana jako drogowa ani jako ETA.
- Wiersze stacji bez godzin współdzielą krótkie okno 150 ms i zbiorcze pobranie OSM (do ośmiu obiektów). Tożsamość oddziału musi być potwierdzona; nie przyjmujemy „24/7” na podstawie samej marki. Dane i niepowodzenia mają odrębne okresy cache, a anulowanie pojedynczego wiersza nie anuluje danych dla pozostałych.
- Trwające pobieranie danych mapy nie zajmuje już jedynego miejsca w kolejce dla interaktywnego wyszukiwania. Pozostają wspólny odstęp startów, ograniczona współbieżność i obsługa limitów serwera.
- Szczegóły miejsca publikują odpowiedzi OSM i Apple niezależnie. Gotowe godziny OSM nie czekają na dodatkowe dane kontaktowe Apple.

Weryfikacja symulatora: **43 testy w 6 zestawach przeszły** (`/private/tmp/NaviAstraFuelHours176Critical.xcresult`). Sprawdzono lokalność, kontekst GPS, rzeczywiste szacunki dojazdu, odzyskiwanie tras, prawidłowe dopasowanie godzin do oddziału, współdzielenie pobierania, ważność danych i anulowanie kolejki. Chronione pliki macOS pozostały bez zmian.

Źródło kontraktu Photon: [oficjalna dokumentacja API](https://github.com/komoot/photon/blob/master/docs/api-v1.md). Zmiany kodu nie stanowią gwarancji dostępności publicznych serwerów. Pomiar urządzenia opisuje osobno rzeczywisty efekt.


## Naprawa godzin i ponowne pomiary — kompilacje 176–178

Po jawnym zainstalowaniu 1.1.174 (176) telefon pokazał BP przy Kolumny i Carrefour przy Rzgowskiej, obie około 1 km trasą / 4 min. Pierwsze wyniki z dojazdem zaobserwowano po 1,38 s. To potwierdziło poprawę lokalności względem 6,3 km / 13 min w kompilacji 174. Godzin nadal nie było przez 45 s. Kompilacja 177 zachowała ten efekt; 46 testów krytycznych przeszło. Publiczne źródła Overpass podczas prób były niedostępne.

Dodano wąski odczyt Nominatim `/lookup` po już znanych, typowanych identyfikatorach OSM stacji. To nie jest dodatkowe wyszukiwanie nazw. Odpowiedź musi wskazywać `amenity=fuel`, ten sam identyfikator, zgodne położenie do 150 m oraz adres bez konfliktu. Dane grupowane są maksymalnie po osiem obiektów. Odstęp startów wynosi przynajmniej 1,1 s, działa cache, timeout, identyfikacja aplikacji i obsługa ograniczeń serwera. Nominatim może publikować godziny niezależnie od wolnego Overpass. Nie zakłada się całodobowego działania na podstawie marki.

Dokumentacja: [Nominatim Lookup](https://nominatim.org/release-docs/latest/api/Lookup/) i [zasady publicznej usługi](https://operations.osmfoundation.org/policies/nominatim/). Limit publicznego serwera dotyczy łącznego ruchu aplikacji, nie pojedynczego telefonu. Przed wdrożeniem dla wielu użytkowników trzeba skierować `nominatimLookupServer` na własny serwer lub współdzielony, limitowany proxy. Obecne ograniczenie w kliencie obsługuje pojedyncze urządzenie; nie gwarantuje limitu całej instalacji wieloużytkownikowej.

W 1.1.176 (178), z potwierdzoną wersją zainstalowanego pakietu, pierwsze wyniki i godziny Carrefour („Otwarte · zamyka o 22:00”) pojawiły się po 1,67 s. BP pokazało „Otwarte całą dobę” dopiero przy obserwacji 16,04 s. Pomiar ujawnił drugi problem: kolejna grupa znanych identyfikatorów czekała za wolnym zapytaniem obszarowym poprzedniej grupy. W poprawce 179 te odczyty mają oddzielne kolejki. Zachowano anulowanie, współdzielenie żądań i limity publicznej usługi.

Dodatkowo poprawiono klucze żądań i walidację cache: ten sam identyfikator z rozbieżnym adresem lub położeniem nie może otrzymać godzin innego dopasowania. Godziny pochodzące ze strony lub Wikidata zachowują krótszy okres ważności i oryginalne pochodzenie. Testy krytyczne obejmują te przypadki.

Uzupełnienie Apple zapytaniem kategorii „gas station” ujawniło wyniki bez potwierdzonej kategorii (m.in. nazwę miasta jako tytuł). Od 179 wymagane jest jawne `pointOfInterestCategory == .gasStation`; brak kategorii nie staje się stacją przez sam filtr żądania. Nadal nie deklaruje się kompletności wszystkich stacji w okolicy.

Materiały: `/private/tmp/NaviAstraLiveFuel176NoBuild.xcresult`, `/private/tmp/NaviAstraFuelHours177Final.xcresult`, `/private/tmp/NaviAstraFuelHours178Final.xcresult`. Pomiar 178 używał normalnego cache, bez czyszczenia. 49 testów krytycznych w sześciu zestawach przeszło.


## Pomiar 179 i weryfikacja danych Apple

Wersja 1.1.177 (179) została jawnie zainstalowana i potwierdzona na urządzeniu. **52 testy krytyczne w sześciu zestawach przeszły**. W 45-sekundowej obserwacji listy BP i Carrefour miały godziny już w pierwszym odczycie po zakończeniu wpisywania i zatwierdzenia; drogowe ETA były widoczne przy odczycie 2,23 s. Wpisywanie zajęło dodatkowo 1,38 s. Nie jest to pomiar zimnego cache godzin: mimo wcześniejszego odświeżenia, przed uruchomieniem próby cache ponownie zawierał godziny ze znacznikami 19:28–19:29. 

Po 45 s listy i 12 s szczegółów, podczas dodatkowego wpisywania ORLEN, połączenie CoreDevice/XPC zostało przerwane. Całe uruchomienie UI nie zakończyło się powodzeniem (xcodebuild 65). Zachowano wcześniejsze obserwacje i zrzuty; nie utożsamia się ich z ukończonym testem całego przepływu. Kolejny test diagnostyczny surowych danych Apple został uruchomiony i zakończony.

Surowe dane wykazały, że zapytanie pobliskich POI zwróciło tylko trzy stacje, a tekstowe wyszukiwanie kategorii „gas station” również ORLEN przy Demokratycznej 125. Wszystkie miały potwierdzony typ stacji. Brak ORLEN w widocznych pierwszych ośmiu wynikach nie oznacza więc automatycznie pominięcia źródła: kandydaci są ograniczani do 16 przed obliczeniem tras, a lista do ośmiu po rankingu. Równe etykiety „~5 min” mogą oznaczać różne czasy 241–300 s. Nie przeprowadzono pełnej walidacji katalogu ani rankingu wszystkich kandydatów.

Apple przekazało również nazwę „Łódź” dla stacji przy Kolumny 25. Końcowa poprawka zastępuje tytuł identyczny z nazwą miasta etykietą „Stacja paliw”, tylko dla potwierdzonej kategorii paliw. Nie przypisuje marki ani nie zmienia identyfikatora, adresu i położenia. Dostawcy nadal mogą zwracać różne nazwy pobliskich obiektów; nie scala się ich wyłącznie na podstawie zbliżonych współrzędnych.

Materiały: `/private/tmp/NaviAstraFuelHours179Final.xcresult`, `/private/tmp/naviastra-179-verification.log`, `/private/tmp/naviastra-179-attachments/`.
