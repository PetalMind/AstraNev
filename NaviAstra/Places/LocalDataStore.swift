import Foundation
import Observation

enum PlaceKind: String, Codable, CaseIterable {
    case favorite, home, work
    var title: String {
        switch self {
        case .favorite: "Ulubione"
        case .home: "Dom"
        case .work: "Praca"
        }
    }

    var defaultIcon: SavedPlaceIcon {
        switch self {
        case .home: .home
        case .work: .work
        case .favorite: .heart
        }
    }
}

enum SavedPlaceIcon: String, Codable, CaseIterable, Identifiable {
    case heart, star, home, work, shoppingCart

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .heart: "heart.fill"
        case .star: "star.fill"
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .shoppingCart: "cart.fill"
        }
    }

    var title: String {
        switch self {
        case .heart: "Serce"
        case .star: "Gwiazda"
        case .home: "Dom"
        case .work: "Praca"
        case .shoppingCart: "Zakupy"
        }
    }
}

struct PlaceRouteEstimate: Equatable, Sendable {
    var minutes: Int
    var distanceMeters: Double
}

struct SavedPlace: Identifiable, Codable {
    var id = UUID()
    var destination: Destination
    var kind: PlaceKind = .favorite
    var customName: String? = nil
    var icon: SavedPlaceIcon = .heart
    var isPinned = true
    var sourceContactIdentifier: String? = nil

    init(id: UUID = UUID(), destination: Destination, kind: PlaceKind = .favorite,
         customName: String? = nil, icon: SavedPlaceIcon? = nil, isPinned: Bool? = nil,
         sourceContactIdentifier: String? = nil) {
        self.id = id
        self.destination = destination
        self.kind = kind
        self.customName = customName
        self.icon = icon ?? kind.defaultIcon
        self.isPinned = isPinned ?? true
        self.sourceContactIdentifier = sourceContactIdentifier
    }

    var displayName: String {
        if let customName = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !customName.isEmpty {
            return customName
        }
        return kind == .favorite ? destination.name : kind.title
    }

    var navigationDestination: Destination {
        Destination(id: destination.id, name: displayName, coordinate: destination.coordinate,
                    address: destination.address, poi: destination.poi)
    }

    private enum CodingKeys: String, CodingKey {
        case id, destination, kind, customName, icon, isPinned, sourceContactIdentifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        destination = try values.decode(Destination.self, forKey: .destination)
        kind = try values.decodeIfPresent(PlaceKind.self, forKey: .kind) ?? .favorite
        customName = try values.decodeIfPresent(String.self, forKey: .customName)
        icon = try values.decodeIfPresent(SavedPlaceIcon.self, forKey: .icon) ?? kind.defaultIcon
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? true
        sourceContactIdentifier = try values.decodeIfPresent(String.self, forKey: .sourceContactIdentifier)
    }
}

struct TripRecord: Identifiable, Codable {
    var id = UUID()
    var destination: Destination
    var waypoints: [Destination] = []
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    var movingSeconds: TimeInterval
    var rerouteCount: Int
    var arrived: Bool
    var originalExpectedTravelTime: TimeInterval? = nil
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var averageSpeedKph: Double { movingSeconds > 0 ? distanceMeters / movingSeconds * 3.6 : 0 }
    var stoppedSeconds: TimeInterval { max(0, duration - movingSeconds) }
    var delaySeconds: TimeInterval? {
        guard arrived, let originalExpectedTravelTime else { return nil }
        return duration - originalExpectedTravelTime
    }

    enum CodingKeys: String, CodingKey {
        case id, destination, waypoints, startedAt, endedAt, distanceMeters, movingSeconds
        case rerouteCount, arrived, originalExpectedTravelTime
    }

    init(id: UUID = UUID(), destination: Destination, waypoints: [Destination] = [], startedAt: Date,
         endedAt: Date, distanceMeters: Double, movingSeconds: TimeInterval, rerouteCount: Int,
         arrived: Bool, originalExpectedTravelTime: TimeInterval? = nil) {
        self.id = id
        self.destination = destination
        self.waypoints = waypoints
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.movingSeconds = movingSeconds
        self.rerouteCount = rerouteCount
        self.arrived = arrived
        self.originalExpectedTravelTime = originalExpectedTravelTime
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        destination = try values.decode(Destination.self, forKey: .destination)
        waypoints = try values.decodeIfPresent([Destination].self, forKey: .waypoints) ?? []
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decode(Date.self, forKey: .endedAt)
        distanceMeters = try values.decode(Double.self, forKey: .distanceMeters)
        movingSeconds = try values.decode(TimeInterval.self, forKey: .movingSeconds)
        rerouteCount = try values.decode(Int.self, forKey: .rerouteCount)
        arrived = try values.decode(Bool.self, forKey: .arrived)
        originalExpectedTravelTime = try values.decodeIfPresent(TimeInterval.self, forKey: .originalExpectedTravelTime)
    }
}

