import Foundation
import Observation

struct FuelStopStation: Identifiable {
    let id: String
    let identity: PlaceIdentity
}

/// A short dwell and separate entrance/exit radii prevent road pass-bys and GPS flicker.
struct FuelStopDetector {
    private var startedAt: Date?
    private var lastLocation: NavigationLocation?
    private var candidateIDs = Set<String>()
    private(set) var candidates: [FuelStopStation] = []
    private var savedStationIDs = Set<String>()

    mutating func saved(_ ids: Set<String>) {
        savedStationIDs.formUnion(ids)
        candidates = []
    }

    mutating func reset() {
        startedAt = nil; lastLocation = nil; candidateIDs = []; candidates = []
        // Keep saved suppression across foreground/sheet interruptions; clear it on physical departure.
    }

    mutating func update(_ location: NavigationLocation?, stations: [FuelStopStation], now: Date) {
        guard let location, location.accuracy.isFinite, (0...30).contains(location.accuracy),
              location.coordinate.latitude.isFinite, location.coordinate.longitude.isFinite,
              abs(location.coordinate.latitude) <= 90, abs(location.coordinate.longitude) <= 180,
              (0...30).contains(now.timeIntervalSince(location.timestamp)) else { reset(); return }
        let nearby = stations.filter { $0.identity.coordinate.distance(to: location.coordinate) <= 120 }
        savedStationIDs.formIntersection(Set(nearby.map(\.id)))
        let elapsed = lastLocation.map { location.timestamp.timeIntervalSince($0.timestamp) }
        let observedSpeed: Double? = lastLocation.flatMap { previous in
            guard let elapsed, elapsed > 0, elapsed <= 45 else { return nil }
            return previous.coordinate.distance(to: location.coordinate) / elapsed
        }
        let reportedSpeed = location.speed.isFinite && location.speed >= 0 &&
            location.speedAccuracy >= 0 && location.speedAccuracy <= 5 ? location.speed : nil
        let stationary = ((reportedSpeed ?? observedSpeed).map { $0 <= 1.5 } ?? false) &&
            (observedSpeed.map { $0 <= 2.5 } ?? true)
        defer { lastLocation = location }
        guard stationary else {
            candidates = []; startedAt = nil; candidateIDs = []
            return
        }
        let radius = candidates.isEmpty ? 70.0 : 120.0
        let eligible = nearby.filter {
            $0.identity.coordinate.distance(to: location.coordinate) <= radius && !savedStationIDs.contains($0.id) &&
                (candidates.isEmpty || candidateIDs.contains($0.id))
        }
        let ids = Set(eligible.map(\.id))
        guard !ids.isEmpty else { candidates = []; startedAt = nil; candidateIDs = []; return }
        if ids != candidateIDs || elapsed.map({ $0 <= 0 || $0 > 45 }) == true {
            startedAt = location.timestamp
            candidateIDs = ids
            candidates = []
        }
        if startedAt == nil { startedAt = location.timestamp }
        if let startedAt, location.timestamp.timeIntervalSince(startedAt) >= 15 {
            candidates = eligible
        }
    }
}

@MainActor @Observable
final class FuelStopStore {
    private(set) var candidates: [FuelStopStation] = []
    @ObservationIgnored private var detector = FuelStopDetector()

    func reset() { detector.reset(); candidates = [] }
    func saved(stationIDs: Set<String>) {
        // Suppress all stations from this visit, including ambiguous adjacent candidates.
        detector.saved(Set(candidates.map(\.id)).union(stationIDs))
        candidates = []
    }
    func refresh(location: NavigationLocation?) async -> Bool {
        guard let location else { reset(); return false }
        do {
            let nearby = try await PaliwoMapaFuelPriceProvider.shared.nearbyStations(at: location.coordinate)
            guard !Task.isCancelled else { return false }
            detector.update(location, stations: nearby, now: Date())
            candidates = detector.candidates
            return !nearby.isEmpty
        } catch {
            if !Task.isCancelled { reset() }
            return false
        }
    }
}

extension EnergyKind {
    var stationFuel: StationFuel? {
        switch self {
        case .pb95: .pb95
        case .pb98: .pb98
        case .diesel: .diesel
        case .lpg: .lpg
        case .electricity: nil
        }
    }
}

extension StationFuelPrice {
    func isReportedToday(at now: Date = Date()) -> Bool {
        guard let reportedAt, reportedAt <= now else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar.isDate(reportedAt, inSameDayAs: now)
    }
}
