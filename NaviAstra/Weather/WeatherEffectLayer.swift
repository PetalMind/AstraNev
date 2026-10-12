import SwiftUI

/// A single drawing surface, with bounded particles and no gesture handling.
struct WeatherEffectLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let configuration: WeatherVisualConfiguration
    let active: Bool
    let perspective: Bool

    var body: some View {
        let animated = active && (configuration.rainIntensity > 0 || configuration.snowIntensity > 0 || configuration.flashes)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animated)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                guard active else { return }
                let time = timeline.date.timeIntervalSinceReferenceDate
                drawFog(in: &context, size: size)
                drawPrecipitation(in: &context, size: size, time: time)
                if configuration.flashes {
                    // A soft atmospheric pulse, without a hard full-screen flash.
                    let phase = time.truncatingRemainder(dividingBy: 43)
                    if phase < 0.9 {
                        let opacity = pow(sin(phase / 0.9 * .pi), 2) * 0.018
                        context.fill(Path(CGRect(origin: .zero, size: size)),
                                     with: .color(Color(naviHex: 0xCCD8F4).opacity(opacity)))
                    }
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawFog(in context: inout GraphicsContext, size: CGSize) {
        guard !reduceTransparency, configuration.fogDensity > 0 else { return }
        let color = Color(naviHex: colorScheme == .dark ? 0x9BAFC3 : 0xE8EFF3)
        let width = Double(size.width)
        let height = Double(size.height)
        // Broad, feathered banks leave the foreground and road labels readable.
        for index in 0..<3 {
            let center = CGPoint(x: width * (0.15 + Double(index) * 0.4),
                                 y: height * (0.06 + Double(index % 2) * 0.16))
            let radius = max(width * 0.72, height * 0.5)
            let gradient = Gradient(colors: [color.opacity(configuration.fogDensity * 0.65),
                                              color.opacity(configuration.fogDensity * 0.2), .clear])
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
        }
    }

    private func drawPrecipitation(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let rain = configuration.rainIntensity > 0
        let amount = rain ? configuration.rainIntensity : configuration.snowIntensity
        guard amount > 0, size.width > 0, size.height > 0 else { return }
        let count = min(110, Int((rain ? 110 : 84) * amount))
        let color = Color(naviHex: colorScheme == .dark ? 0xD0E2F3 : (rain ? 0x527FA4 : 0xF4FAFF))
        let height = Double(size.height) + 40
        let width = Double(size.width) + 48
        for index in 0..<count {
            let seed = Double(index + 1)
            let depth = 0.35 + fractional(seed * 0.6180339) * 0.65
            let speed = (rain ? 240.0 : 24.0) * depth
            let y = fractional(seed * 0.4142136 + time * speed / height) * height - 20
            let wind = configuration.wind * (rain ? 0.8 : 1.4)
            let sway = rain ? 0 : sin(time * (0.35 + depth * 0.25) + seed) * (5 + depth * 7)
            let x = fractional(seed * 0.7548777 + time * wind / width) * width - 24 + sway
            let visibility = foregroundVisibility(x: x, y: y, size: size)
            let opacity = (rain ? 0.3 : 0.65) * depth * visibility
            if rain {
                let length = (perspective ? 7 + 13 * max(0, y) / Double(size.height) : 14) * depth
                let start = CGPoint(x: x, y: y)
                let end = CGPoint(x: x + wind / speed * length, y: y + length)
                var streak = Path()
                streak.move(to: start)
                streak.addLine(to: end)
                context.stroke(streak,
                               with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(opacity)]),
                                                     startPoint: start, endPoint: end),
                               style: StrokeStyle(lineWidth: 0.5 + depth * 0.65, lineCap: .round))
            } else {
                let radius = 0.8 + depth * 1.6
                let center = CGPoint(x: x, y: y)
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect),
                             with: .radialGradient(Gradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.6), .clear]),
                                                   center: center, startRadius: 0, endRadius: radius))
            }
        }
    }

    private func foregroundVisibility(x: Double, y: Double, size: CGSize) -> Double {
        // Smoothly fade around the vehicle instead of cutting a rectangle out of the rain.
        let width = Double(size.width)
        let height = Double(size.height)
        let horizontal = (x - width * 0.5) / max(1, width * 0.22)
        let vertical = (y - height * 0.68) / max(1, height * 0.3)
        let vehicleMask = 1 - 0.88 * exp(-(horizontal * horizontal + vertical * vertical) * 2)
        let distanceToEdge = min(y + 20, height + 20 - y)
        let edgeFade = min(1, max(0, distanceToEdge / 40))
        return vehicleMask * edgeFade
    }

    private func fractional(_ value: Double) -> Double { value - floor(value) }
}
