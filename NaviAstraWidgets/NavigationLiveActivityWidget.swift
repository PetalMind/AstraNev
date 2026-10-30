import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NaviAstraWidgets: WidgetBundle {
    var body: some Widget { NavigationLiveActivityWidget() }
}

struct NavigationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationActivityAttributes.self) { context in
            NavigationLockScreenView(presentation: .init(context: context))
                .environment(\.locale, Locale(identifier: "pl_PL"))
                .activityBackgroundTint(.black.opacity(0.9))
                .activitySystemActionForegroundColor(.white)
                .foregroundStyle(.white)
        } dynamicIsland: { context in
            let presentation = NavigationActivityPresentation(context: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NavigationActivityManeuver(presentation: presentation, size: 30)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(presentation.maneuverLabel)
                        .font(.headline.monospacedDigit())
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    NavigationIslandGuidanceView(presentation: presentation)
                        .environment(\.locale, Locale(identifier: "pl_PL"))
                }
            } compactLeading: {
                NavigationActivityManeuver(presentation: presentation, size: 20)
            } compactTrailing: {
                Text(presentation.compactLabel)
                    .monospacedDigit()
                    .accessibilityLabel(presentation.maneuverLabel)
            } minimal: {
                NavigationActivityManeuver(presentation: presentation, size: 20)
                    .accessibilityLabel(presentation.maneuverLabel)
            }
        }
    }
}

/// One display policy for the Lock Screen and every Dynamic Island presentation.
private struct NavigationActivityPresentation {
    static let locale = Locale(identifier: "pl_PL")
    let state: NavigationActivityAttributes.ContentState
    let isPositionStale: Bool

    init(context: ActivityViewContext<NavigationActivityAttributes>) {
        state = context.state
        isPositionStale = context.isStale || context.state.gpsSignalLost
    }

    var hasCurrentGuidance: Bool { !isPositionStale && !state.isRerouting }
    var guidanceLine: String? {
        guard hasCurrentGuidance else { return nil }
        return state.roadName.isEmpty ? state.instruction : state.roadName
    }
    var maneuverLabel: String {
        if isPositionStale { return "Czekam na GPS" }
        if state.isRerouting { return "Przeliczanie trasy" }
        return state.maneuverDistance.map { Self.distance($0) } ?? "Do celu"
    }
    var compactLabel: String {
        isPositionStale ? "GPS" : state.isRerouting ? "…" : Self.distance(state.maneuverDistance)
    }
    var statusSymbol: String {
        isPositionStale ? "location.slash" : state.isRerouting ? "arrow.triangle.2.circlepath" : "map"
    }
    var statusDescription: String {
        if isPositionStale { return "Oczekiwanie na aktualną pozycję GPS" }
        if state.isRerouting { return "Obliczanie nowej trasy…" }
        return "Odległość i czas trasy niedostępne"
    }
    var arrivalLabel: String? {
        state.arrivalTime?.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Self.locale))
    }
    var progress: Double { state.routeProgress.isFinite ? min(1, max(0, state.routeProgress)) : 0 }

    static func distance(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, (0...400_000_000).contains(meters) else { return "—" }
        if meters >= 1_000 {
            return (meters / 1_000).formatted(.number.precision(.fractionLength(1)).locale(locale)) + " km"
        }
        return (Double(Int((meters / 10).rounded()) * 10)).formatted(.number.precision(.fractionLength(0)).locale(locale)) + " m"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, (0...31_536_000).contains(seconds) else { return "—" }
        let minutes = max(0, Int(ceil(seconds / 60)))
        return minutes >= 60 ? "\(minutes / 60) godz. \(minutes % 60) min" : "\(minutes) min"
    }
}

