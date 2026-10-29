#if os(iOS)
import Foundation
import MapLibre

/// Functional palettes shared by Buildings, Planet v4 and the base map.
/// Neutral variants remain decorative when classification is unavailable.
enum MapBuildingAppearance {
    static let cornerDistance = 0.25
    static let dayFacades: [UInt32] = [0xD8CEBF, 0xECE8DF, 0xCCD4D5, 0xB9CDD5, 0xD9C6B7, 0xC9CCCA]
    static let nightFacades: [UInt32] = [0x403E3B, 0x41464B, 0x34434C, 0x304755, 0x443B3A, 0x343F43]
    static let dayRoofs: [UInt32] = [0xA89F94, 0xB8B8B0, 0x929FA7, 0x829AA7, 0xA4887B, 0x8B9293]
    static let nightRoofs: [UInt32] = [0x303033, 0x2C333C, 0x283640, 0x243541, 0x383031, 0x2B3438]

    static func variant(heightKey: String, count: Int) -> [Any] {
        // Buildings has unique IDs at native z14/15, which are retained while
        // overzooming. Parent IDs keep parts of one building in the same family.
        // Geometry-based variation in the facade pass also covers sources without IDs.
        let heightSeed: [Any] = ["*", ["coalesce", ["get", heightKey], 0], 13]
        let identity: [Any] = ["to-number", ["coalesce", ["get", "group_id"], ["get", "osm_id"], ["id"], heightSeed], heightSeed]
        return ["%", ["abs", ["floor", identity]], count]
    }

    static func applySolidRendering(to layer: MLNFillExtrusionStyleLayer) {
        // Opacity below 1 switches Metal to a depth/stencil prepass that can
        // mask the front extrusion with geometry behind it (MapLibre #1589).
        // Keep the opaque path active even while other style properties fade.
        layer.fillExtrusionPattern = nil
        layer.fillExtrusionOpacityTransition = MLNTransition(duration: 0, delay: 0)
        layer.fillExtrusionOpacity = NSExpression(forConstantValue: 1)
    }

