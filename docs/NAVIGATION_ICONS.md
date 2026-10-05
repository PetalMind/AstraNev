# Ikony manewrów

Źródło: https://github.com/mapbox/directions-icons (Mapbox Directions Icons, CC0 1.0).
Pełna licencja: DIRECTIONS_ICONS_LICENSE.md.

Oryginalne SVG 20 × 20 są osadzone lokalnie jako wektorowe obrazy szablonowe we wspólnym katalogu aplikacji i widgetu. Zawracanie w prawo jest lustrzanym odbiciem `uturn.svg`. Mapowanie typów Valhalli znajduje się w `SharedNavigation/ManeuverIcon.swift`.

Rondo korzysta z natywnego schematu SwiftUI: zjazd jest ustawiony względem kierunku wjazdu, łuk pokazuje obieg odczytany z geometrii trasy, a przy większych ikonach środek zawiera numer zjazdu. Valhalla dostarcza `roundabout_exit_count`, `begin_shape_index` i `end_shape_index`; nowsze serwery także `bearing_before` i `bearing_after`. Starsze serwery korzystają z kierunków obliczonych z polilinii. Numer zjazdu nie służy do wyliczania kąta.

Wjazd 26 i następujący po nim zjazd 27 są łączone tylko w tej samej części trasy. Brakujące albo niejednoznaczne dane zachowują neutralny symbol. Dane ronda są opcjonalne w Live Activity, więc starszy stan nadal można odkodować. Manewr scalania bez kierunku i manewry komunikacji publicznej zachowują SF Symbols.
