#if os(iOS)
import Foundation
import CoreGraphics

/// Metric topology for presentation only. It never changes the routing graph or turn permissions.
nonisolated enum DetailedRoadTopology {
    typealias Vector = DetailedRoadGeometry.Vector
    typealias Sample = DetailedRoadGeometry.Sample

    struct Corridor {
        let road: NormalizedDetailedRoad
        var line: [Sample]
        let start: Int
        let end: Int
        var startInset = 0.0
        var endInset = 0.0
        var startFade = 0.0
        var endFade = 0.0
        var startPaintClearance = 0.0
        var endPaintClearance = 0.0
        var removed = false
    }
    struct RoadEndProfile {
        let corridor: Int
        let atStart: Bool
        let road: NormalizedDetailedRoad
        let anchor: Sample
        /// Points away from the junction, regardless of OSM way direction.
        let tangent: Vector
        let width: Double
        let center: Vector
        let leftEdge: Vector
        let rightEdge: Vector
        let inset: Double
        let lanes: [LanePort]
    }
    struct LanePort {
        let point: Vector
        let outgoing: Bool
        let turns: [String]
    }
    struct LaneConnector {
        let points: [Vector]
        let sourcePort: Int
        let targetPort: Int
        let sourceLane: Int
        let targetLane: Int
    }
    struct Marking {
        let kind: DetailedRoadGraphic.Kind
        let points: [Vector]
        var opacity = 1.0
    }
    struct JunctionRegion {
        let road: NormalizedDetailedRoad
        let surface: [Vector]
        let casing: [Vector]
        let edgeLines: [[Vector]]
        let separators: [Marking]
        /// Inferred trajectories only; they are never rendered as turn arrows.
        let laneConnectors: [LaneConnector]
        let gore: [Vector]
        let continuation: Bool
        /// Actual shared OSM endpoints; never inferred from an overpass crossing.
        var gradeRoads: [NormalizedDetailedRoad] = []
    }
    struct Network {
        var corridors: [Corridor]
        let junctions: [JunctionRegion]
    }
    private struct Node {
        let point: Vector
        var ends: [(corridor: Int, atStart: Bool)] = []
    }
    private struct NodeKey: Hashable {
        let id: Int64?
        let x: Int
        let y: Int
        let level: Int
        let elevated: Bool
    }
    private struct Cell: Hashable { let x: Int; let y: Int }

    static func build(_ input: [NormalizedDetailedRoad], project: (DetailedRoad.Point) -> Vector) throws -> Network {
        var nodes: [Node] = []
        var keys: [NodeKey: Int] = [:]
        var ways: [(road: NormalizedDetailedRoad, samples: [Sample], nodes: [Int])] = []
        var occurrences: [Int: Int] = [:]
        var seen: Set<Int64> = []
        for road in input where road.confidence != .invalid && road.renderLevel != .underground && seen.insert(road.id).inserted {
            try Task.checkCancellation()
            let points = road.points.map(project)
            guard points.count > 1, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            let length = DetailedRoadGeometry.pathLength(points)
            guard length > 0.15 else { continue }
            var samples: [Sample] = [], indices: [Int] = [], traveled = 0.0
            for index in points.indices {
                if index > 0 { traveled += (points[index] - points[index - 1]).length }
                let id = road.nodeIDs.flatMap { $0.count == points.count ? $0[index] : nil }
                let key = NodeKey(id: id, x: id == nil ? Int((points[index].x * 10).rounded()) : 0,
                    y: id == nil ? Int((points[index].y * 10).rounded()) : 0,
                    level: road.layer, elevated: road.bridge)
                let node: Int
                if let existing = keys[key] { node = existing }
                else { node = nodes.count; nodes.append(Node(point: points[index])); keys[key] = node }
                if let last = samples.last, (last.point - points[index]).length < 0.15 { continue }
                samples.append(Sample(point: points[index], fraction: traveled / length))
                indices.append(node)
                occurrences[node, default: 0] += 1
            }
            if samples.count > 1 { ways.append((road, samples, indices)) }
        }
        // The end of a bridge and the start of its approach share an actual OSM node.
        // They connect despite different layer tags. Interior crossings remain separate.
        let terminalNodes = Set(ways.filter { $0.nodes.first != $0.nodes.last }
            .flatMap { [$0.nodes.first!, $0.nodes.last!] })
        var nodeLevels: [Int: Int] = [:]
        var osmNodes: [Int64: [Int]] = [:]
        for (key, node) in keys {
            nodeLevels[node] = key.level
            if let id = key.id { osmNodes[id, default: []].append(node) }
        }
        let gradeGroups = osmNodes.values.filter { group in
            group.count > 1 && group.contains(where: terminalNodes.contains)
                && group.allSatisfy { (nodes[$0].point - nodes[group[0]].point).length < 0.15 }
        }.map { $0.sorted { (nodeLevels[$0] ?? 0, $0) < (nodeLevels[$1] ?? 0, $1) } }
        for group in gradeGroups { for node in group { occurrences[node] = max(2, occurrences[node, default: 0]) } }
        var corridors: [Corridor] = []
        for way in ways {
            var start = 0
            let closed = way.nodes.first == way.nodes.last
            for index in 1..<way.samples.count where index == way.samples.count - 1
                || occurrences[way.nodes[index], default: 0] > 1 || (closed && index == way.samples.count / 2) {
                let line = Array(way.samples[start...index])
                let corridor = corridors.count
                corridors.append(Corridor(road: way.road, line: line, start: way.nodes[start], end: way.nodes[index]))
                nodes[way.nodes[start]].ends.append((corridor, true))
                nodes[way.nodes[index]].ends.append((corridor, false))
                start = index
            }
        }
        // Mutual endpoint snapping cannot join parallel carriageways, different levels or a nearby crossing.
        var aliases = Array(nodes.indices)
        var gradeConnections: Set<Int> = []
        for group in gradeGroups {
            let canonical = group[0]
            gradeConnections.insert(canonical)
            for node in group.dropFirst() {
                aliases[node] = canonical
                nodes[canonical].ends += nodes[node].ends
                nodes[node].ends = []
            }
        }
        var buckets: [Cell: [Int]] = [:]
        let leaves = nodes.indices.filter { nodes[$0].ends.count == 1 }
        for node in leaves {
            let p = nodes[node].point
            buckets[Cell(x: Int(floor(p.x / 2)), y: Int(floor(p.y / 2))), default: []].append(node)
        }
        var nearest: [Int: Int] = [:]
        var work = 0
        for node in leaves {
            try Task.checkCancellation()
            let end = nodes[node].ends[0], road = corridors[end.corridor].road
            guard !road.roundabout else { continue }
            let p = nodes[node].point, cell = Cell(x: Int(floor(p.x / 2)), y: Int(floor(p.y / 2)))
            var bestDistance = 1.25
            for x in (cell.x - 1)...(cell.x + 1) { for y in (cell.y - 1)...(cell.y + 1) {
                for other in buckets[Cell(x: x, y: y)] ?? [] where other != node && work < 50_000 {
                    work += 1
                    let peer = nodes[other].ends[0], peerRoad = corridors[peer.corridor].road
                    guard peer.corridor != end.corridor, samePlane(road, peerRoad), sameRoad(road, peerRoad),
                          !peerRoad.roundabout else { continue }
                    let delta = nodes[other].point - p, distance = delta.length
                    let a = outward(corridors[end.corridor], atStart: end.atStart)
                    let b = outward(corridors[peer.corridor], atStart: peer.atStart)
                    guard distance < bestDistance, a.dot(b) < -0.94,
                          distance < 0.15 || (a.dot(delta.unit) < -0.8 && b.dot(delta.unit) > 0.8) else { continue }
                    nearest[node] = other; bestDistance = distance
                }
            } }
        }
        for node in leaves {
            guard let other = nearest[node], other > node, nearest[other] == node else { continue }
            aliases[other] = node
            nodes[node].ends += nodes[other].ends
            nodes[other].ends = []
        }
        // Cluster only along short, existing links. Distance alone is never evidence of a junction.
        var groups = Array(nodes.indices)
        var members = nodes.indices.map { [$0] }
        func root(_ index: Int) -> Int { var value = aliases[index]; while groups[value] != value { value = groups[value] }; return value }
        for corridor in corridors {
            let a = root(corridor.start), b = root(corridor.end)
            guard a != b, !corridor.road.roundabout,
                  nodes[aliases[corridor.start]].ends.count >= 3, nodes[aliases[corridor.end]].ends.count >= 3,
                  DetailedRoadGeometry.pathLength(corridor.line.map(\.point)) <= min(12, corridor.road.startWidth * 1.5),
                  members[a].count + members[b].count <= 8 else { continue }
            let combined = members[a] + members[b]
            guard combined.allSatisfy({ i in combined.allSatisfy({ (nodes[i].point - nodes[$0].point).length <= 24 }) }) else { continue }
            groups[b] = a; members[a] = combined; members[b] = []
        }
        var regions: [JunctionRegion] = []
        func appendRegion(_ members: [Int]) -> Bool {
            let memberSet = Set(members)
            var ends: [(corridor: Int, atStart: Bool)] = [], internalCorridors: Set<Int> = []
            for node in members {
                for end in nodes[node].ends {
                    let corridor = corridors[end.corridor]
                    if memberSet.contains(aliases[corridor.start]) && memberSet.contains(aliases[corridor.end]) {
                        internalCorridors.insert(end.corridor)
                    } else { ends.append(end) }
                }
            }
            guard ends.count >= 2, ends.count <= 12 else { return false }
            let roads = ends.map { corridors[$0.corridor].road }
            let gradeTransition = members.count == 1 && gradeConnections.contains(members[0])
            guard gradeTransition || roads.allSatisfy({ samePlane(roads[0], $0) }) else { return false }
            // An explicit two-port connection stays continuous through a change of road class/name.
            let continuous = ends.count == 2
                && outward(corridors[ends[0].corridor], atStart: ends[0].atStart)
                    .dot(outward(corridors[ends[1].corridor], atStart: ends[1].atStart)) < -0.8
            let widthChange = continuous && (abs(roads[0].width(at: ends[0].atStart ? 0 : 1)
                - roads[1].width(at: ends[1].atStart ? 0 : 1)) > 0.5 || roads[0].lanes.count != roads[1].lanes.count)
            let maximumWidth = roads.map { max($0.startWidth, $0.endWidth) }.max() ?? 6
            var ports: [RoadEndProfile] = []
            for end in ends {
                let corridor = corridors[end.corridor]
                let length = DetailedRoadGeometry.pathLength(corridor.line.map(\.point))
                var desired = continuous ? 2.0 : max(5, maximumWidth * 0.8)
                if widthChange { desired = corridor.road.roadClass.hasPrefix("motorway") || corridor.road.roadClass.hasPrefix("trunk") ? 30 : 12 }
                if !continuous {
                    let direction = outward(corridor, atStart: end.atStart)
                    for peer in ends where peer.corridor != end.corridor {
                        let dot = direction.dot(outward(corridors[peer.corridor], atStart: peer.atStart))
                        if dot > 0.3 && dot < 0.985 {
                            let angle = acos(max(-1, min(1, dot)))
                            desired = max(desired, min(35, maximumWidth / (2 * tan(angle / 2))))
                        }
                    }
                }
                let inset = min(desired, length * 0.4)
                guard let port = profile(corridor, index: end.corridor, atStart: end.atStart, inset: inset) else { return false }
                ports.append(port)
            }
            let center = members.reduce(Vector(x: 0, y: 0)) { $0 + nodes[$1].point } * (1 / Double(members.count))
            ports.sort { atan2($0.center.y - center.y, $0.center.x - center.x) < atan2($1.center.y - center.y, $1.center.x - center.x) }
            let surface = boundary(ports, padding: 0)
            let casing = boundary(ports, padding: 0.325)
            let coversApproaches = ports.allSatisfy { port in
                let corridor = corridors[port.corridor]
                let oriented = port.atStart ? corridor.line : Array(corridor.line.reversed())
                let steps = max(2, min(32, Int(ceil(port.inset))))
                return (0...steps).allSatisfy { index in
                    guard let (sample, heading) = DetailedRoadGeometry.arrowAnchor(oriented,
                        distance: port.inset * Double(index) / Double(steps)) else { return false }
                    let center = sample.point + heading.left * ((port.atStart ? 1 : -1) * port.road.centerOffset(at: sample.fraction))
                    return contains(center, in: surface) || (center - port.center).length < 0.05
                }
            }
            let simple = !DetailedRoadGeometry.selfIntersects(surface, closed: true)
                && !DetailedRoadGeometry.selfIntersects(casing, closed: true)
                && coversApproaches
                && internalCorridors.allSatisfy({ corridors[$0].line.allSatisfy { contains($0.point, in: surface) } })
            if !simple {
                // At an acute fork the carriageways may overlap beyond both ports. A simple
                // perimeter is then impossible. Keep their full envelopes and let the surface
                // union resolve the overlap; a small rounded hub joins explicit placements.
                guard members.count == 1 else { return false }
                let patch = CGMutablePath()
                let radius = max(0.5, (ports.map(\.width).min() ?? 3) / 2)
                func disk(_ point: Vector) {
                    patch.addPath(DetailedRoadSurfaceGeometry.path((0..<32).map { index in
                        let angle = Double(index) * 2 * .pi / 32
                        return point + Vector(x: cos(angle), y: sin(angle)) * radius
                    }))
                }
                disk(center)
                for end in ends {
                    guard let profile = profile(corridors[end.corridor], index: end.corridor, atStart: end.atStart, inset: 0) else { continue }
                    let delta = profile.center - center
                    if delta.length > 0.001 {
                        let normal = delta.unit.left * radius
                        patch.addPath(DetailedRoadSurfaceGeometry.path([center + normal, profile.center + normal,
                            profile.center - normal, center - normal]))
                        disk(profile.center)
                    }
                    let fade = profile.road.confidence == .exact ? 7.0 : 12.0
                    // At a very acute fork the two carriageways can overlap far past
                    // the small hub. Their independent lane grids must not coexist there.
                    let clearance = paintClearance(profile, peers: ports)
                    if end.atStart { corridors[end.corridor].startPaintClearance = clearance }
                    else { corridors[end.corridor].endPaintClearance = clearance }
                    if end.atStart { corridors[end.corridor].startFade = fade }
                    else { corridors[end.corridor].endFade = fade }
                }
                guard let polygon = DetailedRoadSurfaceGeometry.polygons(patch).first else { return false }
                let main = gradeTransition ? roads.max { $0.layer < $1.layer } ?? roads[0] : roads[0]
                regions.append(JunctionRegion(road: main, surface: polygon.outer, casing: [],
                    edgeLines: [], separators: [], laneConnectors: [], gore: [], continuation: false,
                    gradeRoads: gradeTransition ? roads : []))
                return true
            }
            let connectors = inferredConnectors(ports, continuation: continuous)
            let separators = continuous ? continuationMarkings(ports, connectors: connectors) : []
            let edges = ports.indices.map { corner(from: ports[$0], to: ports[($0 + 1) % ports.count], padding: -0.2) }
            let main = gradeTransition ? roads.max { $0.layer < $1.layer } ?? roads[0]
                : roads.max { priority($0.roadClass) < priority($1.roadClass) } ?? roads[0]
            regions.append(JunctionRegion(road: main, surface: surface, casing: casing,
                edgeLines: roads.allSatisfy({ $0.marked && $0.confidence != .estimated }) ? edges : [],
                separators: separators, laneConnectors: connectors,
                gore: goreIsland(ports, inside: surface), continuation: continuous,
                gradeRoads: gradeTransition ? roads : []))
            for port in ports {
                let clearance = max(0, paintClearance(port, peers: ports) - (gradeTransition ? 0 : port.inset))
                if port.atStart { corridors[port.corridor].startPaintClearance = clearance }
                else { corridors[port.corridor].endPaintClearance = clearance }
                // Both planes retain their complete approach to the shared endpoint.
                // The small junction patch supplies the visible transition on top.
                if gradeTransition { continue }
                // Paint fades across a few metres; short corridors retain a quiet, unmarked centre.
                let hasLaneTaper = continuous && ports.allSatisfy {
                    !$0.lanes.isEmpty && $0.lanes.count == $0.road.lanes.count
                        && ($0.road.directionality == .oneWayForward || $0.road.directionality == .oneWayBackward)
                        && $0.road.confidence != .estimated && $0.road.marked
                } && abs(ports[0].lanes.count - ports[1].lanes.count) <= 2
                    && ports[0].lanes.allSatisfy(\.outgoing) != ports[1].lanes.allSatisfy(\.outgoing)
                let fade = continuous && (!widthChange || hasLaneTaper) ? 0 : (port.road.confidence == .exact ? 7.0 : 12.0)
                if port.atStart { corridors[port.corridor].startInset = port.inset; corridors[port.corridor].startFade = fade }
                else { corridors[port.corridor].endInset = port.inset; corridors[port.corridor].endFade = fade }
            }
            for index in internalCorridors { corridors[index].removed = true }
            return true
        }
        for node in nodes.indices where groups[node] == node && aliases[node] == node && nodes[node].ends.count > 1 {
            try Task.checkCancellation()
            if !appendRegion(members[node]), members[node].count > 1 {
                for member in members[node] { _ = appendRegion([member]) }
            }
        }
        return Network(corridors: corridors.filter { !$0.removed }, junctions: regions)
    }

    private static func paintClearance(_ port: RoadEndProfile, peers: [RoadEndProfile]) -> Double {
        var clearance = 0.0
        for peer in peers where peer.corridor != port.corridor && samePlane(port.road, peer.road) {
            let dot = max(-1, min(1, port.tangent.dot(peer.tangent)))
            let ownHalf = port.width / 2 + abs(port.road.centerOffset(at: port.anchor.fraction))
            let peerHalf = peer.width / 2 + abs(peer.road.centerOffset(at: peer.anchor.fraction))
            let sine = sqrt(max(0, 1 - dot * dot))
            if sine < 0.01 {
                if dot > 0 { clearance = max(clearance, (ownHalf + peerHalf) / 0.01) }
                continue
            }
            let stripBound = (peerHalf + ownHalf * abs(dot)) / sine
            // A ray ends at the shared node. Obtuse branches cease overlapping
            // once the port's entire cross-section is behind the other ray's cap.
            let capBound = dot < 0 ? ownHalf * sine / -dot : Double.infinity
            clearance = max(clearance, min(stripBound, capBound))
        }
        return clearance
    }

    private static func samePlane(_ a: NormalizedDetailedRoad, _ b: NormalizedDetailedRoad) -> Bool {
        a.layer == b.layer && a.bridge == b.bridge && a.renderLevel == b.renderLevel
    }
    private static func sameRoad(_ a: NormalizedDetailedRoad, _ b: NormalizedDetailedRoad) -> Bool {
        guard a.roadClass == b.roadClass else { return false }
        if let identity = a.identity, let peer = b.identity { return identity == peer }
        return true
    }
    private static func priority(_ roadClass: String) -> Int {
        switch roadClass.replacingOccurrences(of: "_link", with: "") {
        case "motorway": return 7
        case "trunk": return 6
        case "primary": return 5
        case "secondary": return 4
        case "tertiary": return 3
        case "residential", "unclassified": return 2
        default: return 1
        }
    }
    private static func outward(_ corridor: Corridor, atStart: Bool) -> Vector {
        let points = corridor.line
        return atStart ? (points[1].point - points[0].point).unit
            : (points[points.count - 2].point - points[points.count - 1].point).unit
    }
    private static func profile(_ corridor: Corridor, index: Int, atStart: Bool, inset: Double) -> RoadEndProfile? {
        let oriented = atStart ? corridor.line : Array(corridor.line.reversed())
        guard let (anchor, tangent) = DetailedRoadGeometry.arrowAnchor(oriented, distance: inset) else { return nil }
        let road = corridor.road, sign = atStart ? 1.0 : -1.0
        let center = anchor.point + tangent.left * (sign * road.centerOffset(at: anchor.fraction))
        let width = road.width(at: anchor.fraction)
        let indices = atStart ? Array(road.lanes.indices) : Array(road.lanes.indices.reversed())
        let lanes: [LanePort] = indices.compactMap { index in
            let lane = road.lanes[index]
            guard lane.direction == .forward || lane.direction == .backward,
                  lane.width(at: anchor.fraction) >= 2 else { return nil }
            return LanePort(point: anchor.point + tangent.left * (sign * road.laneCenter(index, at: anchor.fraction)),
                outgoing: (lane.direction == .forward) == atStart, turns: lane.turns)
        }
        return RoadEndProfile(corridor: index, atStart: atStart, road: road, anchor: anchor, tangent: tangent,
            width: width, center: center, leftEdge: center + tangent.left * (width / 2),
            rightEdge: center - tangent.left * (width / 2), inset: inset, lanes: lanes)
    }
    private static func bezier(_ a: Vector, _ b: Vector, _ c: Vector, _ d: Vector) -> [Vector] {
        let count = max(8, min(48, Int(ceil(((b - a).length + (c - b).length + (d - c).length) / 1.5))))
        return (0...count).map { index in
            let t = Double(index) / Double(count), s = 1 - t
            return a * (s * s * s) + b * (3 * s * s * t) + c * (3 * s * t * t) + d * (t * t * t)
        }
    }
    private static func corner(from a: RoadEndProfile, to b: RoadEndProfile, padding: Double) -> [Vector] {
        let start = a.leftEdge + a.tangent.left * padding
        let end = b.rightEdge - b.tangent.left * padding
        let distance = (end - start).length
        var handle = min(40, distance * 0.38)
        let denominator = a.tangent.cross(b.tangent)
        if abs(denominator) > 0.05 {
            let delta = end - start
            let alongA = delta.cross(b.tangent) / -denominator
            let alongB = a.tangent.cross(delta) / denominator
            if alongA > 0 && alongB > 0 { handle = min(handle, min(alongA, alongB) * 0.65) }
        }
        return bezier(start, start - a.tangent * handle, end - b.tangent * handle, end)
    }
    private static func boundary(_ ports: [RoadEndProfile], padding: Double) -> [Vector] {
        var points: [Vector] = []
        for index in ports.indices {
            let port = ports[index]
            points.append(port.rightEdge - port.tangent.left * padding)
            points += corner(from: port, to: ports[(index + 1) % ports.count], padding: padding)
        }
        if let first = points.first { points.append(first) }
        return points
    }

    private static func inferredConnectors(_ ports: [RoadEndProfile], continuation: Bool) -> [LaneConnector] {
        var result: [LaneConnector] = []
        for source in ports.indices {
            let incoming = ports[source].lanes.indices.filter { !ports[source].lanes[$0].outgoing }
            guard ports[source].road.marked, ports[source].road.confidence != .estimated else { continue }
            for target in ports.indices where target != source {
                let exit = ports[target]
                guard exit.road.marked, exit.road.confidence != .estimated else { continue }
                let outgoing = exit.lanes.indices.filter { exit.lanes[$0].outgoing }
                guard !incoming.isEmpty, !outgoing.isEmpty else { continue }
                let heading = ports[source].tangent * -1
                let angle = atan2(heading.cross(exit.tangent), heading.dot(exit.tangent))
                // Unknown urban turns stay unpainted. A shallow fork can use the outer lane.
                guard continuation || abs(angle) < .pi / 3 else { continue }
                let orderedIncoming = Array(incoming.reversed())
                for (ordinal, laneIndex) in orderedIncoming.enumerated() {
                    let lane = ports[source].lanes[laneIndex]
                    if !lane.turns.isEmpty {
                        let permitted = lane.turns.contains { turn in
                            if abs(angle) < 0.3 { return turn == "through" || turn.hasPrefix("merge_to_") }
                            return angle > 0 ? turn.contains("left") : turn.contains("right")
                        }
                        if !permitted { continue }
                    }
                    if !continuation && abs(angle) > 0.3 && ordinal != (angle > 0 ? 0 : orderedIncoming.count - 1) { continue }
                    let destination = outgoing[min(ordinal, outgoing.count - 1)]
                    let a = lane.point, d = exit.lanes[destination].point
                    let handle = min(40, (d - a).length * 0.38)
                    result.append(LaneConnector(points: bezier(a, a - ports[source].tangent * handle,
                        d - exit.tangent * handle, d), sourcePort: source, targetPort: target,
                        sourceLane: laneIndex, targetLane: destination))
                }
            }
        }
        return result
    }
    private static func continuationMarkings(_ ports: [RoadEndProfile], connectors: [LaneConnector]) -> [Marking] {
        guard ports.count == 2, ports.allSatisfy({ $0.road.marked && $0.road.confidence != .estimated }),
              ports[0].lanes.count == ports[0].road.lanes.count,
              ports[1].lanes.count == ports[1].road.lanes.count else { return [] }
        let a = ports[0], b = ports[1]
        guard !connectors.isEmpty else { return [] }
        if a.lanes.count != b.lanes.count {
            return taperMarkings(ports, connectors: connectors)
        }
        var markings: [Marking] = []
        for index in 1..<a.lanes.count {
            let peer = b.lanes.count - index
            guard a.lanes[index - 1].outgoing != b.lanes[peer].outgoing,
                  a.lanes[index].outgoing != b.lanes[peer - 1].outgoing else { continue }
            // Both adjacent lanes need a coherent, order-preserving connector.
            let connected = [index - 1, index].allSatisfy { lane in
                connectors.contains { ($0.sourcePort == 0 && $0.sourceLane == lane && $0.targetLane == b.lanes.count - lane - 1)
                    || ($0.targetPort == 0 && $0.targetLane == lane && $0.sourceLane == b.lanes.count - lane - 1) }
            }
            guard connected else { continue }
            let start = boundaryPoint(a, after: index), end = boundaryPoint(b, after: peer)
            let handle = min(40, (end - start).length * 0.38)
            let points = bezier(start, start - a.tangent * handle, end - b.tangent * handle, end)
            let kind: DetailedRoadGraphic.Kind = a.lanes[index - 1].outgoing == a.lanes[index].outgoing ? .separator : .center
            if !DetailedRoadGeometry.selfIntersects(points, closed: false) { markings.append(Marking(kind: kind, points: points)) }
        }
        return markings
    }
    private static func boundaryPoint(_ port: RoadEndProfile, after index: Int) -> Vector {
        let originalIndex = port.atStart ? index : port.road.lanes.count - index
        let sign = port.atStart ? 1.0 : -1.0
        return port.anchor.point + port.tangent.left * (sign * port.road.boundaryOffset(after: originalIndex, at: port.anchor.fraction))
    }
    private static func taperMarkings(_ ports: [RoadEndProfile], connectors: [LaneConnector]) -> [Marking] {
        guard let entryIndex = ports.indices.first(where: { !ports[$0].lanes.isEmpty && ports[$0].lanes.allSatisfy({ !$0.outgoing }) }),
              let exitIndex = ports.indices.first(where: { !ports[$0].lanes.isEmpty && ports[$0].lanes.allSatisfy(\.outgoing) }),
              entryIndex != exitIndex else { return [] }
        let entry = ports[entryIndex], exit = ports[exitIndex]
        let incoming = entry.lanes.count, outgoing = exit.lanes.count
        guard abs(incoming - outgoing) <= 2,
              connectors.contains(where: { $0.sourcePort == entryIndex && $0.targetPort == exitIndex }) else { return [] }
        var result: [Marking] = []
        for index in 1..<max(incoming, outgoing) {
            // Keep the lateral order. Extra right lanes converge on the outer carriageway edge.
            let start = index < incoming ? boundaryPoint(entry, after: incoming - index) : entry.leftEdge
            let end = index < outgoing ? boundaryPoint(exit, after: index) : exit.rightEdge
            let handle = min(40, (end - start).length * 0.38)
            let points = bezier(start, start - entry.tangent * handle, end - exit.tangent * handle, end)
            guard !DetailedRoadGeometry.selfIntersects(points, closed: false) else { continue }
            if index < min(incoming, outgoing) {
                result.append(Marking(kind: .separator, points: points))
            } else {
                for band in 0..<4 {
                    let from = band * (points.count - 1) / 4, to = (band + 1) * (points.count - 1) / 4
                    let t = (Double(band) + 0.5) / 4
                    let alpha = incoming > outgoing ? 1 - t : t
                    result.append(Marking(kind: .separator, points: Array(points[from...to]),
                        opacity: alpha * alpha * (3 - 2 * alpha)))
                }
            }
        }
        return result
    }
    private static func goreIsland(_ ports: [RoadEndProfile], inside surface: [Vector]) -> [Vector] {
        guard ports.count == 3, ports.allSatisfy({ $0.road.confidence == .exact && $0.road.marked }),
              ports.allSatisfy({ $0.road.directionality == .oneWayForward || $0.road.directionality == .oneWayBackward }) else { return [] }
        let exits = ports.filter { !$0.lanes.isEmpty && $0.lanes.allSatisfy(\.outgoing) }
        guard exits.count == 2 else { return [] }
        let a = exits[0], b = exits[1], angle = acos(max(-1, min(1, a.tangent.dot(b.tangent))))
        guard angle > 0.25 && angle < 1.1 else { return [] }
        let direction = (a.tangent + b.tangent).unit
        let origin = (a.anchor.point - a.tangent * a.inset + b.anchor.point - b.tangent * b.inset) * 0.5
        let reach = min(a.inset, b.inset)
        let center = origin + direction * (reach * 0.5)
        let halfWidth = min(1.2, reach * sin(angle / 2) * 0.18)
        guard halfWidth > 0.35 else { return [] }
        // A small painted neutral zone, never a claim of a surveyed raised island.
        let nose = center - direction * min(3, reach * 0.2)
        let left = center + direction.left * halfWidth, right = center - direction.left * halfWidth
        let polygon = bezier(nose, nose + direction * 0.8, left - direction * 0.5, left)
            + bezier(left, left + direction * 0.5, right + direction * 0.5, right)
            + bezier(right, right - direction * 0.5, nose + direction * 0.8, nose)
        guard polygon.allSatisfy({ contains($0, in: surface) }), !DetailedRoadGeometry.selfIntersects(polygon, closed: true) else { return [] }
        return polygon
    }
    private static func contains(_ point: Vector, in polygon: [Vector]) -> Bool {
        var inside = false
        guard polygon.count > 3 else { return false }
        for index in 1..<polygon.count {
            let a = polygon[index - 1], b = polygon[index]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
}
#endif
