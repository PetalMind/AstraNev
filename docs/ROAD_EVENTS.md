# Zdarzenia drogowe

NaviAstra korzysta z TomTom Orbis Traffic Incident Details v2. Istniejący
`TrafficSnapshot` jest wspólnym magazynem zdarzeń dla mapy, ostrzeżeń i silnika ETA.
`RouteTrafficMonitor` dopasowuje zdarzenia do drogi, zachowując ich szczegóły.
`SafetyAlertEngine` wybiera aktywne ostrzeżenia bez generowania ograniczeń trasy.

Parser zachowuje wszystkie elementy `events`: opisy, kody REST i kategorie.
Pobiera też `startTime`, `endTime`, `numberOfReports`, `lastReportTime` oraz
`probabilityOfOccurrence`. Brakujące wartości pozostają niedostępne; aplikacja
nie uzupełnia ich szacunkami. Wygasłe i przyszłe zdarzenia nie są przyjmowane
do bieżącego zestawu, a dopasowanie do trasy ponownie sprawdza ich ważność.

Mapa i panel nawigacyjny pokazują wszystkie różne opisy oraz dostępne dane
o zgłoszeniach. Komunikat głosowy może uzupełnić kategorię o szczegółowy opis.
Zamknięcie drogi wymaga dotychczasowego dopasowania geometrii do używanej drogi;
sam punkt obok trasy nie stanowi podstawy objazdu.

`RoadEventCause` oddziela przyczynę od kategorii ikony. Kontrola policyjna ma
etykietę informacyjną i nie powoduje kary ETA ani omijania drogi, nawet gdy
zdarzenie ma opóźnienie lub kategorię zamknięcia.

## Granica dostępności danych

Publiczny schemat Orbis REST v2 udostępnia `events(code,description,iconCategory)`.
Nie dokumentuje `cause.mainCause` ani kategorii `policeCheckpoint`.
SDK TomTom ma odrębny model TPEG `CauseCode`; jego wartości nie są traktowane
jako mapowanie numerycznych kodów REST.

Parser przyjmuje jednoznaczne symboliczne przyczyny zgodne z modelem aplikacji,
gdy dostawca je zwróci. Nie rozpoznaje policji, zwierząt, przedmiotów lub pożaru
przez zgadywanie znaczenia kodów ani analizę tekstu. Obecne REST API nie daje
podstaw do obietnicy dostępności kontroli policyjnych. Nieznane kody pozostają
w szczegółach zdarzenia, a opis dostawcy jest widoczny dla użytkownika.

Nie dodano wysyłania zgłoszeń użytkowników ani dodatkowego dostawcy Waze/HERE.
Dane społecznościowe w szczegółach są informacjami od TomTom.

Dokumentacja dostawcy:
[TomTom Orbis Traffic Incident Details v2](https://docs.tomtom.com/traffic-api/documentation/tomtom-orbis-maps/v2/traffic-incidents/incident-details).
