import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared floating surfaces. Keep nested content opaque enough for map legibility.
struct NavigationGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 26
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = colorScheme == .dark
            ? Color(naviHex: NaviAstraColorPalette.navigationSurface).opacity(0.32)
            : Color.white.opacity(0.26)
        if reduceTransparency || contrast == .increased {
            content
                .background(colorScheme == .dark
                    ? Color(naviHex: NaviAstraColorPalette.navigationSurface)
                    : Color.white, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.2)))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background {
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(tint))
                }
                .overlay(shape.strokeBorder(.white.opacity(0.3)))
                .shadow(color: .black.opacity(0.1), radius: 18, y: 6)
        }
    }
}

struct NavigationStableSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Color(naviHex: colorScheme == .dark
                ? NaviAstraColorPalette.navigationSurface : 0xF9FCFF), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.09), lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.1), radius: 16, y: 5)
    }
}

/// Match the panel surface to the same appearance as its semantic text colors.
struct NavigationGlassPanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let shape: UnevenRoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        let tint = Color(naviHex: colorScheme == .dark
            ? NaviAstraColorPalette.navigationSurface : NaviAstraColorPalette.surfaceDay)
        if reduceTransparency || contrast == .increased {
            content
                .background(tint, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.24), lineWidth: 1))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint.opacity(0.72)), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 22, y: -8)
        } else {
            content
                .background {
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(tint.opacity(0.72)))
                }
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 22, y: -8)
        }
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
    private let minimumMediumHeight: CGFloat?
    private let hidesExpandedChevron: Bool
    private let resizesFromContent: Bool
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
         minimumMediumHeight: CGFloat? = nil,
         hidesExpandedChevron: Bool = false,
         resizesFromContent: Bool = true,
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
        self.minimumMediumHeight = minimumMediumHeight
        self.hidesExpandedChevron = hidesExpandedChevron
        self.resizesFromContent = resizesFromContent
        self.onClose = onClose
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self._isDragging = isDragging
        self.content = content
        self.footer = footer
    }

    private var expandedHeight: CGFloat { max(140, maximumHeight) }

    private var detentHeights: [CGFloat] {
        let expanded = expandedHeight
        // Keep medium distinct from expanded on short screens and in landscape.
        let minimumMedium = min(minimumMediumHeight ?? 0, expanded * 0.8)
        if expanded < 240 {
            let basePeek = min(expanded * 0.6, max(84, expanded * 0.45))
            let maximumPeek = max(basePeek, expanded - 40)
            let peek = min(maximumPeek, max(basePeek, minimumPeekHeight ?? basePeek))
            let medium = min(expanded - 1, max(peek + 24, expanded * mediumHeightFraction,
                                              minimumMedium))
            return [peek, medium, expanded]
        }
        // The compact summary sits below a 60 pt grabber; keep enough room for both.
        let basePeek = min(140, max(124, expanded * 0.18))
        let maximumPeek = max(basePeek, expanded - 60)
        let peek = min(maximumPeek, max(basePeek, minimumPeekHeight ?? basePeek))
        let medium = min(expanded - 1, max(peek + 40, expanded * mediumHeightFraction,
                                          minimumMedium))
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
            sheetBody
                .modifier(NavigationGlassPanelSurface(shape: sheetShape))
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
                .scrollIndicators(resizesFromContent ? .hidden : .visible)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(detent == .peek || (detent == .medium && resizesFromContent))
                .simultaneousGesture(dragGesture(fromContent: true),
                                     including: resizesFromContent ? .all : .none)
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
                .fixedSize(horizontal: false, vertical: true)
                .simultaneousGesture(dragGesture(fromContent: false))
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
                    .fill(Color.naviTextSecondary.opacity(0.7 + 0.25 * min(1, abs(height - restingHeight) / 30)))
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
                            .foregroundStyle(Color.naviTextSecondary)
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(closeAccessibilityLabel)
                } else if !hidesExpandedChevron || selectedIndex < detentHeights.count - 1 {
                    Image(systemName: selectedIndex == detentHeights.count - 1 ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.naviTextSecondary)
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
        // The sheet's top edge moves during resizing; measure in a stable space.
        DragGesture(minimumDistance: 7, coordinateSpace: .global)
            .onChanged { value in
                if dragStartHeight == nil {
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    let isPullingUp = value.translation.height < 0
                    let canExpand = selectedIndex < detentHeights.count - 1
                    if fromContent {
                        guard scrollOffset <= 1 else { return }
                        if isPullingUp {
                            guard canExpand else { return }
                        } else {
                            guard detent != .peek else { return }
                        }
                    }
                    dragStartHeight = restingHeight
                    // Only subtract motion already consumed by an expanded ScrollView.
                    dragStartTranslation = fromContent && detent == .expanded
                        ? value.translation.height : 0
                    ownsCurrentDrag = true
                }
                guard ownsCurrentDrag,
                      let startHeight = self.dragStartHeight,
                      let startTranslation = self.dragStartTranslation else { return }
                let translationSinceCapture = value.translation.height - startTranslation
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    interactiveHeight = rubberBanded(startHeight - translationSinceCapture)
                    isDragging = true
                }
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
