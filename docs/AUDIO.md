# Audio i komunikaty głosowe

Dokument opisuje bieżącą implementację dźwięku w NaviAstra. Audio aplikacji służy do syntezy komunikatów nawigacyjnych przez `AVSpeechSynthesizer`. Nie ma tu odtwarzacza muzyki, plików dźwiękowych ani nagrywania z mikrofonu.

## Przepływ komunikatu

1. `NavigationEngine.updateProgress()` oblicza pozycję na trasie i sprawdza, czy pojawił się manewr, ostrzeżenie drogowe albo zdarzenie w podróży komunikacją.
2. Jeśli komunikaty są włączone, silnik głosowy sprawdza odległość oraz klucz deduplikacji. Ten sam etap tego samego komunikatu nie jest powtarzany przy każdym pomiarze GPS.
3. Silnik tworzy `AVSpeechUtterance` z polskim głosem `pl-PL` i przekazuje go do `AVSpeechSynthesizer`.
4. Na iOS przed syntezą aktywowana jest sesja audio. Na macOS syntezator jest wywoływany bez `AVAudioSession`.

Instrukcja manewru pochodzi z modelu trasy. Aplikacja używa własnej polskiej nazwy manewru, jeśli ją ma, w przeciwnym razie tekstu dostawcy trasy. Do wybranych manewrów dodaje nazwę ulicy.

## Jakie komunikaty są wypowiadane

### Manewry na trasie drogowej

Manewr może mieć trzy etapy. Prędkość przekazywana do obliczeń jest wyrażona w metrach na sekundę.

| Etap | Warunek odległości od manewru | Początek komunikatu |
|---|---|---|
| Wcześniejsza zapowiedź | do `max(200 m, min(1200 m, prędkość × 24 s))` | „Za … metrów …” |
| Bliższa zapowiedź | do `max(80 m, prędkość × 8 s)` | „Za … metrów …” |
| Manewr teraz | do 35 m | Sama instrukcja manewru |

Każdy etap danego manewru jest zapowiadany najwyżej raz do resetu silnika głosowego. Przy wypowiedzeniu manewru aplikacja natychmiast przerywa poprzednią wypowiedź, jeśli syntezator nadal mówi. Odległość w prefiksie jest zaokrąglana w dół do wielokrotności 50 m; przy odległości poniżej 50 m prefiks może więc brzmieć „Za 0 metrów”.

### Ostrzeżenia drogowe

Głosowo zapowiadane są tylko typy oznaczone jako egzekwowanie przepisów — fotoradary, początki i końce odcinkowego pomiaru oraz rejestracja przejazdu na czerwonym świetle — oraz `speedLimitChange`. Ostrzeżenie może zostać wypowiedziane przy dystansie do 1200 m, ponownie do 250 m i bez prefiksu do 40 m. Dla zmiany limitu tekst zawiera nową wartość, jeśli jest dostępna.

Pozostałe typy alertów drogowych, takie jak wypadek, roboty drogowe, zamknięcie drogi czy zmienny limit, nie przechodzą obecnie filtra komunikatu głosowego.

Przełącznik „Ostrzegaj o przekroczeniu limitu” steruje wizualnym oznaczeniem przekroczenia na karcie prędkości. Samo przekroczenie limitu nie uruchamia komunikatu głosowego. Głosowe zapowiedzi dotyczą alertów przypisanych do trasy, a nie porównania bieżącej prędkości z limitem.

### Komunikacja miejska i pociągi

Podczas aktywnej nawigacji w trybie „Komunikacja” aplikacja wypowiada:

- wskazówkę dojścia dla aktualnego odcinka pieszego, raz na dany odcinek podróży;
- informację o wysiadaniu dwa przystanki przed celem odcinka;
- przypomnienie o wysiadaniu na następnym przystanku;
- informację o linii i kierunku kolejnej przesiadki, jeśli występuje;
- „Dotarłeś do celu”, gdy zaakceptowana pozycja GPS znajduje się do 45 m od celu.

Zapowiedzi o wysiadaniu są wypowiadane dopiero po potwierdzeniu, że użytkownik znajduje się w pojeździe. Zdarzenia są deduplikowane osobno dla odcinka, kursu i etapu wysiadania.

Trasa P+R zawiera odcinek samochodowy i odcinki komunikacyjne, ale nie przechodzi przez gałąź komunikatów zarezerwowaną dla trybu `.transit`. Ma ogólne prowadzenie oparte na manewrach trasy; kod tej ścieżki nie planuje dla P+R wypowiedzi o dojściu, wysiadaniu, przesiadce ani komunikatu o dotarciu do celu z gałęzi komunikacyjnej.

