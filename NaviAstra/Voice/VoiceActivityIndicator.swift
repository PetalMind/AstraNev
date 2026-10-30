#if os(iOS)
import SwiftUI

/// Input bars follow measured microphone energy, rather than a repeating animation.
struct VoiceActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Double
    let listening: Bool
    let speaking: Bool
    let processing: Bool

    var body: some View {
        Group {
            if processing {
                ProgressView().tint(Color.accentColor)
            } else if listening {
                HStack(spacing: 3) {
                    ForEach(0..<5) { index in
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .frame(width: 3, height: barHeight(at: index))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            } else {
                Image(systemName: speaking ? "speaker.wave.2.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(at index: Int) -> CGFloat {
        let envelope = [0.45, 0.75, 1.0, 0.75, 0.45][index]
        let energy = level.isFinite ? min(1, max(0, level)) : 0
        return 4 + 24 * energy * envelope
    }
}
#endif
