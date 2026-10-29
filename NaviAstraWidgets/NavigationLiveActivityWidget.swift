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
            HStack(spacing: 14) {
                routeDiagram(context)
                    .frame(width: 110, height: 114)
                    .privacySensitive()
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 9) {
                        ManeuverIcon(type: context.state.maneuver, fallbackSymbol: context.state.symbolName,
                            size: 30, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(maneuverLabel(context)).font(.title3.bold())
                            Text(context.state.roadName.isEmpty ? context.state.instruction : context.state.roadName)
                                .font(.subheadline).lineLimit(2).privacySensitive()
                        }
                    }
                    summary(context)
                    ProgressView(value: context.state.routeProgress).tint(.cyan)
                }
            }
            .padding(14)
            .environment(\.locale, Locale(identifier: "pl_PL"))
            .activityBackgroundTint(.black.opacity(0.9))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ManeuverIcon(type: context.state.maneuver, fallbackSymbol: context.state.symbolName,
                        size: 30, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(maneuverLabel(context)).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        routeDiagram(context).frame(width: 86, height: 86).privacySensitive()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(context.state.roadName.isEmpty ? context.state.instruction : context.state.roadName)
                                .font(.headline).lineLimit(2).privacySensitive()
                            summary(context)
                            ProgressView(value: context.state.routeProgress).tint(.cyan)
                        }
                    }
                    .environment(\.locale, Locale(identifier: "pl_PL"))
                }
            } compactLeading: {
                ManeuverIcon(type: context.state.maneuver, fallbackSymbol: context.state.symbolName,
                    size: 20, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
            } compactTrailing: {
                Text(context.state.isRerouting ? "…" : isPositionStale(context) ? "GPS" : distance(context.state.maneuverDistance))
                    .monospacedDigit()
            } minimal: {
                ManeuverIcon(type: context.state.isRerouting ? nil : context.state.maneuver,
                    fallbackSymbol: context.state.isRerouting ? "arrow.triangle.2.circlepath" : context.state.symbolName,
                    size: 20, roundabout: context.state.isRerouting ? nil : context.state.roundabout)
            }
        }
    }

    private func isPositionStale(_ context: ActivityViewContext<NavigationActivityAttributes>) -> Bool {
        context.isStale || context.state.gpsSignalLost
    }

    @ViewBuilder private func routeDiagram(_ context: ActivityViewContext<NavigationActivityAttributes>) -> some View {
        if !isPositionStale(context), !context.state.isRerouting, let sketch = context.state.routeSketch {
            NavigationActivityRouteDiagram(sketch: sketch)
        } else {
            VStack(spacing: 7) {
                Image(systemName: context.state.isRerouting ? "arrow.triangle.2.circlepath" : isPositionStale(context) ? "location.slash" : "map")
                    .font(.title2)
                Text(context.state.isRerouting ? "Nowa trasa" : isPositionStale(context) ? "Czekam na GPS" : "Schemat niedostępny")
                    .font(.caption2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private func summary(_ context: ActivityViewContext<NavigationActivityAttributes>) -> some View {
        if isPositionStale(context) {
            Text("Oczekiwanie na aktualną pozycję GPS").font(.caption)
        } else if context.state.isRerouting {
            Text("Obliczanie odległości i czasu trasy…").font(.caption)
        } else if let remaining = context.state.remainingDistance,
                  let time = context.state.remainingTime {
            HStack(spacing: 5) {
                Text("\(duration(time)) · \(distance(remaining))")
                Spacer(minLength: 0)
                if let arrival = context.state.arrivalTime {
                    Text(arrival.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                        .locale(Locale(identifier: "pl_PL"))))
                }
            }.font(.caption.monospacedDigit())
        } else {
            Text("Odległość i czas trasy niedostępne").font(.caption)
        }
    }

    private func maneuverLabel(_ context: ActivityViewContext<NavigationActivityAttributes>) -> String {
        if context.state.isRerouting { return "Przeliczanie trasy" }
        if isPositionStale(context) { return "Czekam na GPS" }
        return context.state.maneuverDistance.map { distance($0) } ?? "Do celu"
    }

    private func distance(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, (0...400_000_000).contains(meters) else { return "—" }
        let locale = Locale(identifier: "pl_PL")
        if meters >= 1_000 {
            return (meters / 1_000).formatted(.number.precision(.fractionLength(1)).locale(locale)) + " km"
        }
        return (Double(Int((meters / 10).rounded()) * 10)).formatted(.number.precision(.fractionLength(0)).locale(locale)) + " m"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, (0...31_536_000).contains(seconds) else { return "—" }
        let minutes = max(0, Int(ceil(seconds / 60)))
        return minutes >= 60 ? "\(minutes / 60) godz. \(minutes % 60) min" : "\(minutes) min"
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
