import Foundation

enum PlacePOIMapMarkerKind: String, CaseIterable, Sendable {
    case fuel, parking, parkRide, charging, food, shopping, health, attraction, transit, lodging, cafe, nature, culture, airport, generic

    var symbolName: String {
        switch self {
        case .fuel: "fuelpump.fill"
        case .parking, .parkRide: "parkingsign"
        case .charging: "bolt.car.fill"
        case .food: "fork.knife"
        case .shopping: "bag.fill"
        case .health: "cross.case.fill"
        case .attraction: "camera.fill"
        case .transit: "tram.fill"
        case .lodging: "bed.double.fill"
        case .cafe: "cup.and.saucer.fill"
        case .nature: "leaf.fill"
        case .culture: "building.columns.fill"
        case .airport: "airplane"
        case .generic: "mappin"
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
        case .cafe: "Kawiarnia"
        case .nature: "Park i rekreacja"
        case .culture: "Kultura i zabytki"
        case .airport: "Lotnisko"
        case .generic: "Miejsce"
        }
    }

    var tileValues: [String] {
        switch self {
        case .fuel: ["fuel", "gas_station", "gasstation"]
        case .parking: ["parking"]
        case .parkRide: ["park_ride", "parkride", "park_and_ride"]
        case .charging: ["charging_station", "ev_charger", "ev_charging"]
        case .food: ["food", "restaurant", "fast_food", "bar", "pub", "bakery"]
        case .shopping: ["shop", "grocery", "supermarket", "mall", "clothes", "convenience"]
        case .health: ["hospital", "pharmacy", "doctor", "doctors", "clinic"]
        case .attraction: ["attraction", "viewpoint"]
        case .transit: ["bus", "rail", "railway", "station", "bus_stop", "tram_stop", "subway", "public_transport"]
        case .lodging: ["lodging", "hotel", "hostel", "motel", "guest_house", "camp_site"]
        case .cafe: ["cafe"]
        case .nature: ["park"]
        case .culture: ["museum", "monument", "castle", "theatre", "theater"]
        case .airport: ["airport"]
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
        else if value.contains("cafe") { self = .cafe }
        else if value.hasSuffix("park") { self = .nature }
        else if ["museum", "monument", "castle", "theatre", "theater"].contains(where: { value.contains($0) }) { self = .culture }
        else if value.contains("airport") { self = .airport }
        else if ["food", "restaurant", "cafe", "fastfood", "bar", "pub", "bakery"].contains(where: { value.contains($0) }) { self = .food }
        else if ["shop", "grocery", "supermarket", "mall", "clothes", "convenience", "store"].contains(where: { value.contains($0) }) { self = .shopping }
        else if ["hospital", "pharmacy", "doctor", "clinic"].contains(where: { value.contains($0) }) { self = .health }
        else if ["attraction", "viewpoint"].contains(where: { value.contains($0) }) { self = .attraction }
        else if ["bus", "rail", "railway", "station", "tram", "subway", "airport", "publictransport"].contains(where: { value.contains($0) }) { self = .transit }
        else if ["lodging", "hotel", "hostel", "motel", "guesthouse", "campsite"].contains(where: { value.contains($0) }) { self = .lodging }
        else { return nil }
    }
}

extension PlacePOIMapMarkerKind {
    /// Category identity stays consistent across map tiles, search pins and nearby filters.
    func colorHex(dark: Bool) -> UInt32 {
        switch self {
        case .fuel: dark ? 0xC49BEB : 0x8054A8
        case .parking, .parkRide, .transit, .airport: dark ? 0x82B4EC : 0x286DB5
        case .charging, .nature: dark ? 0x81C698 : 0x327D4B
        case .food, .cafe: dark ? 0xF1AF70 : 0xAF5C20
        case .shopping: dark ? 0x85AFDD : 0x456FA4
        case .health: dark ? 0xF19B9B : 0xBD444A
        case .attraction, .culture: dark ? 0xB49BEB : 0x7953AF
        case .lodging: dark ? 0xD69CCA : 0x995785
        case .generic: dark ? 0xACBAC8 : 0x5B6B7C
        }
    }
}

/// Neutral marker rims separate category colors from the underlying map.
enum PlacePOIMapPalette {
    static func backgroundHex(dark: Bool) -> UInt32 { dark ? 0x26313D : 0xFFFFFF }
}

#if os(iOS)
import UIKit

extension PlacePOIMapPalette {
    @MainActor static func accentColor(dark: Bool) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        return UIColor(named: "AccentColor", in: nil, compatibleWith: traits)
            ?? UIColor(naviHex: dark
                ? NaviAstraColorPalette.brandPrimaryNight : NaviAstraColorPalette.brandPrimaryDay)
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
            let path = CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.height / 2, transform: nil)
            let categoryColor = UIColor(naviHex: colorHex(dark: dark))
            context.setFillColor(categoryColor.cgColor)
            context.addPath(path)
            context.fillPath()

            let rim = UIColor(naviHex: PlacePOIMapPalette.backgroundHex(dark: dark))
            context.setStrokeColor(rim.cgColor)
            context.setLineWidth(1.8)
            context.addPath(path)
            context.strokePath()

            let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            if let glyph = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(dark ? UIColor(naviHex: 0x17212B) : .white, renderingMode: .alwaysOriginal) {
                let scale = 18 / max(glyph.size.width, glyph.size.height)
                let glyphSize = CGSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
                glyph.draw(in: CGRect(x: (size.width - glyphSize.width) / 2,
                                      y: (size.height - glyphSize.height) / 2,
                                      width: glyphSize.width, height: glyphSize.height))
            }
        }
    }
}
#elseif os(macOS)
import AppKit

extension PlacePOIMapPalette {
    static func accentColor(dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        let fallback = NSColor(naviHex: dark
            ? NaviAstraColorPalette.brandPrimaryNight : NaviAstraColorPalette.brandPrimaryDay)
        guard let namedColor = NSColor(named: NSColor.Name("AccentColor")) else { return fallback }
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = namedColor.usingColorSpace(.deviceRGB)
        }
        return resolvedColor ?? fallback
    }
}
#endif

#if os(iOS)
extension UIImage {
    @MainActor func shopPOIMarkerImage() -> UIImage {
        let size = CGSize(width: 36, height: 36)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            renderer.cgContext.setFillColor(UIColor.white.cgColor)
            renderer.cgContext.fillEllipse(in: circle)
            renderer.cgContext.setStrokeColor(UIColor(naviHex: 0xD6DEE6).cgColor)
            renderer.cgContext.setLineWidth(1.8)
            renderer.cgContext.strokeEllipse(in: circle)
            guard self.size.width > 0, self.size.height > 0 else { return }
            let scale = 24 / max(self.size.width, self.size.height)
            let fitted = CGSize(width: self.size.width * scale, height: self.size.height * scale)
            draw(in: CGRect(x: (36 - fitted.width) / 2, y: (36 - fitted.height) / 2,
                            width: fitted.width, height: fitted.height))
        }
    }
}
#endif
