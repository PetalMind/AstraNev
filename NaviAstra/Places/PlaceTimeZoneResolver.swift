import CoreLocation
import Foundation
import MapKit

struct PlaceLocaleContext: Equatable, Sendable {
    var timeZoneIdentifier: String?
    var countryCode: String?
}

@MainActor
enum PlaceTimeZoneResolver {
    private static let cacheLimit = 512
    private static var cache: [String: PlaceLocaleContext] = [:]
    private static var recency: [String] = []
    private static var pending: [String: Task<PlaceLocaleContext?, Never>] = [:]

    static func cachedContext(for coordinate: Coordinate) -> PlaceLocaleContext? {
        let key = key(for: coordinate)
        guard let value = cache[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    static func cachedIdentifier(for coordinate: Coordinate) -> String? {
        cachedContext(for: coordinate)?.timeZoneIdentifier
    }

    static func context(for coordinate: Coordinate) async -> PlaceLocaleContext? {
        let key = key(for: coordinate)
        if let value = cachedContext(for: coordinate) { return value }
        if let task = pending[key] { return await task.value }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let task: Task<PlaceLocaleContext?, Never> = Task { @MainActor in
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = Locale(identifier: "pl_PL")
            guard let mapItems = try? await request.mapItems else { return nil }
            guard let item = mapItems.first else { return nil }
            let country = item.addressRepresentations?.region?.identifier
            let countryCode = country.flatMap { value -> String? in
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalized.count == 2, normalized.allSatisfy(\.isLetter) else { return nil }
                return normalized.lowercased()
            }
            let value = PlaceLocaleContext(timeZoneIdentifier: item.timeZone?.identifier,
                                           countryCode: countryCode)
            return value.timeZoneIdentifier == nil && value.countryCode == nil ? nil : value
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        if let value {
            cache[key] = value
            markRecentlyUsed(key)
            while recency.count > cacheLimit {
                let expired = recency.removeFirst()
                cache[expired] = nil
            }
        }
        return value
    }

    static func identifier(for coordinate: Coordinate) async -> String? {
        await context(for: coordinate)?.timeZoneIdentifier
    }

    private static func markRecentlyUsed(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func key(for coordinate: Coordinate) -> String {
        "\(Int((coordinate.latitude * 10_000).rounded()))/\(Int((coordinate.longitude * 10_000).rounded()))"
    }
}
