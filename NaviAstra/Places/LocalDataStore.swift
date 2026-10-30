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

enum TripTerminationReason: String, Codable, Sendable {
    case completed, userStopped, replaced, interruptedRecovered
}

enum TripTraceUnavailableReason: String, Codable, Sendable {
    case legacyRecord, retention, noReliableLocations
}

/// Accepted measurement intervals remain available after map geometry expires.
nonisolated struct TripDistanceSample: Codable, Sendable {
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: Double
}

struct TripRecord: Identifiable, Codable {
    var vehicleID: UUID? = nil
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
    var drivingScore: DrivingScore? = nil
    var transportMode: TransportMode? = nil
    var trace: [TripTracePoint] = []
    var maximumSpeedKph: Double? = nil
    var measuredStoppedSeconds: TimeInterval? = nil
    var terminationReason: TripTerminationReason? = nil
    var traceUnavailableReason: TripTraceUnavailableReason? = nil
    var distanceSamples: [TripDistanceSample] = []
    var routingQuality: RouteQualityMeasurement? = nil
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var averageSpeedKph: Double { movingSeconds > 0 ? distanceMeters / movingSeconds * 3.6 : 0 }
    var stoppedSeconds: TimeInterval { max(0, measuredStoppedSeconds ?? 0) }
    var recordedSeconds: TimeInterval { min(duration, max(0, movingSeconds) + stoppedSeconds) }
    var unknownSeconds: TimeInterval { max(0, duration - recordedSeconds) }
    var recordingCoverage: Double { duration > 0 ? recordedSeconds / duration : 0 }
    var terminationDescription: String {
        switch terminationReason {
        case .completed: "Dotarto do celu"
        case .userStopped: "Przerwano podróż"
        case .replaced: "Rozpoczęto inną podróż"
        case .interruptedRecovered: "Przejazd odzyskany po nieoczekiwanym zamknięciu aplikacji"
        case nil: arrived ? "Dotarto do celu" : "Przerwano podróż"
        }
    }
    var traceAvailabilityDescription: String {
        guard trace.isEmpty else { return "Zapisany ślad GPS" }
        return switch traceUnavailableReason {
        case .retention: "Ślad GPS usunięto zgodnie z okresem przechowywania. Statystyki przejazdu zachowano."
        case .noReliableLocations: "Nie udało się zapisać wiarygodnych pomiarów GPS podczas tej podróży."
        case .legacyRecord, nil: "Ten starszy wpis nie zawiera zapisanego śladu GPS."
        }
    }
    var drivingScoreUnavailableReason: String? {
        guard drivingScore == nil else { return nil }
        guard transportMode == .car else { return "Ocena prowadzenia jest dostępna dla przejazdów samochodem." }
        if terminationReason == .interruptedRecovered {
            return "Przejazd odzyskano po zamknięciu aplikacji. Pełna ocena prowadzenia nie jest dostępna."
        }
        if !arrived { return "Ocena prowadzenia jest dostępna po dotarciu do celu." }
        return "Dla tego przejazdu nie zapisano oceny prowadzenia."
    }
    var scoreUnavailableReason: String? { drivingScoreUnavailableReason }
    var delaySeconds: TimeInterval? {
        guard arrived, let originalExpectedTravelTime else { return nil }
        return duration - originalExpectedTravelTime
    }

    enum CodingKeys: String, CodingKey {
        case id, destination, waypoints, startedAt, endedAt, distanceMeters, movingSeconds
        case rerouteCount, arrived, originalExpectedTravelTime, drivingScore
        case transportMode, trace, maximumSpeedKph, vehicleID
        case measuredStoppedSeconds, terminationReason, traceUnavailableReason, distanceSamples, routingQuality
    }

