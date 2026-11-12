import Foundation

nonisolated enum RouteSpeedRule: Hashable, Sendable {
    case posted(Int), unrestricted, unknown
}

nonisolated struct RouteSpeedInterval: Sendable {
    let startMeters: Double
    let endMeters: Double
    let rule: RouteSpeedRule
    var fromOSM = false
}

nonisolated struct RouteSpeedWay: Sendable {
    let coordinates: [Coordinate]
    let forward: RouteSpeedRule
    let backward: RouteSpeedRule
    var fromOSM = false

    init(coordinates: [Coordinate], forward: RouteSpeedRule, backward: RouteSpeedRule) {
        self.coordinates = coordinates
        self.forward = forward
        self.backward = backward
    }

    init(_ way: OSMRoadSpeedSegment) {
        func rule(_ direction: String) -> RouteSpeedRule {
            let tags = way.tags
            // A conditional value may change by the time the driver reaches it.
            guard tags["maxspeed:" + direction + ":conditional"] == nil,
                  tags["maxspeed:conditional"] == nil else { return .unknown }
            let raw = tags["maxspeed:" + direction] ?? tags["maxspeed"]
            if let raw, raw.contains(";") || raw.contains("@") { return .unknown }
            if raw?.lowercased() == "none" { return .unrestricted }
            return SpeedLimitParser.parse(raw, tags: tags).map(RouteSpeedRule.posted) ?? .unknown
        }
        coordinates = way.coordinates
        fromOSM = true
        forward = way.tags["oneway"] == "-1" ? .unknown : rule("forward")
        let oneWay = ["yes", "1", "true"].contains(way.tags["oneway"] ?? "") || way.tags["junction"] == "roundabout"
        backward = oneWay ? .unknown : rule("backward")
    }
}

