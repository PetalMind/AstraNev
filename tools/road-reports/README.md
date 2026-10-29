# Opcjonalne wspólne zgłoszenia drogowe iOS

Domyślnie aplikacja zapisuje zgłoszenia tylko na swoim urządzeniu. Ta usługa jest opcjonalnym kodem do samodzielnego uruchomienia; nie została wdrożona ani publicznie wystawiona. Nie wymaga abonamentu, płatnego backendu, klucza zewnętrznego dostawcy ani pakietów poza biblioteką standardową Python 3. Może działać na posiadanym sprzęcie. Publiczny hosting, domena i certyfikat pozostają decyzją operatora; repozytorium nie zakłada ich bezpłatnej dostępności.

Uruchomienie lokalne do weryfikacji protokołu:

```sh
ROAD_REPORTS_DB=/tmp/naviastra-road-reports.sqlite3 python3 tools/road-reports/server.py
```

Usługa nasłuchuje domyślnie tylko na `127.0.0.1:8787`. Aplikacja iOS wymaga publicznego HTTPS. Do rzeczywistego współdzielenia trzeba skonfigurować własny adres HTTPS/proxy, certyfikat zaufany przez iOS, zabezpieczenia i moderację usługi, a następnie ustawić `ROAD_REPORTS_SERVER_URL` w lokalnej konfiguracji budowania. Przykład składni `.xcconfig` chroniącej ukośniki przed interpretacją jako komentarz: `ROAD_REPORTS_SERVER_URL = https:/$()/zgloszenia.example.org`. To miejsce na rzeczywisty adres operatora; `example.org` nie jest działającym backendem projektu. Nie wpisuj tajnych kluczy do tej wartości.

Kontrakt:

- `GET /reports?bbox=minLon,minLat,maxLon,maxLat` zwraca `{ "reports": [...] }`; maksymalnie 200 aktywnych wpisów, tylko obszar Polski, maksymalnie 3° × 2°.
- `POST /reports` przyjmuje `id` UUID v4, `kind` (`police`, `accident`, `hazard`, `jam`, `roadworks`), `coordinate` z `latitude`/`longitude` oraz `createdAt`/`expiresAt` w ISO 8601 z jawną strefą. Maksymalny czas życia to 30 minut, początek nie może być starszy niż 2 minuty. Wysłanie ponownie tego samego ID nie przedłuża ani nie przenosi zgłoszenia.
- Brak kont, identyfikatorów urządzeń, cookies, komentarzy tekstowych i śladów podróży. Punkt jest zaokrąglany do 0,001° także na serwerze. Aplikacja wysyła dopiero po dotknięciu „Udostępnij zgłoszenie innym”. UUID jest losowym identyfikatorem zgłoszenia, nie urządzenia.
- Odczyt maksymalnie 60 razy/minutę, zapis 4 razy/minutę według adresu połączenia. Adres jest używany tylko w krótkiej pamięci licznika, nie jest zapisywany w bazie. Przy proxy konieczny jest dodatkowy limit na brzegu; nie ufamy dostarczanemu przez klienta `X-Forwarded-For`.
- Serwer nie zapisuje adresów, punktów ani treści żądań w logach. Proxy należy skonfigurować zgodnie z tą samą zasadą. Trwała baza SQLite zawiera tylko publiczne zgłoszenia i usuwa wygasłe wpisy przy kolejnej operacji. Operator może usunąć wpis po jego ID bez zmiany aplikacji.

To zgłoszenia **niepotwierdzone**, bez zaufanego systemu potwierdzeń. Nie zmieniają ETA i nie powodują objazdów; kontrola policyjna nie wpływa na trasę. Publiczne uruchomienie wymaga zapewnienia obsługi nadużyć, moderacji i zasad udostępniania. Kod protokołu nie oznacza działającej sieci użytkowników. Formularz aplikacji i dokumentacja wyraźnie odróżniają zapis lokalny od świadomego udostępnienia.
