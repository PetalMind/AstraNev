import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Shared semantic colors. Brand tokens mirror the light and dark AccentColor asset variants.
nonisolated enum NaviAstraColorPalette {
    static let brandPrimaryDay: UInt32 = 0x8B2FE0
    static let brandPrimaryNight: UInt32 = 0xC08BFF
    static let navigationActiveDay: UInt32 = 0x1E5FE0
    static let navigationActiveNight: UInt32 = 0x5AA2FF
    static let routeAlternativeDay: UInt32 = 0x8592A0
    static let routeAlternativeNight: UInt32 = 0x5D6B78
    static let walkingRouteDay: UInt32 = 0x3F4E5C
    static let walkingRouteNight: UInt32 = 0xB5C2CD
    static let cyclingRouteDay: UInt32 = 0x00A37A
    static let cyclingRouteNight: UInt32 = 0x2BD9A8
    static let transitFallback: UInt32 = routeAlternativeDay

    static let userLocationDay: UInt32 = 0x007AFF
    static let userLocationNight: UInt32 = 0x64A8FF
    static let success: UInt32 = 0x2BB673
    static let warning: UInt32 = 0xF5A524
    static let trafficModerate: UInt32 = 0xF5C227
    static let trafficSlow: UInt32 = 0xFF8A1F
    static let danger: UInt32 = 0xE5383B
    static let closure: UInt32 = 0x7A1F2B
    static let info: UInt32 = 0x3B82F6
    static let roadSignRed: UInt32 = 0xD10A14

    static let mapBackgroundDay: UInt32 = 0xF3F2EF
    static let mapBackgroundNight: UInt32 = 0x171C24
    static let mapBuildingDay: UInt32 = 0xE4E2DE
    static let mapBuildingNight: UInt32 = 0x272F39
    static let mapParkDay: UInt32 = 0xD8E8CD
    static let mapParkNight: UInt32 = 0x253D32
    static let mapWaterDay: UInt32 = 0xB4DDF2
    static let mapWaterNight: UInt32 = 0x183B52
    static let mapLocalRoadNight: UInt32 = 0x36414D
    static let mapMainRoadNightExploration: UInt32 = 0x536170
    static let mapMainRoadNightNavigation: UInt32 = 0x465565
    static let mapMainRoadDay: UInt32 = 0xFFF0C2
    static let mapMainRoadOutlineDay: UInt32 = 0xD5D2CC
    static let mapLabelDay: UInt32 = 0x35414C
    static let mapLabelNight: UInt32 = 0xD8E0E8

    static let routeCasingDay: UInt32 = 0x0A2A5C
    static let routeCasingNight: UInt32 = 0x0B121B
    static let navigationSurface: UInt32 = 0x0B121B
    static let surfaceDay: UInt32 = 0xFFFFFF
    static let textPrimaryDay: UInt32 = 0x141B22
    static let textPrimaryNight: UInt32 = 0xF2F5F8
    static let textSecondaryDay: UInt32 = 0x5B6875
    static let textSecondaryNight: UInt32 = 0x9AA8B5
    static let textInactiveDay: UInt32 = 0xB7C0C8
    static let textInactiveNight: UInt32 = 0x4A5866
}

extension Color {
    init(naviHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }

    static var naviTextPrimary: Color {
        naviAdaptive(day: NaviAstraColorPalette.textPrimaryDay,
                     night: NaviAstraColorPalette.textPrimaryNight,
                     name: "NaviAstra.TextPrimary")
    }

    static var naviTextSecondary: Color {
        naviAdaptive(day: NaviAstraColorPalette.textSecondaryDay,
                     night: NaviAstraColorPalette.textSecondaryNight,
                     name: "NaviAstra.TextSecondary")
    }

    static var naviTextInactive: Color {
        naviAdaptive(day: NaviAstraColorPalette.textInactiveDay,
                     night: NaviAstraColorPalette.textInactiveNight,
                     name: "NaviAstra.TextInactive")
    }

    static func naviPOI(_ kind: PlacePOIMapMarkerKind) -> Color {
        naviAdaptive(day: kind.colorHex(dark: false), night: kind.colorHex(dark: true),
                     name: "NaviAstra.POI.\(kind.rawValue)")
    }

    private static func naviAdaptive(day: UInt32, night: UInt32, name: String) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            UIColor(naviHex: traits.userInterfaceStyle == .dark ? night : day)
        })
        #elseif os(macOS)
        Color(nsColor: NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(naviHex: dark ? night : day)
        }))
        #else
        Color(naviHex: day)
        #endif
    }
}

#if os(iOS)
extension UIColor {
    convenience init(naviHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}
#elseif os(macOS)
extension NSColor {
    convenience init(naviHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}
#endif