private struct NavigationLockScreenView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: NavigationActivityPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize,
               presentation.hasCurrentGuidance, let sketch = presentation.state.routeSketch {
                NavigationActivityRouteDiagram(sketch: sketch)
                    .frame(width: 90, height: 104)
                    .privacySensitive()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    NavigationActivityManeuver(presentation: presentation, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.maneuverLabel)
                            .font(.title3.bold().monospacedDigit())
                        if let guidance = presentation.guidanceLine {
                            Text(guidance)
                                .font(.subheadline)
                                .lineLimit(2)
                                .privacySensitive()
                        }
                    }
                }
                NavigationActivitySummary(presentation: presentation)
                NavigationActivityProgress(presentation: presentation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

private struct NavigationIslandGuidanceView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: NavigationActivityPresentation

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize,
               presentation.hasCurrentGuidance, let sketch = presentation.state.routeSketch {
                NavigationActivityRouteDiagram(sketch: sketch)
                    .frame(width: 76, height: 76)
                    .privacySensitive()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let guidance = presentation.guidanceLine {
                    Text(guidance)
                        .font(.headline)
                        .lineLimit(2)
                        .privacySensitive()
                }
                NavigationActivitySummary(presentation: presentation)
                NavigationActivityProgress(presentation: presentation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NavigationActivityManeuver: View {
    let presentation: NavigationActivityPresentation
    let size: CGFloat

    var body: some View {
        ManeuverIcon(type: presentation.hasCurrentGuidance ? presentation.state.maneuver : nil,
                     fallbackSymbol: presentation.hasCurrentGuidance ? presentation.state.symbolName : presentation.statusSymbol,
                     size: size,
                     roundabout: presentation.hasCurrentGuidance ? presentation.state.roundabout : nil)
    }
}

private struct NavigationActivitySummary: View {
    let presentation: NavigationActivityPresentation

    var body: some View {
        if presentation.hasCurrentGuidance,
           let remaining = presentation.state.remainingDistance,
           let time = presentation.state.remainingTime {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    remainingSummary(time: time, distance: remaining)
                    Spacer(minLength: 0)
                    arrival
                }
                VStack(alignment: .leading, spacing: 3) {
                    remainingSummary(time: time, distance: remaining)
                    arrival
                }
            }
            .font(.caption.monospacedDigit())
        } else {
            Label(presentation.statusDescription, systemImage: presentation.statusSymbol)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func remainingSummary(time: TimeInterval, distance: Double) -> some View {
        Text("\(NavigationActivityPresentation.duration(time)) · \(NavigationActivityPresentation.distance(distance))")
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var arrival: some View {
        if let arrival = presentation.arrivalLabel {
            Text("Przyjazd \(arrival)")
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize()
        }
    }
}

private struct NavigationActivityProgress: View {
    let presentation: NavigationActivityPresentation

    var body: some View {
        if presentation.hasCurrentGuidance {
            ProgressView(value: presentation.progress)
                .tint(.cyan)
                .accessibilityLabel("Postęp podróży")
                .accessibilityValue(presentation.progress.formatted(.percent.precision(.fractionLength(0))
                    .locale(NavigationActivityPresentation.locale)))
        }
    }
}

private struct NavigationActivityRouteDiagram: View {
    let sketch: NavigationActivityRouteSketch

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08))
                path(in: size).stroke(.black.opacity(0.6), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                path(in: size).stroke(.cyan, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                if let maneuver = sketch.maneuver {
                    Circle().fill(.orange).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(point(maneuver, in: size))
                }
                Image(systemName: "location.north.fill")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .padding(6).background(.blue, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(point(sketch.puck, in: size))
            }.clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("Schemat trasy, bieżąca pozycja i najbliższy manewr")
    }

    private func point(_ point: NavigationActivityRouteSketch.Point, in size: CGSize) -> CGPoint {
        CGPoint(x: Double(point.x) / 1_000 * size.width, y: Double(point.y) / 1_000 * size.height)
    }

    private func path(in size: CGSize) -> Path {
        Path { path in
            guard let first = sketch.points.first else { return }
            path.move(to: point(first, in: size))
            for coordinate in sketch.points.dropFirst() { path.addLine(to: point(coordinate, in: size)) }
        }
    }
}
