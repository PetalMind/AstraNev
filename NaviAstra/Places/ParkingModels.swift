import Foundation

enum ParkingFeeStatus: String, Codable, Sendable {
    case free
    case paid
    case conditional
    case unknown

    var title: String {
        switch self {
        case .free: "Bezpłatny"
        case .paid: "Płatny"
        case .conditional: "Zależnie od warunków"
        case .unknown: "Brak danych"
        }
    }
}

enum ParkingDataSource: String, Codable, Sendable {
    case openStreetMap
    case municipalOpenData
    case provider

    var title: String {
        switch self {
        case .openStreetMap: "OpenStreetMap"
        case .municipalOpenData: "Miejskie Open Data"
        case .provider: "Dostawca parkingowy"
        }
    }
}

struct ParkingPrice: Codable, Equatable, Sendable {
    let amount: Decimal
    let currencyCode: String?
    let unit: String?
}

struct ParkingTariff: Codable, Equatable, Sendable {
    let status: ParkingFeeStatus
    let chargeDescription: String?
    let conditionalCharge: String?
    let feeCondition: String?
    let hourlyRate: ParkingPrice?
    let firstHourRate: ParkingPrice?
    let subsequentHourRate: ParkingPrice?
    let dailyRate: ParkingPrice?
    let currencyCode: String?
    let freeMinutes: Int?

    static func fromOSMTags(_ tags: [String: String]) -> ParkingTariff {
        let fee = tags["fee"]?.lowercased()
        let feeCondition = tags["fee:conditional"]
        let charge = tags["charge"]
        let conditionalCharge = tags["charge:conditional"]
        let conditionalFee = feeCondition?.lowercased() ?? ""
        let hasConditionalFee = !conditionalFee.isEmpty
        let conditionalSaysPaid = conditionalFee.contains("yes")
        let status: ParkingFeeStatus
        if fee == "yes" {
            status = conditionalSaysPaid ? .conditional : .paid
        } else if fee == "no" {
            status = conditionalSaysPaid ? .conditional : .free
        } else if hasConditionalFee || conditionalCharge != nil {
            status = .conditional
        } else if charge != nil {
            status = .paid
        } else {
            status = .unknown
        }

        let currency = tags["currency"] ?? tags.keys
            .first(where: { $0.hasPrefix("currency:") && tags[$0]?.lowercased() == "yes" })
            .map { String($0.dropFirst("currency:".count)) }

        return ParkingTariff(
            status: status,
            chargeDescription: charge,
            conditionalCharge: conditionalCharge,
            feeCondition: feeCondition,
            hourlyRate: parsePrice(tags["charge:hourly"] ?? tags["charge:hour"],
                                   defaultUnit: "hour", currency: currency) ??
                parsePrice(charge, defaultUnit: nil, currency: currency).flatMap { $0.unit == "hour" ? $0 : nil },
            firstHourRate: parsePrice(tags["charge:first_hour"], defaultUnit: "hour", currency: currency),
            subsequentHourRate: parsePrice(tags["charge:subsequent_hour"] ?? tags["charge:sequelae"],
                                           defaultUnit: "hour", currency: currency),
            dailyRate: parsePrice(tags["charge:daily"] ?? tags["charge:day"],
                                  defaultUnit: "day", currency: currency) ??
                parsePrice(charge, defaultUnit: nil, currency: currency).flatMap { $0.unit == "day" ? $0 : nil },
            currencyCode: currency,
            freeMinutes: parseFreeMinutes(from: feeCondition, baseFee: fee)
        )
    }

