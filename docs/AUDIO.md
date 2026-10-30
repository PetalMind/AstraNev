# Audio i komunikaty głosowe

Dokument opisuje obsługę głosu w aplikacji iOS: automatyczne komunikaty nawigacyjne, polecenia i dialog asystenta, Skróty oraz wspólną sesję audio. Aplikacja korzysta z `AVSpeechSynthesizer` i polskiego rozpoznawacza `SFSpeechRecognizer`. Mikrofon uruchamia się po wybraniu przycisku lub odpowiedniego Skrótu; aplikacja nie nasłuchuje stale słowa wybudzającego.

## Architektura

```text
NavigationSession.updateProgress()
        ↓
VoiceGuidanceEngine
  treść, progi, preferencje, klucze zdarzeń
        ↓
VoiceAnnouncementScheduler
  priorytety, kolejka, przerwania, odstęp, deduplikacja
        ↓
VoiceAudioCoordinator + AVSpeechSynthesizer → AVAudioSession

Mikrofon na mapie
        ↓
SearchSpeechInput → VoiceCommandParser → VoiceAssistant
                                         ↓
                      VoiceNavigationActions / NavigationStore
                                         ↓
                      VoiceAudioCoordinator → odpowiedź głosowa

Uwierzytelniony Skrót → VoiceIntentBridge → VoiceAssistant.open/submit
```

`NavigationSession` dostarcza kontekst GPS i trasę. `VoiceGuidanceEngine` zamienia go na komunikaty, a prywatny `VoiceAnnouncementScheduler` ustala ich kolejność. `VoiceAudioCoordinator` rozdziela dostęp do audio między mikrofon, prowadzenie i odpowiedzi asystenta. Pytania odczytują aktualny stan podróży; zmiany celu, postojów i preferencji przechodzą przez potwierdzenie w `VoiceAssistant` oraz istniejącą sesję nawigacji.

## Etap 1 — polecenia, pytania i panel na mapie

Przycisk mikrofonu w dolnej grupie narzędzi mapy otwiera kompaktowy pasek rozmowy przy dolnej krawędzi. Na czas rozmowy pasek zastępuje dolny panel, zachowując jego stan i przewijanie; nie zajmuje miejsca przy manewrach. Dwuwierszowy podgląd pokazuje bieżącą wypowiedź lub odpowiedź. Dotknięcie tekstu otwiera pełną treść w arkuszu. Przyciski potwierdzenia nazywają czynność, np. „Dodaj postój” lub „Zmień cel”; głosowe „tak” działa jak wcześniej. Są też anulowanie, następna propozycja i zamknięcie rozmowy. Pola dotykowe mają co najmniej 44 pkt, a powierzchnia respektuje ograniczenie przezroczystości i zwiększony kontrast.

Pasek odróżnia przygotowanie mikrofonu, rzeczywiste słuchanie, kończenie rozpoznawania, obliczanie i odpowiedź. Gotowość sygnalizuje dopiero po uruchomieniu silnika audio; rozpoznawacz otrzymuje strumień od jego początku. Słupki reagują na zmierzony poziom PCM, nie na zapętloną animację. Dotknięcie słupków kończy wypowiedź i czeka na wynik końcowy — nie wykonuje widocznego tekstu częściowego. Wykorzystywany jest tryb dyktowania i kontekst pełnych poleceń, w tym „znajdź stację paliw po trasie”. Sam fragment „stację paliw” nie dopowiada brakującej intencji.

| Obszar | Przykłady obsługiwanych poleceń |
|---|---|
| Cel i prowadzenie | „Prowadź do domu”, „Prowadź do pracy”, „Prowadź do Gdańska, ul. Długa 12”, „Rozpocznij nawigację”, „Zakończ nawigację” |
| Czas i odległość | „Kiedy dojadę?”, „Ile kilometrów zostało?”, „Ile czasu zostało?” |
| Najbliższy manewr | „Powtórz”, „Który pas?”, „Który zjazd z ronda?” |
| Ruch | „Czy są korki?”, „Jakie są utrudnienia?” |
| Komunikacja miejska | „Za ile wysiadam?”, „Gdzie mam przesiadkę?”, „Jaka jest następna linia?” |
| Komunikaty i mapa | „Wycisz komunikaty”, „Włącz głos”, „Mów mniej”, „Mów więcej”, „Mów wolniej”, „Pokaż całą trasę”, „Wróć do prowadzenia” |