    init(id: UUID = UUID(), destination: Destination, waypoints: [Destination] = [], startedAt: Date,
         endedAt: Date, distanceMeters: Double, movingSeconds: TimeInterval, rerouteCount: Int,
         arrived: Bool, originalExpectedTravelTime: TimeInterval? = nil,
         drivingScore: DrivingScore? = nil, transportMode: TransportMode? = nil,
         trace: [TripTracePoint] = [], maximumSpeedKph: Double? = nil, vehicleID: UUID? = nil,
         measuredStoppedSeconds: TimeInterval? = nil, terminationReason: TripTerminationReason? = nil,
         traceUnavailableReason: TripTraceUnavailableReason? = nil, distanceSamples: [TripDistanceSample] = []) {
        self.vehicleID = vehicleID
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
        self.drivingScore = drivingScore
        self.transportMode = transportMode
        self.trace = trace
        self.maximumSpeedKph = maximumSpeedKph
        self.measuredStoppedSeconds = measuredStoppedSeconds
        self.terminationReason = terminationReason
        self.traceUnavailableReason = traceUnavailableReason
        self.distanceSamples = distanceSamples
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
        drivingScore = try values.decodeIfPresent(DrivingScore.self, forKey: .drivingScore)
        // Keep historical journeys readable after a transport mode is retired.
        transportMode = try values.decodeIfPresent(String.self, forKey: .transportMode)
            .flatMap { TransportMode(rawValue: $0) }
        trace = try values.decodeIfPresent([TripTracePoint].self, forKey: .trace) ?? []
        maximumSpeedKph = try values.decodeIfPresent(Double.self, forKey: .maximumSpeedKph)
        vehicleID = try values.decodeIfPresent(UUID.self, forKey: .vehicleID)
        measuredStoppedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .measuredStoppedSeconds)
        terminationReason = try values.decodeIfPresent(String.self, forKey: .terminationReason)
            .flatMap(TripTerminationReason.init(rawValue:))
        traceUnavailableReason = try values.decodeIfPresent(String.self, forKey: .traceUnavailableReason)
            .flatMap(TripTraceUnavailableReason.init(rawValue:))
        distanceSamples = try values.decodeIfPresent([TripDistanceSample].self, forKey: .distanceSamples) ?? []
        routingQuality = try? values.decodeIfPresent(RouteQualityMeasurement.self, forKey: .routingQuality)
        // Invalid optional diagnostics must not make a valid trip history unreadable.
        if routingQuality?.isValid == false { routingQuality = nil }
        let safeNumericLimit = Double(Int.max) / 1_000
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              endedAt.timeIntervalSinceReferenceDate.isFinite,
              endedAt >= startedAt, duration.isFinite, duration < safeNumericLimit,
              distanceMeters.isFinite, (0..<safeNumericLimit).contains(distanceMeters),
              movingSeconds.isFinite, (0..<safeNumericLimit).contains(movingSeconds), rerouteCount >= 0,
              averageSpeedKph.isFinite, (0..<safeNumericLimit).contains(averageSpeedKph),
              originalExpectedTravelTime.map({ $0.isFinite && (0..<safeNumericLimit).contains($0) }) ?? true,
              measuredStoppedSeconds.map({ $0.isFinite && (0..<safeNumericLimit).contains($0) }) ?? true,
              maximumSpeedKph.map({ $0.isFinite && (0..<safeNumericLimit).contains($0) }) ?? true,
              trace.allSatisfy({ point in
                  point.coordinate.isValidParkedCarCoordinate && point.timestamp.timeIntervalSinceReferenceDate.isFinite
                      && (point.speedKph.map { $0.isFinite && (0..<safeNumericLimit).contains($0) } ?? true)
              }), distanceSamples.allSatisfy({ sample in
                  sample.startedAt.timeIntervalSinceReferenceDate.isFinite && sample.endedAt.timeIntervalSinceReferenceDate.isFinite
                      && sample.endedAt > sample.startedAt && sample.distanceMeters.isFinite
                      && (0..<safeNumericLimit).contains(sample.distanceMeters)
              }) else {
            throw DecodingError.dataCorruptedError(forKey: .distanceMeters, in: values,
                debugDescription: "Nieprawidłowe pomiary w zapisanym przejeździe.")
        }
    }
}

struct SearchHistoryEntry: Identifiable, Codable {
    var id = UUID()
    var destination: Destination
    var searchedAt = Date()
}

