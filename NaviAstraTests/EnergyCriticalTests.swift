import Foundation
import Testing
@testable import NaviAstra

/// Critical energy accounting and durable data; no view or field-level tests.
@MainActor
struct EnergyCriticalTests {
    private func entry(_ vehicle: EnergyVehicle, _ days: Double, _ quantity: Double,
                       _ odometer: Double?, full: Bool, kind: EnergyKind = .pb95) -> EnergyEntry {
        EnergyEntry(vehicleID: vehicle.id, date: Date(timeIntervalSince1970: days * 86400), kind: kind,
                    quantity: quantity, unitPrice: 6, totalPrice: quantity * 6,
                    odometer: odometer, full: full, station: "", coordinate: nil)
    }

    @Test func partialFillsOdometerAndVehicleIsolationSurviveEditsAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnergyStore(directory: directory)
        let vehicle = EnergyVehicle(name: "Samochód")
        let other = EnergyVehicle(name: "Drugi samochód")
        #expect(store.saveVehicle(vehicle))
        #expect(store.saveVehicle(other))
        let a = entry(vehicle, 1, 40, 1000, full: true)
        var b = entry(vehicle, 2, 10, 1250, full: false)
        let c = entry(vehicle, 3, 25, 1430, full: true)
        #expect(store.saveEntry(c)) // Backdated insert must reorder the whole cycle.
        #expect(store.saveEntry(a))
        #expect(store.saveEntry(b))
        #expect(store.saveEntry(entry(other, 2, 100, 0, full: true)))
        let reloaded = EnergyStore(directory: directory)
        var period = try #require(reloaded.periods(for: vehicle, kind: .pb95, trips: []).first)
        #expect(period.quantity == 35)
        #expect(period.kilometers == 430)
        #expect(abs(try #require(period.consumption) - 8.1395348837) < 0.00001)
        #expect(abs(try #require(period.costPerKm) - 210 / 430.0) < 0.00001)
        b.quantity = 12; b.totalPrice = 72
        #expect(reloaded.saveEntry(b))
        period = try #require(reloaded.periods(for: vehicle, kind: .pb95, trips: []).first)
        #expect(period.quantity == 37)
        #expect(reloaded.removeEntry(b.id))
        #expect(reloaded.periods(for: vehicle, kind: .pb95, trips: []).first?.quantity == 25)
        #expect(!reloaded.removeVehicle(vehicle.id))
        var invalid = c; invalid.odometer = 900
        #expect(!reloaded.saveEntry(invalid))
        #expect(EnergyStore(directory: directory).entries.first(where: { $0.id == c.id })?.odometer == 1430)
        // Malformed storage must never be overwritten by an empty archive.
        let url = directory.appendingPathComponent("energy.json")
        let damaged = Data("damaged".utf8)
        try damaged.write(to: url)
        let broken = EnergyStore(directory: directory)
        #expect(broken.errorMessage != nil)
        #expect(!broken.saveVehicle(vehicle))
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func recordedTripsAndHybridEnergyNeverInventDistanceOrMissingCosts() throws {
        var vehicle = EnergyVehicle(name: "PHEV")
        vehicle.powertrain = .plugInHybrid
        let another = EnergyVehicle(name: "Inny")
        let a = entry(vehicle, 1, 40, nil, full: true)
        let b = entry(vehicle, 3, 35, nil, full: true)
        func trip(_ id: UUID?, mode: TransportMode = .car, start: Double = 1.5, end: Double = 2.5) -> TripRecord {
            TripRecord(destination: Destination(name: "Cel", coordinate: Coordinate(latitude: 52, longitude: 21)),
                startedAt: Date(timeIntervalSince1970: start * 86400), endedAt: Date(timeIntervalSince1970: end * 86400),
                distanceMeters: 430000, movingSeconds: 7200, rerouteCount: 0, arrived: true,
                transportMode: mode, vehicleID: id)
        }
        let encodedTrip = try JSONEncoder().encode(trip(vehicle.id))
        var legacyJSON = try #require(JSONSerialization.jsonObject(with: encodedTrip) as? [String: Any])
        legacyJSON.removeValue(forKey: "vehicleID")
        let legacyTrip = try JSONDecoder().decode(TripRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        #expect(legacyTrip.vehicleID == nil)
        #expect(try JSONDecoder().decode(TripRecord.self, from: encodedTrip).vehicleID == vehicle.id)
        var interrupted = trip(vehicle.id)
        interrupted.arrived = false
        let trips = [trip(vehicle.id), interrupted, trip(nil), trip(another.id), trip(vehicle.id, mode: .walking),
                     trip(vehicle.id, start: 0.5), trip(vehicle.id, end: 3.5)]
        let period = try #require(EnergyCalculator.periods(vehicleID: vehicle.id, kind: .pb95, entries: [b, a], trips: trips).first)
        #expect(period.kilometers == 430)
        #expect(period.trips.count == 1)
        #expect(!period.usesOdometer)
        #expect(EnergyCalculator.periods(vehicleID: vehicle.id, kind: .pb95, entries: [a, b], trips: []).first?.consumption == nil)
        #expect(EnergyCalculator.estimate(vehicle: vehicle, kilometers: 100, date: b.date, entries: [a, b], trips: trips) == nil)
        let evA = entry(vehicle, 1, 20, 1000, full: true, kind: .electricity)
        let evB = entry(vehicle, 3, 43, 1430, full: true, kind: .electricity)
        let estimate = try #require(EnergyCalculator.estimate(vehicle: vehicle, kilometers: 100, date: b.date,
                                                             entries: [a, b, evA, evB], trips: trips))
        #expect(estimate.components.count == 2)
        #expect(abs(estimate.cost - ((35 + 43) / 430.0 * 100 * 6)) < 0.00001)
        #expect(EnergyCalculator.estimate(vehicle: vehicle, kilometers: 100, date: a.date,
                                         entries: [a, b, evA, evB], trips: trips) == nil)
        var invalidA = a; invalidA.odometer = 1500
        var invalidB = b; invalidB.odometer = 1000
        #expect(EnergyCalculator.periods(vehicleID: vehicle.id, kind: .pb95, entries: [invalidA, invalidB], trips: trips).first?.kilometers == nil)
    }

    @Test func stationVisitAndFillBoundaryRespectGPSGapsAndPriceDates() throws {
        let origin = Coordinate(latitude: 52, longitude: 21)
        let station = FuelStopStation(id: "node/1", identity: PlaceIdentity(provider: .openStreetMap,
            externalID: "1", osmType: "node", coordinate: origin, name: "Stacja", category: "fuel", address: nil))
        let adjacent = FuelStopStation(id: "node/2", identity: PlaceIdentity(provider: .openStreetMap,
            externalID: "2", osmType: "node", coordinate: origin, name: "Druga", category: "fuel", address: nil))
        let now = Date(timeIntervalSince1970: 100_000)
        func fix(_ seconds: Double, speed: Double = 0, accuracy: Double = 5, at coordinate: Coordinate? = nil) -> NavigationLocation {
            NavigationLocation(coordinate: coordinate ?? origin, speed: speed, course: 0, accuracy: accuracy,
                               timestamp: now.addingTimeInterval(seconds), speedAccuracy: 1)
        }
        var detector = FuelStopDetector()
        detector.update(fix(0, speed: 15), stations: [station], now: now)
        detector.update(fix(20, speed: 15), stations: [station], now: now.addingTimeInterval(20))
        #expect(detector.candidates.isEmpty)
        detector.update(fix(40), stations: [station, adjacent], now: now.addingTimeInterval(40))
        #expect(detector.candidates.isEmpty)
        detector.update(fix(60), stations: [station, adjacent], now: now.addingTimeInterval(60))
        #expect(detector.candidates.count == 2)
        detector.saved([station.id, adjacent.id])
        detector.reset()
        detector.update(fix(80), stations: [station, adjacent], now: now.addingTimeInterval(80))
        detector.update(fix(100), stations: [station, adjacent], now: now.addingTimeInterval(100))
        #expect(detector.candidates.isEmpty)
        detector.update(fix(120, at: Coordinate(latitude: 52.01, longitude: 21)), stations: [], now: now.addingTimeInterval(120))
        detector.update(fix(140), stations: [station], now: now.addingTimeInterval(140))
        detector.update(fix(160), stations: [station], now: now.addingTimeInterval(160))
        #expect(detector.candidates.isEmpty)
        detector.update(fix(180), stations: [station], now: now.addingTimeInterval(180))
        #expect(detector.candidates.count == 1)
        detector.update(fix(200, accuracy: 60), stations: [station], now: now.addingTimeInterval(200))
        #expect(detector.candidates.isEmpty)

        // Warsaw midnight differs from UTC midnight: fresh download is never the report date.
        let formatter = ISO8601DateFormatter()
        let midnight = try #require(formatter.date(from: "2026-10-08T22:05:00Z"))
        let yesterday = try #require(formatter.date(from: "2026-10-08T21:55:00Z"))
        #expect(!StationFuelPrice(fuel: .pb95, amount: 6, reportedAt: yesterday).isReportedToday(at: midnight))
        #expect(StationFuelPrice(fuel: .pb95, amount: 6, reportedAt: midnight).isReportedToday(at: midnight))
        #expect(!StationFuelPrice(fuel: .pb95, amount: 6, reportedAt: nil).isReportedToday(at: midnight))
        #expect(!StationFuelPrice(fuel: .pb95, amount: 6, reportedAt: midnight.addingTimeInterval(1)).isReportedToday(at: midnight))

        let vehicle = EnergyVehicle(name: "Samochód")
        let end = Coordinate(latitude: 52.001, longitude: 21)
        let meters = origin.distance(to: end)
        var trip = TripRecord(destination: Destination(name: "Cel", coordinate: end), startedAt: now,
            endedAt: now.addingTimeInterval(20), distanceMeters: meters, movingSeconds: 20,
            rerouteCount: 0, arrived: true, transportMode: .car,
            trace: [TripTracePoint(coordinate: origin, timestamp: now, speedKph: 20, startsSegment: true),
                    TripTracePoint(coordinate: end, timestamp: now.addingTimeInterval(20), speedKph: 20, startsSegment: false)],
            vehicleID: vehicle.id)
        let boundary = now.addingTimeInterval(10)
        let first = try #require(EnergyCalculator.recordedKilometers(trip, from: now.addingTimeInterval(-1), to: boundary))
        let second = try #require(EnergyCalculator.recordedKilometers(trip, from: boundary, to: now.addingTimeInterval(21)))
        #expect(abs(first + second - meters / 1000) < 0.00001)
        #expect(abs(first - second) < 0.00001)
        let entries = [EnergyEntry(vehicleID: vehicle.id, date: now.addingTimeInterval(-1), kind: .pb95,
            quantity: 40, unitPrice: 6, totalPrice: 240, full: true, station: "", coordinate: nil),
            EnergyEntry(vehicleID: vehicle.id, date: boundary, kind: .pb95,
            quantity: 10, unitPrice: 6, totalPrice: 60, full: true, station: "", coordinate: nil),
            EnergyEntry(vehicleID: vehicle.id, date: now.addingTimeInterval(21), kind: .pb95,
            quantity: 10, unitPrice: 6, totalPrice: 60, full: true, station: "", coordinate: nil)]
        let cycles = EnergyCalculator.periods(vehicleID: vehicle.id, kind: .pb95, entries: entries, trips: [trip])
        #expect(cycles.count == 2)
        #expect(abs(cycles.reduce(0) { $0 + $1.recordedKilometers } - meters / 1000) < 0.00001)
        trip.arrived = false
        #expect(EnergyCalculator.recordedKilometers(trip, from: now, to: boundary) == nil)
        trip.arrived = true
        trip.trace[1] = TripTracePoint(coordinate: end, timestamp: now.addingTimeInterval(20), speedKph: 20, startsSegment: true)
        #expect(EnergyCalculator.recordedKilometers(trip, from: now, to: boundary) == nil)
        trip.trace = []
        #expect(EnergyCalculator.recordedKilometers(trip, from: now, to: boundary) == nil)
    }

}
