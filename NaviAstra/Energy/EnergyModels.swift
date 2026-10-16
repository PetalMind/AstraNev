import Foundation

enum VehiclePowertrain: String, Codable, CaseIterable, Identifiable {
    case combustion, electric, plugInHybrid
    var id: Self { self }
    var title: String {
        switch self {
        case .combustion: "Spalinowy"
        case .electric: "Elektryczny"
        case .plugInHybrid: "Hybryda plug-in"
        }
    }
}

enum EnergyKind: String, Codable, CaseIterable, Identifiable {
    case pb95, pb98, diesel, lpg, electricity
    var id: Self { self }
    var title: String {
        switch self {
        case .pb95: "Pb95"
        case .pb98: "Pb98"
        case .diesel: "Diesel"
        case .lpg: "LPG"
        case .electricity: "Prąd"
        }
    }
    var unit: String { self == .electricity ? "kWh" : "L" }
    var symbol: String { self == .electricity ? "bolt.car.fill" : "fuelpump.fill" }
}

struct EnergyVehicle: Identifiable, Codable {
    var id = UUID()
    var name: String
    var powertrain: VehiclePowertrain = .combustion
    var fuel: EnergyKind = .pb95
    var tankCapacity: Double? = nil
    var batteryCapacity: Double? = nil
    var kinds: [EnergyKind] {
        switch powertrain {
        case .combustion: [fuel]
        case .electric: [.electricity]
        case .plugInHybrid: [fuel, .electricity]
        }
    }
}

enum FuelLevelBefore: String, Codable, CaseIterable, Identifiable {
    case unspecified, reserve, aboveReserve
    var id: Self { self }
    var title: String {
        switch self {
        case .unspecified: "Nie określono"
        case .reserve: "Na rezerwie"
        case .aboveReserve: "Powyżej rezerwy"
        }
    }
}

struct EnergyEntry: Identifiable, Codable {
    var id = UUID()
    var vehicleID: UUID
    var date = Date()
    var kind: EnergyKind
    var quantity: Double
    var unitPrice: Double
    var totalPrice: Double
    var odometer: Double?
    var full: Bool
    var station: String
    var coordinate: Coordinate?
    // Optional for archives saved before reserve measurements were supported.
    var fuelLevelBefore: FuelLevelBefore? = nil
    var startsAtReserve: Bool { kind != .electricity && fuelLevelBefore == .reserve }
}

enum EnergyMeasurement {
    case fullToFull, reserveToReserve
    var title: String {
        switch self {
        case .fullToFull: "Od pełnego do pełnego"
        case .reserveToReserve: "Szacunek od rezerwy do rezerwy"
        }
    }
}

struct EnergyPeriod: Identifiable {
    var id: UUID { end.id }
    let start: EnergyEntry
    let end: EnergyEntry
    let entries: [EnergyEntry]
    let trips: [TripRecord]
    let recordedKilometers: Double
    let kilometers: Double?
    let usesOdometer: Bool
    let measurement: EnergyMeasurement
    var quantity: Double { entries.reduce(0) { $0 + $1.quantity } }
    var expense: Double { entries.reduce(0) { $0 + $1.totalPrice } }
    var consumption: Double? { kilometers.map { quantity / $0 * 100 } }
    var costPerKm: Double? { kilometers.map { expense / $0 } }
    func overlaps(_ other: EnergyPeriod) -> Bool {
        start.date < other.end.date && end.date > other.start.date
    }
    var quality: String {
        if kilometers == nil { return "Brak prawidłowego dystansu" }
        if start.kind == .electricity { return "Energia ładowania · obejmuje straty" }
        if measurement == .reserveToReserve {
            return usesOdometer
                ? "Szacunek z licznika · różny poziom rezerwy wpływa na wynik"
                : "Szacunek z rezerwy i zapisanych przejazdów · historia może być niepełna"
        }
        return usesOdometer ? "Wysoka · pełny zbiornik i licznik" : "Szacowana · tylko zapisane przejazdy"
    }
}

struct EnergyEstimate {
    struct Component {
        let kind: EnergyKind
        let consumptionPer100Km: Double
        let quantity: Double
        let cost: Double
        let measurementDescription: String
    }
    let components: [Component]
    var cost: Double { components.reduce(0) { $0 + $1.cost } }
}

