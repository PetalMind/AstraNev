# Pogoda na mapie

Źródło: Open-Meteo Forecast API (https://open-meteo.com/en/docs). Dane są prognozą modelową, nie pomiarem ani radarem. Provider jest oddzielony od silnika wizualnego i rendererów MapLibre (iOS) / MapKit (macOS).

Ustawienia: Ustawienia → Mapa → Efekty pogodowe. Domyślnie pogoda jest włączona, z subtelną intensywnością. Można osobno wyłączyć animacje, dopasowanie kolorów, efekty podczas nawigacji oraz prognozę trasy. Wyłączenie pogody zatrzymuje pobieranie; wyłączenie prognozy trasy ogranicza zapytanie do bieżącej lokalizacji.

Bieżąca lokalizacja i maksymalnie 12 punktów wybranej trasy są wysyłane w jednym zapytaniu HTTPS. Odświeżanie następuje co 10 minut, po zmianie trasy, terminu podróży lub obszaru lokalizacji (siatka około 0,05 stopnia), tylko przy aktywnej aplikacji. Zapytania dla poprzedniego kontekstu są anulowane. Brak lokalizacji, błędy API i brak prognozy nie są przedstawiane jako bezchmurna pogoda.

Prognoza trasy wykorzystuje godzinowe dane w pobliżu szacowanego czasu przejazdu. ETA punktów jest interpolowana według odległości wzdłuż geometrii i pozostałego czasu podróży; nie uwzględnia lokalnych różnic prędkości. Termin wyjazdu/przyjazdu z planera jest uwzględniany. Zakres prognozy wynosi 3 dni; brakujące lub odległe godziny nie są zastępowane aktualną pogodą.

Szerokie, półprzezroczyste pasy wokół odcinków trasy oznaczają pogodę w pobliskim punkcie próbkowania. Granice odcinków są połowami odległości między próbkami, a nie meteorologicznymi granicami opadów. Komunikaty o odległości i czasie używają określeń „około” i „prognoza”. Przy długich trasach próbkowanie jest rzadsze. To nie są oficjalne ostrzeżenia meteorologiczne.

Efekty: ciepły/chłodny ton, deszcz, śnieg, mgła oraz sporadyczny błysk burzy podczas przeglądania mapy. Tint jest umieszczony pod trasą i znacznikami. Cząstki są rysowane na jednej powierzchni Canvas (maksymalnie 72, 24 fps), z łagodniejszym efektem w okolicy pojazdu. Mgła to gradient atmosferyczny, nie fizyczne zamglenie obiektów według odległości. Efekty nie przejmują gestów.

Podczas prowadzenia: deszcz 50%, śnieg 40%, mgła 30%, tint 70% zwykłej intensywności, bez błysków. Ograniczenie ruchu i tryb oszczędzania energii wyłączają cząstki i błyski. Aplikacja nie pobiera pogody w tle. Nieaktualne dane po 30 minutach nie generują efektów ani komunikatów trasy.
