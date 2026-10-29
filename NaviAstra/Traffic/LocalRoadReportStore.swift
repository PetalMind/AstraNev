import Foundation
import CoreLocation
import Observation

nonisolated enum RoadReportKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case police, accident, hazard, jam, roadworks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .police: "Kontrola policyjna"
        case .accident: "Wypadek"
        case .hazard: "Zagrożenie na drodze"
        case .jam: "Zgłoszenie korka"
        case .roadworks: "Roboty drogowe"
        }
    }
    var symbol: String {
        switch self {
        case .police: "shield.fill"
        case .accident: "car.side.front.open.fill"
        case .hazard: "exclamationmark.triangle.fill"
        case .jam: "car.2.fill"
        case .roadworks: "cone.fill"
        }
    }
    var category: TrafficIncidentCategory {
        switch self {
        case .police, .hazard: .dangerousConditions
        case .accident: .accident
        case .jam: .jam
        case .roadworks: .roadWorks
        }
    }
}

nonisolated struct LocalRoadReport: Codable, Identifiable, Sendable {
    let id: UUID
    let kind: RoadReportKind
    let coordinate: Coordinate
    let createdAt: Date
    let expiresAt: Date

    func incident(source: RoadIncidentSource = .local, at now: Date = Date()) -> TrafficIncident {
        TrafficIncident(id: "\(source.rawValue)/\(id.uuidString)", description: kind.title,
            coordinate: coordinate, delaySeconds: nil, category: kind.category, severity: .unknown,
            observedAt: now, cause: kind == .police ? .policeCheckpoint : nil,
            startsAt: createdAt, expiresAt: expiresAt, sources: [source], sourceUpdatedAt: createdAt)
    }
}

@MainActor
@Observable
final class LocalRoadReportStore {
    static let shared = LocalRoadReportStore()
    private(set) var reports: [LocalRoadReport] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviAstra/local-road-reports.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let stored = try? JSONDecoder().decode([LocalRoadReport].self, from: data) {
            reports = Array(stored.filter { Self.valid($0, at: Date()) }.prefix(200))
        }
    }

    @discardableResult
    func add(kind: RoadReportKind, coordinate: Coordinate, at date: Date = Date()) throws -> LocalRoadReport {
        guard CLLocationCoordinate2DIsValid(coordinate.cl) else { throw RoadReportError.invalidLocation }
        let report = LocalRoadReport(id: UUID(), kind: kind, coordinate: coordinate,
                                    createdAt: date, expiresAt: date.addingTimeInterval(30 * 60))
        var updated = reports.filter { Self.valid($0, at: date) }
        updated.insert(report, at: 0)
        try save(Array(updated.prefix(200)))
        return report
    }
    func remove(_ id: UUID) throws { try save(reports.filter { $0.id != id && $0.expiresAt > Date() }) }

    func incidents(in boxes: [TrafficBoundingBox], at now: Date = Date()) -> [TrafficIncident] {
        reports.filter { report in Self.valid(report, at: now) && (boxes.isEmpty || boxes.contains(where: { $0.contains(report.coordinate) })) }
            .map { $0.incident(at: now) }
    }
    nonisolated static func valid(_ report: LocalRoadReport, at date: Date) -> Bool {
        CLLocationCoordinate2DIsValid(report.coordinate.cl) && report.createdAt <= date.addingTimeInterval(5) &&
            report.expiresAt > date && report.expiresAt.timeIntervalSince(report.createdAt) > 0 &&
            report.expiresAt.timeIntervalSince(report.createdAt) <= 1_800
    }
    private func save(_ updated: [LocalRoadReport]) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            reports = updated
        } catch { throw RoadReportError.storage }
    }
}

enum RoadReportError: LocalizedError {
    case storage, invalidLocation, server
    var errorDescription: String? {
        switch self {
        case .storage: "Nie udało się zapisać zgłoszenia na urządzeniu."
        case .invalidLocation: "Do zgłoszenia potrzebna jest świeża i dokładna pozycja GPS."
        case .server: "Nie udało się udostępnić zgłoszenia. Lokalny zapis pozostaje na urządzeniu."
        }
    }
}
