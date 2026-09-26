import SwiftUI

/// Shared floating surfaces. Keep nested content opaque enough for map legibility.
struct NavigationGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat = 26
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(.background, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.2)))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.3)))
                .shadow(color: .black.opacity(0.1), radius: 18, y: 6)
        }
    }
}

/// A shared translucent shell for the route preview, active trip, and arrival panels.
struct NavigationGlassPanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: UnevenRoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content
                    .background(Color(red: 0.045, green: 0.075, blue: 0.12).opacity(0.98), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            } else if #available(iOS 26.0, macOS 26.0, *) {
                content
                    .background(shape.fill(Color(red: 0.045, green: 0.075, blue: 0.12).opacity(0.18)))
                    .glassEffect(.regular.interactive(), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            } else {
                content
                    .background {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(
                                LinearGradient(
                                    colors: [Color(red: 0.12, green: 0.18, blue: 0.26).opacity(0.44),
                                             Color(red: 0.045, green: 0.075, blue: 0.12).opacity(0.58)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                        }
                    }
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: -8)
    }
}

/// Three resting heights, with scrolling confined to the content and dragging to the handle.
struct DiscoveryDrawer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var maximumHeight: CGFloat
    var collapseRequest: Int
    @ViewBuilder var content: (Bool) -> Content
    @State private var detent = 1
    @GestureState private var translation: CGFloat = 0

    private var heights: [CGFloat] {
        let maximum = max(140, maximumHeight)
        let candidates = [min(140, maximum), min(360, maximum), maximum]
        var uniqueHeights: [CGFloat] = []
        for candidate in candidates {
            if uniqueHeights.last.map({ abs($0 - candidate) > 1 }) ?? true {
                uniqueHeights.append(candidate)
            }
        }
        return uniqueHeights
    }
    private var selectedDetent: Int { min(max(detent, 0), heights.count - 1) }
    private var detentNames: [String] {
        switch heights.count {
        case 1: ["Zwinięty"]
        case 2: ["Zwinięty", "Rozwinięty"]
        default: ["Zwinięty", "Średni", "Rozwinięty"]
        }
    }
    private var height: CGFloat {
        let baseHeight = heights[selectedDetent] - translation
        let minimumHeight = heights[0]
        let maximumHeight = heights[heights.count - 1]
        return min(maximumHeight, max(minimumHeight, baseHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                let nextDetent = selectedDetent == heights.count - 1
                    ? max(0, selectedDetent - 1)
                    : selectedDetent + 1
                settle(at: nextDetent)
            } label: {
                ZStack {
                    Capsule()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 38, height: 5)
                    Image(systemName: selectedDetent == heights.count - 1 ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 18)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Panel eksploracji")
            .accessibilityValue(detentNames[selectedDetent])
            .accessibilityAdjustableAction { direction in
                settle(at: direction == .increment
                       ? min(heights.count - 1, selectedDetent + 1)
                       : max(0, selectedDetent - 1))
            }
            .highPriorityGesture(DragGesture(minimumDistance: 6)
                .updating($translation) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    let projected = heights[selectedDetent] - value.predictedEndTranslation.height
                    let closest = heights.indices.min {
                        abs(heights[$0] - projected) < abs(heights[$1] - projected)
                    } ?? selectedDetent
                    settle(at: closest)
                })
            ScrollView { content(selectedDetent == 0) }
                .scrollIndicators(.hidden)
        }
        .frame(height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .modifier(NavigationGlassSurface(radius: 30))
        .onChange(of: collapseRequest) { _, _ in settle(at: 0) }
    }

    private func settle(at value: Int) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88)) {
            detent = min(max(value, 0), heights.count - 1)
        }
    }
}
