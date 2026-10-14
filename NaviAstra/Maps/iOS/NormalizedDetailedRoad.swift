#if os(iOS)
import Foundation

nonisolated enum RoadDirectionality: String, Sendable {
    case twoWay, oneWayForward, oneWayBackward, reversible, unknown
}
nonisolated enum RoadGeometryConfidence: String, Sendable {
    /// Complete dimensional attributes, not a claim of survey-grade geometry.
    case exact, derived, estimated, invalid
}
nonisolated enum RoadLaneDirection: String, Sendable { case forward, backward, bothWays, unknown }
nonisolated enum RoadRenderLevel: String, Sendable { case underground, ground, elevated }

nonisolated struct NormalizedDetailedRoad: Sendable {
    struct Lane: Sendable {
        let direction: RoadLaneDirection
        let ordinal: Int
        var startWidth: Double
        var endWidth: Double
        var turns: [String]
        func width(at fraction: Double) -> Double { startWidth + (endWidth - startWidth) * fraction }
    }
    let id: Int64
    let points: [DetailedRoad.Point]
    let roadClass: String
    let directionality: RoadDirectionality
    let confidence: RoadGeometryConfidence
    let renderLevel: RoadRenderLevel
    let layer: Int
    let bridge: Bool
    let covered: Bool
    let marked: Bool
    /// Physical order from left to right when looking along the OSM geometry.
    let lanes: [Lane]
    let startWidth: Double
    let endWidth: Double
    let startCenterOffset: Double
    let endCenterOffset: Double

    func width(at fraction: Double) -> Double { startWidth + (endWidth - startWidth) * fraction }
    func centerOffset(at fraction: Double) -> Double {
        startCenterOffset + (endCenterOffset - startCenterOffset) * fraction
    }
    func boundaryOffset(after lane: Int, at fraction: Double) -> Double {
        lanes.reduce(0) { $0 + $1.width(at: fraction) } / 2
            - lanes.prefix(lane).reduce(0) { $0 + $1.width(at: fraction) } + centerOffset(at: fraction)
    }
    func laneCenter(_ lane: Int, at fraction: Double) -> Double {
        boundaryOffset(after: lane, at: fraction) - lanes[lane].width(at: fraction) / 2
    }
}

