#if os(iOS)
import UIKit

/// A discipline comes from a provider tag, never from a name or the shape of a pitch.
enum MapSportKind: String, CaseIterable {
    case soccer, basketball, tennis, volleyball, handball, badminton, tableTennis
    case padel, athletics, swimming, baseball, rugby, hockey, golf, skating, fitness, multi, other

    static func resolve(layer: String, attributes: [String: Any]) -> Self? {
        guard layer == "poi_sport" || layer == "poi" else { return nil }
        let raw = attributes["sport"] as? String
            ?? (layer == "poi_sport" ? attributes["class"] as? String
                : (attributes["subclass"] as? String ?? attributes["class"] as? String))
        guard let raw else { return layer == "poi_sport" ? .other : nil }
        let values = raw.lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if values.count > 1 { return .multi }
        switch values.first ?? "" {
        case "soccer", "futsal": return .soccer
        case "basketball": return .basketball
        case "tennis": return .tennis
        case "volleyball", "beachvolleyball": return .volleyball
        case "handball": return .handball
        case "badminton": return .badminton
        case "table_tennis": return .tableTennis
        case "padel": return .padel
        case "athletics", "running": return .athletics
        case "swimming": return .swimming
        case "baseball", "softball": return .baseball
        case "rugby", "rugby_union", "rugby_league": return .rugby
        case "hockey", "field_hockey", "ice_hockey": return .hockey
        case "golf": return .golf
        case "skateboard", "skating", "ice_skating", "roller_skating": return .skating
        case "fitness", "gymnastics": return .fitness
        case "multi": return .multi
        default: return layer == "poi_sport" ? .other : nil
        }
    }

    var title: String {
        switch self {
        case .soccer: "Piłka nożna"
        case .basketball: "Koszykówka"
        case .tennis: "Tenis"
        case .volleyball: "Siatkówka"
        case .handball: "Piłka ręczna"
        case .badminton: "Badminton"
        case .tableTennis: "Tenis stołowy"
        case .padel: "Padel"
        case .athletics: "Lekkoatletyka"
        case .swimming: "Pływanie"
        case .baseball: "Baseball"
        case .rugby: "Rugby"
        case .hockey: "Hokej"
        case .golf: "Golf"
        case .skating: "Sporty na rolkach, łyżwach i deskorolce"
        case .fitness: "Ćwiczenia i gimnastyka"
        case .multi: "Obiekt wielofunkcyjny"
        case .other: "Obiekt sportowy"
        }
    }

    var symbol: String {
        switch self {
        case .soccer: "soccerball"
        case .basketball: "basketball.fill"
        case .tennis, .padel: "tennis.racket"
        case .volleyball: "volleyball.fill"
        case .handball: "figure.handball"
        case .badminton: "figure.badminton"
        case .tableTennis: "figure.table.tennis"
        case .athletics: "figure.run"
        case .swimming: "figure.pool.swim"
        case .baseball: "baseball.fill"
        case .rugby: "figure.rugby"
        case .hockey: "figure.hockey"
        case .golf: "figure.golf"
        case .skating: "figure.skating"
        case .fitness: "dumbbell.fill"
        case .multi, .other: "sportscourt.fill"
        }
    }

    func colorHex(dark: Bool) -> UInt32 {
        switch self {
        case .soccer: dark ? 0x4C8063 : 0x81B284
        case .basketball: dark ? 0x946B50 : 0xCF9974
        case .tennis, .padel: dark ? 0x4B7C88 : 0x77AFBB
        case .volleyball: dark ? 0x94845A : 0xCCB881
        case .handball: dark ? 0x79648C : 0xAC96BE
        default: dark ? 0x62816A : 0x91AF8D
        }
    }

    func imageName(dark: Bool) -> String { "naviastra-sport-\(rawValue)-\(dark)" }

    @MainActor func image(dark: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36)).image { context in
            context.cgContext.setFillColor(UIColor(naviHex: colorHex(dark: dark)).cgColor)
            context.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 32, height: 32))
            let glyph = UIImage(systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
                ?? UIImage(systemName: "sportscourt.fill")
            glyph?.withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 9, y: 9, width: 18, height: 18))
        }
    }

    /// Schematic markings in normalized pitch coordinates, not a survey of real lines.
    var markings: [[CGPoint]] {
        func line(_ x: Double, _ y: Double, _ u: Double, _ v: Double) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: u, y: v)]
        }
        func box(_ x: Double, _ y: Double, _ u: Double, _ v: Double) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: u, y: y), CGPoint(x: u, y: v), CGPoint(x: x, y: v), CGPoint(x: x, y: y)]
        }
        func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> [CGPoint] {
            (0...40).map { index in
                let angle = Double(index) * .pi / 20
                return CGPoint(x: x + cos(angle) * rx, y: y + sin(angle) * ry)
            }
        }
        let boundary = box(0.06, 0.06, 0.94, 0.94)
        switch self {
        case .soccer:
            return [boundary, line(0.5, 0.06, 0.5, 0.94), ellipse(0.5, 0.5, 0.085, 0.14),
                    box(0.06, 0.22, 0.22, 0.78), box(0.78, 0.22, 0.94, 0.78),
                    box(0.06, 0.37, 0.12, 0.63), box(0.88, 0.37, 0.94, 0.63)]
        case .basketball:
            return [boundary, line(0.5, 0.06, 0.5, 0.94), ellipse(0.5, 0.5, 0.06, 0.11),
                    box(0.06, 0.34, 0.25, 0.66), box(0.75, 0.34, 0.94, 0.66),
                    ellipse(0.25, 0.5, 0.06, 0.11), ellipse(0.75, 0.5, 0.06, 0.11),
                    line(0.11, 0.44, 0.11, 0.56), line(0.89, 0.44, 0.89, 0.56)]
        case .tennis:
            return [boundary, line(0.5, 0.06, 0.5, 0.94), line(0.06, 0.17, 0.94, 0.17),
                    line(0.06, 0.83, 0.94, 0.83), line(0.27, 0.17, 0.27, 0.83),
                    line(0.73, 0.17, 0.73, 0.83), line(0.27, 0.5, 0.73, 0.5)]
        case .volleyball:
            return [boundary, line(0.5, 0.06, 0.5, 0.94), line(0.35, 0.06, 0.35, 0.94), line(0.65, 0.06, 0.65, 0.94)]
        case .handball:
            return [boundary, line(0.5, 0.06, 0.5, 0.94), box(0.06, 0.2, 0.23, 0.8), box(0.77, 0.2, 0.94, 0.8)]
        default: return []
        }
    }
}
#endif
