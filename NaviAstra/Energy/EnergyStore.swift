import Foundation
import Observation

@MainActor @Observable
final class EnergyStore {
    private struct Archive: Codable {
        var vehicles: [EnergyVehicle] = []
        var entries: [EnergyEntry] = []
        var selectedVehicleID: UUID?
    }
    private var archive = Archive()
    private(set) var errorMessage: String?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var canWrite = true
    /// The archive owner supplies its revision; standalone callers remain uncached.
    @ObservationIgnored var historyRevisionProvider: (() -> UInt64)?
    @ObservationIgnored private var periodCache: [PeriodCacheKey: [EnergyPeriod]] = [:]
    @ObservationIgnored private var cachedHistoryRevision: UInt64?
    private struct PeriodCacheKey: Hashable {
        let vehicleID: UUID
        let kind: EnergyKind
        let tripIDs: [UUID]
        let entryIDs: [UUID]
    }
    var vehicles: [EnergyVehicle] { archive.vehicles }
    var entries: [EnergyEntry] { archive.entries }
    var selectedVehicle: EnergyVehicle? { vehicles.first { $0.id == archive.selectedVehicleID } }

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviAstra", isDirectory: true)
        url = directory.appendingPathComponent("energy.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            }
        } catch {
            canWrite = false
            errorMessage = "Nie udało się wczytać danych paliwa. Zapis został wstrzymany, aby zachować dotychczasowy plik."
            NSLog("EnergyStore load: %@", String(describing: error))
        }
    }

    private func commit(_ updated: Archive) -> Bool {
        guard canWrite else { return false }
        do {
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            archive = updated
            periodCache.removeAll()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Nie udało się zapisać danych paliwa na urządzeniu. Spróbuj ponownie."
            NSLog("EnergyStore save: %@", String(describing: error))
            return false
        }
    }

    @discardableResult func select(_ id: UUID?) -> Bool {
        guard id == nil || vehicles.contains(where: { $0.id == id }) else { return false }
        var updated = archive
        updated.selectedVehicleID = id
        return commit(updated)
    }

    @discardableResult func saveVehicle(_ vehicle: EnergyVehicle) -> Bool {
        guard !vehicle.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              vehicle.fuel != .electricity,
              [vehicle.tankCapacity, vehicle.batteryCapacity].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }) else {
            errorMessage = "Podaj nazwę i prawidłowe pojemności pojazdu."
            return false
        }
        // Existing records retain a consistent energy type.
        if let previous = vehicles.first(where: { $0.id == vehicle.id }),
           entries.contains(where: { $0.vehicleID == vehicle.id }), previous.kinds != vehicle.kinds {
            errorMessage = "Pojazd ma już wpisy. Dodaj osobny profil, aby zmienić rodzaj energii."
            return false
        }
        var updated = archive
        updated.vehicles.removeAll { $0.id == vehicle.id }
        updated.vehicles.append(vehicle)
        if updated.selectedVehicleID == nil { updated.selectedVehicleID = vehicle.id }
        return commit(updated)
    }

    @discardableResult func removeVehicle(_ id: UUID) -> Bool {
        guard !entries.contains(where: { $0.vehicleID == id }) else {
            errorMessage = "Najpierw usuń wpisy tego pojazdu."
            return false
        }
        var updated = archive
        updated.vehicles.removeAll { $0.id == id }
        if updated.selectedVehicleID == id { updated.selectedVehicleID = updated.vehicles.first?.id }
        return commit(updated)
    }

    @discardableResult func saveEntry(_ entry: EnergyEntry) -> Bool {
        guard let vehicle = vehicles.first(where: { $0.id == entry.vehicleID }), vehicle.kinds.contains(entry.kind),
              entry.quantity.isFinite, entry.quantity > 0,
              entry.unitPrice.isFinite, entry.unitPrice >= 0,
              entry.totalPrice.isFinite, entry.totalPrice >= 0,
              entry.kind != .electricity || entry.fuelLevelBefore == nil || entry.fuelLevelBefore == .unspecified,
              entry.date <= Date(), entry.odometer.map({ $0.isFinite && $0 >= 0 }) ?? true,
              abs(entry.quantity * entry.unitPrice - entry.totalPrice) <= 0.02 else {
            errorMessage = "Sprawdź ilość, cenę, kwotę, datę i przebieg."
            return false
        }
        let ordered = entries.filter { $0.vehicleID == entry.vehicleID && $0.id != entry.id } + [entry]
        let readings = ordered.sorted { $0.date < $1.date }.compactMap(\.odometer)
        guard zip(readings, readings.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            errorMessage = "Przebieg nie może maleć między wpisami."
            return false
        }
        guard !entries.contains(where: { $0.id != entry.id && $0.vehicleID == entry.vehicleID && $0.kind == entry.kind && $0.date == entry.date }) else {
            errorMessage = "Wpis tego rodzaju z tą datą już istnieje."
            return false
        }
        var updated = archive
        updated.entries.removeAll { $0.id == entry.id }
        updated.entries.append(entry)
        return commit(updated)
    }

    @discardableResult func removeEntry(_ id: UUID) -> Bool {
        var updated = archive
        updated.entries.removeAll { $0.id == id }
        return commit(updated)
    }

    func periods(for vehicle: EnergyVehicle, kind: EnergyKind, trips: [TripRecord]) -> [EnergyPeriod] {
        cachedPeriods(vehicleID: vehicle.id, kind: kind, entries: entries, trips: trips)
    }

    private func cachedPeriods(vehicleID: UUID, kind: EnergyKind,
                               entries: [EnergyEntry], trips: [TripRecord]) -> [EnergyPeriod] {
        guard let revision = historyRevisionProvider?() else {
            return EnergyCalculator.periods(vehicleID: vehicleID, kind: kind, entries: entries, trips: trips)
        }
        if cachedHistoryRevision != revision {
            periodCache.removeAll()
            cachedHistoryRevision = revision
        }
        let key = PeriodCacheKey(vehicleID: vehicleID, kind: kind,
                                 tripIDs: trips.map(\.id), entryIDs: entries.map(\.id))
        if let periods = periodCache[key] { return periods }
        let periods = EnergyCalculator.periods(vehicleID: vehicleID, kind: kind, entries: entries, trips: trips)
        if periodCache.count >= 32 { periodCache.removeAll() }
        periodCache[key] = periods
        return periods
    }

    func estimate(vehicleID: UUID?, kilometers: Double, at date: Date = Date(), trips: [TripRecord]) -> EnergyEstimate? {
        guard kilometers.isFinite, kilometers >= 0,
              let vehicle = vehicles.first(where: { $0.id == vehicleID }) else { return nil }
        let historical = entries.filter { $0.date <= date }
        var components: [EnergyEstimate.Component] = []
        for kind in vehicle.kinds {
            let periods = cachedPeriods(vehicleID: vehicle.id, kind: kind, entries: historical, trips: trips)
            guard let consumption = EnergyCalculator.average(periods),
                  let price = historical.filter({ $0.vehicleID == vehicle.id && $0.kind == kind })
                    .max(by: { $0.date < $1.date })?.unitPrice else { return nil }
            let quantity = consumption * kilometers / 100
            components.append(.init(kind: kind, consumptionPer100Km: consumption,
                                    quantity: quantity, cost: quantity * price,
                                    measurementDescription: EnergyCalculator.measurementDescription(periods)))
        }
        return EnergyEstimate(components: components)
    }

    /// Retrospective usage uses all available measurements, including the fill closing the trip's cycle.
    func estimate(for trip: TripRecord, trips: [TripRecord]) -> EnergyEstimate? {
        guard trip.transportMode == .car, trip.distanceMeters.isFinite, trip.distanceMeters > 0 else { return nil }
        return estimate(vehicleID: trip.vehicleID, kilometers: trip.distanceMeters / 1000, trips: trips)
    }

    func consumptionUnavailableReason(for vehicle: EnergyVehicle, kind: EnergyKind, trips: [TripRecord]) -> String {
        let cycles = periods(for: vehicle, kind: kind, trips: trips)
        if cycles.isEmpty {
            if kind == .electricity { return "Zapisz dwa ładowania do 100%, aby obliczyć zużycie." }
            let matching = entries.filter { $0.vehicleID == vehicle.id && $0.kind == kind }
            if let last = matching.filter({ $0.startsAtReserve || $0.full }).max(by: { $0.date < $1.date }) {
                if last.startsAtReserve && !last.full {
                    return "Zapisano początek pomiaru na rezerwie. Przy kolejnym tankowaniu na podobnym poziomie zaznacz „Na rezerwie”. Dodaj przebieg lub zapisuj przejazdy, aby obliczyć szacowane spalanie."
                }
                return "Zapisano pełny zbiornik. Kolejne tankowanie do pełna pozwoli obliczyć spalanie; doliczymy tankowania po drodze. Możesz też mierzyć od rezerwy do rezerwy."
            }
            return "Tankujesz za określoną kwotę? Przy dwóch tankowaniach na podobnym poziomie paliwa wybierz „Na rezerwie”. Możesz też mierzyć między dwoma pełnymi zbiornikami. Starsze wpisy uzupełnisz przez „Edytuj” w historii."
        }
        if cycles.contains(where: { !$0.usesOdometer }) {
            return "Brakuje dystansu między wpisami. Uzupełnij licznik lub przypisz zapisane przejazdy do tego pojazdu."
        }
        return "Przebieg na końcu okresu musi być większy niż na początku. Sprawdź licznik we wpisach."
    }
}
