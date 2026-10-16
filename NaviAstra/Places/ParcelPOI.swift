import Foundation

/// OSM postal services can be separate machines or a secondary service in a shop.
nonisolated enum ParcelPOI {
    enum Scope { case all, lockers, pickup }

    struct Query {
        var scope: Scope = .all
        var operatorPattern: String? = nil

        var filters: [String] {
            let lockers = [
                "[amenity=parcel_locker]",
                "[amenity=vending_machine][vending~\"(^|;)parcel_(pickup|mail_in)(;|$)\"]"
            ]
            let pickup = [
                "[amenity=post_office]",
                "[post_office=post_partner]",
                "[\"post_office:parcel_pickup\"][\"post_office:parcel_pickup\"!~\"^(no|false|0)$\",i]",
                "[\"post_office:parcel_to\"][\"post_office:parcel_to\"!~\"^(no|false|0)$\",i]"
            ]
            let selected = scope == .lockers ? lockers : scope == .pickup ? pickup : lockers + pickup
            guard let operatorPattern else { return selected }
            return selected.map {
                $0 + "[~\"^(name|brand|operator|post_office:(brand|service_provider|parcel_pickup|parcel_to))$\"~\"\(operatorPattern)\",i]"
            }
        }

        func selectors(around area: String) -> String {
            "(" + filters.map { "nwr\($0)(\(area));" }.joined() + ");"
        }

        @MainActor func matches(_ result: SearchResult) -> Bool {
            let category = QueryClassifier.normalize(result.category ?? "").filter { $0.isLetter || $0.isNumber }
            let name = QueryClassifier.normalize(result.destination.name)
            let isLocker = category == "parcellocker" || category == "vendingmachine"
                && name.range(of: "paczkomat|automat paczkowy|parcel|locker", options: .regularExpression) != nil
                || name.range(of: "paczkomat|appkomat|lodowkomat|automat paczkowy|one box|packstation|pickup station|dhl box|amazon locker", options: .regularExpression) != nil
            let isPickup = category == "parcelpickup" || category.hasSuffix("postoffice")
                || name.range(of: "punkt (odbioru|nadania)|paczko(punkt|stacja)|parcel shop|parcelshop|service ?point", options: .regularExpression) != nil
            let matchesScope = scope == .lockers ? isLocker
                : scope == .pickup ? isPickup && !isLocker : isLocker || isPickup
            guard matchesScope else {
                return false
            }
            guard let operatorPattern else { return true }
            return [result.destination.name, result.brand, result.operatorName].compactMap { $0 }.contains {
                $0.range(of: operatorPattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
    }

    struct Operator {
        let title: String
        let pattern: String
        let aliases: [String]
    }

    static let operators: [Operator] = [
        Operator(title: "InPost", pattern: "inpost", aliases: ["inpost", "in post"]),
        Operator(title: "DPD", pattern: "dpd", aliases: ["dpd pickup station", "dpd pickup", "dpd"]),
        Operator(title: "DHL", pattern: "dhl", aliases: ["dhl box 24/7", "dhl packstation", "dhl box", "dhl pop", "dhl"]),
        Operator(title: "ORLEN Paczka", pattern: "orlen|ruch", aliases: ["orlen paczka", "orlen paczki", "paczka w ruchu"]),
        Operator(title: "Allegro One", pattern: "allegro|one[ _-]+box|one[ _-]+punkt", aliases: ["allegro one box", "allegro one punkt", "allegro one", "one box", "one punkt", "allegro"]),
        Operator(title: "Pocztex", pattern: "pocztex|poczta[ _-]+polska", aliases: ["pocztex automat", "pocztex", "poczta polska"]),
        Operator(title: "GLS", pattern: "gls", aliases: ["gls parcelshop", "gls"]),
        Operator(title: "UPS", pattern: "ups", aliases: ["ups access point", "ups"]),
        Operator(title: "FedEx", pattern: "fedex", aliases: ["fedex"]),
        Operator(title: "Amazon Locker", pattern: "amazon", aliases: ["amazon hub locker", "amazon locker"])
    ]

    static func category(tags: [String: String], includePickupServices: Bool = true) -> String? {
        if tags["amenity"] == "parcel_locker" || isLegacyLocker(tags) { return "parcel_locker" }
        if tags["amenity"] == "post_office" { return "post_office" }
        if includePickupServices && (tags["post_office"] == "post_partner"
            || hasService(tags["post_office:parcel_pickup"])
            || hasService(tags["post_office:parcel_to"])) { return "parcel_pickup" }
        return nil
    }

    static func name(tags: [String: String], fallback: String, includePickupServices: Bool = true) -> String {
        guard let category = category(tags: tags, includePickupServices: includePickupServices) else {
            return nonempty(tags["name"]) ?? nonempty(tags["brand"]) ?? nonempty(tags["operator"]) ?? fallback
        }
        let title = nonempty(tags["name"])
            ?? brand(tags: tags) ?? operatorName(tags: tags)
            ?? (category == "parcel_locker" ? "Automat paczkowy" : "Punkt odbioru przesyłek")
        guard category == "parcel_locker", let reference = nonempty(tags["ref"]),
              !title.localizedCaseInsensitiveContains(reference) else { return title }
        return "\(title) · \(reference)"
    }

    static func brand(tags: [String: String], includePickupServices: Bool = true) -> String? {
        if category(tags: tags, includePickupServices: includePickupServices) == "parcel_pickup" {
            return formattedServices(tags["post_office:brand"]) ?? nonempty(tags["brand"])
        }
        return nonempty(tags["brand"])
    }

    static func operatorName(tags: [String: String], includePickupServices: Bool = true) -> String? {
        guard category(tags: tags, includePickupServices: includePickupServices) != nil else { return nonempty(tags["operator"]) }
        // The shop's operator is not necessarily the carrier providing pickup.
        return formattedServices(tags["post_office:service_provider"])
            ?? serviceProvider(tags["post_office:parcel_pickup"])
            ?? serviceProvider(tags["post_office:parcel_to"])
            ?? nonempty(tags["operator"])
    }

    static func openingHours(tags: [String: String], includePickupServices: Bool = true) -> String? {
        category(tags: tags, includePickupServices: includePickupServices) == nil ? tags["opening_hours"]
            : tags["post_office:opening_hours"] ?? tags["opening_hours"]
    }

    private static func isLegacyLocker(_ tags: [String: String]) -> Bool {
        tags["amenity"] == "vending_machine"
            && (tags["vending"] ?? "").split(separator: ";").contains {
                ["parcel_pickup", "parcel_mail_in"].contains($0.trimmingCharacters(in: .whitespaces))
            }
    }

    private static func hasService(_ value: String?) -> Bool {
        guard let value = nonempty(value)?.lowercased() else { return false }
        return !["no", "false", "0"].contains(value)
    }

    private static func serviceProvider(_ value: String?) -> String? {
        guard hasService(value), let value = nonempty(value), value.lowercased() != "yes" else { return nil }
        return formattedServices(value)
    }

    private static func formattedServices(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        return value.split(separator: ";").map { service in
            let service = service.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = QueryClassifier.normalize(service).replacingOccurrences(of: "_", with: " ")
            if normalized == "poczta polska" { return "Poczta Polska" }
            if let carrier = operators.first(where: { normalized.range(of: $0.pattern, options: .regularExpression) != nil }) {
                return carrier.title
            }
            return service.replacingOccurrences(of: "_", with: " ")
        }.joined(separator: " · ")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
