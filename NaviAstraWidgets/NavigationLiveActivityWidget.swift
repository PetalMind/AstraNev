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
                    ManeuverIcon(type: context.state.maneuver, fallbackSymbol: context.state.symbolName, size: 34, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
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
                    Text(polishTime(context.state.arrivalTime))
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
                    ManeuverIcon(type: context.state.maneuver, fallbackSymbol: context.state.symbolName, size: 30, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
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
                            Text(polishTime(context.state.arrivalTime))
                        }.font(.caption.monospacedDigit())
                        ProgressView(value: context.state.routeProgress).tint(.cyan)
                    }
                }
            } compactLeading: {
                ManeuverIcon(type: context.state.maneuver, fallbackSymbol: context.state.symbolName, size: 20, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
            } compactTrailing: {
                Text(context.state.isRerouting ? "…" : context.state.maneuverDistance.map(distance) ?? "—")
                    .monospacedDigit()
            } minimal: {
                ManeuverIcon(type: context.state.isRerouting ? nil : context.state.maneuver,
                             fallbackSymbol: context.state.isRerouting ? "arrow.triangle.2.circlepath" : context.state.symbolName, size: 20, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
            }
        }
    }

    private func maneuverLabel(_ context: ActivityViewContext<NavigationActivityAttributes>) -> String {
        if context.state.isRerouting { return "Przeliczanie trasy" }
        return context.state.maneuverDistance.map(distance) ?? context.attributes.destinationName
    }

    private func distance(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "Dystans niedostępny" }
        if meters >= 1_000 {
            let kilometers = String(format: "%.1f", locale: Locale(identifier: "pl_PL"), meters / 1_000)
            return "\(kilometers) km"
        }
        return "\(Int((meters / 10).rounded()) * 10) m"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) * 60 else { return "Czas niedostępny" }
        return "\(max(0, Int(ceil(seconds / 60)))) min"
    }

    private func polishTime(_ date: Date) -> String {
        guard date.timeIntervalSince1970.isFinite else { return "Czas niedostępny" }
        var format = Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "pl_PL"))
        format.timeZone = .current
        return date.formatted(format)
    }
}
