#if os(iOS)
import Foundation
import simd

/// Profiles describe decorative library architecture. Provider classification,
/// observed height and footprint decide which profiles are eligible.
@MainActor
enum MapBuildingModelCatalog {
    enum Family: Hashable { case house, apartments, office, industrial, garage }
    struct Template {
        let id: String
        let families: Set<Family>
        let heights: ClosedRange<Double>
        let levels: ClosedRange<Int>
        let aspect: SIMD2<Double>
    }
    private struct ManifestEntry: Decodable { let id: String; let aspect: [Double] }
    static let templates: [Template] = {
        guard let url = Bundle.main.url(forResource: "environment-models-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else { return [] }
        var output: [Template] = []
        for entry in entries {
            guard entry.aspect.count == 2, entry.aspect.allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
            let id = entry.id
            let families: Set<Family>, heights: ClosedRange<Double>, levels: ClosedRange<Int>
            if id.hasPrefix("house-") {
                families = [.house]
                let oneFloor = ["a", "g", "h", "i", "m"].contains(String(id.dropFirst(6)))
                heights = oneFloor ? 3...9 : 5...16
                levels = oneFloor ? 1...1 : 2...2
            } else if id.hasPrefix("commercial-") {
                families = [.apartments, .office]; heights = 7...18; levels = 3...3
            } else if id.hasPrefix("block-") {
                families = [.apartments, .office]
                switch String(id.dropFirst(6)) {
                case "c", "e": heights = 5...13; levels = 2...2
                case "d", "h": heights = 7...18; levels = 3...3
                case "f", "g", "i", "j", "k": heights = 10...23; levels = 3...5
                case "l", "n": heights = 13...32; levels = 4...6
                default: heights = 18...40; levels = 6...9
                }
            } else if id.hasPrefix("tower-") {
                families = [.apartments, .office]
                switch String(id.suffix(1)) {
                case "a": heights = 18...38; levels = 5...8
                case "b": heights = 28...65; levels = 8...13
                case "d": heights = 36...90; levels = 11...18
                default: heights = 25...60; levels = 7...13
                }
            } else if id.hasPrefix("industrial-") {
                let low = ["h", "i", "j", "k", "p", "q", "s", "t"].contains(String(id.dropFirst(11)))
                families = low ? [.industrial, .garage] : [.industrial]
                heights = low ? 2.5...18 : 5...32
                levels = low ? 1...2 : 2...4
            } else { continue }
            output.append(Template(id: id, families: families, heights: heights, levels: levels,
                aspect: SIMD2(entry.aspect[0], entry.aspect[1])))
        }
        return output
    }()

    static func families(type: String, height: Double) -> Set<Family> {
        switch type {
        case "house", "detached", "semidetached_house", "bungalow", "terrace", "terraced_house": return [.house]
        case "residential": return height <= 16 ? [.house, .apartments] : [.apartments]
        case "apartments", "dormitory": return [.apartments]
        case "office", "commercial", "retail", "supermarket", "hotel": return [.office]
        case "industrial", "factory", "warehouse", "manufacture", "hangar": return [.industrial]
        case "garage", "garages": return height <= 6 ? [.garage] : []
        default: return []
        }
    }
}
#endif
