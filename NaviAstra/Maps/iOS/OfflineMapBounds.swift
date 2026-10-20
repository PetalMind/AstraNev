#if os(iOS)
import Foundation
import MapLibre

/// The exact geographic rectangle submitted to the SDK, independent of the UI viewport.
nonisolated struct OfflineMapBounds: Codable, Equatable, Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    var isValid: Bool {
        [south, west, north, east].allSatisfy(\.isFinite)
            && south >= -85 && north <= 85 && west >= -180 && east <= 180
            && south < north && west < east
    }
    var center: Coordinate { Coordinate(latitude: (south + north) / 2, longitude: (west + east) / 2) }
    var widthKilometers: Double {
        (east - west) * 111.32 * cos(center.latitude * .pi / 180)
    }
    var heightKilometers: Double { (north - south) * 111.32 }
    var dimensions: String {
        String(format: "%.1f × %.1f km", locale: Locale(identifier: "pl_PL"), widthKilometers, heightKilometers)
    }
    var approximateAreaSquareKilometers: Double {
        let radians = Double.pi / 180
        return 6_371 * 6_371 * (east - west) * radians
            * (sin(north * radians) - sin(south * radians))
    }

    static func around(_ coordinate: Coordinate, radiusKilometers: Double) -> Self {
        let delta = radiusKilometers / 111.32
        let longitudeDelta = delta / max(0.08, cos(coordinate.latitude * .pi / 180))
        return Self(south: max(-85, coordinate.latitude - delta), west: max(-180, coordinate.longitude - longitudeDelta),
                    north: min(85, coordinate.latitude + delta), east: min(180, coordinate.longitude + longitudeDelta))
    }

    static func enclosing(_ coordinates: [Coordinate], paddingKilometers: Double = 2) -> Self? {
        guard coordinates.count > 1,
              coordinates.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite
                  && (-85...85).contains($0.latitude) && (-180...180).contains($0.longitude) }) else { return nil }
        let south = coordinates.map(\.latitude).min()!, north = coordinates.map(\.latitude).max()!
        let west = coordinates.map(\.longitude).min()!, east = coordinates.map(\.longitude).max()!
        // Do not turn a route across the antimeridian into an almost global download.
        guard east - west < 180 else { return nil }
        let delta = paddingKilometers / 111.32
        let longitudeDelta = delta / max(0.08, cos((south + north) / 2 * .pi / 180))
        let bounds = Self(south: max(-85, south - delta), west: max(-180, west - longitudeDelta),
                          north: min(85, north + delta), east: min(180, east + longitudeDelta))
        return bounds.isValid ? bounds : nil
    }

    @MainActor var mapLibreBounds: MLNCoordinateBounds {
        MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west),
                            ne: CLLocationCoordinate2D(latitude: north, longitude: east))
    }
}
#endif
