import Foundation

enum TripPlaybackKind: Equatable {
    case recorded
    case interpolated
    case gap
    case beforeFirstFix
    case afterLastFix
}

struct TripPlaybackPosition {
    let coordinate: Coordinate
    let speedKph: Double?
    let kind: TripPlaybackKind
    let elapsed: TimeInterval
    /// The requested, clamped position on the trip's clock.
    let timelineDate: Date
    /// Actual source measurement. For interpolation this is the left endpoint;
    /// before the first fix it is explicitly a future measurement.
    let measurementDate: Date
    let nextMeasurementElapsed: TimeInterval?
    /// Age of a held measurement, or time until the first future measurement.
    let missingDuration: TimeInterval
}

struct TripPlaybackGap: Identifiable {
    let id: Int
    let startElapsed: TimeInterval
    let endElapsed: TimeInterval
    let kind: TripPlaybackKind
    var duration: TimeInterval { endElapsed - startElapsed }
}

/// A prepared snapshot for scrubbing and playback. Preparation sorts and validates
/// once; each position query uses a binary search and does not scan the trace.
struct TripPlaybackTimeline {
    let points: [TripTracePoint]
    let segments: [TripTraceSegment]
    let gaps: [TripPlaybackGap]
    let duration: TimeInterval
    private let startedAt: Date
    private let measurementElapsed: [TimeInterval]

    init(trip: TripRecord) {
        let start = trip.startedAt.timeIntervalSinceReferenceDate.isFinite
            ? trip.startedAt : Date(timeIntervalSinceReferenceDate: 0)
        let length = trip.duration.isFinite ? max(0, trip.duration) : 0
        startedAt = start
        duration = length

        // Keep a break after invalid input instead of joining the fixes on either
        // side. Source order also supplies a deterministic tie-break for dates.
        var candidates: [(index: Int, point: TripTracePoint)] = []
        candidates.reserveCapacity(trip.trace.count)
        var breakBeforeNext = false
        for (index, point) in trip.trace.enumerated() {
            guard Self.isValid(point.coordinate),
                  point.timestamp.timeIntervalSinceReferenceDate.isFinite,
                  point.timestamp.timeIntervalSince(start).isFinite else {
                breakBeforeNext = true
                continue
            }
            candidates.append((index, TripTracePoint(coordinate: point.coordinate,
                timestamp: point.timestamp, speedKph: Self.validSpeed(point.speedKph),
                startsSegment: point.startsSegment || breakBeforeNext)))
            breakBeforeNext = false
        }
        candidates.sort {
            if $0.point.timestamp == $1.point.timestamp { return $0.index < $1.index }
            return $0.point.timestamp < $1.point.timestamp
        }

        var unique: [TripTracePoint] = []
        unique.reserveCapacity(candidates.count)
        for candidate in candidates {
            let point = candidate.point
            if let previous = unique.last, previous.timestamp == point.timestamp {
                // Two different coordinates at the same time cannot form a
                // continuous movement. The later source entry is authoritative.
                unique[unique.count - 1] = TripTracePoint(coordinate: point.coordinate,
                    timestamp: point.timestamp, speedKph: point.speedKph,
                    startsSegment: previous.startsSegment || point.startsSegment
                        || previous.coordinate != point.coordinate)
            } else {
                unique.append(point)
            }
        }

        let maximumSpeed = trip.transportMode?.maximumPlausibleSpeed ?? 100
        var normalized: [TripTracePoint] = []
        normalized.reserveCapacity(unique.count)
        for point in unique {
            let startsSegment: Bool
            if let previous = normalized.last {
                let interval = point.timestamp.timeIntervalSince(previous.timestamp)
                let distance = previous.coordinate.distance(to: point.coordinate)
                startsSegment = point.startsSegment || interval > 30 || interval <= 0
                    || !distance.isFinite || distance > max(30, interval * maximumSpeed)
            } else {
                startsSegment = true
            }
            normalized.append(TripTracePoint(coordinate: point.coordinate, timestamp: point.timestamp,
                speedKph: point.speedKph, startsSegment: startsSegment))
        }
        points = normalized
        measurementElapsed = normalized.map { $0.timestamp.timeIntervalSince(start) }

        var preparedSegments: [TripTraceSegment] = []
        var segmentPoints: [Coordinate] = []
        for point in normalized {
            if point.startsSegment, !segmentPoints.isEmpty {
                preparedSegments.append(TripTraceSegment(id: preparedSegments.count,
                    coordinates: segmentPoints.map(\.cl)))
                segmentPoints.removeAll(keepingCapacity: true)
            }
            segmentPoints.append(point.coordinate)
        }
        if !segmentPoints.isEmpty {
            preparedSegments.append(TripTraceSegment(id: preparedSegments.count,
                coordinates: segmentPoints.map(\.cl)))
        }
        segments = preparedSegments

        var preparedGaps: [TripPlaybackGap] = []
        func appendGap(from: TimeInterval, to: TimeInterval, kind: TripPlaybackKind) {
            let lower = max(0, min(length, from))
            let upper = max(0, min(length, to))
            guard upper > lower else { return }
            preparedGaps.append(TripPlaybackGap(id: preparedGaps.count,
                startElapsed: lower, endElapsed: upper, kind: kind))
        }
        if let first = normalized.first, let last = normalized.last {
            appendGap(from: 0, to: first.timestamp.timeIntervalSince(start), kind: .beforeFirstFix)
            for index in normalized.indices.dropFirst() where normalized[index].startsSegment {
                appendGap(from: normalized[index - 1].timestamp.timeIntervalSince(start),
                    to: normalized[index].timestamp.timeIntervalSince(start), kind: .gap)
            }
            appendGap(from: last.timestamp.timeIntervalSince(start), to: length, kind: .afterLastFix)
        }
        gaps = preparedGaps
    }

