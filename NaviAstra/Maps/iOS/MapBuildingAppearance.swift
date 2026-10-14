#if os(iOS)
import Foundation
import MapLibre

/// Decorative palettes shared by the base map and Planet v4.
/// The variants do not claim surveyed facade or roof materials.
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
        var base: [Any] = ["match", variant(heightKey: heightKey, count: palette.count)]
        for index in 0..<(palette.count - 1) { base += [index, rgb(palette[index])] }
        base.append(rgb(palette[palette.count - 1]))
        // Only the base tileset supplies `colour`. Keep an explicit OSM tint restrained.
        return NSExpression(mglJSONObject: roof ? base : ["interpolate", ["linear"], dark ? 0.10 : 0.18,
            0, base, 1, ["to-color", ["get", "colour"], base]])
    }

    private static func rgb(_ value: UInt32) -> [Any] {
        ["rgb", (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }
}
#endif
