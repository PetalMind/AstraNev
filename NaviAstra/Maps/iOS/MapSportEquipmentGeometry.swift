#if os(iOS)
import Foundation
import simd

/// Schematic equipment follows the same unambiguous rectangular court and
/// discipline used for markings. These are not surveyed positions or dimensions.
enum MapSportEquipmentGeometry {
    typealias Part = MapStreetFurnitureGeometry.Part
    static func parts(sport: MapSportKind, length: Double, width: Double) -> [Part] {
        var parts: [Part] = []
        func box(_ x: Double, _ y: Double, _ w: Double, _ d: Double, _ bottom: Double, _ top: Double,
                 _ material: String = "signFace") {
            parts.append(MapStreetFurnitureGeometry.box(x: x, y: y, width: w, depth: d,
                                                        base: bottom, top: top, material: material))
        }
        switch sport {
        case .soccer, .handball:
            let opening = min(sport == .soccer ? 7.32 : 3.0, width * 0.45)
            let height = sport == .soccer ? min(2.44, opening / 3) : 2.0
            for side in [-1.0, 1.0] {
                let x = side * length * 0.44, back = x + side * min(1.2, length * 0.05)
                for y in [-opening / 2, opening / 2] {
                    box(x, y, 0.10, 0.10, 0, height)
                    box((x + back) / 2, y, abs(back - x), 0.055, 0.02, 0.07, "steel")
                }
                box(x, 0, 0.10, opening + 0.10, height - 0.10, height)
                box(back, 0, 0.055, opening, 0.02, 0.07, "steel")
                // Sparse net strands keep gaps genuinely open to scene depth.
                for row in 1...3 { box(back, 0, 0.025, opening, height * Double(row) / 4, height * Double(row) / 4 + 0.025) }
                for column in 0...6 { box(back, -opening / 2 + opening * Double(column) / 6, 0.025, 0.025, 0.05, height * 0.8) }
            }
        case .basketball:
            for side in [-1.0, 1.0] {
                let x = side * length * 0.39
                box(x + side * 0.35, 0, 0.12, 0.12, 0, 3.65, "steel")
                box(x + side * 0.175, 0, 0.45, 0.10, 3.45, 3.55, "steel")
                box(x, 0, 0.07, min(1.8, width * 0.2), 2.9, 3.95)
                let center = SIMD2(x - side * 0.40, 0)
                for i in 0..<12 {
                    let angle = Double(i) * .pi / 6, next = Double(i + 1) * .pi / 6
                    let a = center + SIMD2(cos(angle), sin(angle)) * 0.23
                    let b = center + SIMD2(cos(next), sin(next)) * 0.23
                    let d = simd_normalize(b - a), n = SIMD2(-d.y, d.x) * 0.018
                    parts.append(.init(outline: [a - n, b - n, b + n, a + n, a - n], base: 3.03, top: 3.07, material: "wood"))
                }
            }
        case .tennis, .volleyball:
            let height = sport == .tennis ? 1.07 : 2.43
            let extent = width * (sport == .tennis ? 0.34 : 0.45)
            for y in [-extent, extent] { box(0, y, 0.07, 0.07, 0, height, "steel") }
            box(0, 0, 0.025, extent * 2, height - 0.035, height)
            for row in 1...4 { box(0, 0, 0.018, extent * 2, height * Double(row) / 5, height * Double(row) / 5 + 0.018) }
            for column in 0...12 { box(0, -extent + Double(column) * extent / 6, 0.018, 0.018, height * 0.2, height) }
        default: break
        }
        return parts
    }
}
#endif
