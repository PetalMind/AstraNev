import Foundation
import Observation

struct NearbySearchRequest: Identifiable {
    let id = UUID()
    let category: NearbyPlaceCategory
    let nearDestination: Bool
}

@MainActor
@Observable
final class PlaceStore {
    @ObservationIgnored private let repository: LocalDataStore

    var places: [SavedPlace] { repository.places }
    var trips: [TripRecord] { repository.trips }
    var searches: [SearchHistoryEntry] { repository.searches }
    var parkedCar: ParkedCar? { repository.parkedCar }

    var errorMessage: String? {
        get { repository.errorMessage }
        set { repository.errorMessage = newValue }
    }

    var selectedMapPlaces: [SearchResult] = []
    var nearbyRequest: NearbySearchRequest?

    init() {
        self.repository = LocalDataStore()
    }

    init(repository: LocalDataStore) {
        self.repository = repository
    }

    @discardableResult
    func saveParkedCar(at coordinate: Coordinate, parkedAt: Date = Date()) -> Bool {
        repository.saveParkedCar(at: coordinate, parkedAt: parkedAt)
    }

    @discardableResult
    func updateParkedCar(_ car: ParkedCar) -> Bool {
        repository.updateParkedCar(car)
    }

    @discardableResult
    func removeParkedCar() -> Bool {
        repository.removeParkedCar()
    }

    func saveParkedCarPhoto(_ data: Data) -> String? {
        repository.saveParkedCarPhoto(data)
    }

    func parkedCarPhotoData(for car: ParkedCar) -> Data? {
        repository.parkedCarPhotoData(for: car)
    }

    @discardableResult
    func add(_ destination: Destination, kind: PlaceKind = .favorite,
             customName: String? = nil, icon: SavedPlaceIcon? = nil,
             isPinned: Bool? = nil, sourceContactIdentifier: String? = nil) -> Bool {
        repository.add(destination, kind: kind, customName: customName, icon: icon,
                       isPinned: isPinned, sourceContactIdentifier: sourceContactIdentifier)
    }

    @discardableResult
    func updatePlace(_ id: UUID, customName: String?, icon: SavedPlaceIcon? = nil,
                     isPinned: Bool? = nil) -> Bool {
        repository.updatePlace(id, customName: customName, icon: icon, isPinned: isPinned)
    }

    @discardableResult
    func updateContactPlace(_ contactReference: String, destination: Destination) -> Bool {
        repository.updateContactPlace(contactReference, destination: destination)
    }

    func removePlace(_ id: UUID) {
        repository.removePlace(id)
    }

    func addTrip(_ trip: TripRecord) {
        repository.addTrip(trip)
    }

    func recordSearch(_ destination: Destination) {
        repository.recordSearch(destination)
    }

    func removeSearch(_ id: UUID) {
        repository.removeSearch(id)
    }

    func removeTrip(_ id: UUID) {
        repository.removeTrip(id)
    }
}
