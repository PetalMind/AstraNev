import SwiftUI

/// Native symbols keep weather legible alongside the other map controls.
struct WeatherIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: WeatherVisualState?
    var size: CGFloat = 28
    var showsBackground = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.57, weight: .medium))
            .symbolRenderingMode(.palette)
            .foregroundStyle(accent, Color.naviTextPrimary.opacity(0.85))
            .frame(width: size, height: size)
            .background {
                if showsBackground {
                    Circle()
                        .fill(LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(accent.opacity(0.12), lineWidth: 0.5))
                }
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        guard let state else { return "questionmark.circle" }
        switch state.condition {
        case .clear: return state.isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case .cloudy: return "cloud.fill"
        case .rain: return "cloud.drizzle.fill"
        case .heavyRain: return "cloud.rain.fill"
        case .snow, .heavySnow: return "cloud.snow.fill"
        case .fog: return "cloud.fog.fill"
        case .storm: return "cloud.bolt.rain.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var accent: Color {
        guard let state, state.condition != .unknown else { return .naviTextSecondary }
        let dark = colorScheme == .dark
        let hex: UInt32
        switch state.condition {
        case .clear:
            hex = state.isDaylight ? (dark ? 0xF4C76A : 0xB77912) : (dark ? 0xC4B5FD : 0x7C6BB3)
        case .cloudy, .fog: hex = dark ? 0xA6B8CA : 0x64788C
        case .rain, .heavyRain: hex = dark ? 0x7CB5EF : 0x3977B5
        case .snow, .heavySnow: hex = dark ? 0xA2D5E2 : 0x398298
        case .storm: hex = dark ? NaviAstraColorPalette.brandPrimaryNight : 0x8265B0
        case .unknown: hex = NaviAstraColorPalette.textSecondaryDay
        }
        return Color(naviHex: hex)
    }
}

nonisolated enum WeatherIconLicense {
    static let text = """
    MIT License

    Copyright (c) 2020-present Bas Milius

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
