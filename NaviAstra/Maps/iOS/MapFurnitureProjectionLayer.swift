#if os(iOS)
import MapLibre
import simd
import UIKit

/// Captures the native camera transform without issuing GPU commands. Selection
/// can project model height with exactly the matrix used to draw the map.
final class MapFurnitureProjectionLayer: MLNCustomStyleLayer {
    let diagnostics = MapRenderDiagnostics()
    static let layerID = MapEnvironmentStyle.prefix + "furniture-projection"
    struct Snapshot {
        let matrix: simd_double4x4
        let world: Double
        let longitude: Double
        let latitude: Double
        let zoom: Double
        let size: CGSize
        let time: TimeInterval

        func groundPoint(at coordinate: CLLocationCoordinate2D) -> CGPoint? {
            let latitude = coordinate.latitude * .pi / 180
            var x = (coordinate.longitude + 180) / 360
            x += (((longitude + 180) / 360) - x).rounded()
            let y = (1 - log(tan(.pi / 4 + latitude / 2)) / .pi) / 2
            let clip = matrix * SIMD4(x * world, y * world, 0, 1)
            guard clip.w > 0.001 else { return nil }
            let point = CGPoint(x: (clip.x / clip.w + 1) * Double(size.width) / 2,
                                y: (1 - clip.y / clip.w) * Double(size.height) / 2)
            return point.x.isFinite && point.y.isFinite ? point : nil
        }

        func bounds(at coordinate: CLLocationCoordinate2D, model: MapStreetFurnitureGeometry.Bounds) -> CGRect? {
            let degreesPerMeter = 180 / (.pi * 6_378_137.0)
            let longitudeScale = degreesPerMeter / cos(coordinate.latitude * .pi / 180)
            var rect = CGRect.null
            for x in [model.minimum.x, model.maximum.x] {
                for y in [model.minimum.y, model.maximum.y] {
                    let latitude = (coordinate.latitude + y * degreesPerMeter) * .pi / 180
                    var worldX = (coordinate.longitude + x * longitudeScale + 180) / 360
                    worldX += (((longitude + 180) / 360) - worldX).rounded()
                    let worldY = (1 - log(tan(.pi / 4 + latitude / 2)) / .pi) / 2
                    for z in [model.minimum.z, model.maximum.z] {
                        let clip = matrix * SIMD4(worldX * world, worldY * world, z, 1)
                        guard clip.w > 0.001 else { continue }
                        let point = CGPoint(x: (clip.x / clip.w + 1) * Double(size.width) / 2,
                                            y: (1 - clip.y / clip.w) * Double(size.height) / 2)
                        guard point.x.isFinite, point.y.isFinite else { continue }
                        rect = rect.union(CGRect(origin: point, size: CGSize(width: 0.01, height: 0.01)))
                    }
                }
            }
            return rect.isNull ? nil : rect
        }
    }
    private let lock = NSLock()
    private var captured: Snapshot?

    func snapshot(on map: MLNMapView) -> Snapshot? {
        lock.lock()
        let value = captured
        lock.unlock()
        guard let value, ProcessInfo.processInfo.systemUptime - value.time < 1,
              abs(value.zoom - map.zoomLevel) < 0.15,
              abs(value.size.width - map.bounds.width) < 1,
              abs(value.size.height - map.bounds.height) < 1 else { return nil }
        // Zoom/age alone do not detect panning, rotation, pitch or contentInset
        // changes. Compare three non-collinear ground anchors with the live map.
        // This avoids assuming units for SDK camera angles.
        let meters = max(10, map.metersPerPoint(atLatitude: value.latitude)
            * Double(min(value.size.width, value.size.height)) * 0.2)
        let dy = meters / 111_319.4908
        let dx = dy / max(0.1, cos(value.latitude * .pi / 180))
        let anchors = [CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude),
            CLLocationCoordinate2D(latitude: value.latitude + dy, longitude: value.longitude),
            CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude + dx)]
        for anchor in anchors {
            guard let captured = value.groundPoint(at: anchor) else { return nil }
            let current = map.convert(anchor, toPointTo: map)
            guard current.x.isFinite, current.y.isFinite,
                  hypot(current.x - captured.x, current.y - captured.y) <= 2 else { return nil }
        }
        return value
    }

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        if let commandBuffer { diagnostics.sample(commandBuffer) }
        let m = context.projectionMatrix
        let matrix = simd_double4x4(columns: (SIMD4(m.m00, m.m01, m.m02, m.m03),
            SIMD4(m.m10, m.m11, m.m12, m.m13), SIMD4(m.m20, m.m21, m.m22, m.m23),
            SIMD4(m.m30, m.m31, m.m32, m.m33)))
        let value = Snapshot(matrix: matrix, world: 512 * pow(2, context.zoomLevel),
            longitude: context.centerCoordinate.longitude, latitude: context.centerCoordinate.latitude,
            zoom: context.zoomLevel, size: context.size,
            time: ProcessInfo.processInfo.systemUptime)
        lock.lock()
        captured = value
        lock.unlock()
    }

    override func willMove(from mapView: MLNMapView) {
        lock.lock()
        captured = nil
        lock.unlock()
        super.willMove(from: mapView)
    }
}
#endif
