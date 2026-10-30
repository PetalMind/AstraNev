#if os(iOS)
import SwiftUI

/// One quiet instrument; only a confirmed limit adds a road sign.
struct DrivingSpeedInstrument: View {
    @ScaledMetric(relativeTo: .largeTitle) private var speedFontSize: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var unitFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .headline) private var detailScale: CGFloat = 1

    let speed: Int?
    let limit: Int?
    let exceedsLimit: Bool
    var condensed = false

    var body: some View {
        HStack(spacing: condensed ? 6 : 10) {
            VStack(spacing: 0) {
                ZStack {
                    // Reserve three full-size digits even while displaying 0–99.
                    // The instrument must grow before the parent moves its tools.
                    Text("888")
                        .hidden()
                        .accessibilityHidden(true)
                    Text(speed.map { $0.formatted(.number.locale(PolishRegionalFormat.locale)) } ?? "—")
                }
                .font(.system(size: speedFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(exceedsLimit
                    ? Color(naviHex: NaviAstraColorPalette.danger) : Color.naviTextPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                Text("km/h")
                    .font(.system(size: unitFontSize, weight: .medium))
                    .foregroundStyle(Color.naviTextSecondary)
            }

            if let limit {
                Rectangle()
                    .fill(Color.naviTextSecondary.opacity(0.25))
                    .frame(width: 1, height: 30 * detailScale)
                DrivingSpeedLimitLayout(minimumDiameter: (condensed ? 48 : 52) * detailScale,
                                        inset: 7 * detailScale) {
                    ZStack {
                        Text("888")
                            .hidden()
                            .accessibilityHidden(true)
                        Text(limit.formatted(.number.locale(PolishRegionalFormat.locale)))
                    }
                    .font(.system(size: (condensed ? 17 : 18) * detailScale,
                                  weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .fixedSize()
                }
                .background(.white, in: Circle())
                .overlay(Circle().strokeBorder(Color(naviHex: NaviAstraColorPalette.roadSignRed), lineWidth: 3))
            }
        }
        .padding(.horizontal, condensed ? 8 : 12)
        .padding(.vertical, 8)
        .modifier(NavigationGlassSurface(radius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(exceedsLimit ? Color(naviHex: NaviAstraColorPalette.danger) : .clear, lineWidth: 1.5)
        }
        .fixedSize()
    }
}

/// Measures the complete label before sizing its circular road sign.
/// A fixed outer frame can otherwise truncate three digits before rendering.
private struct DrivingSpeedLimitLayout: Layout {
    let minimumDiameter: CGFloat
    let inset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let label = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        let diameter = max(minimumDiameter, max(label.width, label.height) + 2 * inset)
        return CGSize(width: diameter, height: diameter)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY),
                              anchor: .center, proposal: .unspecified)
    }
}
#endif
