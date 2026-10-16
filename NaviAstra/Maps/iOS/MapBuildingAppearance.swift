#if os(iOS)
import Foundation
import MapLibre

/// Functional palettes shared by Buildings, Planet v4 and the base map.
/// Neutral variants remain decorative when classification is unavailable.
enum MapBuildingAppearance {
    static let cornerDistance = 0.25
    static let dayFacades: [UInt32] = [0xD1C1AE, 0xE6E1D6, 0xCBD4D5, 0xB8CBD4]
    static let nightFacades: [UInt32] = [0x3E3A39, 0x394049, 0x333F49, 0x2E4050]
    static let dayRoofs: [UInt32] = [0xB3A291, 0xC5C3BA, 0x9FAEB4, 0x94AAB6]
    static let nightRoofs: [UInt32] = [0x303033, 0x2C333C, 0x283640, 0x243541]

    static func variant(heightKey: String, count: Int) -> [Any] {
        // A tile ID when available, otherwise provider height. No random per-frame changes.
        let heightSeed: [Any] = ["*", ["coalesce", ["get", heightKey], 0], 13]
        let seed: [Any] = ["to-number", ["coalesce", ["id"], heightSeed], heightSeed]
        return ["%", ["abs", ["floor", seed]], count]
    }

    static func color(dark: Bool, roof: Bool = false, heightKey: String) -> NSExpression {
        let palette = roof ? (dark ? nightRoofs : dayRoofs) : (dark ? nightFacades : dayFacades)
        var neutral: [Any] = ["match", variant(heightKey: heightKey, count: palette.count)]
        for index in 0..<(palette.count - 1) { neutral += [index, rgb(palette[index])] }
        neutral.append(rgb(palette[palette.count - 1]))
        let functional = BuildingVisualResolver.color(dark: dark, roof: roof, fallback: neutral)
        // Buildings supplies real facade/roof colors. OpenMapTiles may supply `colour`.
        // Invalid or absent values safely fall back to the functional palette.
        let supplied: [Any] = roof
            ? ["coalesce", ["get", "roof_color"], ["get", "facade_color"], ["get", "colour"]]
            : ["coalesce", ["get", "facade_color"], ["get", "colour"]]
        return NSExpression(mglJSONObject: ["interpolate", ["linear"], dark ? 0.20 : 0.65,
            0, functional, 1, ["to-color", supplied, functional]])
    }

    static func outline(dark: Bool) -> NSExpression {
        NSExpression(mglJSONObject: BuildingVisualResolver.color(dark: dark, roof: true,
            fallback: rgb(dark ? 0x48515B : 0xBAB8B2)))
    }

    private static func rgb(_ value: UInt32) -> [Any] {
        ["rgb", (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }
}
/// Resolves only the footprint's own attributes. A tenant POI never reclassifies a building.
enum BuildingVisualResolver {
    static func facade(attributes: [String: Any]) -> BuildingFacadeStyle {
        // Prefer specific tags to generic provider classes such as `building`.
        let values = ["subclass", "building", "class", "building:use"].compactMap {
            (attributes[$0] as? String)?.lowercased()
        }
        for value in values {
            switch value {
            case "residential", "apartments", "house", "detached", "terrace", "dormitory": return .residential
            case "office": return .office
            case "hotel": return .hotel
            case "retail", "commercial", "supermarket", "shop": return .retail
            case "medical", "hospital", "education", "school", "university", "college",
                 "kindergarten", "civic", "government", "public": return .civic
            case "industrial", "factory", "warehouse", "manufacture", "garage", "garages",
                 "shed", "barn", "farm_auxiliary", "greenhouse", "hangar": return .industrial
            case "religious", "church", "cathedral", "chapel", "mosque", "synagogue", "temple",
                 "monastery", "castle", "historic", "landmark", "stadium", "grandstand",
                 "train_station", "transportation": return .landmark
            default: continue
            }
        }
        return .neutral
    }

    static func color(dark: Bool, roof: Bool, fallback: [Any]) -> [Any] {
        let families: [([String], UInt32, UInt32, UInt32, UInt32)] = [
            (["supermarket"], 0xD9BF9D, 0x51463D, 0xB89C7D, 0x423B35),
            (["retail", "commercial", "kiosk"], 0xE1CEB6, 0x48423D, 0xBFAB91, 0x3C3733),
            (["hotel"], 0xD8C7D6, 0x493E4B, 0xB5A0B5, 0x3D3340),
            (["office"], 0xC6D2DD, 0x384754, 0xA2B4C5, 0x2E3C49),
            (["medical", "hospital"], 0xE7CDCB, 0x523E43, 0xC99F9F, 0x443238),
            (["education", "school", "university", "college", "kindergarten"], 0xDDD7B6, 0x494835, 0xBCB18B, 0x3C3B2D),
            (["religious", "church", "cathedral", "chapel", "mosque", "synagogue", "temple", "monastery"], 0xD5C8DB, 0x463F52, 0xB3A0C0, 0x393344),
            (["entertainment", "stadium", "sports_centre", "sports_hall", "grandstand"], 0xC2D8CF, 0x354D46, 0x9DBDAE, 0x2D403A),
            (["industrial", "factory", "warehouse", "manufacture"], 0xC9CCCE, 0x3E4348, 0xA3ABB0, 0x32383D),
            (["civic", "government", "public"], 0xCCD5DD, 0x3E4651, 0xAAB7C4, 0x333B45)
        ]
        func match(_ key: String, fallback: [Any]) -> [Any] {
            var result: [Any] = ["match", ["get", key]]
            for (values, day, night, dayRoof, nightRoof) in families {
                let hex = roof ? (dark ? nightRoof : dayRoof) : (dark ? night : day)
                result += [values, ["rgb", (hex >> 16) & 255, (hex >> 8) & 255, hex & 255]]
            }
            result.append(fallback)
            return result
        }
        return match("subclass", fallback: match("class", fallback: fallback))
    }
}

/// Decorative facade profiles; these are not surveyed window or occupancy data.
enum BuildingFacadeStyle {
    case residential, office, hotel, retail, civic, industrial, landmark, neutral

    var hasWindows: Bool { self != .industrial && self != .landmark }
    var floorHeight: Double {
        switch self {
        case .office: return 3.5
        case .retail: return 4.0
        case .civic: return 3.4
        default: return 3.1
        }
    }
    var windowWidth: Float { self == .office ? 1.5 : (self == .retail ? 1.8 : 1.1) }
    var windowHeight: Float { self == .office ? 1.8 : 1.5 }
    var gap: Float { self == .office ? 0.6 : 0.8 }
    var litProbability: Float {
        switch self {
        case .residential: return 0.28
        case .office: return 0.18
        case .hotel: return 0.45
        case .retail: return 0.22
        case .civic: return 0.12
        case .neutral: return 0.18
        case .industrial, .landmark: return 0
        }
    }
}
#endif
