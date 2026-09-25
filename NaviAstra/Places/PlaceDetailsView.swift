import SwiftUI

struct PlaceDetailsView: View {
    let result: SearchResult
    let onSave: () -> Bool
    let onPlanRoute: () -> Void
    let isNavigating: Bool
    let primaryActionTitle: String
    let supplementalDetails: [String]

    @State private var details: PlaceDetails?
    @State private var isSaved: Bool
    @State private var saveError: String?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var retry = 0
    @State private var showHours = false
    @State private var loadedAt: Date?
    @State private var fuelPriceLookup: FuelPriceLookupResult?
    @State private var fuelPriceError: String?
    @State private var isLoadingFuelPrices = false
    private let provider = OpenStreetMapPlaceDetailsProvider()
    private let fuelPriceProvider: any FuelPriceProvider = BenzynaMapaFuelPriceProvider.shared

    init(result: SearchResult, isSaved: Bool, onSave: @escaping () -> Bool,
         isNavigating: Bool = false, primaryActionTitle: String = "Wyznacz trasę",
         supplementalDetails: [String] = [],
         onPlanRoute: @escaping () -> Void) {
        self.result = result
        self.onSave = onSave
        self.onPlanRoute = onPlanRoute
        self.isNavigating = isNavigating
        self.primaryActionTitle = primaryActionTitle
        self.supplementalDetails = supplementalDetails
        _details = State(initialValue: PlaceDetails.partial(for: result))
        _isSaved = State(initialValue: isSaved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                Text(details?.name ?? result.destination.name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let travelSummary {
                    Label(travelSummary, systemImage: "location")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 9) {
                Button(action: onPlanRoute) {
                    Label(primaryActionTitle,
                          systemImage: isNavigating ? "plus" : "arrow.triangle.turn.up.right.diamond")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    if onSave() {
                        isSaved = true
                        saveError = nil
                    } else {
                        saveError = "Nie udało się zapisać miejsca na urządzeniu."
                    }
                } label: {
                    Label(isSaved ? "Zapisano" : "Zapisz", systemImage: isSaved ? "star.fill" : "star")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 42)
                }
                .buttonStyle(.bordered)
                .disabled(isSaved)
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            Divider()
            ForEach(supplementalDetails, id: \.self) { detail in
                Label(detail, systemImage: "info.circle")
                    .font(.subheadline)
            }
            if let details { detailsContent(details) }
            if isFuelStation { fuelPricesSection }

            if isLoading {
                ProgressView("Uzupełnianie informacji…")
                    .font(.caption)
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                    Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                        .font(.caption.weight(.semibold))
                }
            } else if result.isPOI, details?.hasAdditionalInformation != true, supplementalDetails.isEmpty {
                Text("Brak dodatkowych informacji o tym miejscu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let loadedAt {
                Text("OpenStreetMap · pobrano \(loadedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let details {
                Text(details.source.title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .task(id: "\(result.placeIdentity.cacheKey)/\(retry)") {
            details = PlaceDetails.partial(for: result)
            loadedAt = nil
            loadError = nil
            guard result.isPOI else { return }
            isLoading = true
            defer { isLoading = false }
            if let cached = await provider.cachedDetails(for: result.placeIdentity) {
                guard !Task.isCancelled else { return }
                details = details?.merging(cached) ?? cached
                loadedAt = cached.fetchedAt
            }
            do {
                if let loaded = try await provider.details(for: result.placeIdentity) {
                    guard !Task.isCancelled else { return }
                    details = details?.merging(loaded) ?? loaded
                    loadedAt = loaded.fetchedAt
                }
            } catch {
                guard !Task.isCancelled else { return }
                loadError = "Nie udało się uzupełnić informacji. Dostępne dane pozostają widoczne."
            }
            if let current = details,
               current.timeZoneIdentifier == nil,
               let timeZoneIdentifier = await PlaceTimeZoneResolver.identifier(for: result.destination.coordinate) {
                guard !Task.isCancelled else { return }
                var updated = current
                updated.timeZoneIdentifier = timeZoneIdentifier
                details = updated
            }
        }
        .task(id: fuelPriceTaskID) {
            isLoadingFuelPrices = false
            fuelPriceLookup = nil
            fuelPriceError = nil
            guard isFuelStation else { return }

            isLoadingFuelPrices = true
            defer {
                if !Task.isCancelled { isLoadingFuelPrices = false }
            }
            do {
                let lookup = try await fuelPriceProvider.prices(for: FuelStationLookup(identity: result.placeIdentity))
                guard !Task.isCancelled else { return }
                fuelPriceLookup = lookup
            } catch {
                guard !Task.isCancelled else { return }
                fuelPriceError = "Nie udało się pobrać cen paliw."
            }
        }
    }

    private var fuelPriceTaskID: String {
        "\(result.placeIdentity.cacheKey)/\(details?.category ?? result.category ?? "")/\(retry)"
    }

    private var isFuelStation: Bool {
        (details?.category ?? result.category)?.lowercased().split(separator: "=").last == "fuel"
    }

    private var fuelPricesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ceny paliw", systemImage: "fuelpump.fill")
                .font(.subheadline.weight(.semibold))

            if isLoadingFuelPrices {
                ProgressView("Pobieranie cen…")
                    .font(.caption)
            } else if let fuelPriceError {
                Text(fuelPriceError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption.weight(.semibold))
            } else if let fuelPriceLookup {
                fuelPriceLookupContent(fuelPriceLookup)
            }

            Link("Źródło: BenzynaMAPA.pl + OpenStreetMap",
                 destination: URL(string: "https://benzynamapa.pl")!)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func fuelPriceLookupContent(_ lookup: FuelPriceLookupResult) -> some View {
        switch lookup {
        case .outsideCoverage:
            Text("Ceny BenzynaMAPA są dostępne dla stacji w Polsce.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .stationNotFound:
            Text("Brak dopasowanych cen dla tej stacji.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noPrices:
            Text("Dostawca nie podał cen paliw dla tej stacji.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .prices(let report):
            if report.prices.isEmpty {
                Text("Dostawca nie podał cen paliw dla tej stacji.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(report.prices) { price in
                        HStack(spacing: 5) {
                            Text(price.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 3)
                            Text("\(price.isEstimated ? "~" : "")\(price.amount.formatted(.number.precision(.fractionLength(2)))) zł/l")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
            }

            if let source = report.source, !source.isEmpty {
                Text("Dane: \(source)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let reportedAt = report.reportedAt, !reportedAt.isEmpty {
                Text("Aktualizacja: \(reportedAt)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var travelSummary: String? {
        result.travelSummary
    }

    @ViewBuilder
    private func detailsContent(_ details: PlaceDetails) -> some View {
        if let category = details.category {
            Label(categoryTitle(category), systemImage: "tag")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let brand = details.brand ?? details.operatorName, brand != details.name {
            Label(brand, systemImage: "building.2")
                .font(.caption)
        }

        if let address = details.address, !address.isEmpty {
            Label(address, systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .textSelection(.enabled)
        }

        if let rawHours = details.openingHours, !rawHours.isEmpty, details.osmParking?.openingHours == nil {
            openingHours(rawHours, details: details)
        }

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { contactLinks(details) }
            VStack(alignment: .leading, spacing: 12) { contactLinks(details) }
        }
        .font(.subheadline.weight(.medium))

        if let wheelchair = details.wheelchair {
            Label(wheelchairTitle(wheelchair), systemImage: "figure.roll")
                .font(.subheadline)
        }
        if let parking = details.parking, details.osmParking == nil {
            Label("Parking: \(parking)", systemImage: "parkingsign.circle").font(.subheadline)
        }
        if let parking = details.osmParking {
            parkingInformation(parking, details: details)
        }
        if let driveThrough = details.driveThrough {
            Label(driveThrough.lowercased() == "yes" ? "Drive-through" : "Drive-through: \(driveThrough)", systemImage: "car.side")
                .font(.subheadline)
        }
    }

    private func parkingInformation(_ parking: ParkingInformation, details: PlaceDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Warunki parkowania", systemImage: "parkingsign.circle.fill")
                .font(.subheadline.weight(.semibold))

            parkingRow("Opłaty", parking.tariff.status.title)
            if let freeMinutes = parking.tariff.freeMinutes {
                parkingRow("Bezpłatnie", "pierwsze \(durationText(minutes: freeMinutes))")
            }
            if let hourlyRate = parking.tariff.hourlyRate {
                parkingRow("Stawka godzinowa", parkingPriceText(hourlyRate))
            } else if let charge = parking.tariff.chargeDescription {
                parkingRow("Taryfa", charge)
            }
            if let firstHourRate = parking.tariff.firstHourRate {
                parkingRow("Pierwsza godzina", parkingPriceText(firstHourRate))
            }
            if let subsequentHourRate = parking.tariff.subsequentHourRate {
                parkingRow("Kolejna godzina", parkingPriceText(subsequentHourRate))
            }
            if let dailyRate = parking.tariff.dailyRate {
                parkingRow("Stawka dzienna", parkingPriceText(dailyRate))
            }
            if let feeCondition = parking.tariff.feeCondition {
                parkingRow("Warunkowa opłata", feeCondition)
            }
            if let conditionalCharge = parking.tariff.conditionalCharge {
                parkingRow("Warunkowa taryfa", conditionalCharge)
            }
            if let capacity = parking.capacity {
                parkingRow("Pojemność", "\(capacity) miejsc")
            }
            if let availableSpaces = parking.availableSpaces {
                parkingRow("Wolne miejsca", parking.capacity.map { "\(availableSpaces) / \($0)" } ?? "\(availableSpaces)")
            } else {
                parkingRow("Wolne miejsca", "brak danych na żywo")
            }
            if let maxStay = parking.maxStay {
                parkingRow("Maksymalny postój", parking.maxStayMinutes.map { durationText(minutes: $0) } ?? maxStay)
            }
            if let maxStay = parking.maxStayConditional {
                parkingRow("Warunkowy limit postoju", maxStay)
            }
            if let access = parking.access {
                parkingRow("Dostęp", parkingAccessTitle(access))
            }
            if let access = parking.accessConditional {
                parkingRow("Warunkowy dostęp", access)
            }
            if let parkingType = parking.parkingType {
                parkingRow("Rodzaj", parkingType.replacingOccurrences(of: "_", with: " "))
            }
            if let openingHours = parking.openingHours, !openingHours.isEmpty {
                openingHoursDisclosure(openingHours, details: details)
            }

            ForEach(parking.streetSides, id: \.side) { side in
                VStack(alignment: .leading, spacing: 4) {
                    Text(side.side.title + (side.parkingType.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""))
                        .font(.caption.weight(.semibold))
                    if let condition = side.parkingCondition { parkingRow("Zasada", condition) }
                    if let condition = side.parkingConditionConditional { parkingRow("Zasada warunkowa", condition) }
                    if let fee = side.fee { parkingRow("Opłaty", fee) }
                    if let charge = side.charge { parkingRow("Taryfa", charge) }
                    if let charge = side.chargeConditional { parkingRow("Warunkowa taryfa", charge) }
                    if let condition = side.feeCondition { parkingRow("Warunkowa opłata", condition) }
                    if let maxStay = side.maxStay { parkingRow("Maksymalny postój", maxStay) }
                    if let maxStay = side.maxStayConditional { parkingRow("Limit warunkowy", maxStay) }
                    if let access = side.access { parkingRow("Dostęp", parkingAccessTitle(access)) }
                    if let hours = side.openingHours { parkingRow("Godziny", hours) }
                    if let restriction = side.restriction { parkingRow("Ograniczenie", restriction) }
                    if let restriction = side.restrictionConditional { parkingRow("Ograniczenie warunkowe", restriction) }
                }
                .padding(.top, 3)
            }

            if parking.tariff.status == .unknown {
                Text("Brak informacji o opłacie w OSM nie oznacza, że parking jest bezpłatny.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(parking.dataSources.isEmpty
                 ? "Źródło taryfy: brak danych"
                 : "Źródło: " + parking.dataSources.map(\.title).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func parkingRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func parkingPriceText(_ price: ParkingPrice) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: NSDecimalNumber(decimal: price.amount)) ?? price.amount.description
        let currency = switch price.currencyCode?.uppercased() {
        case "PLN": "zł"
        case "EUR": "€"
        case "USD": "$"
        case "GBP": "£"
        case "CZK": "Kč"
        case let code?: code
        case nil: ""
        }
        let unit = price.unit == "day" ? "/ dzień" : price.unit == "hour" ? "/ godz." : ""
        return [amount, currency].filter { !$0.isEmpty }.joined(separator: " ") + unit
    }

    private func durationText(minutes: Int) -> String {
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return days == 1 ? "1 dzień" : "\(days) dni"
        }
        if minutes % 60 == 0 { return "\(minutes / 60) godz." }
        return "\(minutes) min"
    }

    private func parkingAccessTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "yes", "public", "permissive": "publiczny"
        case "customers": "dla klientów"
        case "private": "prywatny"
        case "no": "brak dostępu publicznego"
        case "permit": "na zezwolenie"
        case "residents": "dla mieszkańców"
        default: value
        }
    }

    private func openingHoursDisclosure(_ rawHours: String, details: PlaceDetails) -> some View {
        DisclosureGroup("Godziny parkowania", isExpanded: $showHours) {
            if let rows = PlaceOpeningHours(rawValue: rawHours,
                                            coordinate: details.coordinate,
                                            countryCode: details.countryCode,
                                            timeZoneIdentifier: details.timeZoneIdentifier).weeklyRows {
                ForEach(Array(rows.enumerated()), id: \.offset) { item in
                    HStack {
                        Text(item.element.0).frame(width: 46, alignment: .leading)
                        Text(item.element.1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(rawHours).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Godziny mogą się różnić w święta.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func contactLinks(_ details: PlaceDetails) -> some View {
        if let phone = details.phone, let url = details.phoneURL {
            Link(destination: url) { Label(phone, systemImage: "phone") }
        }
        if let website = details.websiteURL {
            Link(destination: website) { Label("Strona", systemImage: "globe") }
        }
    }

    @ViewBuilder
    private func openingHours(_ rawHours: String, details: PlaceDetails) -> some View {
        let hours = details.openingHoursInfo
        VStack(alignment: .leading, spacing: 5) {
            if let status = hours?.statusText() {
                Label(status, systemImage: status.hasPrefix("Otwarte") ? "clock.fill" : "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.hasPrefix("Otwarte") ? Color.green : Color.secondary)
            }
            DisclosureGroup("Godziny otwarcia", isExpanded: $showHours) {
                if let rows = hours?.weeklyRows {
                    ForEach(Array(rows.enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.0).frame(width: 46, alignment: .leading)
                            Text(item.element.1)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(rawHours)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Godziny mogą się różnić w święta.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private func categoryTitle(_ category: String) -> String {
        let labels = [
            "supermarket": "Supermarket", "convenience": "Sklep spożywczy", "bakery": "Piekarnia",
            "restaurant": "Restauracja", "fast_food": "Fast food", "cafe": "Kawiarnia",
            "fuel": "Stacja paliw", "parking": "Parking", "charging_station": "Ładowarka EV",
            "pharmacy": "Apteka", "bank": "Bank", "hotel": "Hotel", "park": "Park"
        ]
        return labels[category] ?? category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func wheelchairTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "yes", "designated": "Dostęp dla wózków"
        case "limited": "Ograniczony dostęp dla wózków"
        case "no": "Brak dostępu dla wózków"
        default: "Dostępność: \(value)"
        }
    }
}

private extension PlaceDetails {
    var hasAdditionalInformation: Bool {
        address != nil || openingHours != nil || phone != nil || website != nil ||
            wheelchair != nil || parking != nil || osmParking != nil || driveThrough != nil
    }
}

struct PlaceSearchResultRow: View {
    let result: SearchResult
    let index: Int
    let isSaved: Bool
    let onSave: () -> Bool
    let onSelect: () -> Void
    var isNavigating = false
    var primaryActionTitle = "Wyznacz trasę"
    var supplementalDetails: [String] = []
    var expandedDetails: [String]? = nil

    @State private var isExpanded = false
    var showsSourceSubtitle = true
    var primaryMetaLine: String? = nil
    var onExpand: (() -> Void)? = nil

    private var allSupplementalDetails: [String] {
        expandedDetails ?? supplementalDetails
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let expands = !isExpanded
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded = expands }
                if expands { onExpand?() }
            } label: {
                HStack(spacing: 13) {
                    Text("\(index)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.destination.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if showsSourceSubtitle {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let primaryMetaLine {
                            Text(primaryMetaLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let summary = result.travelSummary {
                            Text(summary)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(supplementalDetails, id: \.self) { detail in
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Ukryj szczegóły miejsca" : "Pokaż szczegóły miejsca")

            if isExpanded {
                PlaceDetailsView(result: result, isSaved: isSaved, onSave: onSave,
                                 isNavigating: isNavigating, primaryActionTitle: primaryActionTitle,
                                 supplementalDetails: allSupplementalDetails, onPlanRoute: onSelect)
                    .id(result.placeIdentity.cacheKey)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
