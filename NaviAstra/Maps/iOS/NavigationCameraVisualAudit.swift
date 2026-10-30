#if DEBUG && os(iOS)
import Foundation
import MapLibre
import OSLog
import QuartzCore

/// Opt-in measurements of the native renderer, not just the camera planner.
/// The replay is synthetic; this file is never produced by ordinary navigation.
@MainActor
final class NavigationCameraVisualAudit {
    static let shared = NavigationCameraVisualAudit()

    private let isEnabled = ["turns", "roundabout"].contains(
        ProcessInfo.processInfo.environment["NAVIASTRA_CAMERA_REPLAY"] ?? "")
    private var startedAt: CFTimeInterval?
    private var previousSampleAt: CFTimeInterval = -.infinity
    private var writer: CameraAuditCSVWriter?

    func recordStartup(event: String, deadline: CFTimeInterval, duration: TimeInterval, zoom: Double) {
        guard isEnabled else { return }
        let elapsed = CACurrentMediaTime() - deadline + NavigationCameraTiming.start
        print("CAMERA_START event=\(event) elapsed_s=\(elapsed) duration_s=\(duration) zoom=\(zoom)")
    }

    func sample(map: MLNMapView, frame: NavigationPuckFrame, rendered: CameraIntent,
                requested: CameraIntent?, viewport: CameraPadding,
                location: NavigationLocation?, transitionProgress: Double) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - previousSampleAt >= 0.05 else { return }
        previousSampleAt = now
        if startedAt == nil { startedAt = now }
        if writer == nil {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("naviastra-camera-audit.csv")
            writer = CameraAuditCSVWriter(url: url, header: Self.columns.joined(separator: ",") + "\n")
        }

        let camera = map.camera
        let width = Double(map.bounds.width)
        let height = Double(map.bounds.height)
        let left = max(0, viewport.left)
        let right = max(left, width - max(0, viewport.right))
        let top = max(0, viewport.top)
        let bottom = max(top, height - max(0, viewport.bottom))
        let puck = map.convert(frame.coordinate.cl, toPointTo: map)
        var outside = 0
        var invalid = 0
        var maxOvershoot = 0.0
        for coordinate in rendered.framingCoordinates {
            let point = map.convert(coordinate.cl, toPointTo: map)
            guard point.x.isFinite, point.y.isFinite else {
                outside += 1
                invalid += 1
                continue
            }
            let overshoot = max(0, left - Double(point.x), Double(point.x) - right,
                                top - Double(point.y), Double(point.y) - bottom)
            if overshoot > 0 { outside += 1 }
            maxOvershoot = max(maxOvershoot, overshoot)
        }
        let insets = map.cameraEdgeInsets
        let values: [Double?] = [
            now - (startedAt ?? now), now, location.map { Date().timeIntervalSince($0.timestamp) },
            camera.heading, map.zoomLevel, Double(camera.pitch),
            Double(puck.x), Double(puck.y), frame.routeProgress, frame.bearing, location?.speed,
            viewport.top, viewport.bottom, viewport.left, viewport.right, width, height,
            max(0, right - left), max(0, bottom - top),
            Double(insets.top), Double(insets.bottom), Double(insets.left), Double(insets.right),
            Double(rendered.framingCoordinates.count), Double(outside), Double(invalid), maxOvershoot,
            rendered.bearing, rendered.zoom, rendered.pitch, rendered.anchorFraction,
            requested?.bearing, requested?.zoom, requested?.pitch, transitionProgress
        ]
        // Swift's numeric description is locale-independent; these are machine
        // records, not localized values presented in the application interface.
        let row = values.map { value in
            value.flatMap { $0.isFinite ? String($0) : nil } ?? ""
        }.joined(separator: ",") + "\n"
        writer?.append(row)
    }

    private static let columns = [
        "elapsed_s", "monotonic_s", "fix_age_s",
        "actual_heading_deg", "actual_zoom", "actual_pitch_deg",
        "puck_x_pt", "puck_y_pt", "route_progress_m", "puck_bearing_deg", "speed_mps",
        "viewport_top_pt", "viewport_bottom_pt", "viewport_left_pt", "viewport_right_pt",
        "map_width_pt", "map_height_pt", "visible_width_pt", "visible_height_pt",
        "camera_inset_top_pt", "camera_inset_bottom_pt", "camera_inset_left_pt", "camera_inset_right_pt",
        "framing_points", "outside_points", "invalid_projection_points", "max_overshoot_pt",
        "rendered_heading_deg", "rendered_zoom", "rendered_pitch_deg", "anchor_fraction",
        "planner_heading_deg", "planner_zoom", "planner_pitch_deg", "transition_progress"
    ]
}

/// Mutable state is confined to the serial utility queue. Neither opening the
/// file nor flushing it can block the main actor's camera/display work.
private nonisolated final class CameraAuditCSVWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NaviAstra.CameraVisualAudit", qos: .utility)
    private let url: URL
    private var rows = ""
    private var flushScheduled = false
    private let logger = Logger(subsystem: "NaviAstra", category: "CameraVisualAudit")

    init(url: URL, header: String) {
        self.url = url
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(header.utf8).write(to: url, options: .atomic)
            } catch {
                self.logger.error("Could not initialize camera audit: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func append(_ row: String) {
        queue.async {
            self.rows += row
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + 1) { self.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        guard !rows.isEmpty else { return }
        let data = Data(rows.utf8)
        rows.removeAll(keepingCapacity: true)
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
        } catch {
            logger.error("Could not flush camera audit: \(error.localizedDescription, privacy: .private)")
        }
    }
}
#endif
