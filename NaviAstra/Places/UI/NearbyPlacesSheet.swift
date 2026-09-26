import SwiftUI

struct NearbyPlacesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let engine: NavigationEngine
    let nearDestination: Bool
    let initialCategory: NearbyPlaceCategory
    let savedPlaces: [SavedPlace]
    let onSave: (Destination) -> Bool
    let onRemoveSaved: (Destination) -> Bool
    let onRenameSaved: (Destination, String) -> Bool
    let onSelect: (Destination) -> Void
    @State private var category: NearbyPlaceCategory
    @State private var retryID = UUID()
    @State private var expandedRadius = false
    @State private var openNowOnly = false
    @State private var open24HoursOnly = false
    @State private var selectedFuelType: String?
    @State private var selectedOperator: String?
    @State private var minimumChargingPower: Double?
    @State private var selectedConnector: String?

    init(engine: NavigationEngine, nearDestination: Bool, initialCategory: NearbyPlaceCategory,
         savedPlaces: [SavedPlace], onSave: @escaping (Destination) -> Bool,
         onRemoveSaved: @escaping (Destination) -> Bool,
         onRenameSaved: @escaping (Destination, String) -> Bool,
         onSelect: @escaping (Destination) -> Void) {
        self.engine = engine
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

    private var nearestSearch: Bool {
        !nearDestination && engine.state.status != .navigating && engine.state.status != .rerouting
    }

    private var availableOperators: [String] {
        Array(Set(engine.state.nearbySuggestions
            .filter { $0.candidate.category == category }
            .compactMap { $0.candidate.operatorOrBrand })).sorted()
    }

    private var availableFuelTypes: [String] {
        Array(Set(engine.state.nearbySuggestions
            .filter { $0.candidate.category == .fuel }
            .flatMap { $0.candidate.fuelTypes })).sorted()
    }

    private var availableConnectors: [String] {
        Array(Set(engine.state.nearbySuggestions
            .filter { $0.candidate.category == .charging }
            .flatMap { $0.candidate.chargingStation?.connectorTypes ?? [] })).sorted()
    }

    private var availablePowerThresholds: [Double] {
        [50.0, 100.0, 150.0].filter { threshold in
            engine.state.nearbySuggestions.contains {
                $0.candidate.category == .charging && ($0.candidate.chargingStation?.maximumPowerKW ?? 0) >= threshold
            }
        }
    }

    private var hasOpeningHoursData: Bool {
        engine.state.nearbySuggestions.contains { $0.candidate.category == category && $0.candidate.isOpenNow != nil }
    }

    private var has24HourData: Bool {
        engine.state.nearbySuggestions.contains { $0.candidate.category == category && $0.candidate.isOpen24Hours }
    }

    private var hasApplicableFilters: Bool {
        category == .fuel
            ? hasOpeningHoursData || has24HourData || !availableFuelTypes.isEmpty || !availableOperators.isEmpty
            : category == .charging && (!availableConnectors.isEmpty || !availablePowerThresholds.isEmpty || !availableOperators.isEmpty)
    }

    private var activeFilterCount: Int {
        (openNowOnly ? 1 : 0) + (open24HoursOnly ? 1 : 0) +
            (selectedFuelType == nil ? 0 : 1) + (selectedOperator == nil ? 0 : 1) +
            (minimumChargingPower == nil ? 0 : 1) + (selectedConnector == nil ? 0 : 1)
    }

    private var filteredSuggestions: [RouteStopSuggestion] {
        engine.state.nearbySuggestions.filter { suggestion in
            let candidate = suggestion.candidate
            if openNowOnly && candidate.isOpenNow != true { return false }
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
        } else if let rawHours = candidate.openingHours,
                  let timeZoneIdentifier = candidate.timeZoneIdentifier
                    ?? PlaceTimeZoneResolver.cachedIdentifier(for: candidate.destination.coordinate),
                  let status = PlaceOpeningHours(rawValue: rawHours,
                                                 coordinate: candidate.destination.coordinate,
                                                 countryCode: candidate.countryCode,
                                                 timeZoneIdentifier: timeZoneIdentifier).statusText() {
            details.append(status)
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                           alignment: .leading, spacing: 8) {
                    ForEach(categories) { value in
                        Button {
                            guard category != value else { return }
                            category = value
                            expandedRadius = false
                            clearFilters()
                            engine.state.nearbySuggestions = []
                            engine.state.nearbyStatus = .searching
                        } label: {
                            Label(value.title, systemImage: value.symbol)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .padding(.horizontal, 12)
                                .foregroundStyle(category == value ? Color.accentColor : Color.primary)
                                .background(category == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == value ? .isSelected : [])
                    }
                }

                if hasApplicableFilters {
                    HStack {
                        Menu {
                            if hasOpeningHoursData {
                                Toggle("Otwarte teraz", isOn: $openNowOnly)
                            }
                            if has24HourData {
                                Toggle("Całodobowe 24h", isOn: $open24HoursOnly)
                            }
                            if category == .fuel {
                                if !availableFuelTypes.isEmpty {
                                    Picker("Rodzaj paliwa", selection: $selectedFuelType) {
                                        Text("Dowolne").tag(Optional<String>.none)
                                        ForEach(availableFuelTypes, id: \.self) { value in
                                            Text(fuelTypeTitle(value)).tag(Optional<String>.some(value))
                                        }
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
                    }
                }

                Text(nearDestination
                     ? "Parking jest wyszukiwany w pobliżu celu. Dostępność wolnych miejsc nie jest sprawdzana."
                     : nearestSearch
                        ? "\(category.title) w promieniu do \(expandedRadius ? 15 : 5) km od Twojej lokalizacji."
                        : "Miejsca do 1,5 km od pozostałej trasy. Czas objazdu uzupełniamy po znalezieniu wyników.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                switch engine.state.nearbyStatus {
                case .idle, .searching:
                    ProgressView(nearDestination
                                 ? "Szukam parkingów do 2 km od celu…"
                                 : nearestSearch ? "Szukam najbliższych miejsc…" : "Szukam miejsc wzdłuż trasy…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable(let message):
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Nie udało się wyszukać miejsc")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Spróbuj ponownie") { retryID = UUID() }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .available:
                    if engine.state.nearbySuggestions.isEmpty {
                        ContentUnavailableView("Brak miejsc w pobliżu",
                                               systemImage: category.symbol,
                                               description: Text(nearestSearch
                                                   ? "Możesz rozszerzyć wyszukiwanie do 15 km."
                                                   : "Spróbuj innej kategorii lub wyszukaj w innym miejscu."))
                    } else if filteredSuggestions.isEmpty {
                        VStack(spacing: 8) {
                            ContentUnavailableView("Brak wyników z tymi filtrami",
                                                   systemImage: "line.3.horizontal.decrease.circle",
                                                   description: Text("Zmień filtry albo wyczyść je, aby zobaczyć wszystkie miejsca."))
                            Button("Wyczyść filtry", action: clearFilters)
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Text("Znaleziono: \(filteredSuggestions.count)")
                            .font(.subheadline.weight(.semibold))
                        List(Array(filteredSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                            let result = searchResult(suggestion)
                            let details = supplementalDetails(for: suggestion.candidate)
                            let operatorName = suggestion.candidate.operatorOrBrand
                            let remainingDetails = operatorName == nil ? details : Array(details.dropFirst())
                            let shouldEstimateOnExpand = nearestSearch
                                && suggestion.estimateStatus != .calculating
                                && (suggestion.travelTime == nil || suggestion.travelDistance == nil)
                            let estimateOnExpand: (() -> Void)? = shouldEstimateOnExpand
                                ? { _ = Task { await engine.estimateNearbyTravel(for: suggestion.id) } }
                                : nil
                            let navigationActive = engine.state.status == .navigating || engine.state.status == .rerouting
                            let primaryActionTitle = nearDestination
                                ? "Wybierz parking"
                                : navigationActive ? "Dodaj przystanek" : "Jedź"
                            PlaceSearchResultRow(
                                result: result, index: index + 1,
                                isSaved: savedPlaces.contains { $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate },
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
                                onExpand: estimateOnExpand)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .navigationTitle(nearDestination
                             ? "Parking przy celu"
                             : nearestSearch ? category.title : "\(category.title) po trasie")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { dismiss() }
                }
            }
            .task(id: "\(category.rawValue)-\(retryID)-\(expandedRadius)") {
                await engine.searchNearbyPlaces(category, nearDestination: nearDestination,
                                                searchRadius: expandedRadius ? 15_000 : 5_000,
                                                resultLimit: expandedRadius ? 50 : 25)
            }
            .safeAreaInset(edge: .bottom) {
                if nearestSearch, !expandedRadius, engine.state.nearbyStatus == .available,
                   engine.state.nearbySuggestions.allSatisfy({ $0.estimateStatus != .calculating }) {
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
        return SearchResult(destination: candidate.destination, street: nil, houseNumber: nil,
                            city: nil, countryCode: candidate.countryCode, isPOI: true,
                            osmID: poi?.provider == .openStreetMap
                                ? poi?.osmID : poi == nil ? candidate.id.replacingOccurrences(of: "-", with: ":") : nil,
                            providerID: candidate.providerID,
                            placeProvider: poi?.provider ?? .openStreetMap,
                            category: poi?.category ?? candidate.osmCategory ?? category,
                            brand: poi?.brand ?? candidate.brand,
                            operatorName: poi?.operatorName ?? candidate.operatorName,
                            openingHours: candidate.openingHours,
                            timeZoneIdentifier: candidate.timeZoneIdentifier,
                            straightDistance: nearDestination
                                ? engine.state.destination.map { $0.coordinate.distance(to: candidate.destination.coordinate) }
                                : nearestSearch
                                    ? engine.state.location?.coordinate.distance(to: candidate.destination.coordinate)
                                    : nil,
                            travelTime: suggestion.travelTime, travelDistance: suggestion.travelDistance,
                            detour: suggestion.detourSeconds, travelEstimateStatus: suggestion.estimateStatus)
    }

}
