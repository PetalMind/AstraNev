#if os(iOS)
import SwiftUI

/// A quiet summary and two levels of actions for the active driving sheet.
struct DrivingNavigationMetric: View {
    let value: String
    let caption: String
    var prominent = false
    var compact = false
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var arrivalSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !compact {
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.naviTextSecondary)
            }
            Text(value)
                .font(.system(size: compact ? min(22, valueSize) : (prominent ? arrivalSize : valueSize),
                              weight: prominent ? .bold : .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(prominent ? Color.accentColor : Color.naviTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct DrivingNavigationActionLabel: View {
    let title: String
    let symbol: String
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .center)
        .foregroundStyle(prominent
            ? (colorScheme == .dark ? Color(naviHex: NaviAstraColorPalette.navigationSurface) : .white)
            : Color.accentColor)
        .background(prominent ? Color.accentColor : Color.accentColor.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct DrivingNavigationOptionLabel: View {
    let title: String
    let symbol: String
    var expanded: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.naviTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: expanded.map { $0 ? "chevron.up" : "chevron.down" } ?? "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.naviTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}
#endif
