import Foundation

enum PlacePOIMapMarkerKind: String, CaseIterable, Sendable {
    case fuel, parking, parkRide, charging, food, shopping, health, attraction, transit, lodging, generic

    var symbolName: String {
        switch self {
        case .fuel: "fuelpump.fill"
        case .parking, .parkRide: "parkingsign.circle.fill"
        case .charging: "bolt.car.fill"
        case .food: "fork.knife"
        case .shopping: "bag.fill"
        case .health: "cross.case.fill"
        case .attraction: "sparkles"
        case .transit: "tram.fill"
        case .lodging: "bed.double.fill"
        case .generic: "mappin.and.ellipse"
        }
    }

    var accessibilityName: String {
        switch self {
        case .fuel: "Stacja paliw"
        case .parking: "Parking"
        case .parkRide: "Parking P+R"
        case .charging: "Ładowarka samochodów elektrycznych"
        case .food: "Gastronomia"
        case .shopping: "Sklep"
        case .health: "Ochrona zdrowia"
        case .attraction: "Atrakcja"
        case .transit: "Transport publiczny"
        case .lodging: "Nocleg"
        case .generic: "Miejsce"
        }
    }

    var tileValues: [String] {
        switch self {
        case .fuel: ["fuel", "gas_station", "gasstation"]
        case .parking: ["parking"]
        case .parkRide: ["park_ride", "parkride", "park_and_ride"]
        case .charging: ["charging_station", "ev_charger", "ev_charging"]
        case .food: ["food", "restaurant", "cafe", "fast_food", "bar", "pub", "bakery"]
        case .shopping: ["shop", "grocery", "supermarket", "mall", "clothes", "convenience"]
        case .health: ["hospital", "pharmacy", "doctor", "doctors", "clinic"]
        case .attraction: ["attraction", "museum", "monument", "viewpoint", "castle", "theatre", "theater", "park"]
        case .transit: ["bus", "rail", "railway", "station", "bus_stop", "tram_stop", "subway", "airport", "public_transport"]
        case .lodging: ["lodging", "hotel", "hostel", "motel", "guest_house", "camp_site"]
        case .generic: []
        }
    }

    init?(category: String?) {
        guard let category else { return nil }
        let value = category.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !value.isEmpty else { return nil }
        if value.contains("parkride") || value.contains("parkandride") { self = .parkRide }
        else if value.contains("gasstation") || value.contains("fuel") { self = .fuel }
        else if value.contains("parking") { self = .parking }
        else if value.contains("chargingstation") || value.contains("evcharger") || value.contains("evcharging") { self = .charging }
        else if ["food", "restaurant", "cafe", "fastfood", "bar", "pub", "bakery"].contains(where: { value.contains($0) }) { self = .food }
        else if ["shop", "grocery", "supermarket", "mall", "clothes", "convenience", "store"].contains(where: { value.contains($0) }) { self = .shopping }
        else if ["hospital", "pharmacy", "doctor", "clinic"].contains(where: { value.contains($0) }) { self = .health }
        else if ["attraction", "museum", "monument", "viewpoint", "castle", "theatre", "theater", "park"].contains(where: { value.contains($0) }) { self = .attraction }
        else if ["bus", "rail", "railway", "station", "tram", "subway", "airport", "publictransport"].contains(where: { value.contains($0) }) { self = .transit }
        else if ["lodging", "hotel", "hostel", "motel", "guesthouse", "campsite"].contains(where: { value.contains($0) }) { self = .lodging }
        else { return nil }
    }
}

/// Semantic backgrounds for POI markers. Their accent comes from the app's AccentColor asset.
enum PlacePOIMapPalette {
    static func backgroundHex(dark: Bool) -> UInt32 { dark ? 0x17283A : 0xF9FCFF }
}

#if os(iOS)
import UIKit

extension PlacePOIMapPalette {
    @MainActor static func accentColor(dark: Bool) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        return UIColor(named: "AccentColor", in: nil, compatibleWith: traits)
            ?? UIColor(red: CGFloat(8) / 255, green: CGFloat(124) / 255,
                       blue: CGFloat(243) / 255, alpha: 1)
    }
}

extension PlacePOIMapMarkerKind {
    @MainActor func makeMapStyleImage(dark: Bool) -> UIImage {
        let size = CGSize(width: 36, height: 36)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            let path = CGPath(roundedRect: rect, cornerWidth: 11, cornerHeight: 11, transform: nil)
            context.setFillColor(UIColor(
                red: CGFloat((PlacePOIMapPalette.backgroundHex(dark: dark) >> 16) & 0xff) / 255,
                green: CGFloat((PlacePOIMapPalette.backgroundHex(dark: dark) >> 8) & 0xff) / 255,
                blue: CGFloat(PlacePOIMapPalette.backgroundHex(dark: dark) & 0xff) / 255,
                alpha: 1).cgColor)
            context.addPath(path)
            context.fillPath()

            let accentColor = PlacePOIMapPalette.accentColor(dark: dark)
            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(1.8)
            context.addPath(path)
            context.strokePath()

            let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(accentColor, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 9, y: 9, width: 18, height: 18))
        }
    }
}
#elseif os(macOS)
import AppKit

extension PlacePOIMapPalette {
    static func accentColor(dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? .current
        return NSColor(named: NSColor.Name("AccentColor"))?.resolvedColor(with: appearance)
            ?? NSColor(srgbRed: CGFloat(8) / 255, green: CGFloat(124) / 255,
                       blue: CGFloat(243) / 255, alpha: 1)
    }
}
#endif
