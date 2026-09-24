# Audio i komunikaty głosowe

Dokument opisuje syntezę mowy w NaviAstra: źródła zdarzeń, harmonogram wypowiedzi, priorytety, tryby podróży, ustawienia i zachowanie sesji audio. Aplikacja używa `AVSpeechSynthesizer`; nie odtwarza tu muzyki ani plików dźwiękowych i nie nagrywa mikrofonu.

## Architektura

```text
NavigationEngine.updateProgress()
        ↓
VoiceGuidanceEngine
  treść, progi, preferencje, klucze zdarzeń
        ↓
VoiceAnnouncementScheduler
  priorytety, kolejka, przerwania, odstęp, deduplikacja
        ↓
AVSpeechSynthesizer
  + AVAudioSession na iOS
```

`NavigationEngine` dostarcza kontekst GPS i trasę. `VoiceGuidanceEngine` zamienia go na komunikaty, a prywatny `VoiceAnnouncementScheduler` decyduje, czy wypowiedź może rozpocząć się teraz, czekać, przerwać inną albo zostać pominięta. Obsługa audio nie zmienia geometrii ani wyboru trasy.

## Źródła i rodzaje komunikatów

### Manewry

Dystans do następnego manewru i bieżąca prędkość wyznaczają trzy etapy. Prędkość jest w metrach na sekundę.

| Etap | Warunek | Tekst |
|---|---|---|
| Wcześniejszy | do `max(200 m, min(1200 m, prędkość × 24 s))` | „Za … metrów …” |
| Bliższy | do `max(80 m, prędkość × 8 s)` | „Za … metrów …” |
| Bezpośredni | do 35 m | Sama instrukcja manewru |

Odległość we wcześniejszych etapach jest zaokrąglana w dół do 50 m. Prefiks jest pomijany poniżej 50 m, więc system nie wypowie „Za 0 metrów”. Tryb „Mała” pomija etap bliższy. Treść pochodzi z `Maneuver.spokenInstruction` i może zawierać nazwę ulicy.

### Alerty drogowe i zdarzenia ruchu

Alerty trasy (`RoadSafetyAlert`) są kwalifikowane według typu ustawieniem gadatliwości. Obsługiwane są: fotoradar, początek i koniec odcinkowego pomiaru, kamera na czerwonym świetle, zmiana i zmienny limit, wypadek, roboty drogowe, zamknięcie, korek, przejazd kolejowy, strefa szkolna i niebezpieczny zakręt. Zmiana limitu wypowiada jego wartość, jeśli dostawca ją podał.

Etapy alertu: do 1200 m, do 250 m i bezpośrednio do 40 m. Alerty drogowe są dopasowane do geometrii trasy. Na trasie P+R dane te są pobierane dla odcinka samochodowego i ogłoszenia są aktywne tylko podczas tego odcinka.

Incydenty ruchu (`TrafficIncident`) mogą dodać wypadek, mgłę, niebezpieczne warunki, deszcz, oblodzenie, korek, zamknięty pas/drogę, roboty, wiatr, podtopienie, objazd lub unieruchomiony pojazd. Incydent musi być z aktualnego, maksymalnie 180-sekundowego obrazu ruchu i znajdować się przed użytkownikiem, w odległości do 1200 m. Gdy dostawca nie podał dystansu po trasie, geometria musi dać się dopasować do trasy z tolerancją 120 m. W trybie „Szczegółowa” komunikat o korku zawiera również opóźnienie, jeśli jest dostępne.

### Komunikacja, dojście i P+R

Aktywna podróż komunikacją ogłasza dojście do kolejnego przystanku lub celu, przesiadkę, linię i kierunek oraz wysiadanie dwa przystanki przed przystankiem docelowym i na następnym przystanku. Zapowiedzi wysiadania wymagają potwierdzenia jazdy pojazdem na podstawie postępu, prędkości lub aktualnej pozycji pojazdu. Zapowiedź na następnym przystanku ma priorytet manewru bezpośredniego.