Parser rozpoznaje określone pełne polskie frazy i ich warianty. Nie wykonuje poleceń na podstawie pojedynczego znalezionego słowa: samo „stop” lub „zakończ” nie kończy podróży. Nazwy własne i adresy pozostają w oryginalnym zapisie. Dom i praca są rozwiązywane na podstawie zapisanych miejsc.

„Powtórz” odczytuje manewr dla bieżącej pozycji, a nie ostatnie nagranie. Odpowiedzi wymagają aktualnej pozycji, postępu dla bieżącej trasy oraz, dla trasy drogowej, wiarygodnego dopasowania do jej geometrii. Brak pasów, numeru zjazdu lub danych o ruchu daje polski komunikat o niedostępności. Dane ruchu starsze niż 180 sekund nie służą do odpowiedzi; brak pomiarów nie jest interpretowany jako brak korków. W komunikacji rozkład jest odróżniany od danych bieżących.

W trybie poleceń częściowa transkrypcja służy wyłącznie do wyświetlania. Polecenie może zostać przekazane najwyżej raz i wyłącznie po wyniku oznaczonym przez rozpoznawacz jako końcowy (`isFinal`). `VoiceRecognitionDeliveryGate` odrzuca wyniki częściowe, duplikaty i spóźnione wyniki wcześniejszej sesji.

Automatyczne zakończenie wypowiedzi wymaga jednocześnie co najmniej 2,5 sekundy bez aktualizacji transkrypcji oraz bez aktywności w bieżących buforach PCM mikrofonu. Sama przerwa w dostarczaniu transkrypcji nie wystarcza. `VoiceRecognitionEndpointPolicy` sprawdza też, czy bufory audio nadal napływają. Po wykryciu ciszy albo ręcznym zakończeniu aplikacja zatrzymuje dopisywanie audio, wywołuje `endAudio()` i czeka do 6 sekund na wynik końcowy; samo zakończenie audio nie wykonuje polecenia. Mikrofon zachowuje rezerwację sesji audio, aby komunikat nawigacji nie dostał się do rozpoznawanego wejścia. Nasłuch ma limit 30 sekund; po przejściu do finalizacji obowiązuje osobny limit 6 sekund. Przekroczenie limitu kończy próbę polskim komunikatem i nigdy nie wykonuje ostatniego częściowego wyniku. Głośne otoczenie może opóźnić wykrycie ciszy.

## Etap 2 — wybór miejsc i zmiany podróży

Asystent odczytuje do trzech propozycji pojedynczo. „Następna” lub „Wybierz drugą” przełącza propozycję, a „Tak” potwierdza wskazany cel albo postój. „Anuluj” odrzuca oczekujące polecenie. Adres można poprawić frazą „Nie, chodziło o Kraków” albo „Popraw adres na Kraków, Wawel”; poprawka uruchamia wyszukiwanie celu.

| Zmiana | Obsługiwane przykłady i zachowanie |
|---|---|
| Postój po drodze | „Znajdź stację paliw po trasie”, „Dodaj ładowarkę”, „Znajdź restaurację po drodze”, „Znajdź MOP po trasie” — odczyt propozycji i potwierdzenie dodania |
| Miejsce przy celu | „Znajdź parking przy celu” — wyszukiwanie w okolicy celu; wybrany wynik jest dodawany jako postój |
| Usunięcie postoju | „Usuń następny postój” — nazwa kolejnego nieodwiedzonego ręcznego postoju i, jeśli dostępny, nowy czas podróży przed potwierdzeniem |
| Preferencje | „Omijaj autostrady”, „Wybierz trasę bez opłat” — propozycja czasu dalszej jazdy przed zastosowaniem ustawienia |

Postoje są obsługiwane dla samochodu, roweru i marszu; zmiana preferencji autostrad/opłat dotyczy samochodu. Podany dodatkowy czas przejazdu pochodzi z obliczeń trasy. Jeśli znany jest tylko czas dojazdu do miejsca, asystent wyraźnie odróżnia go od dodatkowego czasu całej podróży. Nieobsługiwane dodatkowe filtry, np. „najtańszy”, nie są po cichu pomijane przez parser.