    static func color(dark: Bool, roof: Bool = false, heightKey: String) -> NSExpression {
        let palette = roof ? (dark ? nightRoofs : dayRoofs) : (dark ? nightFacades : dayFacades)
        var neutral: [Any] = ["match", variant(heightKey: heightKey, count: palette.count)]
        for index in 0..<(palette.count - 1) { neutral += [index, rgb(palette[index])] }
        neutral.append(rgb(palette[palette.count - 1]))
        let functional = BuildingVisualResolver.color(dark: dark, roof: roof, fallback: neutral)
        let variedFunctional: [Any] = ["interpolate", ["linear"],
            ["*", 0.08, variant(heightKey: heightKey, count: palette.count)], 0, functional, 1, neutral]
        // Buildings supplies real facade/roof colors. OpenMapTiles may supply `colour`.
        // Invalid or absent values safely fall back to the functional palette.
        let supplied: [Any] = roof
            ? ["coalesce", ["get", "roof_color"], ["get", "facade_color"], ["get", "colour"]]
            : ["coalesce", ["get", "facade_color"], ["get", "colour"]]
        return NSExpression(mglJSONObject: ["interpolate", ["linear"], dark ? 0.20 : 0.65,
            0, variedFunctional, 1, ["to-color", supplied, variedFunctional]])
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
enum BuildingFacadeStyle: Int {
    case residential = 1, office, hotel, retail, civic, industrial, landmark, neutral

    var hasWindows: Bool { self != .industrial && self != .landmark }
    var floorHeight: Double {
        switch self {
        case .office: return 3.5
        case .retail: return 4.0
        case .civic: return 3.4
        default: return 3.1
        }
    }
    var windowWidth: Float {
        switch self { case .office: 1.7; case .retail: 2.1; case .hotel: 1.25; case .civic: 1.35; default: 1.15 }
    }
    var windowHeight: Float {
        switch self { case .office: 2.05; case .retail: 2.2; case .hotel: 1.7; default: 1.6 }
    }
    var gap: Float { self == .office ? 0.35 : (self == .hotel ? 0.65 : 0.85) }
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

/// Decorative finishes only. Their color follows supplied tags when available;
/// the variants never assert a surveyed material, window count or building use.
enum BuildingSurfaceFinish {
    static func seed(attributes: [String: Any], identifier: Any?, footprint: [String]) -> UInt64 {
        let supplied = ["group_id", "osm_id", "osm_way_id"].compactMap { attributes[$0] }
            .map(String.init(describing:)).first
        let identity = supplied ?? identifier.map(String.init(describing:))
            ?? Array(Set(footprint)).sorted().joined(separator: ";")
        var hash: UInt64 = 14695981039346656037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash
    }

    static func facade(_ style: BuildingFacadeStyle, attributes: [String: Any], seed: UInt64) -> SIMD3<Float> {
        if let supplied = hexadecimal(attributes["facade_color"] ?? attributes["building:colour"] ?? attributes["colour"]) { return supplied }
        let colors: [UInt32]
        switch style {
        case .office: colors = [0xB6C9D3, 0xCED7DC, 0xBAC6CA, 0xD6DEDE]
        case .hotel: colors = [0xD9CABB, 0xD7C9CE, 0xE1D7C6, 0xC2CBD0]
        case .retail: colors = [0xD8CAB5, 0xE1D9CB, 0xC6CED0, 0xD5C4AE]
        case .civic: colors = [0xE0DCD0, 0xCED6D8, 0xD9D4C5, 0xC5CDD2]
        case .industrial: colors = [0xAEB9BF, 0xC2C9CB, 0xB2BEC3, 0xC4BFB6]
        case .landmark: colors = [0xD0C7B8, 0xDBD2C3, 0xC5CBCA, 0xD6C8B8]
        case .residential, .neutral: colors = [0xE7DFD1, 0xD1D9D7, 0xD6C4B2, 0xC5D1D8, 0xDCCBC0, 0xD4D4CE]
        }
        return rgb(colors[Int(seed % UInt64(colors.count))])
    }

    static func roof(_ style: BuildingFacadeStyle, attributes: [String: Any], seed: UInt64) -> SIMD3<Float> {
        if let supplied = hexadecimal(attributes["roof_color"] ?? attributes["roof:colour"]) { return supplied }
        let colors: [UInt32] = style == .industrial || style == .office
            ? [0x738590, 0x8C969B, 0x74827F, 0x9B9D96]
            : [0x958B7F, 0xA28475, 0x7B8B94, 0x989A91, 0x8D817C, 0x879292]
        return rgb(colors[Int((seed >> 5) % UInt64(colors.count))])
    }

    static func roofPattern(attributes: [String: Any]) -> Float {
        let material = (attributes["roof:material"] ?? attributes["roof_material"]) as? String
        switch material?.lowercased() {
        case "metal", "zinc", "copper", "aluminium", "steel", "sheet_metal": return 1
        case "roof_tiles", "tiles", "slate", "shingle", "shingles": return 2
        case "concrete", "gravel", "asphalt", "bitumen": return 3
        default: return 0
        }
    }

    static func roofShape(attributes: [String: Any]) -> Float {
        let shape = (attributes["roof_shape"] ?? attributes["roof:shape"]) as? String
        switch shape?.lowercased() {
        case "gabled", "gambrel", "half_hipped", "saltbox": return 1
        case "hipped", "mansard": return 2
        case "pyramidal": return 3
        case "dome", "onion", "round", "spherical": return 4
        case "skillion": return 5
        case "sawtooth": return 6
        default: return 0
        }
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
    }
    private static func hexadecimal(_ raw: Any?) -> SIMD3<Float>? {
        guard let raw = raw as? String else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let hex = UInt32(value, radix: 16) else { return nil }
        return rgb(hex)
    }
}
#endif
