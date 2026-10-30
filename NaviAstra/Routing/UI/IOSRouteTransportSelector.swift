#if os(iOS)
import SwiftUI

struct IOSRouteTransportSelector: View {
    let selection: TransportMode
    let onSelect: (TransportMode) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private let modes: [TransportMode] = [.car, .walking, .transit, .bicycle]
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4),
              count: typeSize.isAccessibilitySize ? 2 : 4)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(modes) { mode in
                Button { onSelect(mode) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                        Text(mode.title)
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(selection == mode ? Color.accentColor : .secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: IOSLayout.minimumTarget)
                    .background(selection == mode ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(4)
        .iosCardSurface(radius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sposób podróży")
    }
}
#endif