struct ParkedCar: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var coordinate: Coordinate
    var parkedAt = Date()
    var address: String?
    var floor: String?
    var sector: String?
    var spot: String?
    var note: String?
    var photoPath: String?
    var parkingExpiresAt: Date?
    var gpsAccuracy: Double?

    var mapTimestamp: String {
        if Calendar.current.isDateInToday(parkedAt) {
            return parkedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "pl_PL")))
        }
        return parkedAt.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "pl_PL")))
    }

    var destination: Destination {
        Destination(id: id, name: "Zaparkowany samochód", coordinate: coordinate, address: address)
    }

    var parkingDetails: String? {
        let details = [
            floor.map { "Poziom \($0)" },
            sector.map { "Sektor \($0)" },
            spot.map { "Miejsce \($0)" }
        ].compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }
}

@MainActor @Observable
final class LocalDataStore {
    private(set) var places: [SavedPlace] = []
    private(set) var trips: [TripRecord] = [] {
        didSet { historyRevision &+= 1 }
    }
    private(set) var historyRevision: UInt64 = 0
    private(set) var searches: [SearchHistoryEntry] = []
    private(set) var parkedCar: ParkedCar?
    var errorMessage: String?
    private let directory: URL
    @ObservationIgnored private var canWriteHistory = true
    @ObservationIgnored private var canWriteDeletionJournal = true
    @ObservationIgnored private var historyNotice: String?
    @ObservationIgnored private var pendingTrips: [UUID: TripRecord] = [:]
    @ObservationIgnored private var committedTripIDs: Set<UUID> = []
    @ObservationIgnored private var protectedJournalFiles: Set<String> = []
    @ObservationIgnored private var deletionTombstones: Set<UUID> = []
    @ObservationIgnored private var activeTrip: TripRecord?
    @ObservationIgnored private let removeLearningTrip: (UUID) -> Bool

