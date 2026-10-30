import Foundation
import MapKit

nonisolated struct TripTracePoint: Codable, Sendable {
    let coordinate: Coordinate
    let timestamp: Date
    let speedKph: Double?
    let startsSegment: Bool
}

/// Records only accepted GPS fixes; gaps never become invented connecting lines.
struct TripTraceRecorder {
    private(set) var points: [TripTracePoint] = []
    private(set) var maximumSpeedKph: Double?
    private var previous: NavigationLocation?
    private var needsSegment = true
    private var latestPoint: TripTracePoint?

    mutating func record(_ location: NavigationLocation) {
        guard location.accuracy.isFinite, (0...50).contains(location.accuracy),
              location.coordinate.latitude.isFinite, location.coordinate.longitude.isFinite,
              abs(location.coordinate.latitude) <= 90, abs(location.coordinate.longitude) <= 180 else {
            needsSegment = true
            return
        }
        if let previous {
            let interval = location.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0 else { return }
            let displacement = previous.coordinate.distance(to: location.coordinate)
            if interval > 30 || displacement > max(30, interval * 100) {
                needsSegment = true
            }
        }
        previous = location
        let speed: Double? = location.speed.isFinite && (0...100).contains(location.speed)
            && location.speedAccuracy >= 0 && location.speedAccuracy <= 5
            ? location.speed * 3.6 : nil
        if let speed { maximumSpeedKph = max(maximumSpeedKph ?? 0, speed) }
        latestPoint = TripTracePoint(coordinate: location.coordinate, timestamp: location.timestamp,
                                     speedKph: speed, startsSegment: needsSegment)
        if let last = points.last, !needsSegment,
           location.timestamp.timeIntervalSince(last.timestamp) < 10,
           (location.timestamp.timeIntervalSince(last.timestamp) < 3 ||
            last.coordinate.distance(to: location.coordinate) < 8) { return }
        if let latestPoint { append(latestPoint) }
        needsSegment = false
    }

    /// Keep the last reliable fix even when the normal sampling interval has not elapsed.
    mutating func finalize() {
        guard let latestPoint,
              points.last.map({ $0.timestamp < latestPoint.timestamp }) ?? true else { return }
        append(latestPoint)
    }

    private mutating func append(_ point: TripTracePoint) {
        points.append(point)
        if points.count > 12_000 {
            points = points.enumerated().compactMap { index, point in
                index == 0 || index == points.count - 1 || index.isMultiple(of: 2)
                    || point.startsSegment || (index + 1 < points.count && points[index + 1].startsSegment)
                    ? point : nil
            }
            if points.count > 12_000 {
                points = Array(points.suffix(12_000))
                if let first = points.first {
                    points[0] = TripTracePoint(coordinate: first.coordinate, timestamp: first.timestamp,
                        speedKph: first.speedKph, startsSegment: true)
                }
            }
        }
    }
}

struct TripTraceSegment: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
}

extension TripRecord {
    var traceSegments: [TripTraceSegment] {
        var segments: [[CLLocationCoordinate2D]] = []
        for point in trace {
            if point.startsSegment || segments.isEmpty { segments.append([]) }
            segments[segments.count - 1].append(point.coordinate.cl)
        }
        return segments.enumerated().map { TripTraceSegment(id: $0.offset, coordinates: $0.element) }
    }

    func tracePoint(at elapsed: TimeInterval) -> TripTracePoint? {
        // Compatibility for one-off consumers. Playback views keep a prepared
        // TripPlaybackTimeline so validation and sorting happen only once.
        guard let position = TripPlaybackTimeline(trip: self).position(at: elapsed) else { return nil }
        return TripTracePoint(coordinate: position.coordinate,
            timestamp: position.kind == .interpolated ? position.timelineDate : position.measurementDate,
            speedKph: position.speedKph,
            startsSegment: position.kind == .gap || position.kind == .beforeFirstFix || position.kind == .afterLastFix)
    }
}

nonisolated struct TripHeatCell: Identifiable, Sendable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let visits: Int
}

nonisolated enum TripHeatmap {
    /// One visit per trip per cell prevents waiting or GPS frequency from inflating intensity.
    static func cells(for traces: [[TripTracePoint]]) -> [TripHeatCell] {
        let earthRadius = 6_378_137.0
        var cellSize = 250.0 // Web Mercator meters; physical radius is corrected for latitude.
        var visits: [String: (x: Int, y: Int, count: Int)] = [:]
        // Coarsen the grid for large archives instead of creating tens of thousands of overlays.
        // Recount distinct trips at each resolution, so merging cells never duplicates visits.
        repeat {
            guard !Task.isCancelled else { return [] }
            visits.removeAll(keepingCapacity: true)
            for trace in traces {
                guard !Task.isCancelled else { return [] }
                var visited = Set<String>()
                for (index, point) in trace.enumerated() {
                    if index.isMultiple(of: 256), Task.isCancelled { return [] }
                    guard point.coordinate.latitude.isFinite, point.coordinate.longitude.isFinite,
                          abs(point.coordinate.latitude) <= 90, abs(point.coordinate.longitude) <= 180 else { continue }
                    guard point.coordinate.latitude.isFinite, point.coordinate.longitude.isFinite,
                          abs(point.coordinate.latitude) <= 90,
                          abs(point.coordinate.longitude) <= 180 else { continue }
                    let latitude = max(-85, min(85, point.coordinate.latitude)) * .pi / 180
                    let x = Int(floor(earthRadius * point.coordinate.longitude * .pi / 180 / cellSize))
                    let y = Int(floor(earthRadius * log(tan(.pi / 4 + latitude / 2)) / cellSize))
                    let key = "\(x):\(y)"
                    guard visited.insert(key).inserted else { continue }
                    visits[key] = (x, y, (visits[key]?.count ?? 0) + 1)
                }
            }
            if visits.count <= 1_000 { break }
            cellSize *= 2
        } while true
        return visits.map { key, value in
            let latitude = (2 * atan(exp((Double(value.y) + 0.5) * cellSize / earthRadius)) - .pi / 2)
            return TripHeatCell(id: key,
                               coordinate: CLLocationCoordinate2D(latitude: latitude * 180 / .pi,
                                   longitude: (Double(value.x) + 0.5) * cellSize / earthRadius * 180 / .pi),
                               radius: cellSize * cos(latitude) * 0.75, visits: value.count)
        }.sorted { $0.id < $1.id }
    }
}

enum TripHistoryFormat {
    static let locale = Locale(identifier: "pl_PL")

    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func journeys(_ count: Int) -> String {
        let lastDigit = count % 10
        let lastTwoDigits = count % 100
        let noun = count == 1 ? "podróż"
            : ((2...4).contains(lastDigit) && !(12...14).contains(lastTwoDigits) ? "podróże" : "podróży")
        return "\(count) \(noun)"
    }

    static func distance(_ meters: Double) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(1)).locale(locale)) + " km"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds / 3600) godz. \((seconds % 3600) / 60) min"
    }
}