### Przyjazd innymi trasami

W zwykłej nawigacji drogowej, pieszej lub rowerowej warunek dotarcia kończy prowadzenie i resetuje syntezator. Osobny głosowy komunikat o dotarciu jest obecnie zaimplementowany dla trybu „Komunikacja”, nie dla tych trybów.

## Sterowanie

- `voiceEnabled` domyślnie ma wartość `true`.
- Przełącznik „Komunikaty głosowe” jest dostępny w ustawieniach oraz jako przycisk głośnika podczas nawigacji. Oba sterują tą samą wartością stanu.
- Wartość nie jest zapisywana w `UserDefaults` ani `AppStorage`. Po utworzeniu nowego `NavigationState` komunikaty są domyślnie włączone.
- Wyłączenie komunikatów blokuje kolejne wywołania zapowiedzi. Nie wywołuje `stopSpeaking`, więc wypowiedź już rozpoczęta — lub oczekująca na aktywację sesji iOS — może jeszcze się odezwać.
- `voice.reset()` jest wywoływane przy rozpoczęciu nawigacji, jawnym zakończeniu przez `stop()`, dotarciu do celu na trasie drogowej/pieszej/rowerowej oraz po udanym przeliczeniu trasy. Czyści deduplikację i zatrzymuje bieżącą mowę. Na iOS reset dodatkowo kolejkuje dezaktywację sesji audio. Przyjazd w trybie komunikacji najpierw wypowiada komunikat o dotarciu i nie wykonuje w tym miejscu resetu.

## iOS, macOS i sesja audio

Na iOS `VoiceGuidanceEngine` ustawia kategorię `AVAudioSession` na `.playback`, tryb `.spokenAudio` i opcję `.duckOthers`, po czym aktywuje sesję przed przekazaniem tekstu do syntezatora. Operacje zmiany sesji są wykonywane kolejno. Aktywacja i żądania mowy mają liczniki generacji, które pozwalają odrzucić spóźnioną operację po resecie lub nowszym komunikacie.

Konfiguracja iOS deklaruje tło `audio` w `UIBackgroundModes`. W połączeniu z sesją `.playback` jest to konfiguracja używana do komunikatów audio, gdy nawigacja działa w tle. Tryb komunikacji prosi dodatkowo o uprawnienie do lokalizacji w tle.

Jeśli konfiguracja lub aktywacja sesji iOS zakończy się błędem albo aktywacja zwróci `false`, bieżący komunikat jest pomijany. Błąd nie jest pokazywany użytkownikowi i nie ma jawnego ponowienia ani awaryjnego wywołania syntezatora poza sesją.

Na macOS aplikacja wywołuje `AVSpeechSynthesizer.speak` bez konfiguracji sesji audio. Kod nie ustawia osobno głośności, tempa mowy ani urządzenia wyjściowego; wybór wyjścia pozostaje po stronie systemu. Dla obu platform ustawiany jest język `pl-PL`; dostępność konkretnego głosu zależy od systemu.

## Mapa implementacji

| Obszar | Plik i symbol |
|---|---|
| Stan domyślny przełącznika | [`NavigationEngine.swift`](../NaviAstra/Navigation/NavigationEngine.swift#L35) — `NavigationState.voiceEnabled` |
| Synteza, deduplikacja i sesja audio | [`NavigationEngine.swift`](../NaviAstra/Navigation/NavigationEngine.swift#L344) — `VoiceGuidanceEngine` |
| Wyznaczanie treści mowy dla manewrów | [`Models.swift`](../NaviAstra/Navigation/Models.swift#L163) — `Maneuver.spokenInstruction` |
| Wywołania dla manewrów, alertów, przyjazdu i przesiadek | [`NavigationEngine.swift`](../NaviAstra/Navigation/NavigationEngine.swift#L1443) — `updateProgress()` i `updateTransitVoice(for:journey:)` |
| Kontrolki komunikatów | [`ContentView.swift`](../NaviAstra/ContentView.swift#L1640) — przycisk podczas prowadzenia; sekcja „Prowadzenie i ostrzeżenia” znajduje się w tej samej karcie ustawień |
| Tryby audio i lokalizacji działające w tle na iOS | [`NaviAstra-iOS-Info.plist`](../Config/NaviAstra-iOS-Info.plist) |
