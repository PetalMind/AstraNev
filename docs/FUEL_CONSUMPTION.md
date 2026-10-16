# Pomiar spalania w aplikacji iOS

Formularz tankowania rozdziela poziom paliwa **przed tankowaniem** od pełnego
zbiornika **po tankowaniu**. Tankowanie na rezerwie może jednocześnie kończyć się
pełnym zbiornikiem. Aplikacja nie zakłada automatycznie, że tankowanie częściowe
odbyło się na rezerwie.

## Tankowanie od rezerwy do rezerwy

1. Wpisz litry albo kwotę i cenę za litr.
2. W polu „Paliwo przed tankowaniem” wybierz „Na rezerwie”, jeżeli tankujesz przy
   porównywalnym poziomie rezerwy. Pierwszy taki wpis rozpoczyna pomiar.
3. Przy następnym powrocie do podobnego poziomu wybierz ponownie „Na rezerwie”.
   Nie trzeba tankować do pełna. Zapisuj również wszystkie tankowania po drodze.
4. Wpisz przebieg licznika. Jeżeli brakuje licznika na którymś końcu okresu,
   aplikacja użyje dostępnych ukończonych przejazdów przypisanych do pojazdu.

Okres obejmuje paliwo kupione przy pierwszym tankowaniu i podczas tankowań
pośrednich. Zakup przy końcowym tankowaniu rozpoczyna następny okres. Wynik jest
oznaczony jako szacunek: różnica ilości paliwa pozostającego na rezerwie wpływa
na dokładność. Brakujące przejazdy GPS mogą zawyżyć wyliczone spalanie.

Przykład: 16 L na rezerwie, 4 L po drodze, ponowna rezerwa po 250 km daje
szacunkowo 8 L/100 km. Ilość kupiona przy powrocie na rezerwę nie wchodzi do tych
20 L.

## Pomiar między pełnymi zbiornikami

Nadal można oznaczać „Zatankowano do pełna”. Okres obejmuje wszystkie zakupy
po pierwszym pełnym zbiorniku, łącznie z tankowaniem zamykającym. Zakup otwierający
okres jest pomijany. Ładowanie prądem nadal wymaga dwóch wpisów do 100%; nie
korzysta z oznaczeń rezerwy.

## Średnia, historia i koszty tras

- Podgląd w formularzu pokazuje zamykany okres i wynik, jeżeli są dostępne dane.
- Historia podaje poziom przed tankowaniem, metodę oraz źródło dystansu.
- Prawidłowy pomiar między pełnymi zbiornikami ma pierwszeństwo przed
  nakładającymi się okresami z rezerwy. Ten sam dystans nie jest liczony dwukrotnie.
  Jeżeli pełnemu okresowi brakuje dystansu, możliwy pozostaje szacunek z rezerwy.
- Średnia jest ważona dystansem wybranych okresów. Zasila statystyki, historię
  przejazdów i szacunki kosztów tras; ostatnia zapisana cena służy do wyceny trasy.
- Edycja, dodanie starszego wpisu i usunięcie wpisu przeliczają okresy.
- Stare dane pozostają bez oznaczenia rezerwy. Użytkownik może uzupełnić znane
  poziomy przez „Edytuj” w historii. Nie ma automatycznej konwersji tankowań.

Przebieg licznika ma pierwszeństwo przed GPS. Nieprawidłowej pary odczytów nie
zastępujemy automatycznie dystansem przejazdów. Wymagane są rosnący przebieg i
dodatni dystans między granicami pomiaru.