    private static func parsePrice(_ rawValue: String?, defaultUnit: String?, currency fallbackCurrency: String?) -> ParkingPrice? {
        guard let rawValue else { return nil }
        if defaultUnit == nil {
            let explicitUnitPattern = #"(?i)^\s*(?:(?:PLN|EUR|USD|GBP|CZK|zł|€|\$)\s*)?[0-9]+(?:[.,][0-9]+)?\s*(?:PLN|EUR|USD|GBP|CZK|zł|€|\$)?\s*(?:/|per\s*)(?:hour|h|day|d)\s*$"#
            guard let expression = try? NSRegularExpression(pattern: explicitUnitPattern),
                  expression.firstMatch(in: rawValue, range: NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)) != nil else {
                return nil
            }
        }
        guard let amount = parseAmount(rawValue) else { return nil }
        let currencyExpression = #"(?i)(PLN|EUR|USD|GBP|CZK|zł|€|\$)"#
        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        let foundCurrency = (try? NSRegularExpression(pattern: currencyExpression))?
            .firstMatch(in: rawValue, range: range)
            .flatMap { Range($0.range, in: rawValue).map { String(rawValue[$0]) } }
        let currencyCode: String?
        switch (foundCurrency ?? fallbackCurrency)?.lowercased() {
        case "zł", "pln": currencyCode = "PLN"
        case "€", "eur": currencyCode = "EUR"
        case "$", "usd": currencyCode = "USD"
        case "gbp": currencyCode = "GBP"
        case "czk": currencyCode = "CZK"
        case let value?: currencyCode = value.uppercased()
        case nil: currencyCode = nil
        }
        let lowercased = rawValue.lowercased()
        let unit = lowercased.contains("/hour") || lowercased.contains("/h") || lowercased.contains("per hour")
            ? "hour" : lowercased.contains("/day") || lowercased.contains("/d") || lowercased.contains("per day")
                ? "day" : defaultUnit
        return ParkingPrice(amount: amount, currencyCode: currencyCode, unit: unit)
    }

    private static func parseAmount(_ value: String) -> Decimal? {
        guard let expression = try? NSRegularExpression(pattern: #"[0-9]+(?:[.,][0-9]+)?"#) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let matchRange = Range(match.range, in: value) else { return nil }
        return Decimal(string: value[matchRange].replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func parseFreeMinutes(from condition: String?, baseFee: String?) -> Int? {
        guard let condition,
              let expression = try? NSRegularExpression(
                pattern: #"(?i)(?:stay|duration)\s*(?:<|>)\s*([0-9]+(?:[.,][0-9]+)?)\s*(minutes?|mins?|min|hours?|hrs?|h|days?|d)"#
              ) else { return nil }
        let range = NSRange(condition.startIndex..<condition.endIndex, in: condition)
        guard let match = expression.firstMatch(in: condition, range: range),
              let amountRange = Range(match.range(at: 1), in: condition),
              let durationRange = Range(match.range, in: condition),
              let unitRange = Range(match.range(at: 2), in: condition),
              let amount = Double(condition[amountRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit = condition[unitRange].lowercased()
        let multiplier = unit.hasPrefix("d") ? 1_440.0 : unit.hasPrefix("h") ? 60.0 : 1.0
        let minutes = Int((amount * multiplier).rounded())
        guard minutes > 0 else { return nil }
        let lowercased = condition.lowercased()
        guard let atRange = lowercased.range(of: "@") else { return nil }
        let conditionalValue = lowercased[..<atRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let conditionalRule = lowercased[atRange.upperBound...]
        let compactRule = conditionalRule.filter { !$0.isWhitespace && $0 != "(" && $0 != ")" }
        let compactDuration = condition[durationRange].lowercased()
            .filter { !$0.isWhitespace && $0 != "(" && $0 != ")" }
        guard compactRule == compactDuration else { return nil }
        if lowercased.contains("stay >") || lowercased.contains("duration >") {
            return baseFee == "no" && conditionalValue == "yes" ? minutes : nil
        }
        return baseFee == "yes" && conditionalValue == "no" ? minutes : nil
    }
}

enum ParkingSide: String, Codable, Hashable, Sendable {
    case left
    case right
    case both

    var title: String {
        switch self {
        case .left: "Lewa strona"
        case .right: "Prawa strona"
        case .both: "Obie strony"
        }
    }
}

struct ParkingSideRule: Codable, Equatable, Sendable {
    let side: ParkingSide
    let parkingType: String?
    let parkingCondition: String?
    let parkingConditionConditional: String?
    let fee: String?
    let charge: String?
    let chargeConditional: String?
    let maxStay: String?
    let maxStayConditional: String?
    let access: String?
    let openingHours: String?
    let feeCondition: String?
    let restriction: String?
    let restrictionConditional: String?
}

struct ParkingInformation: Codable, Equatable, Sendable {
    let tariff: ParkingTariff
    let capacity: Int?
    let maxStay: String?
    let maxStayMinutes: Int?
    let maxStayConditional: String?
    let openingHours: String?
    let access: String?
    let accessConditional: String?
    let parkingType: String?
    let streetSides: [ParkingSideRule]
    let dataSources: [ParkingDataSource]
    let availableSpaces: Int?

    static func fromOSMTags(_ tags: [String: String]) -> ParkingInformation? {
        let streetSides = ParkingSide.allCases.compactMap { side -> ParkingSideRule? in
            let prefix = "parking:\(side.rawValue)"
            let conditionPrefix = "parking:condition:\(side.rawValue)"
            let type = tags[prefix] ?? tags["parking:lane:\(side.rawValue)"]
            let parkingCondition = tags[conditionPrefix]
            let parkingConditionConditional = tags["\(conditionPrefix):conditional"]
            let fee = tags["\(prefix):fee"]
            let charge = tags["\(prefix):charge"]
            let chargeConditional = tags["\(prefix):charge:conditional"]
            let maxStay = tags["\(prefix):maxstay"] ?? tags["\(conditionPrefix):maxstay"]
            let maxStayConditional = tags["\(prefix):maxstay:conditional"] ?? tags["\(conditionPrefix):maxstay:conditional"]
            let access = tags["\(prefix):access"] ?? tags["\(conditionPrefix):access"]
            let openingHours = tags["\(prefix):opening_hours"]
            let feeCondition = tags["\(prefix):fee:conditional"]
            let restriction = tags["\(prefix):restriction"]
            let restrictionConditional = tags["\(prefix):restriction:conditional"]
            guard type != nil || parkingCondition != nil || parkingConditionConditional != nil || fee != nil ||
                    charge != nil || chargeConditional != nil || maxStay != nil || maxStayConditional != nil ||
                    access != nil || openingHours != nil || restriction != nil || restrictionConditional != nil else {
                return nil
            }
            return ParkingSideRule(side: side, parkingType: type,
                                   parkingCondition: parkingCondition,
                                   parkingConditionConditional: parkingConditionConditional,
                                   fee: fee, charge: charge, chargeConditional: chargeConditional,
                                   maxStay: maxStay, maxStayConditional: maxStayConditional,
                                   access: access, openingHours: openingHours,
                                   feeCondition: feeCondition, restriction: restriction,
                                   restrictionConditional: restrictionConditional)
        }
        guard tags["amenity"] == "parking" || !streetSides.isEmpty else { return nil }

        let capacity = tags["capacity"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let maxStay = tags["maxstay"]
        return ParkingInformation(tariff: .fromOSMTags(tags),
                                  capacity: capacity,
                                  maxStay: maxStay,
                                  maxStayMinutes: parseDurationMinutes(maxStay),
                                  maxStayConditional: tags["maxstay:conditional"],
                                  openingHours: tags["opening_hours"],
                                  access: tags["access"],
                                  accessConditional: tags["access:conditional"],
                                  parkingType: tags["parking"],
                                  streetSides: streetSides,
                                  dataSources: [.openStreetMap],
                                  availableSpaces: nil)
    }

    static var unknown: ParkingInformation {
        ParkingInformation(tariff: ParkingTariff(status: .unknown, chargeDescription: nil,
                                                 conditionalCharge: nil, feeCondition: nil,
                                                 hourlyRate: nil, firstHourRate: nil,
                                                 subsequentHourRate: nil, dailyRate: nil,
                                                 currencyCode: nil, freeMinutes: nil),
                           capacity: nil, maxStay: nil, maxStayMinutes: nil,
                           maxStayConditional: nil, openingHours: nil,
                           access: nil, accessConditional: nil, parkingType: nil,
                           streetSides: [], dataSources: [], availableSpaces: nil)
    }

    private static func parseDurationMinutes(_ value: String?) -> Int? {
        guard let value,
              let expression = try? NSRegularExpression(pattern: #"(?i)^\s*([0-9]+(?:[.,][0-9]+)?)\s*(minutes?|mins?|min|hours?|hrs?|h|days?|d)\s*$"#) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let amountRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let amount = Double(value[amountRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit = value[unitRange].lowercased()
        let multiplier = unit.hasPrefix("d") ? 1_440.0 : unit.hasPrefix("h") ? 60.0 : 1.0
        let minutes = Int((amount * multiplier).rounded())
        return minutes > 0 ? minutes : nil
    }
}

private extension ParkingSide {
    static var allCases: [ParkingSide] { [.left, .right, .both] }
}
