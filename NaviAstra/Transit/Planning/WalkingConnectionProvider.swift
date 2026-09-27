import Foundation

nonisolated enum WalkingConnectionProvider {
static func fetchGeometry(
    _ request: TransitWalkingGeometryRequest,
    endpoint: URL
) async -> (TransitWalkingGeometryKey, TransitWalkingGeometry?) {
    do {
        guard let route = try await ValhallaRouteProvider(endpoint: endpoint)
            .calculateRoutes(from: request.from, to: request.to, mode: .walking).first else {
            return (request.key, nil)
        }
        return (request.key, TransitWalkingGeometry(coordinates: route.coordinates,
                                                    duration: route.expectedTravelTime))
    } catch {
        return (request.key, nil)
    }
}
}
