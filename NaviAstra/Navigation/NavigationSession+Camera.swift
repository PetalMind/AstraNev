import Foundation

extension NavigationSession {
    func setFreeLook() {
        mapCameraController.setFreeLook()
    }

    func returnToFollow() {
        if state.status != .navigating && state.status != .rerouting {
            locationManager.requestCurrentLocation()
        }
        mapCameraController.returnToFollow()
    }

    func showRouteOverview() {
        mapCameraController.showRouteOverview()
    }

    func focusMap(on coordinate: Coordinate, zoom: Double = 15.5) {
        mapCameraController.focusMap(on: coordinate, zoom: zoom)
    }

    func updateCameraIntent(using precomputedRouteProjection: RouteProjection? = nil) {
        guard appIsForeground else { return }
        mapCameraController.updateCameraIntent(using: precomputedRouteProjection)
    }

    func prepareNavigationCamera(for route: NavigationRoute) {
        guard appIsForeground else { return }
        mapCameraController.prepareNavigationCamera(for: route) { [weak self] routeID, projection, timestamp in
            self?.previousRouteMatch = (routeID, projection, timestamp)
            self?.updateCameraIntent(using: projection)
        }
    }

    func updateNavigationCameraState(force: Bool = false) {
        guard appIsForeground else { return }
        mapCameraController.updateNavigationCameraState(force: force)
    }

    func revealRoute() {
        guard appIsForeground else { return }
        mapCameraController.revealRoute()
    }
}
