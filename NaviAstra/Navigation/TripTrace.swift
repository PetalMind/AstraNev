import Foundation
import MapKit

struct TripTracePoint: Codable {
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
        if let last = points.last, !needsSegment,
           location.timestamp.timeIntervalSince(last.timestamp) < 10,
           (location.timestamp.timeIntervalSince(last.timestamp) < 3 ||
            last.coordinate.distance(to: location.coordinate) < 8) { return }
        points.append(TripTracePoint(coordinate: location.coordinate, timestamp: location.timestamp,
                                    speedKph: speed, startsSegment: needsSegment))
        needsSegment = false
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
        let date = startedAt.addingTimeInterval(elapsed)
        // Binary search keeps scrubbing and playback inexpensive on long trips.
        var low = 0
        var high = trace.count
        while low < high {
            let mid = (low + high) / 2
            if trace[mid].timestamp <= date { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let left = trace[low - 1]
        guard low < trace.count else {
            return date.timeIntervalSince(left.timestamp) <= 15 ? left : nil
        }
        let right = trace[low]
        let interval = right.timestamp.timeIntervalSince(left.timestamp)
        guard !right.startsSegment, interval > 0, interval <= 30 else {
            return date.timeIntervalSince(left.timestamp) <= 1 ? left : nil
        }
        let fraction = max(0, min(1, date.timeIntervalSince(left.timestamp) / interval))
        let longitudeDelta = (right.coordinate.longitude - left.coordinate.longitude + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        let longitude = (left.coordinate.longitude + longitudeDelta * fraction + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        return TripTracePoint(
            coordinate: Coordinate(latitude: left.coordinate.latitude +
                                    (right.coordinate.latitude - left.coordinate.latitude) * fraction,
                                   longitude: longitude),
            timestamp: date, speedKph: left.speedKph, startsSegment: false)
    }
}

struct TripHeatCell: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let visits: Int
}

enum TripHeatmap {
    /// One visit per trip per cell prevents waiting or GPS frequency from inflating intensity.
    static func cells(for trips: [TripRecord]) -> [TripHeatCell] {
        let earthRadius = 6_378_137.0
        var cellSize = 250.0 // Web Mercator meters; physical radius is corrected for latitude.
        var visits: [String: (x: Int, y: Int, count: Int)] = [:]
        // Coarsen the grid for large archives instead of creating tens of thousands of overlays.
        // Recount distinct trips at each resolution, so merging cells never duplicates visits.
        repeat {
            visits.removeAll(keepingCapacity: true)
            for trip in trips {
                var visited = Set<String>()
                for point in trip.trace {
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