    init(directory: URL? = nil, removeLearningTrip: ((UUID) -> Bool)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviAstra", isDirectory: true)
        self.removeLearningTrip = removeLearningTrip ?? { DrivingLearningEngine.shared.removeTrip($0) }
        do { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true) }
        catch { report(error, message: "Nie udało się przygotować lokalnego zapisu na urządzeniu.") }
        do { places = try Self.read([SavedPlace].self, from: self.directory.appendingPathComponent("places.json")) ?? [] }
        catch { report(error, message: "Nie udało się wczytać ulubionych na urządzeniu.") }
        loadTripHistory()
        do { searches = try Self.read([SearchHistoryEntry].self, from: self.directory.appendingPathComponent("searches.json")) ?? [] }
        catch { report(error, message: "Nie udało się wczytać historii wyszukiwania na urządzeniu.") }
        do { parkedCar = try Self.read(ParkedCar.self, from: self.directory.appendingPathComponent("parked-car.json")) }
        catch { report(error, message: "Nie udało się wczytać miejsca samochodu na urządzeniu.") }
        recoverTripJournal()
    }

    @discardableResult
    func saveParkedCar(at coordinate: Coordinate, parkedAt: Date = Date(), gpsAccuracy: Double? = nil) -> Bool {
        guard coordinate.isValidParkedCarCoordinate else {
            errorMessage = "Nie można zapisać nieprawidłowej pozycji samochodu."
            return false
        }
        let accuracy = gpsAccuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let car = ParkedCar(coordinate: coordinate, parkedAt: parkedAt, gpsAccuracy: accuracy)
        guard persist(car, file: "parked-car.json") else { return false }
        parkedCar = car
        return true
    }

    @discardableResult
    func updateParkedCar(_ car: ParkedCar) -> Bool {
        var updated = car
        let oldPhotoPath = parkedCar?.photoPath
        if let current = parkedCar, current.id == car.id {
            if updated.address == nil { updated.address = current.address }
            if updated.photoPath == nil { updated.photoPath = current.photoPath }
        }
        guard persist(updated, file: "parked-car.json") else { return false }
        parkedCar = updated
        if let oldPhotoPath, oldPhotoPath != updated.photoPath {
            try? FileManager.default.removeItem(at: parkedCarPhotoURL(for: oldPhotoPath))
        }
        return true
    }

    @discardableResult
    func removeParkedCar() -> Bool {
        let file = directory.appendingPathComponent("parked-car.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            if let photoPath = parkedCar?.photoPath {
                try? FileManager.default.removeItem(at: parkedCarPhotoURL(for: photoPath))
            }
            parkedCar = nil
            errorMessage = durabilityNotice
            return true
        } catch {
            report(error, message: "Nie udało się usunąć miejsca samochodu na urządzeniu.")
            return false
        }
    }

    func saveParkedCarPhoto(_ data: Data, for carID: UUID) -> String? {
        guard var car = parkedCar, car.id == carID else { return nil }
        let fileName = "parked-car-\(UUID().uuidString).photo"
        do {
            try data.write(to: parkedCarPhotoURL(for: fileName), options: .atomic)
            car.photoPath = fileName
            guard updateParkedCar(car) else {
                try? FileManager.default.removeItem(at: parkedCarPhotoURL(for: fileName))
                return nil
            }
            return fileName
        } catch {
            report(error, message: "Nie udało się zapisać zdjęcia samochodu na urządzeniu.")
            return nil
        }
    }

    func parkedCarPhotoData(for car: ParkedCar) async -> Data? {
        guard let photoPath = car.photoPath else { return nil }
        let url = parkedCarPhotoURL(for: photoPath)
        return await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
    }

    private func parkedCarPhotoURL(for fileName: String) -> URL {
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        return directory.appendingPathComponent(safeFileName)
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
                  $0.destination.name != destination.name
                      || $0.destination.coordinate != destination.coordinate
                      || $0.destination.address != destination.address
                      || $0.destination.poi != destination.poi
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
    @discardableResult
    func assignVehicle(_ vehicleID: UUID?, to tripID: UUID) -> Bool {
        var updated = trips
        guard let index = updated.firstIndex(where: { $0.id == tripID }), updated[index].transportMode == .car else { return false }
        updated[index].vehicleID = vehicleID
        if pendingTrips[tripID] != nil {
            guard persist(updated[index], file: pendingFile(tripID)) else { return false }
            pendingTrips[tripID] = updated[index]
        }
        guard persist(updated, file: "trips.json") else { return false }
        trips = updated
        committedTripIDs = Set(updated.map(\.id))
        return true
    }

    /// Checkpoints are a separate atomic file, never a rewrite of the archive.
    @discardableResult
    func saveActiveTrip(_ trip: TripRecord) -> Bool {
        guard !deletionTombstones.contains(trip.id) else { return false }
        if !canWriteDeletionJournal {
            // An unreadable deletion journal must not let a new session replace
            // an older checkpoint whose deletion status we cannot establish.
            return persist(trip, file: isolatedActiveFile(trip.id))
        }
        if activeTrip == nil {
            let url = directory.appendingPathComponent("active-trip.json")
            do { activeTrip = try Self.read(TripRecord.self, from: url) }
            catch {
                preserveUnreadableJournal(url)
                guard !FileManager.default.fileExists(atPath: url.path) else { return false }
            }
        }
        if let previous = activeTrip, previous.id != trip.id, !committedTripIDs.contains(previous.id) {
            var finalized = pendingTrips[previous.id] ?? previous
            if pendingTrips[previous.id] == nil {
                finalized.arrived = false
                finalized.terminationReason = .interruptedRecovered
                finalized.drivingScore = nil
            }
            guard persist(finalized, file: pendingFile(finalized.id)) else { return false }
            pendingTrips[finalized.id] = finalized
        }
        guard persist(trip, file: "active-trip.json") else { return false }
        activeTrip = trip
        return true
    }

    /// The final record is journaled before replacing the archive. Failed writes
    /// remain queued and cannot erase the last durable active-trip checkpoint.
    @discardableResult
    func addTrip(_ trip: TripRecord) -> Bool {
        guard !deletionTombstones.contains(trip.id) else { return false }
        pendingTrips[trip.id] = trip
        let journaled = persist(trip, file: pendingFile(trip.id))
        retryPendingHistoryWrites()
        if pendingTrips[trip.id] == nil { return true }
        if journaled {
            // A durable journal also lets the user inspect the unsynced record.
            upsertVisibleTrip(trip)
            errorMessage = "Przejazd zabezpieczono w zapisie roboczym. Zapis historii zostanie ponowiony."
        }
        return false
    }

    /// Called on launch and when returning to the foreground; all steps are
    /// idempotent so a process exit between two files cannot resurrect a trip.
    func retryPendingHistoryWrites() {
        guard !pendingTrips.isEmpty || !deletionTombstones.isEmpty else { return }
        // A small final journal may fit even when replacing the full archive
        // fails. Retry it independently for records previously held only in RAM.
        for trip in pendingTrips.values where !deletionTombstones.contains(trip.id) {
            _ = persist(trip, file: pendingFile(trip.id))
        }
        var updated = trips.filter { !deletionTombstones.contains($0.id) }
        for trip in pendingTrips.values where !deletionTombstones.contains(trip.id) {
            updated.removeAll { $0.id == trip.id }
            updated.append(trip)
        }
        updated.sort { $0.startedAt > $1.startedAt }
        retainHistoryGeometry(in: &updated)
        let archiveSaved = persist(updated, file: "trips.json")
        if archiveSaved {
            trips = updated
            committedTripIDs = Set(updated.map(\.id))
        }
        var cleanupFailed = false
        for id in Array(pendingTrips.keys) where archiveSaved {
            guard removeActiveJournal(for: id), removeJournalFile(isolatedActiveFile(id)) else {
                cleanupFailed = true
                continue
            }
            guard removeJournalFile(pendingFile(id)) else { cleanupFailed = true; continue }
            pendingTrips.removeValue(forKey: id)
        }
        var remaining = deletionTombstones
        for id in deletionTombstones {
            let removedPending = removeJournalFile(pendingFile(id))
            let removedActive = removeActiveJournal(for: id) && removeJournalFile(isolatedActiveFile(id))
            let removedLearning = removeLearningTrip(id)
            if archiveSaved && removedPending && removedActive && removedLearning {
                remaining.remove(id)
            } else { cleanupFailed = true }
        }
        if remaining != deletionTombstones {
            if persist(remaining, file: "trip-deletions.json") { deletionTombstones = remaining }
            else { cleanupFailed = true }
        }
        if cleanupFailed && archiveSaved {
            errorMessage = "Zmianę historii zapisano. Usuwanie pozostałych danych przejazdu zostanie ponowione."
        } else if archiveSaved {
            errorMessage = durabilityNotice
        }
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
    @discardableResult
    func removeTrip(_ id: UUID) -> Bool {
        guard canWriteDeletionJournal else {
            errorMessage = durabilityNotice
            return false
        }
        var tombstones = deletionTombstones
        tombstones.insert(id)
        guard persist(tombstones, file: "trip-deletions.json") else { return false }
        deletionTombstones = tombstones
        trips.removeAll { $0.id == id }
        pendingTrips.removeValue(forKey: id)
        retryPendingHistoryWrites()
        return true
    }
    @discardableResult private func persist<T: Encodable>(_ value: T, file: String) -> Bool {
        guard !protectedJournalFiles.contains(file) else {
            errorMessage = "Nie można zastąpić nieczytelnego zapisu roboczego, dopóki jego kopia nie zostanie zabezpieczona."
            return false
        }
        if file == "trips.json", !canWriteHistory {
            errorMessage = historyNotice ?? "Historia wymaga odzyskania. Oryginalny plik pozostawiono bez zmian."
            return false
        }
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            errorMessage = durabilityNotice
            return true
        } catch {
            report(error, message: "Nie udało się zapisać danych na urządzeniu. Zwolnij miejsce i spróbuj ponownie.")
            return false
        }
    }

    private func loadTripHistory() {
        do {
            deletionTombstones = try Self.read(Set<UUID>.self,
                from: directory.appendingPathComponent("trip-deletions.json")) ?? []
        } catch {
            canWriteHistory = false
            canWriteDeletionJournal = false
            historyNotice = "Nie udało się odczytać oczekujących usunięć historii. Zapis historii wstrzymano, aby chronić dane."
            report(error, message: historyNotice!)
        }
        let url = directory.appendingPathComponent("trips.json")
        do {
            trips = try Self.read([TripRecord].self, from: url) ?? []
        } catch {
            report(error, message: "Nie udało się odczytać całej historii przejazdów.")
            do {
                // Preserve the exact source before allowing any repaired writes.
                let original = try Data(contentsOf: url)
                let initialBackup = directory.appendingPathComponent("trips-recovery-original.json")
                if (try? Data(contentsOf: initialBackup)) != original {
                    let backup = FileManager.default.fileExists(atPath: initialBackup.path)
                        ? directory.appendingPathComponent("trips-recovery-\(UUID().uuidString).json") : initialBackup
                    try original.write(to: backup, options: .atomic)
                }
                let elements = try JSONSerialization.jsonObject(with: original) as? [Any] ?? []
                var recovered: [TripRecord] = []
                var identifiers: Set<UUID> = []
                for element in elements {
                    guard JSONSerialization.isValidJSONObject(element),
                          let data = try? JSONSerialization.data(withJSONObject: element),
                          let trip = try? JSONDecoder().decode(TripRecord.self, from: data),
                          identifiers.insert(trip.id).inserted else { continue }
                    recovered.append(trip)
                }
                guard !recovered.isEmpty else { throw HistoryRecoveryFailure.noReadableRecords }
                trips = recovered
                historyNotice = "Odzyskano poprawne wpisy historii. Część wpisów jest nieczytelna; oryginalny plik zachowano w kopii odzyskiwania."
                errorMessage = historyNotice
            } catch {
                canWriteHistory = false
                historyNotice = "Nie udało się wczytać historii. Oryginalny plik pozostawiono bez zmian; nowe przejazdy są zabezpieczane osobno."
                report(error, message: historyNotice!)
            }
        }
        trips.removeAll { deletionTombstones.contains($0.id) }
        if !canWriteDeletionJournal { trips = [] }
        trips.sort { $0.startedAt > $1.startedAt }
        committedTripIDs = Set(trips.map(\.id))
    }

    private func recoverTripJournal() {
        guard canWriteDeletionJournal else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix("pending-trip-") && file.pathExtension == "json" {
                do {
                    guard let trip = try Self.read(TripRecord.self, from: file) else { continue }
                    if deletionTombstones.contains(trip.id) { continue }
                    // A completed archive write may precede journal cleanup.
                    // Never replace later edits with such an old journal copy.
                    if trips.contains(where: { $0.id == trip.id }) {
                        _ = removeJournalFile(file.lastPathComponent)
                    } else { pendingTrips[trip.id] = trip }
                } catch {
                    preserveUnreadableJournal(file)
                    report(error, message: "Nie udało się odczytać jednego zapisu roboczego przejazdu. Plik zachowano do odzyskania.")
                }
            }
            for file in files where file.lastPathComponent.hasPrefix("isolated-active-trip-") && file.pathExtension == "json" {
                do {
                    guard var checkpoint = try Self.read(TripRecord.self, from: file) else { continue }
                    if deletionTombstones.contains(checkpoint.id) { continue }
                    if committedTripIDs.contains(checkpoint.id) {
                        _ = removeJournalFile(file.lastPathComponent)
                    } else if pendingTrips[checkpoint.id] == nil {
                        checkpoint.arrived = false
                        checkpoint.terminationReason = .interruptedRecovered
                        checkpoint.drivingScore = nil
                        pendingTrips[checkpoint.id] = checkpoint
                        _ = persist(checkpoint, file: pendingFile(checkpoint.id))
                    }
                } catch {
                    preserveUnreadableJournal(file)
                    report(error, message: "Nie udało się odczytać jednego zapisu roboczego przejazdu. Plik zachowano do odzyskania.")
                }
            }
        } catch {
            report(error, message: "Nie udało się odczytać katalogu zapisów roboczych. Zachowano je na urządzeniu.")
        }
        // Read the active checkpoint independently of directory enumeration.
        do {
            let activeURL = directory.appendingPathComponent("active-trip.json")
            let checkpoint: TripRecord?
            do { checkpoint = try Self.read(TripRecord.self, from: activeURL) }
            catch {
                preserveUnreadableJournal(activeURL)
                report(error, message: "Nie udało się odczytać ostatniego zapisu roboczego podróży. Plik zachowano do odzyskania.")
                checkpoint = nil
            }
            if var checkpoint {
                activeTrip = checkpoint
                if deletionTombstones.contains(checkpoint.id) {
                    // The tombstone cleanup also removes the active checkpoint.
                } else if trips.contains(where: { $0.id == checkpoint.id }) {
                    if removeJournalFile("active-trip.json") { activeTrip = nil }
                } else if pendingTrips[checkpoint.id] == nil {
                    checkpoint.arrived = false
                    checkpoint.terminationReason = .interruptedRecovered
                    checkpoint.drivingScore = nil
                    pendingTrips[checkpoint.id] = checkpoint
                    _ = persist(checkpoint, file: pendingFile(checkpoint.id))
                }
            }
        }
        retryPendingHistoryWrites()
        for trip in pendingTrips.values where !deletionTombstones.contains(trip.id) { upsertVisibleTrip(trip) }
    }

    private func retainHistoryGeometry(in trips: inout [TripRecord]) {
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -365, to: Date()) ?? .distantPast
        for index in trips.indices where (index >= 300 || trips[index].startedAt < cutoff) && !trips[index].trace.isEmpty {
            if trips[index].distanceSamples.isEmpty {
                // This mirrors legacy fuel-distance acceptance; expiry must not
                // change the contribution of a trip crossing a fuel purchase.
                let trip = trips[index]
                trips[index].distanceSamples = zip(trip.trace, trip.trace.dropFirst()).compactMap { left, right in
                    let seconds = right.timestamp.timeIntervalSince(left.timestamp)
                    guard !right.startsSegment, seconds > 0, seconds <= 30,
                          left.timestamp >= trip.startedAt, right.timestamp <= trip.endedAt,
                          [left.coordinate, right.coordinate].allSatisfy(\.isValidParkedCarCoordinate) else { return nil }
                    let distance = left.coordinate.distance(to: right.coordinate)
                    guard distance.isFinite, distance <= max(30, seconds * 60),
                          (right.speedKph.map { $0.isFinite && $0 >= 1.8 } ?? (distance / seconds >= 0.5)) else { return nil }
                    return TripDistanceSample(startedAt: left.timestamp, endedAt: right.timestamp, distanceMeters: distance)
                }
            }
            trips[index].trace = []
            trips[index].traceUnavailableReason = .retention
        }
    }

    private func upsertVisibleTrip(_ trip: TripRecord) {
        trips.removeAll { $0.id == trip.id }
        trips.append(trip)
        trips.sort { $0.startedAt > $1.startedAt }
    }

    private func pendingFile(_ id: UUID) -> String { "pending-trip-\(id.uuidString).json" }
    private func isolatedActiveFile(_ id: UUID) -> String { "isolated-active-trip-\(id.uuidString).json" }

    private var durabilityNotice: String? {
        if let historyNotice { return historyNotice }
        if !pendingTrips.isEmpty { return "Nie wszystkie przejazdy zapisano w historii. Zapis zostanie ponowiony." }
        if !deletionTombstones.isEmpty { return "Usuwanie pozostałych danych przejazdu zostanie ponowione." }
        return nil
    }

    private func removeActiveJournal(for id: UUID) -> Bool {
        do {
            // Verify the file itself: a failed earlier directory listing or
            // decode is not evidence that an active checkpoint does not exist.
            let stored = try Self.read(TripRecord.self, from: directory.appendingPathComponent("active-trip.json"))
            guard stored?.id == id else { return true }
            guard removeJournalFile("active-trip.json") else { return false }
            if activeTrip?.id == id { activeTrip = nil }
            return true
        } catch {
            report(error, message: "Nie udało się sprawdzić zapisu roboczego usuwanej podróży. Usunięcie zostanie ponowione.")
            return false
        }
    }

    private func preserveUnreadableJournal(_ url: URL) {
        do {
            let backup = directory.appendingPathComponent("history-journal-recovery-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: backup)
            protectedJournalFiles.remove(url.lastPathComponent)
            // The preserved copy prevents repeated recovery of the same bad file.
            try? FileManager.default.removeItem(at: url)
        } catch {
            protectedJournalFiles.insert(url.lastPathComponent)
            report(error, message: "Nie udało się zabezpieczyć nieczytelnego zapisu roboczego. Oryginalny plik pozostawiono bez zmian.")
        }
    }

    private func removeJournalFile(_ name: String) -> Bool {
        let url = directory.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return true
        } catch {
            report(error, message: "Nie udało się usunąć pomocniczego zapisu przejazdu. Usunięcie zostanie ponowione.")
            return false
        }
    }

    private func report(_ error: Error, message: String) {
        NSLog("[LocalDataStore] %@", String(describing: error))
        errorMessage = message
    }

    private enum HistoryRecoveryFailure: Error { case noReadableRecords }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Coordinate {
    var isValidParkedCarCoordinate: Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}
