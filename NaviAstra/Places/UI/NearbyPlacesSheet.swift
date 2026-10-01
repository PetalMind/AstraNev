import SwiftUI

struct NearbyPlacesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let navigationStore: NavigationStore
    let nearDestination: Bool
    let initialCategory: NearbyPlaceCategory
    let savedPlaces: [SavedPlace]
    let onSave: (Destination) -> Bool
    let onRemoveSaved: (Destination) -> Bool
    let onRenameSaved: (Destination, String) -> Bool
    let onSelect: (Destination) -> Void
    @State private var category: NearbyPlaceCategory
    @State private var retryID = UUID()
    @State private var nameQuery = ""
    @State private var expandedRadius = false
    @State private var openNowOnly = false
    @State private var open24HoursOnly = false
    @State private var selectedFuelType: String?
    @State private var selectedOperator: String?
    @State private var minimumChargingPower: Double?
    @State private var selectedConnector: String?
    @State private var openingHoursPresentations: [String: OpeningHoursPresentation] = [:]

    init(navigationStore: NavigationStore, nearDestination: Bool, initialCategory: NearbyPlaceCategory,
         savedPlaces: [SavedPlace], onSave: @escaping (Destination) -> Bool,
         onRemoveSaved: @escaping (Destination) -> Bool,
         onRenameSaved: @escaping (Destination, String) -> Bool,
         onSelect: @escaping (Destination) -> Void) {
        self.navigationStore = navigationStore
        self.nearDestination = nearDestination
        self.initialCategory = initialCategory
        self.savedPlaces = savedPlaces
        self.onSave = onSave
        self.onRemoveSaved = onRemoveSaved
        self.onRenameSaved = onRenameSaved
        self.onSelect = onSelect
        _category = State(initialValue: initialCategory)
    }

    private var categories: [NearbyPlaceCategory] {
        nearDestination ? [.parking, .parkRide] : [.fuel, .food, .parking, .charging, .parkRide]
    }

    private var nearbySearchRefreshKey: String {
        let categoryKey = category.rawValue
        let retryKey = retryID.uuidString
        let radiusKey = expandedRadius ? "expanded" : "default"
        return [categoryKey, retryKey, radiusKey, String(nearestSearch),
                String(navigationStore.state.location != nil)].joined(separator: "-")
    }

    private var openingHoursRefreshKey: String {
        navigationStore.state.nearbySuggestions.map { suggestion in
            let candidate = suggestion.candidate
            return [candidate.id, candidate.openingHours ?? "", candidate.countryCode ?? "",
                    candidate.timeZoneIdentifier ?? "", String(candidate.destination.coordinate.latitude),
                    String(candidate.destination.coordinate.longitude)].joined(separator: "|")
        }.joined(separator: "\n")
    }

    private var nearestSearch: Bool {
        !nearDestination && navigationStore.state.status != .navigating && navigationStore.state.status != .rerouting
    }

    private var availableOperators: [String] {
        Array(Set(navigationStore.state.nearbySuggestions
            .filter { $0.candidate.category == category }
            .compactMap { $0.candidate.operatorOrBrand })).sorted()
    }

    private var availableFuelTypes: [String] {
        Array(Set(navigationStore.state.nearbySuggestions
            .filter { $0.candidate.category == .fuel }
            .flatMap { $0.candidate.fuelTypes })).sorted()
    }

    private var availableConnectors: [String] {
        Array(Set(navigationStore.state.nearbySuggestions
            .filter { $0.candidate.category == .charging }
            .flatMap { $0.candidate.chargingStation?.connectorTypes ?? [] })).sorted()
    }

    private var availablePowerThresholds: [Double] {
        [50.0, 100.0, 150.0].filter { threshold in
            navigationStore.state.nearbySuggestions.contains {
                $0.candidate.category == .charging && ($0.candidate.chargingStation?.maximumPowerKW ?? 0) >= threshold
            }
        }
    }

    private var hasOpeningHoursData: Bool {
        navigationStore.state.nearbySuggestions.contains {
            $0.candidate.category == category && ($0.candidate.isOpen24Hours || openingHoursPresentations[$0.id]?.isOpen != nil)
        }
    }

    private var has24HourData: Bool {
        navigationStore.state.nearbySuggestions.contains { $0.candidate.category == category && $0.candidate.isOpen24Hours }
    }

    private var hasApplicableFilters: Bool {
        hasOpeningHoursData || has24HourData || !availableOperators.isEmpty
            || (category == .fuel && !availableFuelTypes.isEmpty)
            || (category == .charging && (!availableConnectors.isEmpty || !availablePowerThresholds.isEmpty))
            || activeFilterCount > 0
    }

    private var activeFilterCount: Int {
        (openNowOnly ? 1 : 0) + (open24HoursOnly ? 1 : 0) +
            (selectedFuelType == nil ? 0 : 1) + (selectedOperator == nil ? 0 : 1) +
            (minimumChargingPower == nil ? 0 : 1) + (selectedConnector == nil ? 0 : 1)
    }

    private var filteredSuggestions: [RouteStopSuggestion] {
        let query = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return navigationStore.state.nearbySuggestions.filter { suggestion in
            let candidate = suggestion.candidate
            guard candidate.category == category else { return false }
            if !query.isEmpty {
                let searchableText = [candidate.destination.name, candidate.destination.address,
                                      candidate.operatorName, candidate.brand]
                    .compactMap { $0 }.joined(separator: " ")
                if !searchableText.localizedStandardContains(query) { return false }
            }
            if openNowOnly && !candidate.isOpen24Hours
                && openingHoursPresentations[suggestion.id]?.isOpen != true { return false }
            if open24HoursOnly && !candidate.isOpen24Hours { return false }
            if let selectedFuelType, !candidate.fuelTypes.contains(selectedFuelType) { return false }
            if let selectedOperator, candidate.operatorOrBrand != selectedOperator { return false }
            if let minimumChargingPower,
               (candidate.chargingStation?.maximumPowerKW ?? 0) < minimumChargingPower { return false }
            if let selectedConnector,
               !(candidate.chargingStation?.connectorTypes.contains(selectedConnector) ?? false) { return false }
            return true
        }
    }

    @MainActor
    private func refreshOpeningHours() async {
        openingHoursPresentations = [:]
        for suggestion in navigationStore.state.nearbySuggestions {
            guard !Task.isCancelled else { return }
            guard let presentation = await suggestion.candidate.openingHoursPresentation() else { continue }
            guard !Task.isCancelled else { return }
            openingHoursPresentations[suggestion.id] = presentation
        }
    }

    private func clearFilters() {
        openNowOnly = false
        open24HoursOnly = false
        selectedFuelType = nil
        selectedOperator = nil
        minimumChargingPower = nil
        selectedConnector = nil
    }

    private func fuelTypeTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "octane_95": "Benzyna 95"
        case "octane_98": "Benzyna 98"
        case "diesel": "Diesel"
        case "lpg": "LPG"
        case "cng": "CNG"
        case "h2": "Wodór"
        case "e10": "E10"
        case "e85": "E85"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func connectorTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "ccs", "ccs2", "ccs_combo_2": "CCS"
        case "type2", "type_2": "Type 2"
        case "chademo": "CHAdeMO"
        case "tesla_supercharger": "Tesla"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func supplementalDetails(for candidate: NearbyPlaceCandidate) -> [String] {
        var details: [String] = []
        if let operatorName = candidate.operatorOrBrand { details.append(operatorName) }
        if candidate.isOpen24Hours {
            details.append("Otwarte 24h")
        } else if candidate.openingHours != nil {
            if let presentation = openingHoursPresentations[candidate.id] {
                if let status = presentation.statusText {
                    details.append(status)
                } else if let failure = presentation.failure {
                    details.append(failure.errorDescription ?? "Godziny niedostępne")
                } else if presentation.isAvailable {
                    details.append("Godziny niepewne")
                }
            } else {
                details.append("Sprawdzam godziny otwarcia…")
            }
        }
        if candidate.category == .fuel {
            if !candidate.fuelTypes.isEmpty {
                details.append(candidate.fuelTypes.map(fuelTypeTitle).joined(separator: " · "))
            }
        } else if candidate.category == .charging, let station = candidate.chargingStation {
            var capabilities: [String] = []
            if let power = station.maximumPowerKW {
                capabilities.append("\(Int(power.rounded())) kW")
            }
            if !station.connectorTypes.isEmpty {
                capabilities.append(station.connectorTypes.map(connectorTitle).joined(separator: " / "))
            }
            if !capabilities.isEmpty { details.append(capabilities.joined(separator: " · ")) }
            if let count = station.chargingPointCount { details.append(chargingPointCountTitle(count)) }
            if station.availability == .unavailable { details.append("Oznaczona jako niedziałająca w OSM") }
        }
        return details
    }

    private func expandedDetails(for candidate: NearbyPlaceCandidate) -> [String] {
        if candidate.category == .fuel {
            return candidate.fuelTypes.map(fuelTypeTitle)
        }
        guard candidate.category == .charging, let station = candidate.chargingStation else { return [] }
        var details: [String] = []
        var capabilities: [String] = []
        if let power = station.maximumPowerKW {
            capabilities.append("\(Int(power.rounded())) kW")
        }
        if !station.connectorTypes.isEmpty {
            capabilities.append(station.connectorTypes.map(connectorTitle).joined(separator: " / "))
        }
        if !capabilities.isEmpty { details.append(capabilities.joined(separator: " · ")) }
        if let count = station.chargingPointCount { details.append(chargingPointCountTitle(count)) }
        if station.availability == .unavailable { details.append("Oznaczona jako niedziałająca w OSM") }
        details.append("Brak danych o wolnych stanowiskach na żywo")
        return details
    }

    private func chargingPointCountTitle(_ count: Int) -> String {
        let remainder = count % 100
        let suffix: String
        if (12...14).contains(remainder) {
            suffix = "punktów ładowania"
        } else {
            switch count % 10 {
            case 1: suffix = "punkt ładowania"
            case 2...4: suffix = "punkty ładowania"
            default: suffix = "punktów ładowania"
            }
        }
        return "\(count) \(suffix)"
    }

    private var categorySelector: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                   alignment: .leading, spacing: 8) {
            ForEach(categories) { value in
                Button {
                    guard category != value else { return }
                    category = value
                    expandedRadius = false
                    nameQuery = ""
                    clearFilters()
                    navigationStore.state.nearbySuggestions = []
                    navigationStore.state.nearbyStatus = .searching
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: value.symbol)
                            .foregroundStyle(Color.naviPOI(value.markerKind))
                            .frame(width: 22)
                        Text(value.title)
                            .foregroundStyle(Color.naviTextPrimary)
                        Spacer(minLength: 0)
                        if category == value {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.naviPOI(value.markerKind))
                        }
                    }
                    .font(.subheadline.weight(category == value ? .semibold : .medium))
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(category == value ? Color.naviPOI(value.markerKind).opacity(0.12) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(category == value ? Color.naviPOI(value.markerKind).opacity(0.45) : .clear)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == value ? .isSelected : [])
            }
        }
    }

    private var nearbyFilterControls: some View {
        HStack {
            Menu {
                if hasOpeningHoursData {
                    Toggle("Otwarte teraz", isOn: $openNowOnly)
                }
                if has24HourData {
                    Toggle("Całodobowe 24h", isOn: $open24HoursOnly)
                }
                if category == .fuel, !availableFuelTypes.isEmpty {
                    Picker("Rodzaj paliwa", selection: $selectedFuelType) {
                        Text("Dowolne").tag(Optional<String>.none)
                        ForEach(availableFuelTypes, id: \.self) { value in
                            Text(fuelTypeTitle(value)).tag(Optional<String>.some(value))
                        }
                    }
                }
                if category == .charging {
                    if !availablePowerThresholds.isEmpty {
                        Picker("Moc minimalna", selection: $minimumChargingPower) {
                            Text("Dowolna").tag(Optional<Double>.none)
                            ForEach(availablePowerThresholds, id: \.self) { value in
                                Text("Co najmniej \(Int(value)) kW").tag(Optional<Double>.some(value))
                            }
                        }
                    }
                    if !availableConnectors.isEmpty {
                        Picker("Złącze", selection: $selectedConnector) {
                            Text("Dowolne").tag(Optional<String>.none)
                            ForEach(availableConnectors, id: \.self) { value in
                                Text(connectorTitle(value)).tag(Optional<String>.some(value))
                            }
                        }
                    }
                }
                if !availableOperators.isEmpty {
                    Picker("Operator", selection: $selectedOperator) {
                        Text("Dowolny").tag(Optional<String>.none)
                        ForEach(availableOperators, id: \.self) { value in
                            Text(value).tag(Optional<String>.some(value))
                        }
                    }
                }
                if activeFilterCount > 0 {
                    Divider()
                    Button("Wyczyść filtry", systemImage: "xmark.circle", action: clearFilters)
                }
            } label: {
                Label(activeFilterCount == 0 ? "Filtry" : "Filtry · \(activeFilterCount)",
                      systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
            if activeFilterCount > 0 {
                Button("Wyczyść", action: clearFilters)
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Wyczyść filtry miejsc")
            }
        }
        .frame(minHeight: 44)
    }

    private func filterChip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.accentColor.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("Usuń filtr: \(title)")
    }

    private var activeFilterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if openNowOnly { filterChip("Otwarte teraz") { openNowOnly = false } }
                if open24HoursOnly { filterChip("Całodobowe") { open24HoursOnly = false } }
                if let selectedFuelType {
                    filterChip(fuelTypeTitle(selectedFuelType)) { self.selectedFuelType = nil }
                }
                if let selectedOperator {
                    filterChip(selectedOperator) { self.selectedOperator = nil }
                }
                if let minimumChargingPower {
                    filterChip("Od \(Int(minimumChargingPower)) kW") { self.minimumChargingPower = nil }
                }
                if let selectedConnector {
                    filterChip(connectorTitle(selectedConnector)) { self.selectedConnector = nil }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var searchDescription: String {
        if nearDestination {
            return "Do 2 km od celu. Brak danych o wolnych miejscach parkingowych."
        }
        if nearestSearch {
            let radius = expandedRadius ? 15 : 5
            return "\(category.title) w promieniu do \(radius) km od Twojej lokalizacji."
        }
        return "Do 1,5 km od pozostałej trasy. Czas objazdu pokazujemy, jeśli jest dostępny."
    }

    private var searchStatusTitle: String {
        if nearDestination { return "Szukam parkingów do 2 km od celu…" }
        return nearestSearch ? "Szukam najbliższych miejsc…" : "Szukam miejsc wzdłuż trasy…"
    }

    private var navigationTitle: String {
        if nearDestination { return "Parking przy celu" }
        return nearestSearch ? "Szukaj w pobliżu" : "Miejsca po drodze"
    }

    private var searchRadius: Double {
        expandedRadius ? 15_000 : 5_000
    }

    private var searchResultLimit: Int {
        expandedRadius ? 50 : 25
    }

    private var canExpandSearchRadius: Bool {
        nearestSearch && !expandedRadius && navigationStore.state.nearbyStatus == .available
    }

    @ViewBuilder
    private var nearbyStatusContent: some View {
        switch navigationStore.state.nearbyStatus {
        case .idle, .searching:
            VStack(spacing: 14) {
                ProgressView()
                Text(searchStatusTitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.naviTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case .unavailable(let message):
            unavailableSearchContent(message: message)
        case .available:
            availableSearchContent
        }
    }

    private func unavailableSearchContent(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.naviTextSecondary)
            Text("Nie udało się wyszukać miejsc")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.naviTextSecondary)
                .multilineTextAlignment(.center)
            Button("Spróbuj ponownie") { retryID = UUID() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @ViewBuilder
    private var availableSearchContent: some View {
        if navigationStore.state.nearbySuggestions.isEmpty {
            ContentUnavailableView(
                "Brak miejsc w pobliżu",
                systemImage: category.symbol,
                description: Text(nearestSearch
                    ? expandedRadius
                        ? "Nie znaleziono miejsc do 15 km. Wybierz inną kategorię."
                        : "Nie znaleziono miejsc do 5 km. Rozszerz zasięg lub wybierz inną kategorię."
                    : "Spróbuj innej kategorii lub ponów wyszukiwanie."))
        } else if filteredSuggestions.isEmpty {
            VStack(spacing: 8) {
                ContentUnavailableView(
                    "Brak pasujących miejsc",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Zmień nazwę lub filtry, aby zobaczyć więcej znalezionych miejsc."))
                Button("Pokaż wszystkie znalezione miejsca") {
                    nameQuery = ""
                    clearFilters()
                }
                    .buttonStyle(.bordered)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Wyniki · \(filteredSuggestions.count)")
                    .font(.headline)
                Spacer()
                Text(nearDestination ? "Przy celu" : nearestSearch ? "Najbliżej najpierw" : "Wzdłuż trasy")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
            }
            nearbyResultsList
        }
    }

    private var nearbyResultsList: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(filteredSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                nearbyResultRow(suggestion, index: index)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .id(category)
    }

    private func nearbyResultRow(_ suggestion: RouteStopSuggestion, index: Int) -> some View {
        let result = searchResult(suggestion)
        let details = supplementalDetails(for: suggestion.candidate)
        let operatorName = suggestion.candidate.operatorOrBrand
        let remainingDetails = operatorName == nil ? details : Array(details.dropFirst())
        let shouldEstimateOnExpand = nearestSearch
            && suggestion.estimateStatus != .calculating
            && (suggestion.travelTime == nil || suggestion.travelDistance == nil)
        let estimateOnExpand: (() -> Void)? = shouldEstimateOnExpand
            ? { _ = Task { await navigationStore.estimateNearbyTravel(for: suggestion.id) } }
            : nil
        let navigationActive = navigationStore.state.status == .navigating || navigationStore.state.status == .rerouting
        let primaryActionTitle = nearDestination
            ? "Wybierz parking"
            : navigationActive ? "Dodaj przystanek" : "Jedź"

        return PlaceSearchResultRow(
            result: result,
            index: index + 1,
            isSaved: savedPlaces.contains {
                $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate
            },
            onSave: { onSave(result.navigationDestination) },
            onRemove: { onRemoveSaved(result.destination) },
            onRename: { onRenameSaved(result.destination, $0) },
            onSelect: {
                onSelect(result.navigationDestination)
                dismiss()
            },
            isNavigating: navigationActive,
            primaryActionTitle: primaryActionTitle,
            supplementalDetails: remainingDetails,
            expandedDetails: expandedDetails(for: suggestion.candidate),
            showsSourceSubtitle: false,
            primaryMetaLine: operatorName,
            onExpand: estimateOnExpand,
            showsQuickRouteAction: true)
    }

    @ViewBuilder
    private var searchRadiusExpansionControl: some View {
        if canExpandSearchRadius {
            Button {
                expandedRadius = true
            } label: {
                Label("Pokaż więcej · do 15 km", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var searchContextTitle: String {
        if nearDestination { return navigationStore.state.destination?.name ?? "Przy celu podróży" }
        return nearestSearch ? "Wokół Twojej lokalizacji" : "Na dalszej części trasy"
    }

    private var nameSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.naviTextSecondary)
            TextField("Filtruj wyniki po nazwie", text: $nameQuery)
                .textFieldStyle(.plain)
                .submitLabel(.search)
            if !nameQuery.isEmpty {
                Button { nameQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.naviTextSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Wyczyść nazwę")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, nameQuery.isEmpty ? 12 : 0)
        .frame(minHeight: 48)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(searchContextTitle, systemImage: nearDestination ? "flag.fill" : nearestSearch ? "location.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline.weight(.semibold))
                        Text(searchDescription)
                            .font(.footnote)
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Kategorie").font(.headline)
                        categorySelector
                    }
                    if navigationStore.state.nearbyStatus == .available {
                        VStack(spacing: 4) {
                            nameSearchField
                            if hasApplicableFilters { nearbyFilterControls }
                            if activeFilterCount > 0 { activeFilterChips }
                        }
                    }
                    nearbyStatusContent
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navigationTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Odśwież", systemImage: "arrow.clockwise") { retryID = UUID() }
                        .disabled(navigationStore.state.nearbyStatus == .searching)
                }
            }
            .task(id: nearbySearchRefreshKey) {
                await navigationStore.searchNearbyPlaces(
                    category,
                    nearDestination: nearDestination,
                    searchRadius: searchRadius,
                    resultLimit: searchResultLimit)
            }
            .task(id: openingHoursRefreshKey) {
                await refreshOpeningHours()
            }
            .safeAreaInset(edge: .bottom) {
                searchRadiusExpansionControl
            }
        }
    }

    private func searchResult(_ suggestion: RouteStopSuggestion) -> SearchResult {
        let candidate = suggestion.candidate
        let poi = candidate.destination.poi
        let category: String = switch candidate.category {
        case .fuel: "fuel"
        case .food: "restaurant"
        case .parking, .parkRide: "parking"
        case .charging: "charging_station"
        }
        let osmID: String?
        if poi?.provider == .openStreetMap {
            osmID = poi?.osmID
        } else if poi == nil {
            osmID = candidate.id.replacingOccurrences(of: "-", with: ":")
        } else {
            osmID = nil
        }

        let straightDistance: Double?
        if nearDestination {
            straightDistance = navigationStore.state.destination.map {
                $0.coordinate.distance(to: candidate.destination.coordinate)
            }
        } else if nearestSearch {
            straightDistance = navigationStore.state.location?.coordinate.distance(
                to: candidate.destination.coordinate)
        } else {
            straightDistance = nil
        }

        return SearchResult(destination: candidate.destination, street: nil, houseNumber: nil,
                            city: nil, countryCode: candidate.countryCode, isPOI: true,
                            osmID: osmID,
                            providerID: candidate.providerID,
                            placeProvider: poi?.provider ?? .openStreetMap,
                            category: poi?.category ?? candidate.osmCategory ?? category,
                            brand: poi?.brand ?? candidate.brand,
                            operatorName: poi?.operatorName ?? candidate.operatorName,
                            openingHours: candidate.openingHours,
                            timeZoneIdentifier: candidate.timeZoneIdentifier,
                            straightDistance: straightDistance,
                            travelTime: suggestion.travelTime, travelDistance: suggestion.travelDistance,
                            detour: suggestion.detourSeconds, travelEstimateStatus: suggestion.estimateStatus)
    }

}