struct SearchHistoryEntry: Identifiable, Codable {
    var id = UUID()
    var destination: Destination
    var searchedAt = Date()
}

@MainActor @Observable
final class LocalDataStore {
    private(set) var places: [SavedPlace] = []
    private(set) var trips: [TripRecord] = []
    private(set) var searches: [SearchHistoryEntry] = []
    var errorMessage: String?
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviAstra", isDirectory: true)
        do { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true) }
        catch { errorMessage = "Nie udało się przygotować lokalnego zapisu: \(error.localizedDescription)" }
        do { places = try Self.read([SavedPlace].self, from: self.directory.appendingPathComponent("places.json")) ?? [] }
        catch { errorMessage = "Nie udało się wczytać ulubionych: \(error.localizedDescription)" }
        do { trips = try Self.read([TripRecord].self, from: self.directory.appendingPathComponent("trips.json")) ?? [] }
        catch { errorMessage = "Nie udało się wczytać historii: \(error.localizedDescription)" }
        do { searches = try Self.read([SearchHistoryEntry].self, from: self.directory.appendingPathComponent("searches.json")) ?? [] }
        catch { errorMessage = "Nie udało się wczytać historii wyszukiwania: \(error.localizedDescription)" }
    }

    @discardableResult
    func add(_ destination: Destination, kind: PlaceKind = .favorite,
             customName: String? = nil, icon: SavedPlaceIcon? = nil,
             isPinned: Bool? = nil, sourceContactIdentifier: String? = nil) -> Bool {
        guard !places.contains(where: { $0.destination.coordinate == destination.coordinate && $0.kind == kind }) else { return true }
        var updated = places
        if kind == .home || kind == .work { updated.removeAll { $0.kind == kind } }
        updated.insert(SavedPlace(destination: destination, kind: kind, customName: customName,
                                  icon: icon, isPinned: isPinned,
                                  sourceContactIdentifier: sourceContactIdentifier), at: 0)
        guard persist(updated, file: "places.json") else { return false }
        places = updated
        return true
    }

    @discardableResult
    func updatePlace(_ id: UUID, customName: String?, icon: SavedPlaceIcon? = nil,
                     isPinned: Bool? = nil) -> Bool {
        guard var place = places.first(where: { $0.id == id }) else { return false }
        place.customName = customName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let icon { place.icon = icon }
        if let isPinned { place.isPinned = isPinned }
        let updated = places.map { $0.id == id ? place : $0 }
        guard persist(updated, file: "places.json") else { return false }
        places = updated
        return true
    }

    @discardableResult
    func updateContactPlace(_ contactReference: String, destination: Destination) -> Bool {
        let matchingPlaces = places.filter { $0.sourceContactIdentifier == contactReference }
        guard !matchingPlaces.isEmpty,
              matchingPlaces.contains(where: {
                  $0.destination.coordinate != destination.coordinate || $0.destination.address != destination.address
              }) else { return false }
        let updated = places.map { place in
            guard place.sourceContactIdentifier == contactReference else { return place }
            var refreshed = place
            refreshed.destination = Destination(id: place.destination.id, name: destination.name,
                                                coordinate: destination.coordinate,
                                                address: destination.address, poi: destination.poi)
            return refreshed
        }
        guard persist(updated, file: "places.json") else { return false }
        places = updated
        return true
    }
    func removePlace(_ id: UUID) {
        let updated = places.filter { $0.id != id }
        if persist(updated, file: "places.json") { places = updated }
    }
    func addTrip(_ trip: TripRecord) {
        var updated = trips
        updated.insert(trip, at: 0)
        if persist(updated, file: "trips.json") { trips = updated }
    }
    func recordSearch(_ destination: Destination) {
        var updated = searches.filter { $0.destination.coordinate != destination.coordinate }
        updated.insert(SearchHistoryEntry(destination: destination), at: 0)
        updated = Array(updated.prefix(30))
        if persist(updated, file: "searches.json") { searches = updated }
    }
    func removeSearch(_ id: UUID) {
        let updated = searches.filter { $0.id != id }
        if persist(updated, file: "searches.json") { searches = updated }
    }
    func removeTrip(_ id: UUID) {
        let updated = trips.filter { $0.id != id }
        if persist(updated, file: "trips.json") { trips = updated }
    }
    @discardableResult private func persist<T: Encodable>(_ value: T, file: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Nie udało się zapisać danych na urządzeniu: \(error.localizedDescription)"
            return false
        }
    }
    private static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