P+R używa wspólnego postępu `JourneyLeg`: prowadzenie drogowe i alerty działają na pierwszym odcinku samochodowym, a odcinki piesze i komunikacyjne korzystają z tych samych wskazówek dojścia, potwierdzania jazdy i komunikatów o wysiadaniu co zwykła podróż komunikacją.

### Przyjazd i przeliczenie trasy

Przyjazd przechodzi przez wspólną metodę `arriveAtDestination()` i może wypowiedzieć „Dotarłeś do celu” dla każdego trybu, o ile głos jest włączony. Komunikat ma priorytet krytyczny. Odległość wykrycia wynosi do 45 m dla komunikacji i P+R; pozostałe tryby wymagają bliskości końca trasy i niskiej prędkości.

Po udanym przeliczeniu trasy jest dodawana informacja „Trasa została przeliczona”. Reset po reroutingu zachowuje zakończone klucze semantyczne, a usuwa kolejkę i bieżącą wypowiedź. Dzięki temu ten sam manewr lub alert nie wraca tylko dlatego, że provider nadał trasie nowe ID.

## Kolejka, priorytety i deduplikacja

Scheduler porządkuje wypowiedzi według priorytetów (od najwyższego):

1. **Krytyczny** — przyjazd, zamknięcie drogi oraz poważne, bliskie incydenty; może przerwać każdą wypowiedź.
2. **Manewr bezpośredni** — instrukcja do 35 m, ostatnie ostrzeżenie drogowe lub wysiadanie na następnym przystanku; może przerwać informację albo alert bezpieczeństwa.
3. **Nawigacja** — zapowiedź manewru, wskazówka odcinka pieszego i przeliczenie trasy.
4. **Bezpieczeństwo** — pozostałe alerty drogowe i incydenty.
5. **Informacja** — korek lub zbiorcze utrudnienie.

Priorytet bezpieczeństwa może przerwać informację. Wypowiedzi niższego priorytetu nie przerywają bieżącej. Gdy audio jest zajęte, nowe informacje są pomijane, a pozostałe trafiają do uporządkowanej kolejki. Dla wypowiedzi poza krytycznymi i bezpośrednimi scheduler zachowuje odstęp 2,5 sekundy po zakończonej mowie.

Klucz `pending` blokuje dodanie tego samego zdarzenia drugi raz podczas oczekiwania lub mówienia. Klucz trafia do `spoken` dopiero po callbacku `didFinish` syntezatora. Błąd aktywacji sesji, watchdog bez startu i callback anulowania zwalniają klucz, pozwalając na ponowienie. Callback `didStart` oznacza jedynie rozpoczęcie, nie sukces. Watchdog kończy próbę, jeśli syntezator nie rozpocznie jej w ciągu 8 sekund.

Manewry są deduplikowane semantycznie na podstawie rodzaju, znormalizowanej nazwy ulicy i przybliżonej lokalizacji, osobno dla każdego etapu. Alerty i incydenty używają ich stabilnego ID i etapu, a podróże — ID odcinka lub kursu. Klucze zakończonych wypowiedzi przetrwają rerouting; rozpoczęcie nowej nawigacji czyści je.

## Ustawienia i panel audio

Preferencje są zapisywane w `UserDefaults` pod kluczami `voiceEnabled`, `voiceVerbosity`, `voiceIdentifier`, `voiceSpeechRate` i `voiceVolume`. Domyślnie głos jest włączony, tryb to „Standardowa”, tempo wynosi `0.5`, a głośność `1.0`.

Użytkownik może ustawić:

- **Gadatliwość:** „Mała”, „Standardowa” lub „Szczegółowa”. Mała pomija bliższy etap manewru, korek, zdarzenia zbiorcze i część mniej krytycznych alertów; nadal podaje wysiadanie na następnym przystanku. Standardowa pomija korki i zdarzenia zbiorcze. Szczegółowa obejmuje znane typy i podaje czas opóźnienia korka, gdy dostawca go udostępni.
- **Głos:** automatyczny polski głos systemowy albo głos `pl-PL` z listy udostępnionej przez system. Niedostępny zapisany identyfikator wraca do automatycznego wyboru.
- **Tempo:** suwak `0.38–0.62` przekazywany do `AVSpeechUtterance.rate`.
- **Głośność komunikatu:** suwak `0–1` przekazywany do `AVSpeechUtterance.volume`; nie zmienia systemowej głośności ani muzyki.

Ustawienia są w sekcji „Głos i komunikaty”. Podczas prowadzenia przycisk głośnika przełącza mowę, a panel pod ikoną suwaków udostępnia te same opcje w skrócie.

Wyłączenie głosu natychmiast zatrzymuje bieżącą wypowiedź, opróżnia kolejkę i unieważnia oczekujące aktywacje audio. Ponowne włączenie nie odtwarza anulowanych komunikatów; następne zdarzenia mogą zostać wygenerowane normalnie. Jawne zakończenie nawigacji zatrzymuje mowę i czyści deduplikację.

## Platformy i sesja audio

Na iOS scheduler ustawia kategorię `AVAudioSession` na `.playback`, tryb `.spokenAudio` i opcję `.duckOthers`, aby ściszyć inne odtwarzanie na czas komunikatu. Operacje aktywacji i dezaktywacji sesji są szeregowowane. Identyfikator wypowiedzi i licznik generacji unieważniają spóźnione operacje po przerwaniu, wyciszeniu lub resecie.

Jeśli aktywacja sesji się nie powiedzie lub zwróci brak aktywacji, komunikat nie jest oznaczany jako wypowiedziany. Bieżąca próba jest zwalniana i może zostać ponowiona, gdy źródło zdarzenia ponownie ją zgłosi. Błąd nie ma osobnego komunikatu w interfejsie. Konfiguracja iOS deklaruje tryb audio w tle w `UIBackgroundModes`; podróże z odcinkiem komunikacji proszą też o uprawnienie lokalizacyjne „Zawsze”.

Na macOS `AVSpeechSynthesizer` jest wywoływany bez `AVAudioSession`; wybór urządzenia wyjściowego pozostaje po stronie systemu. Na obu platformach systemowy głos `pl-PL` może nie być dostępny — wtedy automatyczny wybór pozostaje zależny od zainstalowanych głosów.

## Mapa implementacji

| Obszar | Plik i symbol |
|---|---|
| Ustawienia głosu i kolejka | [`VoiceGuidanceEngine.swift`](../NaviAstra/Navigation/VoiceGuidanceEngine.swift) — `VoiceGuidancePreferences`, `VoiceGuidanceEngine`, `VoiceAnnouncementScheduler` |
| Integracja z GPS, podróżą i przyjazdem | [`NavigationEngine.swift`](../NaviAstra/Navigation/NavigationEngine.swift) — `updateProgress()`, `updateJourneyVoiceProgress()`, `updateTransitVoice(for:journey:)`, `arriveAtDestination()` |
| Tekst manewru | [`Models.swift`](../NaviAstra/Navigation/Models.swift) — `Maneuver.spokenInstruction` |
| Typy alertów drogowych | [`RoadSafetyData.swift`](../NaviAstra/Navigation/RoadSafetyData.swift) — `RoadAlertType`, `RoadSafetyAlert` |
| Typy incydentów ruchu | [`TrafficProvider.swift`](../NaviAstra/Traffic/TrafficProvider.swift) — `TrafficIncidentCategory`, `TrafficIncident` |
| Panel podczas prowadzenia i ustawienia | [`ContentView.swift`](../NaviAstra/ContentView.swift) — `voiceQuickControls`, przycisk mapy i sekcja „Głos i komunikaty” |
| Konfiguracja audio i lokalizacji w tle iOS | [`NaviAstra-iOS-Info.plist`](../Config/NaviAstra-iOS-Info.plist) |