/// A boundary exists only when positively identified on both sides or at a directional sign.
/// Lookups are binary searches in already resolved spans, independent of route length.
nonisolated struct RouteSpeedLimitProfile: Sendable {
    private struct Span: Sendable {
        let start: Double
        let end: Double
        let kph: Int
    }
    private var spans: [Span] = []

    init(intervals: [RouteSpeedInterval]) {
        self.init(intervals: intervals, signs: [])
    }

    private struct Sign {
        let distance: Double
        let speed: Int?
        let endsLimit: Bool
        let previousSpeed: Int?
    }

    private init(intervals: [RouteSpeedInterval], signs: [Sign]) {
        var events: [Double: [(rule: RouteSpeedRule, delta: Int, fromOSM: Bool)]] = [:]
        for item in intervals where item.startMeters.isFinite && item.endMeters.isFinite && item.endMeters > item.startMeters {
            events[item.startMeters, default: []].append((item.rule, 1, item.fromOSM))
            events[item.endMeters, default: []].append((item.rule, -1, item.fromOSM))
        }
        let positions = events.keys.sorted()
        var activeOSM: [RouteSpeedRule: Int] = [:]
        var activeProvider: [RouteSpeedRule: Int] = [:]
        var runs: [RouteSpeedInterval] = []
        for (start, end) in zip(positions, positions.dropFirst()) {
            for event in events[start] ?? [] {
                if event.fromOSM {
                    activeOSM[event.rule, default: 0] += event.delta
                    if activeOSM[event.rule] == 0 { activeOSM[event.rule] = nil }
                } else {
                    activeProvider[event.rule, default: 0] += event.delta
                    if activeProvider[event.rule] == 0 { activeProvider[event.rule] = nil }
                }
            }
            // A directed map restriction, including unresolved conditional data,
            // takes precedence over the routing engine's generic posted value.
            let active = activeOSM.isEmpty ? activeProvider : activeOSM
            let rule = active.count == 1 ? active.keys.first! : .unknown
            if let last = runs.last, last.rule == rule {
                runs[runs.count - 1] = RouteSpeedInterval(startMeters: last.startMeters, endMeters: end, rule: rule)
            } else {
                runs.append(RouteSpeedInterval(startMeters: start, endMeters: end, rule: rule))
            }
        }

        var signIndex = 0
        for (index, run) in runs.enumerated() {
            guard case .posted(let kph) = run.rule else { continue }
            while signIndex < signs.count, signs[signIndex].distance < run.startMeters { signIndex += 1 }
            var next = signIndex
            var end: Double?
            while next < signs.count, signs[next].distance <= run.endMeters {
                let sign = signs[next]
                if sign.endsLimit ? (sign.previousSpeed == nil || sign.previousSpeed == kph) : sign.speed != kph {
                    end = sign.distance
                    break
                }
                next += 1
            }
            if end == nil, index + 1 < runs.count, runs[index + 1].rule != .unknown { end = run.endMeters }
            if let end, end > run.startMeters { spans.append(.init(start: run.startMeters, end: end, kph: kph)) }
        }
    }

    func remainingMeters(from progress: Double, limit: Int) -> Double? {
        guard progress.isFinite else { return nil }
        var low = 0, high = spans.count
        while low < high {
            let mid = low + (high - low) / 2
            if spans[mid].end <= progress { low = mid + 1 } else { high = mid }
        }
        guard low < spans.count, spans[low].start <= progress, spans[low].kph == limit else { return nil }
        return spans[low].end - progress
    }

    init(geometry: RouteProgressGeometry, from start: Double, through end: Double, ways: [RouteSpeedWay], signs: [RoadSafetyAlert]) {
        let start = max(0, start), end = min(end, geometry.length)
        guard end > start else { self.init(intervals: []); return }
        let points = geometry.corridor(from: start, through: end)
        guard points.count <= 8_000 else { self.init(intervals: []); return }
        let corridor = RouteProgressGeometry(coordinates: points)
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        guard let south = lats.min(), let north = lats.max(), let west = lons.min(), let east = lons.max() else {
            self.init(intervals: []); return
        }
        let latPad = 4 / 110_574.0
        let lonPad = 4 / max(1000, cos(south * .pi / 180) * 111_320)

        // Match both ends of each physical edge. Equally close passages on loops cannot establish a boundary.
        func position(_ point: Coordinate) -> Double? {
            let nearby = corridor.projections(near: point, within: 2)
            guard let closest = nearby.min(by: { $0.distanceFromRoute < $1.distanceFromRoute }),
                  !nearby.contains(where: { abs($0.alongRoute - closest.alongRoute) > 4 }) else { return nil }
            return closest.alongRoute
        }
        var intervals: [RouteSpeedInterval] = []
        var work = 0
        func align(_ way: RouteSpeedWay, after signPosition: Double? = nil) -> Bool {
            var previous: Double?
            for edge in zip(way.coordinates, way.coordinates.dropFirst()) {
                guard !Task.isCancelled else { return false }
                work += 1
                guard work <= 150_000 else { return false }
                let (a, b) = edge
                guard max(a.latitude, b.latitude) >= south - latPad, min(a.latitude, b.latitude) <= north + latPad,
                      max(a.longitude, b.longitude) >= west - lonPad, min(a.longitude, b.longitude) <= east + lonPad else {
                    previous = nil
                    continue
                }
                var aDistance = previous ?? position(a)
                var bDistance = position(b)
                previous = bDistance
                // A route/window can begin or finish inside a long way. Keep only its actual covered portion.
                if aDistance == nil || bDistance == nil {
                    var edges = [(coordinate: a, distance: aDistance), (coordinate: b, distance: bDistance)]
                    for (point, distance) in [(points[0], 0.0), (points[points.count - 1], corridor.length)] {
                        if let p = MapMatcher.project(point, onto: [a, b]), p.distanceFromRoute <= 2 {
                            edges.append((point, distance))
                        }
                    }
                    let matched = edges.compactMap { item -> (Double, Double)? in
                        guard let distance = item.distance else { return nil }
                        return (a.distance(to: item.coordinate), distance)
                    }.sorted { $0.0 < $1.0 }
                    aDistance = matched.first?.1
                    bDistance = matched.last?.1
                }
                guard let aDistance, let bDistance, abs(bDistance - aDistance) > 0.1 else { continue }
                let low = min(aDistance, bDistance), high = max(aDistance, bDistance)
                // Sparse endpoints alone can coincide across a bend, interchange or shortcut.
                let section = corridor.corridor(from: low, through: high)
                work += section.count
                guard work <= 150_000 else { return false }
                guard let first = section.first, let last = section.last,
                      abs((high - low) - first.distance(to: last)) <= max(2, (high - low) * 0.005),
                      section.allSatisfy({ (MapMatcher.project($0, onto: [a, b])?.distanceFromRoute ?? .infinity) <= 2 })
                else { continue }
                let lower = max(signPosition ?? start, start + low)
                guard start + high > lower else { continue }
                intervals.append(.init(startMeters: lower, endMeters: start + high,
                    rule: bDistance > aDistance ? way.forward : way.backward, fromOSM: way.fromOSM))
            }
            return true
        }
        for way in ways {
            guard align(way) else { self.init(intervals: []); return }
        }

        var changes: [Sign] = []
        var postedSigns: [Int64: (kph: Int, zone: Bool)] = [:]
        for sign in signs.sorted(by: { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }) {
            guard let distance = sign.distanceAlongRoute, (start...end).contains(distance),
                  let context = sign.signRouteContext, context.forward != nil || context.travelBearing != nil,
                  let anchor = geometry.coordinate(at: distance),
                  let road = MapMatcher.project(anchor, onto: context.road), road.distanceFromRoute <= 3,
                  context.road.indices.contains(road.segment + 1),
                  let before = geometry.coordinate(at: max(0, distance - 2)),
                  let after = geometry.coordinate(at: min(geometry.length, distance + 2)) else { continue }
            let a = context.road[road.segment], b = context.road[road.segment + 1]
            let forward = RoadGeometryAlignment.isAligned(a, b, before, after, directed: true)
            guard RoadGeometryAlignment.isAligned(a, b, before, after),
                  context.forward.map({ $0 == forward }) ?? true else { continue }
            if let bearing = context.travelBearing {
                let dx = (after.longitude - before.longitude) * cos(before.latitude * .pi / 180)
                let heading = (atan2(dx, after.latitude - before.latitude) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                let delta = abs(bearing - heading)
                guard min(delta, 360 - delta) <= 30 else { continue }
            }
            let codes = Set(PolishRoadSign.codes(sign.signCode ?? ""))
            let previous = context.roadID.flatMap { postedSigns[$0] }
            if !codes.isDisjoint(with: ["B-34", "B-42", "B-44"]) {
                // A generic end-of-restrictions sign does not cancel the underlying statutory limit.
                let speed = sign.speedLimitKph ?? previous?.kph
                guard let speed, codes.contains("B-34") ||
                        (previous.map { $0.zone == codes.contains("B-44") } == true) else { continue }
                changes.append(.init(distance: distance, speed: nil, endsLimit: true, previousSpeed: speed))
                if let id = context.roadID { postedSigns[id] = nil }
            } else if sign.type == .speedLimitSign || sign.type == .trafficZoneSign, let speed = sign.speedLimitKph, speed > 0 {
                changes.append(.init(distance: distance, speed: speed, endsLimit: false, previousSpeed: nil))
                if let id = context.roadID { postedSigns[id] = (speed, codes.contains("B-43")) }
                var way = RouteSpeedWay(coordinates: context.road, forward: forward ? .posted(speed) : .unknown,
                                       backward: forward ? .unknown : .posted(speed))
                way.fromOSM = true
                guard align(way, after: distance) else { self.init(intervals: []); return }
            }
        }
        self.init(intervals: intervals, signs: changes.sorted { $0.distance < $1.distance })
    }
}

@MainActor
final class SpeedLimitDistanceTracker {
    private struct Window: Equatable {
        let routeID: UUID
        let kilometre: Int
    }
    private var window: Window?
    private var profile: RouteSpeedLimitProfile?
    private var profileTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var lookupWays: [RouteSpeedWay] = []
    private var lastLookup = Date.distantPast
    private var revision = 0

    func sourcesChanged() {
        revision += 1
        profileTask?.cancel()
        profileTask = nil
        profile = nil
    }

    func reset() {
        sourcesChanged()
        window = nil
        lookupTask?.cancel()
        lookupTask = nil
        lookupWays.removeAll()
    }

    func remaining(position: SpeedLimitRoadPosition, limit: Int, geometry: @autoclosure () -> RouteProgressGeometry,
                   snapshots: [RoadDataSnapshot?], signs: [RoadSafetyAlert], provider: SpeedLimitProvider,
                   updated: @escaping @MainActor () -> Void) -> Double? {
        guard position.progress.isFinite, position.progress >= 0 else { return nil }
        if window?.routeID == position.routeID,
           let distance = profile?.remainingMeters(from: position.progress, limit: limit) { return distance }
        let currentWindow = Window(routeID: position.routeID, kilometre: Int(position.progress / 1000))
        if window != currentWindow {
            reset()
            window = currentWindow
        }
        guard profileTask == nil else { return nil }
        if profile == nil {
            let geometry = geometry()
            let start = max(0, Double(currentWindow.kilometre) * 1_000 - 20)
            let end = min(geometry.length, start + 12_000)
            let revision = revision
            let ways = lookupWays
            profileTask = Task { [weak self] in
                let work = Task.detached(priority: .utility) {
                    var osm: [Int64: OSMRoadSpeedSegment] = [:]
                    for snapshot in snapshots.compactMap({ $0 }).sorted(by: { $0.fetchedAt < $1.fetchedAt })
                        where Date().timeIntervalSince(snapshot.fetchedAt) < 86_400 {
                        for way in snapshot.speedSegments { osm[way.id] = way }
                    }
                    return RouteSpeedLimitProfile(geometry: geometry, from: start, through: end,
                        ways: osm.values.map(RouteSpeedWay.init) + ways, signs: signs)
                }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, self.revision == revision, self.window == currentWindow else { return }
                self.profileTask = nil
                self.profile = result
                updated()
            }
        } else if lookupTask == nil, Date().timeIntervalSince(lastLookup) >= 90 {
            lastLookup = .now
            let geometry = geometry()
            lookupTask = Task { [weak self] in
                let ways = (try? await provider.speedLimitWays(aheadOn: geometry, from: position.progress)) ?? []
                guard !Task.isCancelled, let self, self.window == currentWindow else { return }
                self.lookupTask = nil
                if !ways.isEmpty {
                    self.lookupWays = ways
                    self.sourcesChanged()
                    updated()
                }
            }
        }
        return nil
    }
}
