#if os(iOS)
import SwiftUI

/// The settings catalogue owns only its search and navigation presentation.
/// Feature stores and the actual settings remain with their existing owners.
struct IOSSettingsIndex<Destination: View>: View {
    let summary: (IOSSettingsCategory) -> String
    @ViewBuilder let destination: (IOSSettingsCategory) -> Destination
    @State private var query = ""

    private var matchingCategories: [IOSSettingsCategory] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return IOSSettingsCategory.allCases }
        return IOSSettingsCategory.allCases.filter { category in
            [category.title, category.section, summary(category), category.searchTerms].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                         locale: PolishRegionalFormat.locale) != nil
            }
        }
    }

    var body: some View {
        let categories = matchingCategories
        List {
            if categories.isEmpty {
                ContentUnavailableView("Nie znaleziono ustawień", systemImage: "magnifyingglass",
                    description: Text("Wpisz inną nazwę, na przykład „głos”, „mapa” lub „pojazd”."))
            } else {
                ForEach(IOSSettingsCategory.sections, id: \.self) { section in
                    let items = categories.filter { $0.section == section }
                    if !items.isEmpty {
                        Section(section) {
                            ForEach(items) { category in
                                NavigationLink(value: category) {
                                    IOSSettingsCategoryLabel(category: category, summary: summary(category))
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: IOSSettingsCategory.self) { category in
            destination(category)
        }
        .searchable(text: $query, prompt: "Szukaj ustawień")
        .scrollDismissesKeyboard(.interactively)
        .environment(\.locale, PolishRegionalFormat.locale)
    }
}

enum IOSSettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case routes, guidance, personalization, marker, energy, history, map, offline, traffic, transit, advanced, privacy
    var id: Self { self }
    static let sections = ["Podróż", "Twoje dane", "Mapa i otoczenie", "Aplikacja"]

    var section: String {
        switch self {
        case .routes, .guidance, .personalization, .marker: "Podróż"
        case .energy, .history: "Twoje dane"
        case .map, .offline, .traffic, .transit: "Mapa i otoczenie"
        case .advanced, .privacy: "Aplikacja"
        }
    }

    var title: String {
        switch self {
        case .routes: "Trasy i pojazd"
        case .guidance: "Głos i ostrzeżenia"
        case .personalization: "Personalizacja tras"
        case .marker: "Twój znacznik"
        case .energy: "Paliwo i koszty jazdy"
        case .history: "Historia przejazdów"
        case .map: "Wygląd i zawartość mapy"
        case .offline: "Mapy offline"
        case .traffic: "Ruch drogowy"
        case .transit: "Komunikacja publiczna"
        case .advanced: "Narzędzia i zaawansowane"
        case .privacy: "Dane i prywatność"
        }
    }

    var symbol: String {
        switch self {
        case .routes: "point.topleft.down.curvedto.point.bottomright.up"
        case .guidance: "speaker.wave.2.fill"
        case .personalization: "point.3.connected.trianglepath.dotted"
        case .marker: "location.north.circle.fill"
        case .energy: "fuelpump.fill"
        case .history: "clock.arrow.circlepath"
        case .map: "map.fill"
        case .offline: "arrow.down.circle.fill"
        case .traffic: "car.side.fill"
        case .transit: "tram.fill"
        case .advanced: "slider.horizontal.3"
        case .privacy: "lock.shield.fill"
        }
    }

    var searchTerms: String {
        switch self {
        case .routes: "samochód pieszo rower elektryczny ładowanie bateria unikanie autostrad"
        case .guidance: "dźwięk lektor komunikaty prędkość"
        case .personalization: "uczenie preferencje skróty zapamiętane drogi"
        case .marker: "model strzałka kolor wielkość"
        case .energy: "tankowanie zużycie ładowanie"
        case .history: "GPS ślad ocena prowadzenia"
        case .map: "dzień noc satelitarna 3D budynki pogoda kategorie miejsca fotoradary"
        case .offline: "bez internetu pobieranie obszar paczki"
        case .traffic: "korki TomTom zgłoszenia GDDKiA"
        case .transit: "autobus tramwaj pociąg MPK Transitous"
        case .advanced: "serwer Valhalla zasięg GPX diagnostyka obszary omijane"
        case .privacy: "licencje źródła internet dane lokalne"
        }
    }
}

private struct IOSSettingsCategoryLabel: View {
    let category: IOSSettingsCategory
    let summary: String
    @ScaledMetric(relativeTo: .body) private var iconSize = 38.0

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: category.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: iconSize, height: iconSize)
                .background(Color.accentColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
#endif
