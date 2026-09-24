import CoreLocation
import Foundation
import MapKit

@MainActor
enum PlaceTimeZoneResolver {
    private static var cache: [String: String] = [:]
    private static var pending: [String: Task<String?, Never>] = [:]

    static func cachedIdentifier(for coordinate: Coordinate) -> String? {
        cache[key(for: coordinate)]
    }

    static func identifier(for coordinate: Coordinate) async -> String? {
        let key = key(for: coordinate)
        if let value = cache[key] { return value }
        if let task = pending[key] { return await task.value }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let task: Task<String?, Never> = Task { @MainActor in
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = Locale(identifier: "pl_PL")
            guard let mapItems = try? await request.mapItems else { return nil }
            return mapItems.first?.timeZone?.identifier
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        if let value { cache[key] = value }
        if cache.count > 512 { cache = cache.filter { $0.key == key } }
        return value
    }

    private static func key(for coordinate: Coordinate) -> String {
        "\(Int((coordinate.latitude * 10_000).rounded()))/\(Int((coordinate.longitude * 10_000).rounded()))"
    }
}
