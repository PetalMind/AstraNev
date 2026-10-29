import Foundation

/// Local observations, not road identifiers or navigable routes. Valhalla must
/// recalculate every suggested variant with the current access restrictions.
nonisolated enum DrivingTraceLearning {
    static func segments(trace: [TripTracePoint]) throws -> [LearnedRoadSegment] {
        guard trace.count >= 10, let first = trace.first, let last = trace.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= 60,
              trace.allSatisfy({ $0.coordinate.isValidValhallaCoordinate }),
              !trace.dropFirst().contains(where: \.startsSegment) else {
            throw DrivingLearningFailure.incompleteTrace
        }
        for (left, right) in zip(trace, trace.dropFirst()) {
            let elapsed = right.timestamp.timeIntervalSince(left.timestamp)
            guard elapsed > 0, elapsed <= 30,
                  left.coordinate.distance(to: right.coordinate) <= max(30, elapsed * 60) else {
                throw DrivingLearningFailure.incompleteTrace
            }
        }
        let result = segments(coordinates: trace.map(\.coordinate))
        guard result.reduce(0, { $0 + $1.length }) >= 500 else {
            throw DrivingLearningFailure.incompleteTrace
        }
        return result
    }

    static func segments(coordinates: [Coordinate]) -> [LearnedRoadSegment] {
        guard coordinates.count > 1, coordinates.allSatisfy(\.isValidValhallaCoordinate) else { return [] }
        let geometry = RouteProgressGeometry(coordinates: coordinates)
        guard geometry.length.isFinite, geometry.length > 0 else { return [] }
        let step = max(100, geometry.length / 500)
        var result: [LearnedRoadSegment] = []
        var start = 0.0
        while start < geometry.length {
            let end = min(geometry.length, start + step)
            let points = geometry.corridor(from: start, through: end)
            if let first = points.first, let last = points.last, points.count > 1 {
                result.append(LearnedRoadSegment(id: "trace:\(cell(first)):\(cell(last))",
                    coordinates: points, length: end - start, names: []))
            }
            start = end
        }
        return result
    }

    /// Require a sustained separation and a later rejoin in the forward direction.
    /// A parallel street within GPS uncertainty, a stop or a loop is weak evidence.
    static func deviations(actual: [LearnedRoadSegment], proposed: [LearnedRoadSegment],
                           trace: [TripTracePoint]) -> [DrivingDeviation] {
        guard !actual.isEmpty, !proposed.isEmpty, trace.count >= 10 else { return [] }
        let baseline = RouteProgressGeometry(coordinates: proposed.flatMap(\.coordinates))
        let observed = RouteProgressGeometry(coordinates: trace.map(\.coordinate))
        var anchor: (index: Int, along: Double)?
        var separatedLength = 0.0
        var previousFar = false
        var result: [DrivingDeviation] = []
        for index in trace.indices {
            let point = trace[index]
            let projection = baseline.project(point.coordinate, within: 75)
            let far = projection == nil || projection!.distanceFromRoute >= 60
            if index > 0, far && previousFar {
                separatedLength += trace[index - 1].coordinate.distance(to: point.coordinate)
            }
            previousFar = far
            guard let projection, projection.distanceFromRoute <= 35 else { continue }
            defer { anchor = (index, projection.alongRoute); separatedLength = 0 }
            guard let anchor, index > anchor.index + 1, separatedLength >= 500,
                  projection.alongRoute >= anchor.along + 200 else { continue }
            let entry = trace[anchor.index].coordinate, exit = point.coordinate
            let length = observed.cumulativeDistances[index] - observed.cumulativeDistances[anchor.index]
            guard entry.distance(to: exit) >= 200, length <= entry.distance(to: exit) * 4 else { continue }
            var stopped = 0.0
            for position in (anchor.index + 1)...index {
                let left = trace[position - 1], right = trace[position]
                let dt = right.timestamp.timeIntervalSince(left.timestamp)
                if (left.speedKph.map { $0 < 3 } ?? false) || left.coordinate.distance(to: right.coordinate) / dt < 0.8 {
                    stopped += dt
                }
            }
            guard stopped < 60 else { continue }
            let preferred = segments(coordinates: observed.corridor(
                from: observed.cumulativeDistances[anchor.index], through: observed.cumulativeDistances[index]))
            let avoided = segments(coordinates: baseline.corridor(from: anchor.along, through: projection.alongRoute))
            guard !preferred.isEmpty, !avoided.isEmpty else { continue }
            let path = RouteProgressGeometry(coordinates: preferred.flatMap(\.coordinates))
            let fingerprint = [0.25, 0.5, 0.75].compactMap { path.coordinate(at: path.length * $0) }
                .map { cell($0, scale: 1_000) }.joined(separator: "/")
            result.append(DrivingDeviation(id: "local:\(cell(entry, scale: 1_000))→\(cell(exit, scale: 1_000))|\(fingerprint)",
                entry: entry, exit: exit, preferred: preferred, avoided: avoided,
                elapsed: point.timestamp.timeIntervalSince(trace[anchor.index].timestamp)))
        }
        return result
    }

    private static func cell(_ point: Coordinate, scale: Double = 10_000) -> String {
        "\(Int((point.latitude * scale).rounded())):\(Int((point.longitude * scale).rounded()))"
    }
}
