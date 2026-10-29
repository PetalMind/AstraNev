#if os(iOS)
import SwiftUI

/// One quiet instrument; only a confirmed limit adds a road sign.
struct DrivingSpeedInstrument: View {
    let speed: Int?
    let limit: Int?
    let exceedsLimit: Bool
    var condensed = false

    var body: some View {
        HStack(spacing: condensed ? 6 : 10) {
            VStack(spacing: 0) {
                Text(speed.map { $0.formatted(.number.locale(PolishRegionalFormat.locale)) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(exceedsLimit
                        ? Color(naviHex: NaviAstraColorPalette.danger) : Color.naviTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("km/h")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.naviTextSecondary)
            }
            .frame(width: condensed ? 40 : 44)

            if let limit {
                Rectangle()
                    .fill(Color.naviTextSecondary.opacity(0.25))
                    .frame(width: 1, height: 30)
                Text(limit.formatted(.number.locale(PolishRegionalFormat.locale)))
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: condensed ? 36 : 40, height: condensed ? 36 : 40)
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
#endif
