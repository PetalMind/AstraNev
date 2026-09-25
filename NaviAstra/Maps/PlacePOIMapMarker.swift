import CoreGraphics
import Foundation

enum PlacePOIMapMarkerKind: String, CaseIterable, Sendable {
    case fuel, parking, parkRide, charging, food, shopping, health, attraction, transit, lodging, generic

    var accentHex: UInt32 {
        switch self {
        case .fuel: 0xC87918
        case .parking: 0x5369B5
        case .parkRide: 0x8060B5
        case .charging: 0x168A73
        case .food: 0xC85F4D
        case .shopping: 0x9A5CA6
        case .health: 0xC64E57
        case .attraction: 0xA15E91
        case .transit: 0x377CA7
        case .lodging: 0x617687
        case .generic: 0x647681
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

enum PlacePOIMapGlyph {
    static func draw(_ kind: PlacePOIMapMarkerKind, in context: CGContext, rect: CGRect, color: CGColor) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 24, y: rect.height / 24)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(1.9)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch kind {
        case .fuel:
            strokeRoundedRect(in: context, rect: CGRect(x: 5, y: 4, width: 10, height: 16), radius: 1.5)
            strokeRoundedRect(in: context, rect: CGRect(x: 7, y: 6, width: 6, height: 4), radius: 0.6)
            context.beginPath()
            context.move(to: CGPoint(x: 15, y: 7))
            context.addLine(to: CGPoint(x: 17, y: 8.5))
            context.addLine(to: CGPoint(x: 17, y: 17))
            context.addQuadCurve(to: CGPoint(x: 19, y: 17), control: CGPoint(x: 18, y: 18))
            context.addLine(to: CGPoint(x: 19, y: 13))
            context.strokePath()
            strokeLine(context, [(7, 20), (13, 20)])
        case .parking:
            strokeCircle(in: context, rect: CGRect(x: 3, y: 3, width: 18, height: 18))
            strokeLine(context, [(9, 17), (9, 7), (13, 7)])
            context.beginPath()
            context.move(to: CGPoint(x: 13, y: 7))
            context.addCurve(to: CGPoint(x: 13, y: 13), control1: CGPoint(x: 17, y: 7), control2: CGPoint(x: 17, y: 13))
            context.addLine(to: CGPoint(x: 9, y: 13))
            context.strokePath()
        case .parkRide:
            strokeLine(context, [(6, 18), (6, 6), (11, 6)])
            context.beginPath()
            context.move(to: CGPoint(x: 11, y: 6))
            context.addCurve(to: CGPoint(x: 11, y: 12), control1: CGPoint(x: 15, y: 6), control2: CGPoint(x: 15, y: 12))
            context.addLine(to: CGPoint(x: 6, y: 12))
            context.strokePath()
            strokeLine(context, [(14, 8), (19, 8), (19, 13)])
            strokeLine(context, [(17, 11), (19, 13), (21, 11)])
            strokeLine(context, [(20, 16), (15, 16), (15, 20)])
            strokeLine(context, [(17, 18), (15, 20), (13, 18)])
        case .charging:
            strokeRoundedRect(in: context, rect: CGRect(x: 6, y: 3, width: 12, height: 18), radius: 2)
            context.beginPath()
            context.move(to: CGPoint(x: 14, y: 6))
            context.addLine(to: CGPoint(x: 10, y: 12))
            context.addLine(to: CGPoint(x: 13, y: 12))
            context.addLine(to: CGPoint(x: 10, y: 18))
            context.addLine(to: CGPoint(x: 16, y: 10))
            context.addLine(to: CGPoint(x: 13, y: 10))
            context.closePath()
            context.fillPath()
        case .food:
            strokeLine(context, [(6, 4), (6, 10), (9, 10), (9, 4)])
            strokeLine(context, [(7.5, 10), (7.5, 20)])
            context.beginPath()
            context.move(to: CGPoint(x: 17, y: 4))
            context.addCurve(to: CGPoint(x: 15, y: 10), control1: CGPoint(x: 17, y: 7), control2: CGPoint(x: 16, y: 9))
            context.addLine(to: CGPoint(x: 16, y: 20))
            context.strokePath()
        case .shopping:
            strokeRoundedRect(in: context, rect: CGRect(x: 4, y: 8, width: 16, height: 12), radius: 1.5)
            context.beginPath()
            context.move(to: CGPoint(x: 8, y: 9))
            context.addCurve(to: CGPoint(x: 16, y: 9), control1: CGPoint(x: 8, y: 3), control2: CGPoint(x: 16, y: 3))
            context.strokePath()
        case .health:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 9, y: 3)); path.addLine(to: CGPoint(x: 15, y: 3))
            path.addLine(to: CGPoint(x: 15, y: 9)); path.addLine(to: CGPoint(x: 21, y: 9))
            path.addLine(to: CGPoint(x: 21, y: 15)); path.addLine(to: CGPoint(x: 15, y: 15))
            path.addLine(to: CGPoint(x: 15, y: 21)); path.addLine(to: CGPoint(x: 9, y: 21))
            path.addLine(to: CGPoint(x: 9, y: 15)); path.addLine(to: CGPoint(x: 3, y: 15))
            path.addLine(to: CGPoint(x: 3, y: 9)); path.addLine(to: CGPoint(x: 9, y: 9))
            path.closeSubpath()
            context.addPath(path); context.fillPath()
        case .attraction:
            let center = CGPoint(x: 12, y: 12)
            let path = CGMutablePath()
            for index in 0..<10 {
                let radius: CGFloat = index.isMultiple(of: 2) ? 9 : 4
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath(); context.addPath(path); context.fillPath()
        case .transit:
            strokeRoundedRect(in: context, rect: CGRect(x: 4, y: 4, width: 16, height: 15), radius: 3)
            strokeRoundedRect(in: context, rect: CGRect(x: 7, y: 7, width: 10, height: 5), radius: 1)
            strokeLine(context, [(7, 15), (7, 16), (17, 16), (17, 15)])
            strokeCircle(in: context, rect: CGRect(x: 7, y: 17, width: 3, height: 3))
            strokeCircle(in: context, rect: CGRect(x: 14, y: 17, width: 3, height: 3))
        case .lodging:
            strokeLine(context, [(4, 7), (4, 19), (20, 19), (20, 10)])
            strokeLine(context, [(4, 14), (20, 14), (20, 19)])
            strokeRoundedRect(in: context, rect: CGRect(x: 6, y: 10, width: 5, height: 3), radius: 0.7)
            strokeLine(context, [(11, 11), (17, 11), (19, 14)])
        case .generic:
            strokeCircle(in: context, rect: CGRect(x: 5, y: 5, width: 14, height: 14))
            strokeCircle(in: context, rect: CGRect(x: 10, y: 10, width: 4, height: 4))
        }
        context.restoreGState()
    }

