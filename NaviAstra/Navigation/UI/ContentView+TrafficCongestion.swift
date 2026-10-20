#if os(iOS)
import SwiftUI

/// Presentation only: ETA and route selection continue to use RoadRouteETA.
private struct TrafficCongestion: Identifiable {
    let id: String
    var start: Double
    var end: Double
    var colorHex: UInt32
    var travelTime: Double?
    var delay: Double?

    var title: String {
        colorHex == RouteColorPalette.trafficModerate ? "Spowolniony ruch" : "Korek"
    }
}

private struct RouteCongestionSummary {
    var congestion: [TrafficCongestion] = []
    var routeDelay: Double?
    var hasClosure = false
    var partiallyMeasured = true

    static func make(route: NavigationRoute, from start: Double,
                     traffic: TrafficSnapshot?, now: Date) -> Self {
        guard let traffic, (-5...240).contains(now.timeIntervalSince(traffic.updatedAt)) else { return Self() }
        let geometry = RouteProgressGeometry(route)
        let lower = min(geometry.length, max(0, start))
        let colors: Set<UInt32> = [RouteColorPalette.trafficModerate, RouteColorPalette.trafficSlow,
                                  RouteColorPalette.trafficHeavy, RouteColorPalette.trafficStationary]
        func severity(of colorHex: UInt32) -> Int {
            switch colorHex {
            case RouteColorPalette.trafficModerate: 1
            case RouteColorPalette.trafficSlow: 2
            case RouteColorPalette.trafficHeavy: 3
            default: 0
            }
        }
        func fresh(_ segment: RouteTrafficSegment) -> Bool {
            segment.routeID == route.id && segment.startDistance.isFinite && segment.endDistance.isFinite &&
                segment.endDistance > max(lower, segment.startDistance) &&
                (-5...240).contains(now.timeIntervalSince(segment.measuredAt ?? traffic.updatedAt))
        }
        let measured = traffic.routeFlowSegments.filter(fresh)
        func grouped(_ segments: [RouteTrafficSegment], measured: Bool) -> [TrafficCongestion] {
            var result: [TrafficCongestion] = []
            var cursor = lower
            for segment in segments.sorted(by: { $0.startDistance < $1.startDistance }) {
                let a = max(cursor, segment.startDistance), b = min(geometry.length, segment.endDistance)
                guard b > a else { continue }
                cursor = b
                guard !segment.isRoadClosure, colors.contains(segment.colorHex) else { continue }
                let duration: Double?
                let delay: Double?
                if measured, let speed = segment.currentSpeedKph, speed.isFinite, speed > 0,
                   let freeSpeed = segment.freeFlowSpeedKph, freeSpeed.isFinite, freeSpeed > 0 {
                    let measuredTime = (b - a) / (speed / 3.6)
                    duration = measuredTime
                    delay = max(0, measuredTime - (b - a) / (freeSpeed / 3.6))
                } else {
                    // A stopped flow or a color alone cannot predict when traffic starts moving.
                    duration = nil
                    delay = nil
                }
                if let last = result.last, a <= last.end + 1 {
                    let index = result.count - 1
                    result[index].end = b
                    if severity(of: segment.colorHex) > severity(of: last.colorHex) {
                        result[index].colorHex = segment.colorHex
                    }
                    result[index].travelTime = last.travelTime.flatMap { t in duration.map { t + $0 } }
                    result[index].delay = last.delay.flatMap { t in delay.map { t + $0 } }
                } else {
                    result.append(TrafficCongestion(id: segment.id, start: a, end: b,
                        colorHex: segment.colorHex, travelTime: duration, delay: delay))
                }
            }
            return result
        }
        let confirmed = grouped(measured, measured: true)
        // Display geometry has a looser road match. It can explain a color, never supply times.
        let displayOnly = grouped(traffic.routeColorSegments.filter(fresh), measured: false).filter { display in
            !confirmed.contains { $0.start < display.end && $0.end > display.start }
        }
        let incidents = traffic.incidentDataAvailable ? traffic.incidents.filter {
            (-5...120).contains(now.timeIntervalSince($0.observedAt ?? traffic.updatedAt)) &&
                RouteTrafficMonitor.incidentProjection($0, geometry: geometry, route: route, at: now)
                    .map { $0.alongRoute > lower + 40 } == true
        } : []
        let prepared = RoadRouteETA.PreparedRoute(route, geometry: geometry)
        let eta = RoadRouteETA.estimate(route, prepared: prepared, from: lower, traffic: traffic)
        let base = RoadRouteETA.estimate(route, prepared: prepared, from: lower, traffic: nil)
        let coverage = TrafficCoverage.measure(route: route, from: lower, traffic: traffic, now: now, geometry: geometry)
        let stoppedFlow = measured.contains { !$0.isRoadClosure && $0.currentSpeedKph == 0 }
        return Self(congestion: (confirmed + displayOnly).sorted { $0.start < $1.start },
            routeDelay: eta.isFinite && !stoppedFlow && (coverage.freshDistance > 0 || incidents.contains { ($0.routingDelaySeconds ?? 0) > 0 })
                ? max(0, eta - base) : nil,
            hasClosure: !eta.isFinite, partiallyMeasured: coverage.routeFraction < 0.99)
    }
}

