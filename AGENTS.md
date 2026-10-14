# Zasady pracy nad NaviAstra

- Zwracaj się do użytkownika „Stworco”.
- Nie twórz pojedynczych testów ani nie proś o testowanie prostych funkcjonalności. Testowanie wykonuj tylko przy zmianach w funkcjonalnościach krytycznych.
- Zwiększaj wersję aplikacji iOS przy zmianach w jej kodzie; nie zwiększaj wersji zamrożonej aplikacji macOS.

## Zakres rozwoju: wyłącznie iOS

- Aktywnie rozwijamy wyłącznie aplikację iOS oraz jej widżety. Dokumentacja funkcji, instrukcje budowania i zmiany agentów mają dotyczyć iOS.
- Wersja macOS jest zamrożona i odłączona od aktywnych celów Xcode. Nie edytuj, nie rozwijaj, nie naprawiaj, nie buduj ani nie przywracaj tej wersji bez wyraźnego polecenia Stworcy dotyczącego macOS.
- Chronione są: `NaviAstra/Maps/macOS/`, `NaviAstra/Maps/MacMapView.swift`, `NaviAstra/Maps/MacMapAnnotations.swift`, `NaviAstra/Maps/MacMapCameraAnimator.swift`, `Config/NaviAstra-macOS-Info.plist`, `NaviAstraMac.entitlements` i `archive/macos/`.
- W `NaviAstra.xcodeproj/project.pbxproj` pozostaw bez zmian nieaktywne obiekty wersji macOS o identyfikatorach zaczynających się od `A200`. Nie dodawaj `NaviAstraMac` do listy celów, produktów ani aktywnych schematów.
- W plikach współdzielonych pozostaw bez zmian gałęzie `#if os(macOS)` / `#elseif os(macOS)` i inne fragmenty przeznaczone tylko dla macOS. Wspólną logikę można zmieniać na potrzeby iOS; nie dodawaj przy tym dostosowań ani nowych funkcji dla macOS.
- Zlecenie zmiany iOS lub kodu współdzielonego nie stanowi zgody na zmiany wersji macOS. Nie używaj jej kompilacji jako zastępstwa weryfikacji iOS.

## Język i formatowanie

- Cały interfejs aplikacji ma być zawsze po polsku, niezależnie od języka urządzenia. Dotyczy to wszystkich ekranów, przycisków, ustawień, komunikatów, błędów, powiadomień, widżetów i funkcji dostępności.
- Daty, godziny, nazwy dni tygodnia i miesięcy, liczby, jednostki oraz czasy podróży również mają być prezentowane po polsku. Używaj polskich ustawień regionalnych (`pl_PL`), także w kontrolkach systemowych, takich jak `DatePicker`.
- Daty i godziny formatuj automatycznie za pomocą systemowych formatterów z polskimi ustawieniami regionalnymi. Nie polegaj na domyślnym języku urządzenia i nie składaj dat ręcznie z angielskich nazw.
- Strefę czasową i zmianę czasu obsługuj automatycznie za pomocą systemowego kalendarza. Dla zapisanych planów podróży respektuj ich zapisaną strefę czasową. Nie stosuj stałych przesunięć UTC.
- Nie pokazuj użytkownikowi surowych angielskich błędów, kluczy lokalizacji, nazw enumów ani technicznych wartości z API. Tłumacz je na czytelne polskie komunikaty; szczegóły techniczne zachowuj w logach. Nazwy własne miejsc, marek i osób zachowuj w oryginalnym brzmieniu.
- Każda nowa lub zmieniana funkcja musi przestrzegać tych zasad we wszystkich miejscach, w których prezentuje dane użytkownikowi.
