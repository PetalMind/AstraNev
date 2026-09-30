#if os(iOS)
import MapLibre
import UIKit

enum MapLibreCameraAnimator {
    @discardableResult
    static func apply(_ intent: CameraIntent, state: NavigationCameraState, to map: MLNMapView,
                      completionHandler: @escaping () -> Void) -> Bool {
        guard isValid(intent.target), intent.zoom.isFinite, intent.pitch.isFinite,
              intent.bearing.isFinite else { return false }
        let validBounds = intent.bounds.filter(isValid)
        if !validBounds.isEmpty,
           state == .destinationPreview || state == .routeOverview || state == .arrived ||
            state.usesNavigationPerspective {
            let camera = map.camera
            camera.pitch = CGFloat(intent.pitch)
            camera.heading = intent.bearing
            map.setCamera(camera, withDuration: 0, animationTimingFunction: nil)
            let lats = validBounds.map(\.latitude), lons = validBounds.map(\.longitude)
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!),
                                             ne: CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
            let animated = intent.animationDuration.map { $0 > 0 } ?? true
            map.setVisibleCoordinateBounds(bounds,
                edgePadding: UIEdgeInsets(top: CGFloat(intent.padding.top), left: CGFloat(intent.padding.left),
                                          bottom: CGFloat(intent.padding.bottom), right: CGFloat(intent.padding.right)),
                animated: animated, completionHandler: completionHandler)
            return true
        }
        let camera = map.camera
        camera.centerCoordinate = intent.target.cl
        let pitch = min(60, max(0, intent.pitch))
        let targetAltitude = MLNAltitudeForZoomLevel(
            intent.zoom, CGFloat(pitch), intent.target.latitude, map.bounds.size)
        guard targetAltitude.isFinite else { return false }
        camera.pitch = CGFloat(pitch)
        camera.heading = intent.bearing.truncatingRemainder(dividingBy: 360)
        camera.altitude = max(120, targetAltitude)
        let defaultDuration: TimeInterval = switch state {
        case .startingNavigation: 0.35
        case .maneuverNow: 0.45
        case .leavingManeuver: 0.7
        case .approachingManeuver: 0.4
        case .followNavigation, .rerouting, .weakGPS: 0.28
        default: 0.45
        }
        let duration = intent.animationDuration ?? defaultDuration
        map.setCamera(camera, withDuration: duration, animationTimingFunction: nil,
                      edgePadding: UIEdgeInsets(top: intent.padding.top, left: intent.padding.left,
                                                bottom: intent.padding.bottom, right: intent.padding.right),
                      completionHandler: completionHandler)
        return true
    }

    private static func isValid(_ coordinate: Coordinate) -> Bool {
        coordinate.latitude.isFinite && (-90...90).contains(coordinate.latitude) &&
            coordinate.longitude.isFinite && (-180...180).contains(coordinate.longitude)
    }
}
#endif
