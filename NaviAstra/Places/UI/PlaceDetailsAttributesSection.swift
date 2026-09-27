import Foundation
import SwiftUI

struct PlaceDetailsAttributesSection: View {
    let details: PlaceDetails
    @Binding var showHours: Bool

    var body: some View {
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
            PlaceDetailsOpeningHoursSection(
                rawHours: rawHours,
                coordinate: details.coordinate,
                countryCode: details.countryCode,
                timeZoneIdentifier: details.timeZoneIdentifier,
                isExpanded: $showHours)
        }

        PlaceDetailsContactLinksSection(details: details)

        if let wheelchair = details.wheelchair {
            Label(wheelchairTitle(wheelchair), systemImage: "figure.roll")
                .font(.subheadline)
        }
        if let parking = details.parking, details.osmParking == nil {
            Label("Parking: \(parking)", systemImage: "parkingsign.circle").font(.subheadline)
        }
        if let parking = details.osmParking {
            PlaceParkingInformationSection(parking: parking, details: details, showHours: $showHours)
        }
        if let driveThrough = details.driveThrough {
            Label(driveThrough.lowercased() == "yes" ? "Drive-through" : "Drive-through: \(driveThrough)",
                  systemImage: "car.side")
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

private struct PlaceDetailsOpeningHoursSection: View {
    let rawHours: String
    let coordinate: Coordinate?
    let countryCode: String?
    let timeZoneIdentifier: String?
    @Binding var isExpanded: Bool
    @State private var presentation: OpeningHoursPresentation?

    private var evaluationKey: String {
        [rawHours, countryCode ?? "", timeZoneIdentifier ?? "",
         coordinate.map { String($0.latitude) } ?? "", coordinate.map { String($0.longitude) } ?? ""]
            .joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let status = presentation?.statusText {
                Label(status, systemImage: status.hasPrefix("Otwarte") ? "clock.fill" : "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.hasPrefix("Otwarte") ? Color.green : Color.secondary)
            } else if let failure = presentation?.failure {
                Label(failure.errorDescription ?? "Godziny niedostępne", systemImage: "exclamationmark.clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if presentation?.isAvailable == true {
                Label("Godziny niepewne", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Godziny otwarcia", isExpanded: $isExpanded) {
                if let rows = presentation?.weeklyRows {
                    ForEach(Array(rows.enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.day).frame(width: 46, alignment: .leading)
                            Text(item.element.hours)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else if let failure = presentation?.failure {
                    Text(failure.errorDescription ?? "Godziny niedostępne")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rawHours)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
        .task(id: evaluationKey) {
            guard !Task.isCancelled else { return }
            guard coordinate == nil || timeZoneIdentifier != nil else {
                presentation = .unavailable(.timeZoneUnavailable)
                return
            }
            let evaluated = await PlaceOpeningHours(rawValue: rawHours,
                                                    coordinate: coordinate,
                                                    countryCode: countryCode,
                                                    timeZoneIdentifier: timeZoneIdentifier).presentation()
            guard !Task.isCancelled else { return }
            presentation = evaluated
        }
    }
}

private struct PlaceDetailsContactLinksSection: View {
    let details: PlaceDetails

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { links }
            VStack(alignment: .leading, spacing: 12) { links }
        }
        .font(.subheadline.weight(.medium))
    }

    @ViewBuilder
    private var links: some View {
        if let phone = details.phone, let url = details.phoneURL {
            Link(destination: url) { Label(phone, systemImage: "phone") }
        }
        if let website = details.websiteURL {
            Link(destination: website) { Label("Strona", systemImage: "globe") }
        }
    }
}

private struct PlaceParkingInformationSection: View {
    let parking: ParkingInformation
    let details: PlaceDetails
    @Binding var showHours: Bool

    var body: some View {
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
                PlaceParkingOpeningHoursDisclosure(
                    rawHours: openingHours,
                    details: details,
                    isExpanded: $showHours)
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
}

private struct PlaceParkingOpeningHoursDisclosure: View {
    let rawHours: String
    let details: PlaceDetails
    @Binding var isExpanded: Bool
    @State private var presentation: OpeningHoursPresentation?

    private var evaluationKey: String {
        [rawHours, details.countryCode ?? "", details.timeZoneIdentifier ?? "",
         details.coordinate.map { String($0.latitude) } ?? "",
         details.coordinate.map { String($0.longitude) } ?? ""].joined(separator: "|")
    }

    var body: some View {
        DisclosureGroup("Godziny parkowania", isExpanded: $isExpanded) {
            if let rows = presentation?.weeklyRows {
                ForEach(Array(rows.enumerated()), id: \.offset) { item in
                    HStack {
                        Text(item.element.day).frame(width: 46, alignment: .leading)
                        Text(item.element.hours)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if let failure = presentation?.failure {
                Text(failure.errorDescription ?? "Godziny niedostępne")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(rawHours).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(rawHours).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Godziny mogą się różnić w święta.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
        .task(id: evaluationKey) {
            guard !Task.isCancelled else { return }
            let evaluated = await PlaceOpeningHours(rawValue: rawHours,
                                                    coordinate: details.coordinate,
                                                    countryCode: details.countryCode,
                                                    timeZoneIdentifier: details.timeZoneIdentifier).presentation()
            guard !Task.isCancelled else { return }
            presentation = evaluated
        }
    }
}