    func clampedElapsed(_ elapsed: TimeInterval) -> TimeInterval {
        guard !elapsed.isNaN else { return 0 }
        return max(0, min(duration, elapsed))
    }

    func position(at requestedElapsed: TimeInterval) -> TripPlaybackPosition? {
        guard let first = points.first else { return nil }
        let elapsed = clampedElapsed(requestedElapsed)
        let date = startedAt.addingTimeInterval(elapsed)
        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if measurementElapsed[middle] <= elapsed { low = middle + 1 } else { high = middle }
        }

        guard low > 0 else {
            return TripPlaybackPosition(coordinate: first.coordinate, speedKph: nil,
                kind: .beforeFirstFix, elapsed: elapsed, timelineDate: date,
                measurementDate: first.timestamp, nextMeasurementElapsed: nextMeasurement(at: 0),
                missingDuration: max(0, measurementElapsed[0] - elapsed))
        }
        let leftIndex = low - 1
        let left = points[leftIndex]
        if measurementElapsed[leftIndex] == elapsed {
            return TripPlaybackPosition(coordinate: left.coordinate, speedKph: left.speedKph,
                kind: .recorded, elapsed: elapsed, timelineDate: date, measurementDate: left.timestamp,
                nextMeasurementElapsed: nextMeasurement(at: low), missingDuration: 0)
        }
        guard low < points.count else {
            return TripPlaybackPosition(coordinate: left.coordinate, speedKph: nil,
                kind: .afterLastFix, elapsed: elapsed, timelineDate: date, measurementDate: left.timestamp,
                nextMeasurementElapsed: nil, missingDuration: max(0, elapsed - measurementElapsed[leftIndex]))
        }
        let right = points[low]
        if right.startsSegment {
            return TripPlaybackPosition(coordinate: left.coordinate, speedKph: nil,
                kind: .gap, elapsed: elapsed, timelineDate: date, measurementDate: left.timestamp,
                nextMeasurementElapsed: nextMeasurement(at: low),
                missingDuration: max(0, elapsed - measurementElapsed[leftIndex]))
        }

        let interval = measurementElapsed[low] - measurementElapsed[leftIndex]
        let fraction = max(0, min(1, (elapsed - measurementElapsed[leftIndex]) / interval))
        let longitudeDelta = (right.coordinate.longitude - left.coordinate.longitude + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        let longitude = (left.coordinate.longitude + longitudeDelta * fraction + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        let coordinate = Coordinate(latitude: left.coordinate.latitude
            + (right.coordinate.latitude - left.coordinate.latitude) * fraction, longitude: longitude)
        let speed: Double?
        if let leftSpeed = left.speedKph, let rightSpeed = right.speedKph {
            speed = leftSpeed + (rightSpeed - leftSpeed) * fraction
        } else {
            speed = nil
        }
        return TripPlaybackPosition(coordinate: coordinate, speedKph: speed, kind: .interpolated,
            elapsed: elapsed, timelineDate: date, measurementDate: left.timestamp,
            nextMeasurementElapsed: nextMeasurement(at: low), missingDuration: 0)
    }

    private func nextMeasurement(at index: Int) -> TimeInterval? {
        guard measurementElapsed.indices.contains(index) else { return nil }
        let elapsed = measurementElapsed[index]
        return (0...duration).contains(elapsed) ? elapsed : nil
    }

    private static func validSpeed(_ speed: Double?) -> Double? {
        guard let speed, speed.isFinite, (0...360).contains(speed) else { return nil }
        return speed
    }

    private static func isValid(_ coordinate: Coordinate) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude) && (-180...180).contains(coordinate.longitude)
    }
}
