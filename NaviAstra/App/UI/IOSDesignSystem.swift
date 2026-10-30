#if os(iOS)
import SwiftUI

/// Content surfaces are opaque; glass is reserved for controls floating above the map.
enum IOSLayout {
    static let spacing: CGFloat = 16
    static let cardRadius: CGFloat = 20
    static let minimumTarget: CGFloat = 44
    static let readableWidth: CGFloat = 680
}

struct IOSCardSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat = IOSLayout.cardRadius

    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.3 : 0.07), lineWidth: 1)
            }
    }
}

struct IOSSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .foregroundStyle(.primary)
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func iosCardSurface(radius: CGFloat = IOSLayout.cardRadius) -> some View {
        modifier(IOSCardSurface(radius: radius))
    }
}
#endif
