#if os(iOS)
import MapLibre
import UIKit

/// Shared screen-space rules. A high camera zoom alone does not make the far
/// side of a tilted map suitable for small geometry.
@MainActor
enum MapDetailPolicy {
    static var constrained: Bool {
        let process = ProcessInfo.processInfo
        return process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
    }
    static var refreshInterval: TimeInterval { constrained ? 0.7 : 0.35 }
    static let retention: TimeInterval = 15

    static func smooth(_ value: Double, from start: Double, to end: Double) -> Double {
        let t = max(0, min(1, (value - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    static func projectedSpan(at coordinate: CLLocationCoordinate2D, meters: Double, on map: MLNMapView) -> Double {
        let dy = meters / 111_320 / 2
        let dx = dy / max(0.1, cos(coordinate.latitude * .pi / 180))
        let west = map.convert(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude - dx), toPointTo: map)
        let east = map.convert(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude + dx), toPointTo: map)
        let south = map.convert(CLLocationCoordinate2D(latitude: coordinate.latitude - dy, longitude: coordinate.longitude), toPointTo: map)
        let north = map.convert(CLLocationCoordinate2D(latitude: coordinate.latitude + dy, longitude: coordinate.longitude), toPointTo: map)
        let horizontal = hypot(east.x - west.x, east.y - west.y)
        let vertical = hypot(north.x - south.x, north.y - south.y)
        let span = sqrt(horizontal * vertical)
        return span.isFinite ? Double(span) : 0
    }

    static func viewportKey(on map: MLNMapView) -> String {
        let c = map.centerCoordinate
        return "\(Int(c.latitude * 10_000)):\(Int(c.longitude * 10_000)):\(Int(map.zoomLevel * 4)):\(Int(map.camera.pitch / 5)):\(Int(map.camera.heading / 10)):\(map.bounds.size):\(map.contentInset)"
    }

    static func contains(_ coordinate: CLLocationCoordinate2D, on map: MLNMapView, margin: CGFloat = 128) -> Bool {
        let point = map.convert(coordinate, toPointTo: map)
        return point.x.isFinite && point.y.isFinite && map.bounds.insetBy(dx: -margin, dy: -margin).contains(point)
    }
}

/// Missing tiles are not evidence that a previously observed object disappeared.
/// Retain observations briefly, bounded by the current viewport and a hard budget.
@MainActor
final class MapDetailObservations<Value> {
    private struct Entry { let value: Value; let coordinate: CLLocationCoordinate2D; let seen: Date }
    private var entries: [String: Entry] = [:]

    func reset() { entries.removeAll() }

    func remove(keys: Set<String>) {
        for key in keys { entries.removeValue(forKey: key) }
    }

    func merge(_ values: [(String, Value, CLLocationCoordinate2D)], on map: MLNMapView, limit: Int) -> [String: Value] {
        let now = Date()
        for (key, value, coordinate) in values { entries[key] = Entry(value: value, coordinate: coordinate, seen: now) }
        entries = entries.filter {
            now.timeIntervalSince($0.value.seen) < MapDetailPolicy.retention
                && MapDetailPolicy.contains($0.value.coordinate, on: map, margin: 256)
        }
        if entries.count > limit {
            let keep = Set(entries.sorted { $0.value.seen > $1.value.seen }.prefix(limit).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
        return entries.mapValues(\.value)
    }
}
#endif