/// Full cycles use (start, end] purchases; reserve cycles use [start, end) purchases.
/// Prefer full cycles wherever intervals overlap, so distance never contributes twice.
enum EnergyCalculator {
    static func periods(vehicleID: UUID, kind: EnergyKind, entries: [EnergyEntry], trips: [TripRecord]) -> [EnergyPeriod] {
        let ordered = entries.filter { $0.vehicleID == vehicleID && $0.kind == kind }
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let fullIndices = ordered.indices.filter { ordered[$0].full }
        let reserveIndices = ordered.indices.filter { ordered[$0].startsAtReserve }
        let fullRanges = zip(fullIndices, fullIndices.dropFirst()).map { ($0, $1, EnergyMeasurement.fullToFull) }
        let reserveRanges = zip(reserveIndices, reserveIndices.dropFirst()).map { ($0, $1, EnergyMeasurement.reserveToReserve) }
        let candidates = (fullRanges + reserveRanges).map { first, last, measurement in
            let start = ordered[first]
            let entry = ordered[last]
            let purchases = measurement == .fullToFull
                ? Array(ordered[(first + 1)...last]) : Array(ordered[first..<last])
            let contributions = trips.compactMap { trip -> (TripRecord, Double)? in
                guard trip.vehicleID == vehicleID,
                      let distance = recordedKilometers(trip, from: start.date, to: entry.date) else { return nil }
                return (trip, distance)
            }
            let matching = contributions.map { $0.0 }
            let gpsKm = contributions.reduce(0) { $0 + $1.1 }
            let hasOdometer = start.odometer != nil && entry.odometer != nil
            let distance: Double?
            if let first = start.odometer, let last = entry.odometer {
                let delta = last - first
                // Never silently substitute GPS for an invalid pair of odometer readings.
                distance = delta.isFinite && delta > 0 ? delta : nil
            } else {
                distance = gpsKm > 0 ? gpsKm : nil
            }
            return EnergyPeriod(start: start, end: entry, entries: purchases, trips: matching,
                                recordedKilometers: gpsKm, kilometers: distance, usesOdometer: hasOdometer,
                                measurement: measurement)
        }
        let validFull = candidates.filter { $0.measurement == .fullToFull && $0.consumption != nil }
        let reserves = candidates.filter { candidate in
            candidate.measurement == .reserveToReserve && !validFull.contains { $0.overlaps(candidate) }
        }
        let invalidFull = candidates.filter { candidate in
            candidate.measurement == .fullToFull && candidate.consumption == nil &&
                !reserves.contains { $0.overlaps(candidate) }
        }
        return (validFull + invalidFull + reserves).sorted { $0.end.date < $1.end.date }
    }

    static func measurementDescription(_ periods: [EnergyPeriod]) -> String {
        let valid = periods.filter { $0.consumption != nil }
        let reserve = valid.contains { $0.measurement == .reserveToReserve }
        let full = valid.contains { $0.measurement == .fullToFull }
        let method = reserve
            ? (full ? "Pełne zbiorniki i szacunki między rezerwami."
                    : "Szacunek od rezerwy do rezerwy. Różny poziom rezerwy wpływa na wynik.")
            : "Pomiar między pełnymi wpisami."
        return method + (valid.allSatisfy { $0.usesOdometer }
            ? " Dystans z licznika." : " Dystans obejmuje zapisane przejazdy; historia może być niepełna.")
    }

    /// Crossing fills only receive their share of continuous, accepted trace segments.
    /// Interrupted trips and GPS gaps never contribute invented kilometers.
    static func recordedKilometers(_ trip: TripRecord, from start: Date, to end: Date) -> Double? {
        guard trip.arrived, trip.transportMode == .car, end > start,
              trip.endedAt > trip.startedAt, trip.endedAt > start, trip.startedAt < end,
              trip.distanceMeters.isFinite, trip.distanceMeters > 0 else { return nil }
        if trip.startedAt >= start, trip.endedAt <= end { return trip.distanceMeters / 1000 }
        var meters = 0.0
        for (left, right) in zip(trip.trace, trip.trace.dropFirst()) {
            let seconds = right.timestamp.timeIntervalSince(left.timestamp)
            guard !right.startsSegment, seconds > 0, seconds <= 30,
                  left.timestamp >= trip.startedAt, right.timestamp <= trip.endedAt,
                  [left.coordinate, right.coordinate].allSatisfy({
                      $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
                  }) else { continue }
            let clippedStart = max(start, left.timestamp)
            let clippedEnd = min(end, right.timestamp)
            guard clippedEnd > clippedStart else { continue }
            let distance = left.coordinate.distance(to: right.coordinate)
            guard distance.isFinite, distance <= max(30, seconds * 60),
                  (right.speedKph.map { $0.isFinite && $0 >= 1.8 } ?? (distance / seconds >= 0.5)) else { continue }
            meters += distance * clippedEnd.timeIntervalSince(clippedStart) / seconds
        }
        return meters > 0 ? meters / 1000 : nil
    }

    static func average(_ periods: [EnergyPeriod]) -> Double? {
        let valid = periods.filter { $0.kilometers != nil }
        let distance = valid.reduce(0) { $0 + ($1.kilometers ?? 0) }
        guard distance > 0 else { return nil }
        return valid.reduce(0) { $0 + $1.quantity } / distance * 100
    }

    static func estimate(vehicle: EnergyVehicle, kilometers: Double, date: Date,
                         entries: [EnergyEntry], trips: [TripRecord]) -> EnergyEstimate? {
        guard kilometers.isFinite, kilometers >= 0 else { return nil }
        let historical = entries.filter { $0.date <= date }
        var components: [EnergyEstimate.Component] = []
        for kind in vehicle.kinds {
            let cycles = periods(vehicleID: vehicle.id, kind: kind, entries: historical, trips: trips)
            guard let consumption = average(cycles),
                  let price = historical.filter({ $0.vehicleID == vehicle.id && $0.kind == kind })
                    .max(by: { $0.date < $1.date })?.unitPrice else { return nil }
            let quantity = consumption * kilometers / 100
            components.append(.init(kind: kind, consumptionPer100Km: consumption,
                                    quantity: quantity, cost: quantity * price,
                                    measurementDescription: measurementDescription(cycles)))
        }
        return EnergyEstimate(components: components)
    }
}
