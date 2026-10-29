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

nonisolated enum NavigationBottomSheetDetent: Int, CaseIterable, Sendable {
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

nonisolated private struct NavigationBottomSheetMeasurement: Equatable, Sendable {
    let detent: NavigationBottomSheetDetent
    let height: CGFloat
}

/// A map-attached sheet with shared detents, drag physics, and scroll handoff.
struct NavigationBottomSheet<Content: View, Footer: View, PinnedHeader: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var detent: NavigationBottomSheetDetent
    @Binding private var isDragging: Bool
    private let maximumHeight: CGFloat
    private let accessibilityLabel: String
    private let appearance: NavigationBottomSheetAppearance
    private let mediumHeightFraction: CGFloat
    private let minimumPeekHeight: CGFloat?
    private let minimumMediumHeight: CGFloat?
    private let dragHandleHeight: CGFloat
    private let hidesExpandedChevron: Bool
    private let resizesFromContent: Bool
    private let fitsCompactContent: Bool
    private let fitsPeekToHeader: Bool
    private let bottomContentInset: CGFloat
    private let onClose: (() -> Void)?
    private let closeAccessibilityLabel: String
    private let pinnedHeader: (NavigationBottomSheetDetent, CGFloat) -> PinnedHeader
    private let content: (NavigationBottomSheetDetent, CGFloat) -> Content
    private let footer: (NavigationBottomSheetDetent, CGFloat) -> Footer
    private let scrollSpaceName = UUID().uuidString
    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartHeight: CGFloat?
    @State private var dragStartTranslation: CGFloat?
    @State private var interactiveHeight: CGFloat?
    @State private var ownsCurrentDrag = false
    @State private var contentHeights: [Int: CGFloat] = [:]
    @State private var footerHeights: [Int: CGFloat] = [:]
    @State private var pinnedHeaderHeight: CGFloat = 0
    @GestureState private var dragGestureIsActive = false

    init(detent: Binding<NavigationBottomSheetDetent>,
         maximumHeight: CGFloat,
         accessibilityLabel: String,
         appearance: NavigationBottomSheetAppearance = .navigation,
         isDragging: Binding<Bool>,
         mediumHeightFraction: CGFloat = 0.48,
         minimumPeekHeight: CGFloat? = nil,
         minimumMediumHeight: CGFloat? = nil,
         dragHandleHeight: CGFloat = 60,
         hidesExpandedChevron: Bool = false,
         resizesFromContent: Bool = true,
         fitsCompactContent: Bool = false,
         fitsPeekToHeader: Bool = false,
         bottomContentInset: CGFloat = 0,
         onClose: (() -> Void)? = nil,
         closeAccessibilityLabel: String = "Zamknij panel",
         @ViewBuilder pinnedHeader: @escaping (NavigationBottomSheetDetent, CGFloat) -> PinnedHeader = { _, _ in EmptyView() },
         @ViewBuilder content: @escaping (NavigationBottomSheetDetent, CGFloat) -> Content,
         @ViewBuilder footer: @escaping (NavigationBottomSheetDetent, CGFloat) -> Footer) {
        self._detent = detent
        self.maximumHeight = maximumHeight
        self.accessibilityLabel = accessibilityLabel
        self.appearance = appearance
        self.mediumHeightFraction = min(0.72, max(0.28, mediumHeightFraction))
        self.minimumPeekHeight = minimumPeekHeight
        self.minimumMediumHeight = minimumMediumHeight
        self.dragHandleHeight = max(44, dragHandleHeight)
        self.hidesExpandedChevron = hidesExpandedChevron
        self.resizesFromContent = resizesFromContent
        self.fitsCompactContent = fitsCompactContent
        self.fitsPeekToHeader = fitsPeekToHeader
        self.bottomContentInset = max(0, bottomContentInset)
        self.onClose = onClose
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self._isDragging = isDragging
        self.pinnedHeader = pinnedHeader
        self.content = content
        self.footer = footer
    }

    private var expandedHeight: CGFloat { max(140, maximumHeight) }

    private var detentHeights: [CGFloat] {
        let expanded = expandedHeight
        // Keep medium distinct from expanded on short screens and in landscape.
        let minimumMedium = min(minimumMediumHeight ?? 0, expanded * 0.8)
        if fitsPeekToHeader {
            // The summary keeps its position while the same details are revealed
            // beneath it. Reserve the home indicator even in the compact state.
            let peek = min(expanded - 2, max(minimumPeekHeight ?? 0,
                dragHandleHeight + pinnedHeaderHeight + bottomContentInset
                    + (footerHeights[detent.rawValue] ?? footerHeights.values.max() ?? 0)))
            let medium = min(expanded - 1, max(peek + min(64, (expanded - peek) * 0.5),
                                               expanded * mediumHeightFraction, minimumMedium))
            return [peek, medium, expanded]
        }
        if expanded < 240 {
            let basePeek = min(expanded * 0.6, max(84, expanded * 0.45))
            let maximumPeek = max(basePeek, expanded - 40)
            let peek = min(maximumPeek, max(basePeek, minimumPeekHeight ?? basePeek,
                                            contentHeight(for: .peek)))
            let medium = min(expanded - 1, max(peek + 24, expanded * mediumHeightFraction,
                                              minimumMedium, contentHeight(for: .medium)))
            return [peek, medium, expanded]
        }
        // Keep enough room for the compact summary and the grabber.
        let basePeek = min(140, max(124, expanded * 0.18))
        let maximumPeek = max(basePeek, expanded - dragHandleHeight)
        let peek = min(maximumPeek, max(basePeek, minimumPeekHeight ?? basePeek,
                                        contentHeight(for: .peek)))
        let medium = min(expanded - 1, max(peek + 40, expanded * mediumHeightFraction,
                                          minimumMedium, contentHeight(for: .medium)))
        return [peek, medium, expanded]
    }

    private func contentHeight(for detent: NavigationBottomSheetDetent) -> CGFloat {
        guard fitsCompactContent else { return 0 }
        // Reserve room for the entire content above the fixed footer, including
        // the grabber and the scroll position marker. On short screens the
        // maximum sheet height still wins and the content remains scrollable.
        return dragHandleHeight + pinnedHeaderHeight + (contentHeights[detent.rawValue] ?? 0)
            + (footerHeights[detent.rawValue] ?? 0) + bottomContentInset + 1
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

    private var scrollsPinnedHeader: Bool {
        fitsPeekToHeader && (expandedHeight < 240
            || dragHandleHeight + pinnedHeaderHeight + bottomContentInset
                + (footerHeights[detent.rawValue] ?? footerHeights.values.max() ?? 0) + 44 > expandedHeight)
    }

    private var contentOverflowsViewport: Bool {
        let reserved = dragHandleHeight + (scrollsPinnedHeader ? 0 : pinnedHeaderHeight) + bottomContentInset
            + (footerHeights[detent.rawValue] ?? 0)
        let scrollContent = (contentHeights[detent.rawValue] ?? 0)
            + (scrollsPinnedHeader ? pinnedHeaderHeight : 0) + 1
        return scrollContent > max(0, height - reserved) + 1
    }

    var body: some View {
        styledSheet
            .onChange(of: dragGestureIsActive) { _, active in
                guard fitsPeekToHeader, !active, ownsCurrentDrag else { return }
                // GestureState also resets when iOS cancels a recognizer, when
                // onEnded is not delivered (for example, an interruption).
                let target = nearestDetent(to: height)
                clearDragTracking()
                moveDetent(to: target)
            }
            .onChange(of: maximumHeight) { _, _ in
                if fitsPeekToHeader { resetDrag() }
            }
            .onDisappear { resetDrag() }
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

            if !scrollsPinnedHeader {
                measuredPinnedHeader
            }

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

                        if scrollsPinnedHeader {
                            measuredPinnedHeader
                        }

                        content(detent, progress)
                            .allowsHitTesting(!fitsPeekToHeader || detent != .peek)
                            .accessibilityHidden(fitsPeekToHeader && (detent == .peek || isDragging))
                            .onGeometryChange(for: NavigationBottomSheetMeasurement.self) { geometry in
                                NavigationBottomSheetMeasurement(
                                    detent: detent, height: geometry.size.height.rounded(.up))
                            } action: { measurement in
                                guard fitsPeekToHeader || (fitsCompactContent && measurement.detent != .expanded) else { return }
                                contentHeights[measurement.detent.rawValue] = measurement.height
                            }
                    }
                }
                .coordinateSpace(name: scrollSpaceName)
                .scrollIndicators(resizesFromContent ? .hidden : .visible)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(detent == .peek || (fitsPeekToHeader && ownsCurrentDrag)
                    || (detent == .medium && resizesFromContent && !fitsPeekToHeader))
                .simultaneousGesture(dragGesture(fromContent: true),
                                     including: resizesFromContent ? .all : .none)
                .clipped()
                .contentShape(Rectangle())
                .onPreferenceChange(NavigationBottomSheetScrollOffsetKey.self) { minY in
                    scrollOffset = max(0, -minY)
                }
                .onChange(of: detent) { _, newValue in
                    guard newValue != .expanded, !fitsPeekToHeader || newValue == .peek else { return }
                    scrollOffset = 0
                    proxy.scrollTo("navigation-bottom-sheet-scroll-top", anchor: .top)
                }
            }

            footer(detent, progress)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: NavigationBottomSheetMeasurement.self) { geometry in
                    NavigationBottomSheetMeasurement(
                        detent: detent, height: geometry.size.height.rounded(.up))
                } action: { measurement in
                    guard fitsPeekToHeader || (fitsCompactContent && measurement.detent != .expanded) else { return }
                    footerHeights[measurement.detent.rawValue] = measurement.height
                }
                .simultaneousGesture(dragGesture(fromContent: false))

            if bottomContentInset > 0 {
                Color.clear.frame(height: bottomContentInset)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .clipShape(sheetShape)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: detent)
    }

    private var measuredPinnedHeader: some View {
        pinnedHeader(detent, progress)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: {
                pinnedHeaderHeight = $0
            }
            .simultaneousGesture(dragGesture(fromContent: false),
                                 including: scrollsPinnedHeader ? .none : .all)
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
        .frame(maxWidth: .infinity, minHeight: dragHandleHeight)
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
            .updating($dragGestureIsActive) { _, state, _ in state = true }
            .onChanged { value in
                if dragStartHeight == nil {
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    let isPullingUp = value.translation.height < 0
                    let canExpand = selectedIndex < detentHeights.count - 1
                    if fromContent {
                        guard scrollOffset <= 1 else { return }
                        if isPullingUp {
                            guard canExpand else { return }
                            // At the middle stop, long details scroll directly;
                            // the pinned summary and handle still expand the sheet.
                            if fitsPeekToHeader, detent == .medium, contentOverflowsViewport { return }
                        } else {
                            guard detent != .peek else { return }
                        }
                    }
                    dragStartHeight = restingHeight
                    // Only subtract motion already consumed by an expanded ScrollView.
                    dragStartTranslation = fromContent && (detent == .expanded || fitsPeekToHeader)
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
                clearDragTracking()
                moveDetent(to: targetIndex)
            }
    }

    private func rubberBanded(_ rawHeight: CGFloat) -> CGFloat {
        let minimum = detentHeights[0]
        let maximum = detentHeights.last!
        if fitsPeekToHeader { return min(maximum, max(minimum, rawHeight)) }
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
            if !ownsCurrentDrag { isDragging = false }
        }
    }

    private func resetDrag() {
        isDragging = false
        clearDragTracking()
        interactiveHeight = nil
    }

    private func clearDragTracking() {
        ownsCurrentDrag = false
        dragStartHeight = nil
        dragStartTranslation = nil
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