Propozycja czasu po zmianie preferencji lub usunięciu postoju korzysta z pełnego `calculateRoutes` w odizolowanej sesji. Zachowuje dostawcę tras, ustawienia pojazdu, potwierdzone zamknięcia oraz kontekst baterii EV; uwzględnia ponowne planowanie ładowania. Podczas prowadzenia punktem początkowym jest aktualny GPS, a lista postojów obejmuje pozostałą część podróży. W podglądzie używany jest wybrany punkt początkowy, ręczne postoje i zaplanowany czas wyjazdu lub przyjazdu, z odpowiednią strefą czasową. Samo obliczenie propozycji nie zmienia aktywnej podróży, zapisanych preferencji, punktów dojazdu ani historii i nie publikuje diagnostyki czy ocen personalizacji. Zatwierdzenie ponownie przelicza trasę; wynik może różnić się od propozycji po zmianie warunków.

Rozpoczęcie i zakończenie prowadzenia, zmiana celu, dodanie/usunięcie postoju oraz zastosowanie preferencji wymagają „Tak”. Odpowiedzi na pytania, regulacja mowy i sterowanie mapą nie wymagają potwierdzenia. Po pytaniu asystenta nasłuch może wznowić się bez ponownego dotykania ekranu dopiero wtedy, gdy syntezator potwierdzi zakończenie całej odpowiedzi przez `didFinish`.

Potwierdzenie oraz lista propozycji są przypisane do celu, trasy, postojów, preferencji, trybu i stanu podróży. Wygasają po 90 sekundach lub przy zmianie tego kontekstu. Powtórzone „Tak” nie uruchamia ponownie tej samej zmiany. Błąd rozpoznawania, przerwanie nasłuchu lub zamknięcie panelu usuwa oczekujący dialog. Przerwana albo niedokończona odpowiedź asystenta również usuwa potwierdzenie i propozycje; nie włącza automatycznie mikrofonu. Już zatwierdzona i rozpoczęta zmiana trasy kończy swoje obliczenia również po zamknięciu panelu.

## Etap 3 — Skróty, rozpoznawanie offline i blokada ekranu

`NaviAstraVoiceShortcuts` udostępnia: „Rozmowa głosowa”, „Do domu”, „Do pracy”, „Czas dojazdu” oraz „Wycisz komunikaty”. Akcja „Ustaw wyciszenie nawigacji” pozwala również ustawić parametr wyciszenia na wyłączony. Wszystkie intencje otwierają aplikację na pierwszym planie, wymagają uwierzytelnienia (`requiresAuthentication`) i są wykonywane w procesie głównej aplikacji. Nie ma intencji kończącej podróż ani potwierdzającej oczekującą zmianę.

`VoiceIntentBridge.attach(assistant:)` podłącza asystenta. `enqueue(_:)` przechowuje najnowsze żądanie, jeżeli aplikacja dopiero się uruchamia. `resumePendingRequest()` dostarcza je dokładnie raz po podłączeniu asystenta, aktywacji aplikacji i udostępnieniu chronionych danych. Obsługują to zdarzenia cyklu życia, bez stałego opóźnienia startu. Nowsze żądanie zastępuje wcześniejsze, jeszcze niedostarczone.

Polskie nazwy i frazy Skrótów nie oznaczają gwarancji polskojęzycznej obsługi przez Siri. Dostępność Siri zależy od języków i funkcji udostępnianych przez system. Własny asystent NaviAstry rozpoznaje i odpowiada po polsku; akcje są także dostępne w aplikacji Skróty.

W ustawieniach, w sekcji „Polecenia głosowe”, przełącznik „Rozpoznawaj tylko na urządzeniu” zapisuje `voiceOfflineOnly`. Włączony wymaga `supportsOnDeviceRecognition` dla polskiego rozpoznawacza i ustawia `requiresOnDeviceRecognition`; przy braku obsługi aplikacja odmawia uruchomienia zamiast przejść na sieć. Wyłączony pozostawia wybór przetwarzania systemowi Apple, bez wymuszania rozpoznawania lokalnego; nagranie może być przetwarzane przez Apple przez internet. Wyszukiwanie nowych miejsc i obliczanie tras nadal może wymagać internetu.

