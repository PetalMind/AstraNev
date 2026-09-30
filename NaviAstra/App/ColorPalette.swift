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

    static let userLocationDay: UInt32 = 0x00B8D9
    static let userLocationNight: UInt32 = 0x22D3EE
    static let success: UInt32 = 0x2BB673
    static let warning: UInt32 = 0xF5A524
    static let trafficModerate: UInt32 = 0xF5C227
    static let trafficSlow: UInt32 = 0xFF8A1F
    static let danger: UInt32 = 0xE5383B
    static let closure: UInt32 = 0x7A1F2B
    static let info: UInt32 = 0x3B82F6
    static let roadSignRed: UInt32 = 0xD10A14

    static let mapBackgroundDay: UInt32 = 0xEEF1F3
    static let mapBackgroundNight: UInt32 = 0x0E1620
    static let mapBuildingDay: UInt32 = 0xE2E7EA
    static let mapBuildingNight: UInt32 = 0x1A2531
    static let mapParkDay: UInt32 = 0xD3E6D0
    static let mapParkNight: UInt32 = 0x1B3630
    static let mapWaterDay: UInt32 = 0xBCD9EA
    static let mapWaterNight: UInt32 = 0x12324A
    static let mapLocalRoadNight: UInt32 = 0x26343F
    static let mapMainRoadNightExploration: UInt32 = 0x3A4B58
    static let mapMainRoadNightNavigation: UInt32 = 0x2F3D49
    static let mapMainRoadOutlineDay: UInt32 = 0xC3CCD2
    static let mapLabelDay: UInt32 = 0x2B3640
    static let mapLabelNight: UInt32 = 0xC5D0D8

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
