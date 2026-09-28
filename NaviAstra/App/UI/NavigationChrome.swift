import SwiftUI
#if os(iOS)
import UIKit
#endif

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

enum NavigationBottomSheetDetent: Int, CaseIterable {
    case peek
    case medium
    case expanded

    var title: String {
        switch self {
        case .peek: "Zwinięty"
        case .medium: "Średni"
        case .expanded: "Rozwinięty"
        }
    }
}

enum NavigationBottomSheetAppearance: Equatable {
    case navigation
    case discovery
}

private struct NavigationBottomSheetScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A map-attached sheet with shared detents, drag physics, and scroll handoff.
struct NavigationBottomSheet<Content: View, Footer: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var detent: NavigationBottomSheetDetent
    @Binding private var isDragging: Bool
    private let maximumHeight: CGFloat
    private let accessibilityLabel: String
    private let appearance: NavigationBottomSheetAppearance
    private let mediumHeightFraction: CGFloat
    private let minimumPeekHeight: CGFloat?
    private let hidesExpandedChevron: Bool
    private let onClose: (() -> Void)?
    private let closeAccessibilityLabel: String
    private let content: (NavigationBottomSheetDetent, CGFloat) -> Content
    private let footer: (NavigationBottomSheetDetent, CGFloat) -> Footer
    private let scrollSpaceName = UUID().uuidString
    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartHeight: CGFloat?
    @State private var dragStartTranslation: CGFloat?
    @State private var interactiveHeight: CGFloat?
    @State private var ownsCurrentDrag = false

    init(detent: Binding<NavigationBottomSheetDetent>,
         maximumHeight: CGFloat,
         accessibilityLabel: String,
         appearance: NavigationBottomSheetAppearance = .navigation,
         isDragging: Binding<Bool>,
         mediumHeightFraction: CGFloat = 0.48,
         minimumPeekHeight: CGFloat? = nil,
         hidesExpandedChevron: Bool = false,
         onClose: (() -> Void)? = nil,
         closeAccessibilityLabel: String = "Zamknij panel",
         @ViewBuilder content: @escaping (NavigationBottomSheetDetent, CGFloat) -> Content,
         @ViewBuilder footer: @escaping (NavigationBottomSheetDetent, CGFloat) -> Footer) {
        self._detent = detent
        self.maximumHeight = maximumHeight
        self.accessibilityLabel = accessibilityLabel
        self.appearance = appearance
        self.mediumHeightFraction = min(0.72, max(0.28, mediumHeightFraction))
        self.minimumPeekHeight = minimumPeekHeight
        self.hidesExpandedChevron = hidesExpandedChevron
        self.onClose = onClose
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self._isDragging = isDragging
        self.content = content
        self.footer = footer
    }

    private var expandedHeight: CGFloat { max(140, maximumHeight) }

    private var detentHeights: [CGFloat] {
        let expanded = expandedHeight
        if expanded < 240 {
            let basePeek = min(expanded * 0.6, max(84, expanded * 0.45))
            let maximumPeek = max(basePeek, expanded - 40)
            let peek = min(maximumPeek, max(basePeek, minimumPeekHeight ?? basePeek))
            let medium = min(expanded - 1, max(peek + 24, expanded * mediumHeightFraction))
            return [peek, medium, expanded]
        }
        // The compact summary sits below a 60 pt grabber; keep enough room for both.
        let basePeek = min(140, max(124, expanded * 0.18))
        let maximumPeek = max(basePeek, expanded - 60)
        let peek = min(maximumPeek, max(basePeek, minimumPeekHeight ?? basePeek))
        let medium = min(expanded - 1, max(peek + 40, expanded * mediumHeightFraction))
        return [peek, medium, expanded]
    }

    private var selectedIndex: Int {
        min(max(detent.rawValue, 0), detentHeights.count - 1)
    }

    private var restingHeight: CGFloat { detentHeights[selectedIndex] }

    private var height: CGFloat {
        interactiveHeight ?? restingHeight
    }

    private var progress: CGFloat {
        let range = max(1, detentHeights.last! - detentHeights[0])
        return min(1, max(0, (height - detentHeights[0]) / range))
    }

    private var cornerRadius: CGFloat { 32 - 12 * progress }

    var body: some View {
        styledSheet
    }

    @ViewBuilder
    private var styledSheet: some View {
        if appearance == .navigation {
            sheetBody.modifier(NavigationGlassPanelSurface(shape: sheetShape))
        } else {
            sheetBody.modifier(NavigationGlassSurface(radius: cornerRadius))
        }
    }

    private var sheetBody: some View {
        VStack(spacing: 0) {
            dragHandle

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: NavigationBottomSheetScrollOffsetKey.self,
                                value: geometry.frame(in: .named(scrollSpaceName)).minY)
                        }
                        .frame(height: 1)
                        .id("navigation-bottom-sheet-scroll-top")

                        content(detent, progress)
                    }
                }
                .coordinateSpace(name: scrollSpaceName)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(detent == .peek)
                .simultaneousGesture(dragGesture(fromContent: true))
                .onPreferenceChange(NavigationBottomSheetScrollOffsetKey.self) { minY in
                    scrollOffset = max(0, -minY)
                }
                .onChange(of: detent) { _, newValue in
                    guard newValue != .expanded else { return }
                    scrollOffset = 0
                    proxy.scrollTo("navigation-bottom-sheet-scroll-top", anchor: .top)
                }
            }

            footer(detent, progress)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .clipShape(sheetShape)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: detent)
    }

    private var dragHandle: some View {
        ZStack {
            Button(action: advanceDetent) {
                Capsule()
                    .fill(Color.white.opacity(0.55 + 0.25 * min(1, abs(height - restingHeight) / 30)))
                    .frame(width: 38, height: 5)
                    .scaleEffect(x: isDragging ? 1.06 : 1, y: 1, anchor: .center)
                    .frame(width: 60, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(detent.title)
            .accessibilityAdjustableAction { direction in
                moveDetent(to: direction == .increment
                           ? min(detentHeights.count - 1, selectedIndex + 1)
                           : max(0, selectedIndex - 1))
            }

            HStack {
                Spacer(minLength: 0)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(appearance == .navigation
                                             ? Color.white.opacity(0.72)
                                             : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(closeAccessibilityLabel)
                } else if !hidesExpandedChevron || selectedIndex < detentHeights.count - 1 {
                    Image(systemName: selectedIndex == detentHeights.count - 1 ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(appearance == .navigation
                                         ? Color.white.opacity(0.48)
                                         : Color.secondary.opacity(0.5))
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .contentShape(Rectangle())
        .highPriorityGesture(dragGesture(fromContent: false))
    }

    private var sheetShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: cornerRadius, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: cornerRadius),
            style: .continuous)
    }

    private func dragGesture(fromContent: Bool) -> some Gesture {
        DragGesture(minimumDistance: 7)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if dragStartHeight == nil {
                    let isPullingUp = value.translation.height < 0
                    let canExpand = selectedIndex < detentHeights.count - 1
                    if fromContent {
                        guard scrollOffset <= 1 else { return }
                        if isPullingUp {
                            guard detent == .peek && canExpand else { return }
                        } else {
                            guard detent != .peek else { return }
                        }
                    }
                    dragStartHeight = restingHeight
                    dragStartTranslation = value.translation.height
                    ownsCurrentDrag = true
                }
                guard ownsCurrentDrag,
                      let startHeight = self.dragStartHeight,
                      let startTranslation = self.dragStartTranslation else { return }
                let translationSinceCapture = value.translation.height - startTranslation
                interactiveHeight = rubberBanded(startHeight - translationSinceCapture)
                isDragging = true
            }
            .onEnded { value in
                guard ownsCurrentDrag,
                      let startHeight = self.dragStartHeight,
                      let startTranslation = self.dragStartTranslation else {
                    resetDrag()
                    return
                }

                let projectedHeight = startHeight - (value.predictedEndTranslation.height - startTranslation)
                let velocity = -(value.predictedEndTranslation.height - value.translation.height) / 0.25
                var targetIndex = nearestDetent(to: projectedHeight)
                if velocity > 650 {
                    targetIndex = min(detentHeights.count - 1, selectedIndex + 1)
                } else if velocity < -650 {
                    targetIndex = max(0, selectedIndex - 1)
                }
                ownsCurrentDrag = false
                dragStartHeight = nil
                dragStartTranslation = nil
                moveDetent(to: targetIndex)
            }
    }

    private func rubberBanded(_ rawHeight: CGFloat) -> CGFloat {
        let minimum = detentHeights[0]
        let maximum = detentHeights.last!
        if rawHeight < minimum { return minimum - min(42, (minimum - rawHeight) * 0.24) }
        if rawHeight > maximum { return maximum + min(42, (rawHeight - maximum) * 0.24) }
        return rawHeight
    }

    private func nearestDetent(to height: CGFloat) -> Int {
        detentHeights.indices.min { abs(detentHeights[$0] - height) < abs(detentHeights[$1] - height) }
            ?? selectedIndex
    }

    private func advanceDetent() {
        moveDetent(to: selectedIndex == detentHeights.count - 1
                   ? max(0, selectedIndex - 1)
                   : selectedIndex + 1)
    }

    private func moveDetent(to index: Int) {
        let boundedIndex = min(max(index, 0), detentHeights.count - 1)
        let nextDetent = NavigationBottomSheetDetent(rawValue: boundedIndex) ?? .expanded
        if nextDetent != detent { selectionHaptic() }
        isDragging = true
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
                      completionCriteria: .logicallyComplete) {
            detent = nextDetent
            interactiveHeight = nil
        } completion: {
            isDragging = false
        }
    }

    private func resetDrag() {
        isDragging = false
        ownsCurrentDrag = false
        dragStartHeight = nil
        dragStartTranslation = nil
        interactiveHeight = nil
    }

    private func selectionHaptic() {
#if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
#endif
    }
}

/// Discovery shares the map sheet physics while keeping its compact search surface.
struct DiscoveryDrawer<Content: View>: View {
    var maximumHeight: CGFloat
    var collapseRequest: Int
    @Binding var detent: NavigationBottomSheetDetent
    @Binding var isDragging: Bool
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        NavigationBottomSheet(detent: $detent,
                              maximumHeight: maximumHeight,
                              accessibilityLabel: "Panel eksploracji",
                              appearance: .discovery,
                              isDragging: $isDragging) { selectedDetent, _ in
            content(selectedDetent == .peek)
        } footer: { _, _ in
            EmptyView()
        }
        .onChange(of: collapseRequest) { _, _ in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { detent = .peek }
        }
    }
}