Mikrofon asystenta działa wyłącznie przy aktywnej aplikacji i dostępnych chronionych danych. Przejście w tło lub blokada ekranu kończy rozmowę, usuwa potwierdzenia i zatrzymuje nasłuch. Powrót nie włącza mikrofonu samoczynnie; potrzebne jest kolejne jawne uruchomienie. Automatyczne komunikaty już aktywnej nawigacji nadal mogą działać w tle, zgodnie z uprawnieniami i systemową obsługą audio. Nie wdrożono stałego nasłuchu ani rozmowy z asystentem przez zablokowany ekran.

## Głosowe wyszukiwanie

Wyszukiwarka prosi system o osobne uprawnienia do rozpoznawania mowy i mikrofonu dopiero po dotknięciu przycisku mikrofonu. `SFSpeechRecognizer` używa polskiego locale, a rozpoznawane fragmenty na bieżąco uzupełniają pole zapytania i uruchamiają standardowe wyszukiwanie. Ponowne dotknięcie przycisku albo zamknięcie wyszukiwarki kończy nasłuchiwanie. Wymagane opisy prywatności są skonfigurowane dla iOS.

## Źródła i rodzaje komunikatów

### Manewry

Dystans, prędkość i złożoność manewru wyznaczają trzy etapy przez `GuidanceQualityEngine`. Poniższe progi dotyczą samochodu; `v` to prędkość w metrach na sekundę, a `c` to złożoność uwzględniająca m.in. węzły, ronda, liczbę pasów i bliskie kolejne skręty.

| Etap | Warunek | Tekst |
|---|---|---|
| Wcześniejszy | do `max(200, min(1500, v × (24 + 5c)))` m | „Za … metrów …” |
| Bliższy | do `max(80, min(próg wcześniejszy × 0,6, v × (8 + 3c)))` m | „Za … metrów …” |
| Bezpośredni | do `min(45, max(20, v × 1,5))` m | Sama instrukcja manewru |

Poza samochodem wcześniejszy próg wynosi `max(45, min(150, v × 24))` m, bliższy `max(20, v × 8)` m, a bezpośredni 12 m. Odległość we wcześniejszych etapach jest zaokrąglana w dół do 50 m. Prefiks jest pomijany poniżej 50 m, więc system nie wypowie „Za 0 metrów”. Tryb „Mała” pomija etap bliższy. Treść korzysta z instrukcji dostawcy dla odpowiedniego etapu albo z `Maneuver.spokenInstruction`; wcześniejsze etapy mogą dodawać wskazówkę pasów. Wjazd na rondo ma jeden klucz zapowiedzi, a bezpośredni komunikat zjazdu usuwa nieaktualną zapowiedź wjazdu z kolejki.

### Alerty drogowe i zdarzenia ruchu

Alerty trasy (`RoadSafetyAlert`) są kwalifikowane według typu ustawieniem gadatliwości. Obsługiwane są: fotoradar, początek i koniec odcinkowego pomiaru, kamera na czerwonym świetle, zmiana i zmienny limit, wypadek, roboty drogowe, zamknięcie, korek, przejazd kolejowy, strefa szkolna i niebezpieczny zakręt. Zmiana limitu wypowiada jego wartość, jeśli dostawca ją podał.

Etapy alertu: do 1200 m, do 250 m i bezpośrednio do 40 m. Alerty drogowe są dopasowane do geometrii trasy.

Incydenty ruchu (`TrafficIncident`) mogą dodać wypadek, mgłę, niebezpieczne warunki, deszcz, oblodzenie, korek, zamknięty pas/drogę, roboty, wiatr, podtopienie, objazd lub unieruchomiony pojazd. Incydent musi być z aktualnego, maksymalnie 180-sekundowego obrazu ruchu i znajdować się przed użytkownikiem, w odległości do 1200 m. Gdy dostawca nie podał dystansu po trasie, geometria musi dać się dopasować do trasy z tolerancją 120 m. W trybie „Szczegółowa” komunikat o korku zawiera również opóźnienie, jeśli jest dostępne.

### Komunikacja i dojście

Aktywna podróż komunikacją ogłasza dojście do kolejnego przystanku lub celu, przesiadkę, linię i kierunek oraz wysiadanie dwa przystanki przed przystankiem docelowym i na następnym przystanku. Zapowiedzi wysiadania wymagają potwierdzenia jazdy pojazdem na podstawie postępu, prędkości lub aktualnej pozycji pojazdu. Zapowiedź na następnym przystanku ma priorytet manewru bezpośredniego.

### Przyjazd i przeliczenie trasy