    private static func strokeLine(_ context: CGContext, _ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: point.1)) }
        context.strokePath()
    }

    private static func strokeCircle(in context: CGContext, rect: CGRect) {
        context.strokeEllipse(in: rect)
    }

    private static func strokeRoundedRect(in context: CGContext, rect: CGRect, radius: CGFloat) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }
}

#if os(iOS)
import UIKit

final class PlacePOIMapGlyphView: UIView {
    let kind: PlacePOIMapMarkerKind
    let tint: UIColor

    init(frame: CGRect, kind: PlacePOIMapMarkerKind, tint: UIColor) {
        self.kind = kind
        self.tint = tint
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        PlacePOIMapGlyph.draw(kind, in: context, rect: bounds.insetBy(dx: 1, dy: 1), color: tint.cgColor)
    }
}

extension PlacePOIMapMarkerKind {
    @MainActor func makeMapStyleImage() -> UIImage {
        let size = CGSize(width: 36, height: 36)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            context.setFillColor(UIColor.white.withAlphaComponent(0.97).cgColor)
            context.addPath(path); context.fillPath()
            let color = UIColor(red: CGFloat((accentHex >> 16) & 0xff) / 255,
                                green: CGFloat((accentHex >> 8) & 0xff) / 255,
                                blue: CGFloat(accentHex & 0xff) / 255, alpha: 1)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2)
            context.addPath(path); context.strokePath()
            PlacePOIMapGlyph.draw(self, in: context, rect: rect.insetBy(dx: 6, dy: 6), color: color.cgColor)
        }
    }
}
#elseif os(macOS)
import AppKit

final class PlacePOIMapGlyphView: NSView {
    let kind: PlacePOIMapMarkerKind
    let tint: NSColor

    override var isFlipped: Bool { true }

    init(frame: NSRect, kind: PlacePOIMapMarkerKind, tint: NSColor) {
        self.kind = kind
        self.tint = tint
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        PlacePOIMapGlyph.draw(kind, in: context, rect: bounds.insetBy(dx: 1, dy: 1), color: tint.cgColor)
    }
}
#endif
