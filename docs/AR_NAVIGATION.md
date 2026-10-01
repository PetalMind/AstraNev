# Nawigacja piesza AR

AR jest dostępne podczas aktywnej nawigacji pieszej na urządzeniu obsługującym
`ARWorldTrackingConfiguration`, po przyznaniu dostępu do kamery. Zasięg Apple
Geo Tracking nie jest warunkiem wejścia w AR.

## Dwa tryby

- **AR geograficzne:** `ARGeoTrackingConfiguration` i `ARGeoAnchor`. Uruchamia się,
  gdy urządzenie i aktualny region obsługują tę funkcję. Strzałki są widoczne tylko
  przy normalnym śledzeniu kamery i stanie `localized` z dokładnością medium/high.
- **AR · GPS i kompas:** `ARWorldTrackingConfiguration` z `gravityAndHeading`.
  Współrzędne trasy są przeliczane na lokalne osie east/up/south. To wskazówki
  orientacyjne; nie wyznaczają dokładnej pozycji chodnika. Ich wysokość wynika
  z poziomej powierzchni wykrytej przez ARKit w pobliżu użytkownika.
  Poziom ten jest przedłużany na odcinek przed użytkownikiem; nie jest
  pomiarem nachylenia ani wysokości całej dalszej trasy. Lokalny początek jest aktualizowany po ruchu
  o co najmniej max(8 m, dokładność GPS) lub po 20 s nowych pomiarów GPS.

Sprawdzenie dostępności Apple ma limit 6 s. Brak dostępności, błąd sesji
geograficznej lub 20 s bez wystarczającej lokalizacji przełącza widok na GPS
i kompas. Lokalny tryb nie wymaga usługi VPS ani połączenia z nią; sama trasa
nadal pochodzi ze zwykłego mechanizmu wyznaczania tras aplikacji.

## Geometria i jakość danych

`ARRouteGuidance` jest wspólne dla oceny gotowości i obu trybów renderowania.
Wykorzystuje istniejące `RouteProgressGeometry`: `geometryProgress` oznacza
część długości geometrii, nie indeks w tablicy współrzędnych. Punkty strzałek
leżą na stałej siatce co 4 m, od co najmniej 4 m przed postępem do 48 m
przed postępem. Siatka ogranicza przesuwanie kotwic przy kolejnych aktualizacjach.

Warunki wyświetlania:

- prawidłowe współrzędne, skończona dokładność GPS 0–25 m, wiek pozycji 0–15 s;
- pozycja najwyżej max(15 m, dokładność GPS) od geometrii trasy;
- normalny stan śledzenia kamery;
- wykryty poziom podłoża w pobliżu użytkownika (pozioma powierzchnia pod
  kamerą, z wykluczeniem powierzchni rozpoznanych jako meble);
- w trybie lokalnym: dostępny true north, dokładność kompasu 0–20° i wiek 0–10 s;
- w trybie geograficznym: lokalizacja AR z dokładnością medium/high.

Niepewne wskazówki są ukrywane. Brak aktualizacji GPS także wygasza gotowość
przycisku AR. Zmiana trasy odświeża geometrię i odrzuca instrukcje poprzedniej
trasy. Zakończenie nawigacji albo zmiana transportu z pieszego zamyka AR.
Przejście aplikacji w tło zatrzymuje sesję kamery i dodatkowy odczyt kompasu.

## Wizualizacja

Wskazówki tworzą serię płaskich, białych grotów z niebieskim obramowaniem
i cienkim ciemnym konturem. Najbliższy grot jest o 18% większy. Wskazówki
są poziome, ułożone tuż nad wykrytym poziomem podłoża (bez pochylenia 50°).
Materiały unlit zachowują kolor niezależnie od oświetlenia sceny. Siatka
bryły jest współdzielona przez strzałki. Oba tryby włączają poziome
wykrywanie powierzchni. Do wykrycia podłoża strzałki pozostają ukryte,
a komunikat prosi o skierowanie kamery na ziemię. Wysokość aktualizuje się
wraz z pomiarami powierzchni, także dla kotwic geograficznych.

Nagłówek pokazuje używany tryb. Tryb lokalny pokazuje zgłaszaną dokładność GPS
oraz ograniczenie wskazówek; dolna karta eksponuje odległość i bieżący manewr.

## Alternatywny dostawca VPS

Google ARCore Geospatial obsługuje iOS. Dodanie tego dostawcy wymaga osobnej
integracji SDK, Google Cloud z włączonym ARCore API, uwierzytelniania oraz
obsługi rzeczywistego zasięgu VPS i dokładności. Obecna implementacja nie
zawiera tego SDK ani konfiguracji usługi. Lokalny GPS/kompas nie zastępuje
precyzji wizualnej lokalizacji VPS.

Dokumentacja:

- [Apple: geographic tracking](https://developer.apple.com/documentation/arkit/tracking-geographic-locations-in-ar)
- [Apple: heading-aligned axes](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum/gravityandheading)
- [Apple: geographic tracking status](https://developer.apple.com/documentation/arkit/argeotrackingstatus)
- [Google: Geospatial for iOS](https://developers.google.com/ar/develop/ios/geospatial/quickstart)

## Granice weryfikacji

Regresje krytycznej geometrii obejmują długość zamiast gęstości wierzchołków,
postęp z poprzedniej trasy, niepewne/stare/przyszłe pomiary GPS, pozycję poza
trasą oraz zgodność obrotów strzałek i lokalnych osi z kierunkami świata.
Kompilacja nie potwierdza jakości GPS, kalibracji kompasu, ułożenia kotwic,
wyglądu przez kamerę ani zachowania przy przełączaniu trybów w terenie.

## Płynność uruchamiania

Budowanie indeksu geometrii trasy odbywa się poza głównym wątkiem, zarówno
w widoku AR, jak i przy ocenie gotowości. Polecenia uruchomienia, resetu
i zatrzymania sesji ARKit wykonuje osobna kolejka szeregowa; zamknięcie
widoku w trakcie startu ustawia zatrzymanie po rozpoczęciu sesji.
Zmiana między GPS/kompasem a trybem geograficznym rekonfiguruje istniejący
ARView zamiast ponownie tworzyć widok kamery. Niezmieniony komunikat
śledzenia nie jest ponownie zapisywany do stanu SwiftUI. Spóźnione callbacki
po zamknięciu widoku są ignorowane.