Przyjazd przechodzi przez wspólną metodę `arriveAtDestination()` i wypowiada komunikat dostosowany do trybu, np. „Cel osiągnięty samochodem.”, o ile głos jest włączony. Komunikat ma priorytet krytyczny. Wykrycie przyjazdu należy do postępu nawigacji, niezależnie od otwarcia panelu asystenta.

Po udanym przeliczeniu trasy jest dodawana informacja „Trasa została przeliczona”. Reset po reroutingu zachowuje zakończone klucze semantyczne, a usuwa kolejkę i bieżącą wypowiedź. Dzięki temu ten sam manewr lub alert nie wraca tylko dlatego, że provider nadał trasie nowe ID.

## Kolejka, priorytety i deduplikacja

Scheduler porządkuje wypowiedzi według priorytetów (od najwyższego):

1. **Krytyczny** — przyjazd, zamknięcie drogi oraz poważne, bliskie incydenty; może przerwać każdą wypowiedź.
2. **Manewr bezpośredni** — instrukcja po osiągnięciu progu bezpośredniego, ostatnie ostrzeżenie drogowe lub wysiadanie na następnym przystanku; może przerwać informację albo alert bezpieczeństwa.
3. **Nawigacja** — zapowiedź manewru, wskazówka odcinka pieszego i przeliczenie trasy.
4. **Bezpieczeństwo** — pozostałe alerty drogowe i incydenty.
5. **Informacja** — korek lub zbiorcze utrudnienie.

Priorytet bezpieczeństwa może przerwać informację. Wypowiedzi niższego priorytetu nie przerywają bieżącej. Gdy audio jest zajęte, nowe informacje są pomijane, a pozostałe trafiają do uporządkowanej kolejki. Dla wypowiedzi poza krytycznymi i bezpośrednimi scheduler zachowuje odstęp 2,5 sekundy po zakończonej mowie.

Klucz `pending` blokuje dodanie tego samego zdarzenia drugi raz podczas oczekiwania lub mówienia. Po callbacku `didStart` klucz jest już traktowany jako zużyty, dzięki czemu przerwanie przez pilniejszy komunikat nie uruchamia pętli powtórzeń przy kolejnym GPS. Callback `didFinish` kończy wypowiedź, a błąd aktywacji sesji, watchdog bez startu i anulowanie przed rozpoczęciem zwalniają klucz, pozwalając na ponowienie. Watchdog kończy próbę, jeśli syntezator nie rozpocznie jej w ciągu 8 sekund.

Manewry są deduplikowane semantycznie na podstawie rodzaju, znormalizowanej nazwy ulicy i przybliżonej lokalizacji, osobno dla każdego etapu. Alerty i incydenty drogowe używają wspólnego klucza typu oraz przybliżonej lokalizacji i etapu, więc to samo zdarzenie nie wraca przy zmianie ID dostawcy ani między źródłami. Klucze zakończonych i rozpoczętych wypowiedzi przetrwają rerouting; rozpoczęcie nowej nawigacji czyści je.

W iOS oczekująca wypowiedź wymaga aktualnego potwierdzenia przez źródło: najwyżej sprzed 2 sekund dla priorytetów krytycznego i bezpośredniego oraz 4 sekund dla pozostałych. Aktualizacje GPS odświeżają treść oczekującego zdarzenia. Przejście do późniejszego etapu usuwa wcześniejsze zapowiedzi, a zmiana następnego manewru usuwa oczekujące instrukcje poprzedniego. Po rozmowie odczytywana jest świeża instrukcja, a nie zgromadzone podczas nasłuchu zaległości.

## Ustawienia i panel audio

Preferencje są zapisywane w `UserDefaults` pod kluczami `voiceEnabled`, `voiceVerbosity`, `voiceIdentifier`, `voiceSpeechRate` i `voiceVolume`. Domyślnie głos jest włączony, tryb to „Standardowa”, tempo wynosi `0.5`, a głośność `1.0`.

Użytkownik może ustawić:

