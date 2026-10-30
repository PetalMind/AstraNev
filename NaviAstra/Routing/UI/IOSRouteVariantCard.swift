#if os(iOS)
import SwiftUI

/// Presentation-only route choice: routing and start decisions stay in the feature store.
struct IOSRouteVariantCard<Details: View, StartAction: View>: View {
    let title: String
    let duration: String
    let arrival: String
    let distance: String
    let explanation: String
    let accessibilitySummary: String
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder var details: Details
    @ViewBuilder var startAction: StartAction
    @Environment(\.dynamicTypeSize) private var typeSize

    private var layout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    }

    var body: some View {
        layout {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                    Text(duration)
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("U celu \(arrival) · \(distance)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    details
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: IOSLayout.minimumTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint("\(title). \(explanation) Wybierz ten wariant trasy.")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            startAction
        }
        .padding(IOSLayout.spacing)
        .iosCardSurface()
        .overlay {
            RoundedRectangle(cornerRadius: IOSLayout.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
    }
}
#endif
