import SwiftUI

/// A single drawing surface, with bounded particles and no gesture handling.
struct WeatherEffectLayer: View {
    let configuration: WeatherVisualConfiguration
    let active: Bool
    let perspective: Bool

    var body: some View {
        let animated = active && (configuration.rainIntensity > 0 || configuration.snowIntensity > 0 || configuration.flashes)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animated)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let rain = configuration.rainIntensity > 0
                let amount = rain ? configuration.rainIntensity : configuration.snowIntensity
                if active && amount > 0 {
                    for index in 0..<Int(90 * amount) {
                        let seed = Double(index)
                        let depth = 0.4 + fractional(seed * 0.618) * 0.6
                        let speed = (rain ? 210.0 : 25.0) * depth
                        let y = fractional(seed * 0.347 + time * speed / max(1, size.height)) * size.height
                        let drift = configuration.wind * (rain ? 0.6 : 2) * time
                        let x = fractional(seed * 0.731 + drift / max(1, size.width)) * size.width
                        // Keep the central foreground around the vehicle visually clear.
                        let protected = abs(x - size.width / 2) < size.width * 0.14 && y > size.height * 0.48
                        let alpha = (rain ? 0.22 : 0.38) * depth * (protected ? 0.12 : 1)
                        var path = Path()
                        if rain {
                            let length = (perspective ? 8 + 10 * y / max(1, size.height) : 12) * depth
                            path.move(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x + 3 + configuration.wind * 0.15, y: y + length))
                            context.stroke(path, with: .color(.white.opacity(alpha)), lineWidth: 0.7)
                        } else {
                            let radius = 1 + depth * 1.5
                            path.addEllipse(in: CGRect(x: x + sin(time * 0.7 + seed) * 9, y: y, width: radius, height: radius))
                            context.fill(path, with: .color(.white.opacity(alpha)))
                        }
                    }
                }
                if active && configuration.flashes && time.truncatingRemainder(dividingBy: 43) < 0.15 {
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.035)))
                }
            }
        }
        .overlay {
            LinearGradient(colors: [.white.opacity(configuration.fogDensity), .white.opacity(configuration.fogDensity * 0.3), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fractional(_ value: Double) -> Double { value - floor(value) }
}