- **Gadatliwość:** „Mała”, „Standardowa” lub „Szczegółowa”. Mała pomija bliższy etap manewru, korek, zdarzenia zbiorcze i część mniej krytycznych alertów; nadal podaje wysiadanie na następnym przystanku. Standardowa pomija korki i zdarzenia zbiorcze. Szczegółowa obejmuje znane typy i podaje czas opóźnienia korka, gdy dostawca go udostępni.
- **Głos:** automatyczny polski głos systemowy albo dowolny głos z listy udostępnionej przez system, podzielonej na polskie i pozostałe języki. Lista pokazuje nazwę, język i jakość; odświeża się przy otwarciu i po powrocie do aplikacji. Komunikaty pozostają po polsku, więc głosy innych języków mogą wymawiać je z akcentem. Niedostępny zapisany identyfikator jest oznaczony w ustawieniach; synteza korzysta wtedy z automatycznego polskiego głosu. Dodatkowe głosy pobiera się w ustawieniach dostępności urządzenia.
- **Tempo:** suwak `0.38–0.62` przekazywany do `AVSpeechUtterance.rate`.
- **Głośność komunikatu:** suwak `0–1` przekazywany do `AVSpeechUtterance.volume`; nie zmienia systemowej głośności ani muzyki.

Ustawienia są w sekcji „Komunikaty głosowe”; osobna sekcja „Polecenia głosowe” zawiera ustawienie lokalnego rozpoznawania oraz objaśnienie zachowania w tle. Podczas prowadzenia przycisk głośnika przełącza mowę, a panel pod ikoną suwaków udostępnia opcje komunikatów w skrócie.

Wyłączenie głosu natychmiast zatrzymuje bieżącą wypowiedź, opróżnia kolejkę i unieważnia oczekujące aktywacje audio. Ponowne włączenie nie odtwarza anulowanych komunikatów; następne zdarzenia mogą zostać wygenerowane normalnie. Jawne zakończenie nawigacji zatrzymuje mowę i czyści deduplikację.

Wyciszenie dotyczy automatycznych komunikatów. Asystent nadal odpowiada na jawnie zadane pytanie, korzystając z wybranego głosu, tempa i głośności. Głośność ustawiona na zero wycisza także te odpowiedzi; ich tekst pozostaje widoczny w panelu.

## Wspólna sesja audio iOS

`VoiceAudioCoordinator` jest właścicielem `AVAudioSession`. Mikrofon używa `.playAndRecord`, trybu `.measurement` i opcji `.defaultToSpeaker`, `.duckOthers`, `.allowBluetoothHFP`. Mowa używa `.playback`, `.spokenAudio` i `.duckOthers`. Mikrofon, komunikat nawigacji i odpowiedź asystenta nie przejmują sesji jednocześnie. Identyfikatory właściciela i generacji odrzucają spóźnione operacje po zatrzymaniu albo zmianie rozmowy.

Zwykłe komunikaty czekają podczas krótkiej rozmowy. Krytyczna lub bezpośrednia wskazówka może przerwać mikrofon i odpowiedź asystenta; nasłuchiwanie nie uruchomi się ponownie w trakcie tej wskazówki. Nie można rozpocząć nagrywania podczas pilnego komunikatu. Rozmowa telefoniczna, zmiana dostępnego urządzenia audio albo reset usług audio kończą bieżący nasłuch czytelnym komunikatem. Ponowienie wymaga jawnej akcji użytkownika, gdy wejście jest już dostępne.

`speakReply(_:completion:)` rozróżnia zakończenie odpowiedzi od anulowania. Tylko `didFinish` zgłasza powodzenie; anulowanie, błąd aktywacji, przerwanie przez wskazówkę, zmianę urządzenia audio lub przekroczenie 30 sekund zgłasza niepowodzenie. Asystent pokazuje wtedy „Odpowiedź została przerwana”, usuwa oczekujące potwierdzenie i wymaga ponowienia polecenia. Zakończenie sesji lub samo wywołanie callbacku nie jest traktowane jako odtworzenie pytania do końca.

Jeśli aktywacja sesji się nie powiedzie lub zwróci brak aktywacji, komunikat nie jest oznaczany jako wypowiedziany. Bieżąca próba jest zwalniana i może zostać ponowiona, gdy źródło zdarzenia ponownie ją zgłosi. Błąd nie ma osobnego komunikatu w interfejsie. Konfiguracja iOS deklaruje tryb audio w tle w `UIBackgroundModes`; podróże z odcinkiem komunikacji proszą też o uprawnienie lokalizacyjne „Zawsze”.

Systemowy głos `pl-PL` może nie być dostępny — wtedy automatyczny wybór pozostaje zależny od zainstalowanych głosów.

## Mapa implementacji