extension ContentView {
    private func congestionSummary(at date: Date) -> RouteCongestionSummary? {
        guard navigationStore.state.transportMode == .car, let route = navigationStore.state.route,
              navigationStore.state.status != .routePreview || navigationStore.state.journeyTimeMode == .now else { return nil }
        return .make(route: route, from: navigationStore.state.roadAlertRouteDistance,
                     traffic: navigationStore.state.traffic, now: date)
    }

    private func congestionDuration(_ seconds: Double) -> String {
        seconds < 60 ? "mniej niż 1 min" : time(seconds)
    }

    private func congestionDetails(_ congestion: TrafficCongestion) -> [String] {
        let traveled = navigationStore.state.roadAlertRouteDistance
        var details = [congestion.start <= traveled + 10 ? "Jesteś na tym odcinku" : "Za \(distance(congestion.start - traveled))",
                       "Długość odcinka z danymi o spowolnieniu: \(distance(congestion.end - congestion.start))"]
        if let travelTime = congestion.travelTime, let delay = congestion.delay {
            details += ["Szacowany przejazd: \(congestionDuration(travelTime))",
                        "Opóźnienie na odcinku: \(congestionDuration(delay)) względem swobodnego ruchu"]
        } else {
            details.append("Czas przejazdu i opóźnienie na odcinku są niedostępne")
        }
        return details
    }

    var navigationCongestionBanner: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if isNavigating, let summary = congestionSummary(at: context.date),
               let congestion = summary.congestion.first,
               congestion.start <= navigationStore.state.roadAlertRouteDistance + 12_000 {
                let traveled = navigationStore.state.roadAlertRouteDistance
                let remaining = max(0, congestion.start - traveled)
                VStack(alignment: .leading, spacing: 4) {
                    NavigationAlertDisclosure(title: congestion.title,
                        distanceText: remaining <= 10 ? "Teraz" : distance(remaining), distance: remaining,
                        details: congestionDetails(congestion) + ["Czas rozładowania korka jest nieznany"],
                        tint: Color(naviHex: congestion.colorHex), cornerRadius: 17,
                        symbol: Image(systemName: "car.side.fill").foregroundStyle(Color(naviHex: congestion.colorHex)))
                        .id(congestion.id)
                    Text(congestion.travelTime.flatMap { travelTime in
                        congestion.delay.map { delay in
                            "Przejazd: około \(congestionDuration(travelTime)) · opóźnienie: \(congestionDuration(delay))"
                        }
                    }
                         ?? "Brak wiarygodnego czasu przejazdu przez odcinek")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.naviTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var routeTrafficDelaySummary: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let summary = congestionSummary(at: context.date) {
                if summary.hasClosure {
                    Label("Zamknięcie na trasie — czas wymaga przeliczenia", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger))
                } else if let delay = summary.routeDelay, delay > 0 {
                    Button { appRouter.present(.trafficDetails) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Ruch wydłuża trasę o około \(congestionDuration(delay))", systemImage: "car.side.fill")
                                .foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
                                .fixedSize(horizontal: false, vertical: true)
                            if summary.partiallyMeasured {
                                Text("Na odcinkach z dostępnymi danymi")
                                    .font(.caption2).foregroundStyle(Color.naviTextSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Otwiera szczegóły opóźnień na trasie")
                } else if !summary.congestion.isEmpty {
                    Button { appRouter.present(.trafficDetails) } label: {
                        Label("Spowolniony ruch na trasie · zobacz szczegóły", systemImage: "car.side.fill")
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(.caption.weight(.semibold))
    }

    var routeCongestionDetailsCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let summary = congestionSummary(at: context.date) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ruch na Twojej trasie").font(.headline)
                    if summary.hasClosure {
                        Text("Zamknięcie na trasie. Czas dojazdu wymaga przeliczenia.")
                    } else if let delay = summary.routeDelay {
                        Text(delay > 0 ? "Wydłużenie trasy: około \(congestionDuration(delay))"
                             : "Pomiary nie wskazują dodatkowego opóźnienia względem czasu bazowego.")
                        Text("Porównanie z bazowym czasem trasy na odcinkach z danymi o ruchu.")
                            .foregroundStyle(Color.naviTextSecondary)
                        if isNavigating {
                            Text("Wpływ ruchu jest już uwzględniony w przewidywanym czasie dojazdu.")
                                .foregroundStyle(Color.naviTextSecondary)
                        }
                    } else {
                        Text("Brak wiarygodnego pomiaru wydłużenia trasy.")
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    if summary.partiallyMeasured {
                        Text("Dane obejmują część trasy. Opóźnienia na pozostałych odcinkach są nieznane.")
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    ForEach(summary.congestion) { congestion in
                        Divider()
                        Label(congestion.title, systemImage: "car.side.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(naviHex: congestion.colorHex))
                        ForEach(congestionDetails(congestion), id: \.self) { detail in
                            Text(detail)
                        }
                    }
                    Text("Czasy są szacunkowe i zmieniają się wraz z ruchem. Czas rozładowania korka jest nieznany.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
                .font(.subheadline)
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NavigationGlassSurface(radius: 22))
            }
        }
    }
}
#endif
