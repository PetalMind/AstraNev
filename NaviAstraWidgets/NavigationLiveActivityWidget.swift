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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: context.state.symbolName).font(.largeTitle.bold())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(maneuverLabel(context)).font(.title2.bold())
                        Text(context.state.roadName.isEmpty ? context.state.instruction : context.state.roadName)
                            .font(.headline).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if context.isStale || context.state.gpsSignalLost {
                    Text("Oczekiwanie na aktualną pozycję GPS").font(.caption)
                }
                HStack {
                    Text(duration(context.state.remainingTime))
                    Text("·")
                    Text(distance(context.state.remainingDistance))
                    Spacer()
                    Text(context.state.arrivalTime, style: .time)
                }.font(.subheadline.monospacedDigit())
                ProgressView(value: context.state.routeProgress).tint(.cyan)
            }
            .padding(16)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbolName).font(.title.bold())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(maneuverLabel(context)).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.roadName.isEmpty ? context.state.instruction : context.state.roadName)
                            .font(.headline).lineLimit(1)
                        if context.isStale || context.state.gpsSignalLost {
                            Text("Oczekiwanie na GPS").font(.caption)
                        }
                        HStack {
                            Text("\(duration(context.state.remainingTime)) · \(distance(context.state.remainingDistance))")
                            Spacer()
                            Text(context.state.arrivalTime, style: .time)
                        }.font(.caption.monospacedDigit())
                        ProgressView(value: context.state.routeProgress).tint(.cyan)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
            } compactTrailing: {
                Text(context.state.isRerouting ? "…" : context.state.maneuverDistance.map(distance) ?? "—")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: context.state.isRerouting ? "arrow.triangle.2.circlepath" : context.state.symbolName)
            }
        }
    }

    private func maneuverLabel(_ context: ActivityViewContext<NavigationActivityAttributes>) -> String {
        if context.state.isRerouting { return "Przeliczanie trasy" }
        return context.state.maneuverDistance.map(distance) ?? context.attributes.destinationName
    }

    private func distance(_ meters: Double) -> String {
        if meters >= 1_000 { return String(format: "%.1f km", meters / 1_000) }
        return "\(Int((meters / 10).rounded()) * 10) m"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        "\(max(0, Int(ceil(seconds / 60)))) min"
    }
}
