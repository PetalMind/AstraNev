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
    }
}

struct PlaceDetailsActionBar: View {
    let primaryActionTitle: String
    let isNavigating: Bool
    let isSaved: Bool
    let favoritePulseScale: CGFloat
    let canRemoveSavedPlace: Bool
    let showsPrimaryAction: Bool
    let onPlanRoute: () -> Void
    let onRouteFromPlace: (() -> Void)?
    let onToggleSavedState: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            if showsPrimaryAction {
                Button(action: onPlanRoute) {
                    Label(primaryActionTitle,
                          systemImage: isNavigating ? "plus" : "arrow.triangle.turn.up.right.diamond")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }

            if let onRouteFromPlace, !isNavigating {
                Button(action: onRouteFromPlace) {
                    Label("Stąd", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Wyznacz trasę z tego miejsca")
            }

            Button(action: onToggleSavedState) {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSaved ? Color.accentColor : Color.naviTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .scaleEffect(favoritePulseScale)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isSaved ? "Usuń z Ulubionych" : "Dodaj do Ulubionych")
            .accessibilityHint(isSaved ? "Wymaga potwierdzenia" : "Zapisz to miejsce na później")
            .disabled(isSaved && !canRemoveSavedPlace)
        }
    }
}

struct PlaceDetailsQuickContact: View {
    let details: PlaceDetails

    var body: some View {
        HStack(spacing: 10) {
            if let url = details.phoneURL {
                Link(destination: url) {
                    Label("Zadzwoń", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Zadzwoń: \(details.phone ?? "")")
            }
            if let url = details.websiteURL {
                Link(destination: url) {
                    Label("Witryna", systemImage: "globe")
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .font(.subheadline.weight(.semibold))
    }
}

enum PlaceCategoryPresentation {
    nonisolated static func title(_ category: String) -> String {
        let raw = category.split(separator: "=").last.map(String.init) ?? category
        let key = raw.lowercased().replacingOccurrences(of: "mkpoicategory", with: "")
            .filter { $0.isLetter || $0.isNumber }
        let labels = [
            "supermarket": "Supermarket", "convenience": "Sklep spożywczy", "bakery": "Piekarnia",
            "restaurant": "Restauracja", "fastfood": "Fast food", "cafe": "Kawiarnia",
            "fuel": "Stacja paliw", "gasstation": "Stacja paliw", "parking": "Parking",
            "chargingstation": "Stacja ładowania", "evcharger": "Stacja ładowania",
            "pharmacy": "Apteka", "bank": "Bank", "atm": "Bankomat", "hotel": "Hotel",
            "hostel": "Hostel", "guesthouse": "Pensjonat", "park": "Park", "garden": "Ogród",
            "museum": "Muzeum", "castle": "Zamek", "theater": "Teatr", "theatre": "Teatr",
            "movietheater": "Kino", "cinema": "Kino", "attraction": "Atrakcja turystyczna",
            "viewpoint": "Punkt widokowy", "monument": "Pomnik", "memorial": "Miejsce pamięci",
            "placeofworship": "Miejsce kultu", "hospital": "Szpital", "school": "Szkoła",
            "university": "Uniwersytet", "library": "Biblioteka", "store": "Sklep",
            "mall": "Centrum handlowe", "shoppingcentre": "Centrum handlowe", "zoo": "Zoo",
            "airport": "Lotnisko", "publictransport": "Transport publiczny", "police": "Policja",
            "postoffice": "Poczta", "fitnesscenter": "Centrum fitness", "sportscentre": "Centrum sportowe"
        ]
        return labels[key] ?? raw.replacingOccurrences(of: "MKPOICategory", with: "")
            .replacingOccurrences(of: "_", with: " ").capitalized
    }
}
