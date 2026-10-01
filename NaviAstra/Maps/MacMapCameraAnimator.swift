#if os(macOS)
import AppKit
import CoreLocation
import MapKit

enum MacMapCameraAnimator {
    static func apply(_ intent: CameraIntent, state: NavigationCameraState, to map: MKMapView) {
        let animated = intent.animationDuration.map { $0 > 0 } ?? true
        if !intent.bounds.isEmpty,
           state == .destinationPreview || state == .routeOverview || state == .arrived ||
            state.usesNavigationPerspective {
            let camera = map.camera
            camera.pitch = CGFloat(intent.pitch)
            camera.heading = intent.bearing
            map.setCamera(camera, animated: false)
            let rect = intent.bounds.map { MKMapPoint($0.cl) }.reduce(MKMapRect.null) {
                $0.union(MKMapRect(x: $1.x, y: $1.y, width: 1, height: 1))
            }
            map.setVisibleMapRect(rect,
                edgePadding: NSEdgeInsets(top: CGFloat(intent.padding.top), left: CGFloat(intent.padding.left),
                                          bottom: CGFloat(intent.padding.bottom), right: CGFloat(intent.padding.right)), animated: animated)
            return
        }
        let previousCamera = map.camera
        let camera = map.camera
        camera.centerCoordinate = intent.target.cl
        camera.pitch = CGFloat(intent.pitch)
        camera.heading = intent.bearing
        camera.centerCoordinateDistance = max(150, 40_000_000 / pow(2, intent.zoom))
        if state == .browse {
            // MapKit has no padded setCamera overload. Fit a north-up local rectangle
            // into the unobscured viewport instead of the whole window.
            let point = MKMapPoint(intent.target.cl)
            let metersPerPoint = MKMetersPerMapPointAtLatitude(intent.target.latitude)
            let width = camera.centerCoordinateDistance / max(0.001, metersPerPoint)
            let availableWidth = max(100, Double(map.bounds.width) - intent.padding.left - intent.padding.right)
            let availableHeight = max(100, Double(map.bounds.height) - intent.padding.top - intent.padding.bottom)
            let height = width * availableHeight / availableWidth
            map.setVisibleMapRect(MKMapRect(x: point.x - width / 2, y: point.y - height / 2,
                                           width: width, height: height),
                                  edgePadding: NSEdgeInsets(top: intent.padding.top, left: intent.padding.left,
                                                            bottom: intent.padding.bottom, right: intent.padding.right),
                                  animated: animated)
        } else if intent.followCoordinate != nil {
            // MapKit has no padded perspective-camera setter. Resolve the offset
            // in its own projection so heading and pitch participate in framing.
            map.setCamera(camera, animated: false)
            let desiredX = (intent.padding.left + Double(map.bounds.width) - intent.padding.right) / 2
            let desiredTopY = (intent.padding.top + Double(map.bounds.height) - intent.padding.bottom) / 2
            let desiredY = map.isFlipped ? desiredTopY : Double(map.bounds.height) - desiredTopY
            for _ in 0..<2 {
                let actual = map.convert(intent.target.cl, toPointTo: map)
                let centerPoint = CGPoint(x: map.bounds.midX + actual.x - desiredX,
                                          y: map.bounds.midY + actual.y - desiredY)
                camera.centerCoordinate = map.convert(centerPoint, toCoordinateFrom: map)
                map.setCamera(camera, animated: false)
            }
            if animated { map.setCamera(previousCamera, animated: false) }
            map.setCamera(camera, animated: animated)
        } else {
            map.setCamera(camera, animated: animated)
        }
    }
}
#endif