| Obszar | Plik i symbol |
|---|---|
| Wyszukiwanie głosowe | [`SearchSpeechInput.swift`](../NaviAstra/Search/SearchSpeechInput.swift) — uprawnienia, przechwytywanie audio i polska transkrypcja |
| Rozpoznawanie poleceń | [`VoiceCommand.swift`](../NaviAstra/Voice/VoiceCommand.swift) — `VoiceCommand`, `VoiceQuery`, `VoiceCommandParser.parse(_:)` |
| Dialog i potwierdzenia | [`VoiceAssistant.swift`](../NaviAstra/Voice/VoiceAssistant.swift), [`VoiceAssistant+Dialog.swift`](../NaviAstra/Voice/VoiceAssistant+Dialog.swift), [`VoiceDialogContext.swift`](../NaviAstra/Voice/VoiceDialogContext.swift) — stan rozmowy, propozycje, ważność kontekstu |
| Odpowiedzi i wyszukiwanie | [`VoiceNavigationActions.swift`](../NaviAstra/Voice/VoiceNavigationActions.swift) — aktualne dane podróży, zapisane cele, propozycje postojów |
| Propozycja wariantu | [`NavigationSession+VoiceQuote.swift`](../NaviAstra/Voice/NavigationSession+VoiceQuote.swift) — `voiceRouteEstimate`, odizolowane obliczenie pełnej trasy z postojami, czasem planu i EV |
| Zmiany aktywnej podróży | [`NavigationSession+VoiceEditing.swift`](../NaviAstra/Voice/NavigationSession+VoiceEditing.swift) — zmiana celu/preferencji, dodanie i usunięcie ręcznego postoju |
| Panel i ustawienia poleceń | [`VoiceAssistantPanel.swift`](../NaviAstra/Voice/VoiceAssistantPanel.swift) — `VoiceAssistantButton`, `VoiceAssistantPanel`, `VoiceAssistantSettings` |
| Skróty i uruchomienie aplikacji | [`VoiceAppIntents.swift`](../NaviAstra/Voice/VoiceAppIntents.swift) — intencje, `NaviAstraVoiceShortcuts`, `VoiceIntentBridge` |
| Właściciel sesji audio | [`VoiceAudioCoordinator.swift`](../NaviAstra/Voice/VoiceAudioCoordinator.swift) — nasłuch, prowadzenie, odpowiedzi i przerwania |
| Ustawienia głosu i kolejka | [`VoiceGuidanceEngine.swift`](../NaviAstra/Navigation/VoiceGuidanceEngine.swift) — `VoiceGuidancePreferences`, `VoiceGuidanceEngine`, `VoiceAnnouncementScheduler` |
| Progi zapowiedzi | [`GuidanceQualityEngine.swift`](../NaviAstra/Navigation/Engine/GuidanceQualityEngine.swift) — `GuidanceQuality.stage(at:)` |
| Integracja z GPS, podróżą i przyjazdem | [`NavigationSession+Progress.swift`](../NaviAstra/Navigation/NavigationSession+Progress.swift) — `updateProgress()`, `updateJourneyVoiceProgress()`, `updateTransitVoice(for:journey:)`, `arriveAtDestination()` |
| Tekst manewru | [`Models.swift`](../NaviAstra/Navigation/Models.swift) — `Maneuver.spokenInstruction` |
| Typy alertów drogowych | [`RoadSafetyData.swift`](../NaviAstra/Navigation/RoadSafetyData.swift) — `RoadAlertType`, `RoadSafetyAlert` |
| Typy incydentów ruchu | [`TrafficProvider.swift`](../NaviAstra/Traffic/TrafficProvider.swift) — `TrafficIncidentCategory`, `TrafficIncident` |
| Panel podczas prowadzenia i ustawienia | [`ContentView+Journey.swift`](../NaviAstra/Navigation/UI/ContentView+Journey.swift) — `voiceQuickControls`; [`ContentView+MapPanels.swift`](../NaviAstra/Maps/UI/ContentView+MapPanels.swift) — przycisk mapy; [`ContentView+Settings.swift`](../NaviAstra/Settings/UI/ContentView+Settings.swift) — sekcja „Komunikaty głosowe” |
| Konfiguracja audio i lokalizacji w tle iOS | [`NaviAstra-iOS-Info.plist`](../Config/NaviAstra-iOS-Info.plist) |