/// Strict normalization is shared by the Overpass path and the future tile-generation contract.
nonisolated enum DetailedRoadNormalizer {
    private enum Invalid: Error { case attributes }
    private static let supportedTurns: Set<String> = [
        "left", "slight_left", "sharp_left", "through", "right", "slight_right", "sharp_right",
        "reverse", "merge_to_left", "merge_to_right"
    ]

    static func normalize(_ road: DetailedRoad) -> NormalizedDetailedRoad? {
        try? make(road)
    }

    private static func make(_ road: DetailedRoad) throws -> NormalizedDetailedRoad {
        let tags = road.tags
        guard road.points.count >= 2 else { throw Invalid.attributes }
        let roadClass = tags["highway"] ?? ""
        let directionality: RoadDirectionality
        if tags["oneway:conditional"] != nil { directionality = .reversible }
        else {
            switch tags["oneway"] {
            case "yes", "1", "true": directionality = .oneWayForward
            case "-1": directionality = .oneWayBackward
            case "no", "0", "false": directionality = .twoWay
            case "reversible", "alternating": directionality = .reversible
            case nil:
                directionality = roadClass == "motorway" || tags["junction"] == "roundabout" ? .oneWayForward : .twoWay
            default: directionality = .unknown
            }
        }
        func count(_ key: String) throws -> Int? {
            guard let raw = tags[key] else { return nil }
            guard let value = Int(raw), (0...12).contains(value) else { throw Invalid.attributes }
            return value
        }
        let declaredTotal = try count("lanes")
        let forward = try count("lanes:forward"), backward = try count("lanes:backward")
        let shared = try count("lanes:both_ways") ?? 0
        if declaredTotal == 0 { throw Invalid.attributes }
        var total = declaredTotal
        if let forward, let backward {
            let sum = forward + backward + shared
            guard sum > 0, sum <= 12, total == nil || total == sum else { throw Invalid.attributes }
            total = sum
        } else if let total {
            guard (forward ?? 0) + (backward ?? 0) + shared <= total else { throw Invalid.attributes }
        }
        switch directionality {
        case .oneWayForward:
            guard (backward ?? 0) == 0, shared == 0,
                  total == nil || forward == nil || total == forward else { throw Invalid.attributes }
            total = total ?? forward
        case .oneWayBackward:
            guard (forward ?? 0) == 0, shared == 0,
                  total == nil || backward == nil || total == backward else { throw Invalid.attributes }
            total = total ?? backward
        default: break
        }
        let laneWidth = roadClass.hasPrefix("motorway") || roadClass.hasPrefix("trunk") ? 3.5 : 3.1
        var lanes: [NormalizedDetailedRoad.Lane] = []
        func group(_ count: Int, _ direction: RoadLaneDirection) -> [NormalizedDetailedRoad.Lane] {
            (0..<count).map { .init(direction: direction, ordinal: $0 + 1,
                                  startWidth: laneWidth, endWidth: laneWidth, turns: []) }
        }
        if let total {
            switch directionality {
            case .oneWayForward: lanes = group(total, .forward)
            case .oneWayBackward: lanes = group(total, .backward).reversed()
            case .twoWay:
                if let forward, let backward {
                    let f = group(forward, .forward), b = Array(group(backward, .backward).reversed())
                    let s = group(shared, .bothWays)
                    lanes = tags["driving_side"] == "left" ? f + s + b : b + s + f
                } else { lanes = group(total, .unknown) }
            case .reversible, .unknown: lanes = group(total, .unknown)
            }
        }
        let completeDirections = !lanes.isEmpty && lanes.allSatisfy { $0.direction != .unknown }
        let uncertainExtras = tags.contains { key, value in
            (key.hasPrefix("cycleway") && (value.contains("lane") || value.contains("shared")))
                || key.hasPrefix("parking:") || (key.hasPrefix("shoulder") && value != "no")
        }

        // Per-lane widths retain physical ordering and may taper to zero at a way endpoint.
        var explicitWidths = true
        for endpoint in ["start", "end"] {
            let generic = try widths(tags["width:lanes:\(endpoint)"] ?? tags["width:lanes"], count: lanes.count, taper: true)
            if generic != nil && (tags.keys.contains { $0.hasPrefix("width:lanes:forward") || $0.hasPrefix("width:lanes:backward") || $0.hasPrefix("width:lanes:both_ways") }) {
                throw Invalid.attributes // Competing definitions are not silently repaired.
            }
            for index in lanes.indices {
                let lane = lanes[index]
                let suffix: String?
                switch lane.direction {
                case .forward: suffix = "forward"
                case .backward: suffix = "backward"
                case .bothWays: suffix = "both_ways"
                case .unknown: suffix = nil
                }
                var value: Double?
                if let generic {
                    // Unsuffixed lane attributes on a reverse one-way are ordered in the travel direction.
                    let ordinal = directionality == .oneWayBackward ? lanes.count - index - 1 : index
                    value = generic[ordinal]
                } else if let suffix {
                    let groupCount = lanes.filter { $0.direction == lane.direction }.count
                    let raw = tags["width:lanes:\(suffix):\(endpoint)"] ?? tags["width:lanes:\(suffix)"]
                    value = try widths(raw, count: groupCount, taper: true)?[lane.ordinal - 1]
                }
                if let value {
                    if endpoint == "start" { lanes[index].startWidth = value }
                    else { lanes[index].endWidth = value }
                } else { explicitWidths = false }
            }
        }
        for lane in lanes where lane.startWidth == 0 && lane.endWidth == 0 { _ = lane; throw Invalid.attributes }
        let measuredWidth = try dimension(tags["width"], range: 2...60)
        let estimatedWidth: Double
        switch roadClass {
        case "motorway": estimatedWidth = 7.4
        case "trunk": estimatedWidth = 7.1
        case "primary", "secondary": estimatedWidth = 6.5
        case "tertiary", "unclassified": estimatedWidth = 5.5
        case "residential", "living_street": estimatedWidth = 5
        default: estimatedWidth = 3.5
        }
        var confidence: RoadGeometryConfidence = lanes.isEmpty ? .estimated : .derived
        if !explicitWidths, let measuredWidth, completeDirections, !uncertainExtras,
           measuredWidth / Double(lanes.count) >= 2.2, measuredWidth / Double(lanes.count) <= 4.5,
           !tags.keys.contains(where: { $0.hasPrefix("width:lanes") }) {
            for index in lanes.indices {
                lanes[index].startWidth = measuredWidth / Double(lanes.count)
                lanes[index].endWidth = measuredWidth / Double(lanes.count)
            }
            explicitWidths = true
        }
        var startWidth = measuredWidth ?? (lanes.isEmpty ? estimatedWidth : lanes.reduce(0) { $0 + $1.startWidth } + (explicitWidths ? 0 : 0.4))
        var endWidth = measuredWidth ?? (lanes.isEmpty ? estimatedWidth : lanes.reduce(0) { $0 + $1.endWidth } + (explicitWidths ? 0 : 0.4))
        if explicitWidths, !lanes.isEmpty {
            guard startWidth + 0.05 >= lanes.reduce(0, { $0 + $1.startWidth }),
                  endWidth + 0.05 >= lanes.reduce(0, { $0 + $1.endWidth }) else { throw Invalid.attributes }
        } else if lanes.reduce(0, { $0 + $1.startWidth }) > startWidth + 0.05
                    || lanes.reduce(0, { $0 + $1.endWidth }) > endWidth + 0.05 {
            // A measured carriageway narrower than the heuristic lane stack cannot be divided reliably.
            lanes = []
            confidence = .estimated
        }
        if lanes.isEmpty { startWidth = measuredWidth ?? estimatedWidth; endWidth = startWidth }
        guard startWidth > 0, endWidth > 0, startWidth <= 60, endWidth <= 60 else { throw Invalid.attributes }
        if explicitWidths, completeDirections, !uncertainExtras { confidence = .exact }
        if directionality == .reversible || directionality == .unknown || tags["lanes:conditional"] != nil {
            confidence = .estimated
        }
        // A bad turn string removes arrows for the complete directional group, never just its bad token.
        for direction in [RoadLaneDirection.forward, .backward, .bothWays] {
            let indices = lanes.indices.filter { lanes[$0].direction == direction }
            guard !indices.isEmpty else { continue }
            let suffix = direction == .bothWays ? "both_ways" : direction.rawValue
            let specific = tags["turn:lanes:\(suffix)"]
            let oneWay = directionality == .oneWayForward || directionality == .oneWayBackward
            let generic = oneWay ? tags["turn:lanes"] : nil
            guard generic == nil || specific == nil || generic == specific,
                  let turns = turns(specific ?? generic, count: indices.count) else { continue }
            for index in indices { lanes[index].turns = turns[lanes[index].ordinal - 1] }
        }

        let placement = try placementOffsets(tags, lanes: lanes, directionality: directionality)
        let tunnel = tags["tunnel"].map { !["no", "0", "false"].contains($0) } ?? false
        let underground = tunnel || tags["location"] == "underground"
        let bridge = tags["bridge"].map { !["no", "0", "false"].contains($0) } ?? false
        let covered = tags["covered"].map { !["no", "0", "false"].contains($0) } ?? false
        let layer: Int
        if let raw = tags["layer"] {
            guard let value = Int(raw), (-3...5).contains(value) else { throw Invalid.attributes }
            layer = value
        } else { layer = bridge ? 1 : (underground ? -1 : 0) }
        // Layer controls order; it never implies a bridge or tunnel by itself.
        let renderLevel: RoadRenderLevel = underground ? .underground : (bridge ? .elevated : .ground)
        return NormalizedDetailedRoad(id: road.id, points: road.points, roadClass: roadClass,
            directionality: directionality, confidence: confidence, renderLevel: renderLevel,
            layer: layer, bridge: bridge, covered: covered, marked: tags["lane_markings"] != "no",
            lanes: lanes, startWidth: startWidth, endWidth: endWidth,
            startCenterOffset: placement.0, endCenterOffset: placement.1)
    }

    private static func dimension(_ raw: String?, range: ClosedRange<Double>) throws -> Double? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let factor: Double
        if text.hasSuffix(" ft") { factor = 0.3048; text = String(text.dropLast(3)) }
        else { factor = 1; if text.hasSuffix(" m") { text = String(text.dropLast(2)) } }
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite,
              range.contains(number * factor) else { throw Invalid.attributes }
        return number * factor
    }
    private static func widths(_ raw: String?, count: Int, taper: Bool) throws -> [Double?]? {
        guard let raw else { return nil }
        let fields = raw.components(separatedBy: "|")
        guard count > 0, fields.count == count else { throw Invalid.attributes }
        return try fields.map { $0.isEmpty ? nil : try dimension($0, range: (taper ? 0 : 1.5)...6) }
    }
    private static func turns(_ raw: String?, count: Int) -> [[String]]? {
        guard let raw else { return nil }
        let fields = raw.components(separatedBy: "|")
        guard fields.count == count else { return nil }
        var result: [[String]] = []
        for field in fields {
            if field.isEmpty || field == "none" { result.append([]); continue }
            let values = field.components(separatedBy: ";")
            guard values.allSatisfy({ supportedTurns.contains($0) }), Set(values).count == values.count else { return nil }
            result.append(values.sorted())
        }
        return result
    }

    private static func placementOffsets(_ tags: [String: String], lanes: [NormalizedDetailedRoad.Lane],
                                         directionality: RoadDirectionality) throws -> (Double, Double) {
        let keys = ["placement", "placement:forward", "placement:backward"]
        var offsets: [Double] = []
        for endpoint in ["start", "end"] {
            var candidates: [Double] = []
            let widths = lanes.map { endpoint == "start" ? $0.startWidth : $0.endWidth }
            for key in keys {
                let raw = tags["\(key):\(endpoint)"] ?? tags[key]
                guard let raw else { continue }
                if raw == "transition" { throw Invalid.attributes } // No safe neighbor topology is available yet.
                if raw == "center" { candidates.append(0); continue }
                let parts = raw.components(separatedBy: ":")
                guard parts.count == 2, let number = Int(parts[1]), number >= 1,
                      ["middle_of", "left_of", "right_of"].contains(parts[0]) else { throw Invalid.attributes }
                let index: Int
                let sign: Double
                if key == "placement" {
                    guard directionality == .oneWayForward || directionality == .oneWayBackward,
                          number <= lanes.count else { throw Invalid.attributes }
                    index = number - 1 // Generic placement numbers lanes along the OSM way, also for oneway=-1.
                    sign = 1
                } else {
                    let direction: RoadLaneDirection = key.hasSuffix("backward") ? .backward : .forward
                    guard let found = lanes.indices.first(where: { lanes[$0].direction == direction && lanes[$0].ordinal == number }) else {
                        throw Invalid.attributes
                    }
                    index = found; sign = direction == .backward ? -1 : 1
                }
                var offset = widths.reduce(0, +) / 2 - widths.prefix(index).reduce(0, +) - widths[index] / 2
                if parts[0] == "left_of" { offset += sign * widths[index] / 2 }
                if parts[0] == "right_of" { offset -= sign * widths[index] / 2 }
                candidates.append(-offset)
            }
            if let first = candidates.first {
                guard candidates.allSatisfy({ abs($0 - first) < 0.1 }) else { throw Invalid.attributes }
                offsets.append(first)
            } else { offsets.append(0) }
        }
        return (offsets[0], offsets[1])
    }
}
#endif
