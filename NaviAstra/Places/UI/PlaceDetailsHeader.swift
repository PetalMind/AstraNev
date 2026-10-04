import SwiftUI

struct PlaceDetailsHeroSummary: View {
    let title: String
    let symbol: String
    let showsPOIIcon: Bool
    let categoryTitle: String?
    let travelSummary: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsPOIIcon {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let categoryTitle {
                    Text(categoryTitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                }
                if let travelSummary {
                    Label(travelSummary, systemImage: "location")
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlaceDetailsActionBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let primaryActionTitle: String
    let isNavigating: Bool
    let showsPrimaryAction: Bool
    let onPlanRoute: () -> Void
    let onRouteFromPlace: (() -> Void)?

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 9) { actions }
        } else {
            HStack(spacing: 9) { actions }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if showsPrimaryAction {
            Button(action: onPlanRoute) {
                Label(primaryActionTitle,
                      systemImage: isNavigating ? "plus" : "arrow.triangle.turn.up.right.diamond")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }

        if let onRouteFromPlace, !isNavigating {
            Button(action: onRouteFromPlace) {
                Label("Trasa stąd", systemImage: "arrowshape.turn.up.left")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Wyznacz trasę z tego miejsca")
        }
    }
}

struct PlaceDetailsFavoriteButton: View {
    let isSaved: Bool
    let pulseScale: CGFloat
    let canRemove: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSaved ? Color.accentColor : Color.naviTextSecondary)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
                .scaleEffect(pulseScale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSaved ? "Usuń z Ulubionych" : "Dodaj do Ulubionych")
        .accessibilityHint(isSaved ? "Wymaga potwierdzenia" : "Zapisz to miejsce na później")
        .disabled(isSaved && !canRemove)
    }
}

struct PlaceDetailsQuickContact: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let details: PlaceDetails
    var showsPhoneNumber = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) { contactLinks }
                } else {
                    HStack(spacing: 10) { contactLinks }
                }
            }
            .font(.subheadline.weight(.semibold))

            if showsPhoneNumber, details.phoneURL != nil, let phone = details.phone {
                Text("Telefon: \(phone)")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var contactLinks: some View {
        if let url = details.phoneURL {
            Link(destination: url) {
                Label("Zadzwoń", systemImage: "phone.fill")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Zadzwoń: \(details.phone ?? "")")
        }
        if let url = details.websiteURL {
            Link(destination: url) {
                Label("Witryna", systemImage: "globe")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

}

enum PlaceCategoryPresentation {
    // Provider identifiers stay unchanged; only their visible names are localized.
    nonisolated static func title(_ category: String) -> String {
        let raw = category.split(separator: "=").last.map(String.init) ?? category
        let key = raw.lowercased().replacingOccurrences(of: "mkpoicategory", with: "")
            .filter { $0.isLetter || $0.isNumber }
        return labels[key] ?? "Miejsce"
    }

    nonisolated private static let labels: [String: String] = [
        "food": "Jedzenie",
        "restaurant": "Restauracja",
        "fastfood": "Bar szybkiej obsługi",
        "cafe": "Kawiarnia",
        "bar": "Bar",
        "pub": "Pub",
        "icecream": "Lodziarnia",
        "bakery": "Piekarnia",
        "pastry": "Cukiernia",
        "confectionery": "Cukiernia",
        "biergarten": "Ogródek piwny",
        "brewery": "Browar",
        "distillery": "Destylarnia",
        "winery": "Winnica",
        "nightclub": "Klub nocny",
        "nightlife": "Klub nocny",
        "foodcourt": "Strefa gastronomiczna",
        "fuel": "Stacja paliw",
        "gasstation": "Stacja paliw",
        "parking": "Parking",
        "parkride": "Parking P+R",
        "parkandride": "Parking P+R",
        "chargingstation": "Stacja ładowania",
        "evcharger": "Stacja ładowania",
        "evcharging": "Stacja ładowania",
        "carrental": "Wypożyczalnia samochodów",
        "automotiverepair": "Warsztat samochodowy",
        "carrepair": "Warsztat samochodowy",
        "automotivedealership": "Salon samochodowy",
        "car": "Salon samochodowy",
        "commercialvehicledealership": "Salon pojazdów użytkowych",
        "motorbikedealership": "Salon motocyklowy",
        "motorcycle": "Salon motocyklowy",
        "carwash": "Myjnia samochodowa",
        "carparts": "Sklep z częściami samochodowymi",
        "restarea": "Miejsce obsługi podróżnych",
        "services": "Miejsce obsługi podróżnych",
        "store": "Sklep",
        "shop": "Sklep",
        "convenience": "Sklep spożywczy",
        "grocery": "Sklep spożywczy",
        "supermarket": "Supermarket",
        "mall": "Centrum handlowe",
        "shoppingcentre": "Centrum handlowe",
        "shoppingcenter": "Centrum handlowe",
        "foodmarket": "Targ spożywczy",
        "marketplace": "Targowisko",
        "clothes": "Sklep odzieżowy",
        "clothing": "Sklep odzieżowy",
        "shoes": "Sklep obuwniczy",
        "books": "Księgarnia",
        "bookstore": "Księgarnia",
        "florist": "Kwiaciarnia",
        "electronics": "Sklep z elektroniką",
        "furniture": "Sklep meblowy",
        "hardware": "Sklep z narzędziami",
        "doityourself": "Sklep budowlany",
        "chemist": "Drogeria",
        "cosmetics": "Drogeria",
        "pet": "Sklep zoologiczny",
        "pets": "Sklep zoologiczny",
        "sports": "Sklep sportowy",
        "bicycle": "Sklep rowerowy",
        "jewelry": "Jubiler",
        "jewellery": "Jubiler",
        "optician": "Optyk",
        "alcohol": "Sklep z alkoholem",
        "beverages": "Sklep z alkoholem",
        "wine": "Sklep z alkoholem",
        "tobacco": "Sklep z tytoniem",
        "gift": "Sklep z upominkami",
        "toys": "Sklep z zabawkami",
        "stationery": "Sklep papierniczy",
        "mobilephone": "Sklep z telefonami",
        "secondhand": "Sklep z używanymi rzeczami",
        "charity": "Sklep charytatywny",
        "departmentstore": "Dom towarowy",
        "varietystore": "Sklep wielobranżowy",
        "butcher": "Sklep mięsny",
        "seafood": "Sklep rybny",
        "greengrocer": "Warzywniak",
        "deli": "Sklep z delikatesami",
        "delicatessen": "Sklep z delikatesami",
        "kiosk": "Kiosk",
        "newsagent": "Kiosk",
        "gardencentre": "Sklep z artykułami ogrodniczymi",
        "houseware": "Sklep z artykułami gospodarstwa domowego",
        "baby": "Sklep z artykułami dla dzieci",
        "medicalsupply": "Sklep z artykułami medycznymi",
        "pharmacy": "Apteka",
        "hospital": "Szpital",
        "clinic": "Przychodnia",
        "doctor": "Gabinet lekarski",
        "doctors": "Gabinet lekarski",
        "dentist": "Gabinet dentystyczny",
        "veterinary": "Gabinet weterynaryjny",
        "animalservice": "Usługi dla zwierząt",
        "health": "Ochrona zdrowia",
        "healthcare": "Ochrona zdrowia",
        "bank": "Bank",
        "atm": "Bankomat",
        "bureaudechange": "Kantor",
        "postoffice": "Poczta",
        "postbox": "Skrzynka pocztowa",
        "mailbox": "Skrzynka pocztowa",
        "police": "Policja",
        "firestation": "Straż pożarna",
        "toilets": "Toaleta",
        "toilet": "Toaleta",
        "restroom": "Toaleta",
        "drinkingwater": "Woda pitna",
        "fountain": "Fontanna",
        "bench": "Ławka",
        "shelter": "Schronienie",
        "recycling": "Punkt recyklingu",
        "vendingmachine": "Automat sprzedażowy",
        "parcellocker": "Paczkomat",
        "telephone": "Telefon publiczny",
        "hotel": "Hotel",
        "hostel": "Hostel",
        "motel": "Motel",
        "guesthouse": "Pensjonat",
        "lodging": "Nocleg",
        "accommodation": "Nocleg",
        "campsite": "Kemping",
        "campground": "Kemping",
        "caravansite": "Pole kempingowe dla kamperów",
        "rvpark": "Pole kempingowe dla kamperów",
        "alpinehut": "Schronisko turystyczne",
        "wildernesshut": "Schronisko turystyczne",
        "apartment": "Apartament wakacyjny",
        "resort": "Ośrodek wypoczynkowy",
        "chalet": "Chata",
        "park": "Park",
        "nationalpark": "Park narodowy",
        "garden": "Ogród",
        "forest": "Las",
        "wood": "Las",
        "naturereserve": "Rezerwat przyrody",
        "beach": "Plaża",
        "playground": "Plac zabaw",
        "amusementpark": "Park rozrywki",
        "themepark": "Park rozrywki",
        "aquarium": "Akwarium",
        "zoo": "Ogród zoologiczny",
        "attraction": "Atrakcja turystyczna",
        "tourism": "Atrakcja turystyczna",
        "viewpoint": "Punkt widokowy",
        "scenicview": "Punkt widokowy",
        "landmark": "Zabytek",
        "historic": "Zabytek",
        "monument": "Pomnik",
        "nationalmonument": "Pomnik",
        "memorial": "Miejsce pamięci",
        "castle": "Zamek",
        "fortress": "Twierdza",
        "fort": "Twierdza",
        "ruins": "Ruiny",
        "archaeologicalsite": "Stanowisko archeologiczne",
        "museum": "Muzeum",
        "gallery": "Galeria sztuki",
        "artwork": "Dzieło sztuki",
        "theater": "Teatr",
        "theatre": "Teatr",
        "movietheater": "Kino",
        "cinema": "Kino",
        "musicvenue": "Sala koncertowa",
        "planetarium": "Planetarium",
        "conventioncenter": "Centrum wystawiennicze",
        "exhibitioncentre": "Centrum wystawiennicze",
        "fairground": "Teren targowy",
        "artscentre": "Dom kultury",
        "communitycentre": "Dom kultury",
        "library": "Biblioteka",
        "placeofworship": "Miejsce kultu",
        "church": "Kościół",
        "chapel": "Kaplica",
        "mosque": "Meczet",
        "synagogue": "Synagoga",
        "cemetery": "Cmentarz",
        "graveyard": "Cmentarz",
        "airport": "Lotnisko",
        "aerodrome": "Lotnisko",
        "airportterminal": "Terminal lotniska",
        "terminal": "Terminal lotniska",
        "publictransport": "Transport publiczny",
        "publictransportation": "Transport publiczny",
        "busstation": "Dworzec autobusowy",
        "bus": "Przystanek autobusowy",
        "busstop": "Przystanek autobusowy",
        "rail": "Stacja kolejowa",
        "railway": "Stacja kolejowa",
        "station": "Stacja kolejowa",
        "trainstation": "Stacja kolejowa",
        "tramstop": "Przystanek tramwajowy",
        "subway": "Stacja metra",
        "subwayentrance": "Stacja metra",
        "ferryterminal": "Terminal promowy",
        "halt": "Przystanek",
        "stopposition": "Przystanek",
        "platform": "Przystanek",
        "taxi": "Postój taksówek",
        "bicyclerental": "Wypożyczalnia rowerów",
        "bicycleparking": "Parking rowerowy",
        "marina": "Przystań",
        "harbour": "Port",
        "harbor": "Port",
        "helipad": "Lądowisko dla helikopterów",
        "heliport": "Lądowisko dla helikopterów",
        "school": "Szkoła",
        "university": "Uniwersytet",
        "college": "Szkoła wyższa",
        "kindergarten": "Przedszkole",
        "childcare": "Przedszkole",
        "drivingschool": "Szkoła jazdy",
        "government": "Urząd",
        "publicbuilding": "Urząd",
        "townhall": "Ratusz",
        "courthouse": "Sąd",
        "embassy": "Ambasada",
        "office": "Biuro",
        "travelagency": "Biuro podróży",
        "estateagent": "Pośrednictwo nieruchomości",
        "insurance": "Firma ubezpieczeniowa",
        "lawyer": "Kancelaria prawna",
        "accountant": "Biuro rachunkowe",
        "fitnesscenter": "Siłownia",
        "fitnesscentre": "Siłownia",
        "sportscentre": "Centrum sportowe",
        "sportscenter": "Centrum sportowe",
        "stadium": "Stadion",
        "pitch": "Boisko",
        "baseball": "Boisko do baseballu",
        "basketball": "Boisko do koszykówki",
        "soccer": "Boisko do piłki nożnej",
        "volleyball": "Boisko do siatkówki",
        "tennis": "Kort tenisowy",
        "golf": "Pole golfowe",
        "golfcourse": "Pole golfowe",
        "minigolf": "Minigolf",
        "gokart": "Tor kartingowy",
        "hiking": "Szlak pieszy",
        "fishing": "Łowisko",
        "kayaking": "Przystań kajakowa",
        "rockclimbing": "Ścianka wspinaczkowa",
        "swimming": "Basen",
        "swimmingpool": "Basen",
        "surfing": "Miejsce do surfowania",
        "skating": "Lodowisko",
        "icerink": "Lodowisko",
        "skiing": "Ośrodek narciarski",
        "skatepark": "Park do jazdy na deskorolce",
        "bowling": "Kręgielnia",
        "spa": "Ośrodek odnowy biologicznej",
        "beauty": "Salon kosmetyczny",
        "hairdresser": "Fryzjer",
        "laundry": "Pralnia",
        "drycleaning": "Pralnia",
        "sauna": "Sauna",
        "picnicarea": "Miejsce piknikowe",
        "picnicsite": "Miejsce piknikowe",
        "picnictable": "Stół piknikowy",
        "information": "Punkt informacji",
        "informationbooth": "Punkt informacji",
        "visitorcenter": "Centrum informacji turystycznej",
        "rangerstation": "Siedziba straży parku",
        "ticketoffice": "Kasa biletowa",
        "tower": "Wieża",
        "windmill": "Wiatrak",
        "lighthouse": "Latarnia morska",
        "peak": "Szczyt",
        "caveentrance": "Jaskinia",
        "waterfall": "Wodospad",
        "spring": "Źródło",
        "tree": "Drzewo",
        "stone": "Kamień",
        "saddle": "Przełęcz",
        "speedcamera": "Fotoradar",
        "trafficsignals": "Sygnalizacja świetlna",
        "surveillance": "Kamera monitoringu",
        "poi": "Miejsce",
        "yes": "Miejsce",
    ]
}
