import CoreLocation
import Foundation
import MapKit

@MainActor
enum PlaceTimeZoneResolver {
    struct Context {
        let timeZoneIdentifier: String?
        let countryCode: String?
    }
    private static var cache: [String: Context] = [:]
    private static var pending: [String: Task<Context?, Never>] = [:]

    static func cachedIdentifier(for coordinate: Coordinate) -> String? {
        cache[key(for: coordinate)]?.timeZoneIdentifier
    }

    static func cachedCountryCode(for coordinate: Coordinate) -> String? {
        cache[key(for: coordinate)]?.countryCode
    }

    static func identifier(for coordinate: Coordinate) async -> String? {
        await context(for: coordinate)?.timeZoneIdentifier
    }

    static func context(for coordinate: Coordinate) async -> Context? {
        let key = key(for: coordinate)
        if let value = cache[key] { return value }
        if let task = pending[key] { return await task.value }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let task: Task<Context?, Never> = Task { @MainActor in
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = Locale(identifier: "pl_PL")
            guard let mapItems = try? await request.mapItems else { return nil }
            guard let item = mapItems.first else { return nil }
            return Context(timeZoneIdentifier: item.timeZone?.identifier,
                           countryCode: item.addressRepresentations?.region?.identifier.lowercased())
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
