import SwiftUI

/// Static Meteocons Flat SVG artwork, bundled locally under the MIT license.
struct WeatherIcon: View {
    let state: WeatherVisualState?
    var size: CGFloat = 28

    var body: some View {
        Image(assetName)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        guard let state else { return "weather_not_available" }
        let name: String
        switch state.condition {
        case .clear: name = state.isDaylight ? "clear_day" : "clear_night"
        case .cloudy: name = state.isDaylight ? "overcast_day" : "overcast_night"
        case .rain: name = "rain"
        case .heavyRain: name = "extreme_rain"
        case .snow: name = "snow"
        case .heavySnow: name = "extreme_snow"
        case .fog: name = "fog"
        case .storm: name = "thunderstorms_rain"
        case .unknown: name = "not_available"
        }
        return "weather_\(name)"
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
