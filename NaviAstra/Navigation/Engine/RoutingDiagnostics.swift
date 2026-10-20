import Foundation
import Observation

nonisolated struct RoutingDecisionCandidate: Codable, Identifiable, Sendable {
    let id: UUID
    let distance: Double
    let eta: Double?
    let rankingValue: Double?
    let rawScore: RouteScore
    let normalized: RouteScoringEngine.NormalizedComponents
    let maneuverCount: Int
    let unpavedDistance: Double?
    let tollDistance: Double?
    let roughManeuverDistance: Double?
    let tollManeuverDistance: Double?
    let coverage: TrafficCoverage
    let geometry: [Coordinate]
    let reason: String
    var personalRank: Int? = nil
    var personalEvidence: DrivingRouteAssessment? = nil
}

nonisolated struct RoutingDecisionRecord: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let timestamp: Date
    let source: String
    let appVersion: String?
    let preference: RoutePreference
    let selectedRouteID: UUID?
    let recommendedRouteID: UUID?
    let calculationSeconds: Double?
    let samplingCount: Int?
    let samplingBudget: Int?
    let gpsMatchQuality: Double?
    let candidates: [RoutingDecisionCandidate]
    let failure: String?

    var isReplayable: Bool {
        guard schemaVersion == 1, candidates.count <= 32 else { return false }
        return candidates.allSatisfy { candidate in
            let score = candidate.rawScore, normalized = candidate.normalized
            return score.travelTime >= 0 && !score.travelTime.isNaN && score.distance.isFinite && score.distance >= 0 &&
                score.maneuverCost.isFinite && score.maneuverCost >= 0 &&
                [score.roadQualityCost, score.reliabilityCost, score.tollCost].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true } &&
                [normalized.time, normalized.distance].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
                [normalized.comfort, normalized.surface, normalized.reliability].allSatisfy { $0.map { $0.isFinite && (0...1).contains($0) } ?? true } &&
                candidate.geometry.count <= 200_000 && candidate.geometry.allSatisfy(\.isValidValhallaCoordinate)
                    && (candidate.personalRank.map { (0..<32).contains($0) } ?? true)
        }
    }

    static func make(routes: [NavigationRoute], preference: RoutePreference, selected: UUID?,
                     source: String, calculationSeconds: Double?, samplingCount: Int? = nil,
                     samplingBudget: Int? = nil, gpsMatchQuality: Double? = nil,
                     starts: [UUID: Double] = [:], traffic: [UUID: TrafficSnapshot] = [:], failure: String? = nil,
                     personalOrder: [UUID]? = nil, personalEvidence: [UUID: DrivingRouteAssessment]? = nil) -> Self {
        let scores = routes.map { RouteScoringEngine.score($0, from: starts[$0.id] ?? 0, traffic: traffic[$0.id]) }
        let normalized = RouteScoringEngine.normalized(scores)
        let values = RouteScoringEngine.rankingValues(scores, preference: preference)
        let recommended = personalOrder?.first ?? routes.indices.sorted {
            if values[$0] != values[$1] { return values[$0] < values[$1] }
            if scores[$0].travelTime != scores[$1].travelTime { return scores[$0].travelTime < scores[$1].travelTime }
            if scores[$0].distance != scores[$1].distance { return scores[$0].distance < scores[$1].distance }
            return $0 < $1
        }.first.map { routes[$0].id }
        let fastest = scores.map(\.travelTime).filter(\.isFinite).min()
        let candidates = routes.indices.map { index -> RoutingDecisionCandidate in
            let route = routes[index], score = scores[index]
            let remaining = RouteProgressGeometry(route)
            let turns = route.maneuvers.filter {
                remaining.cumulativeDistances.indices.contains($0.shapeIndex) &&
                    remaining.cumulativeDistances[$0.shapeIndex] >= (starts[route.id] ?? 0)
            }
            func distance(flag: (ManeuverInformation) -> Bool?) -> Double? {
                guard !turns.isEmpty, turns.allSatisfy({ $0.information.map(flag) != nil &&
                    (flag($0.information!) != true || $0.information?.distanceMeters != nil) }) else { return nil }
                return turns.reduce(0) { sum, turn in
                    flag(turn.information!) == true ? sum + max(0, turn.information?.distanceMeters ?? 0) : sum
                }
            }
            var reasons: [String] = []
            if selected == route.id { reasons.append("Aktywny wariant") }
            if recommended == route.id { reasons.append("Rekomendacja: \(preference.title)") }
            if let position = personalOrder?.firstIndex(of: route.id) {
                reasons.append("Pozycja po personalizacji: \(position + 1); wynik bazowy bez zmiany ETA")
            }
            if let fastest, score.travelTime.isFinite { reasons.append("\(Int((score.travelTime - fastest).rounded())) s względem najszybszego wariantu") }
            if !score.hasManeuverData { reasons.append("Brak danych manewrów") }
            reasons.append("\(turns.filter { RouteScoringEngine.maneuverCost($0.kind) > 0 }.count) manewrów kierunkowych")
            if score.roadQualityCost == nil { reasons.append("Nawierzchnia nieporównywalna lub nieznana") }
            return RoutingDecisionCandidate(id: route.id, distance: score.distance,
                eta: score.travelTime.isFinite ? score.travelTime : nil,
                rankingValue: values[index].isFinite ? values[index] : nil,
                rawScore: score, normalized: normalized[index], maneuverCount: turns.count,
                unpavedDistance: !turns.isEmpty && turns.allSatisfy({ $0.information?.rough == false }) ? 0 : nil,
                tollDistance: !turns.isEmpty && turns.allSatisfy({ $0.information?.toll == false }) ? 0 : nil,
                roughManeuverDistance: distance { $0.rough }, tollManeuverDistance: distance { $0.toll },
                coverage: TrafficCoverage.measure(route: route, from: starts[route.id] ?? 0, traffic: traffic[route.id]),
                geometry: route.coordinates, reason: reasons.joined(separator: "; "),
                personalRank: personalOrder?.firstIndex(of: route.id), personalEvidence: personalEvidence?[route.id])
        }
        return Self(schemaVersion: 1, id: UUID(), timestamp: .now, source: source,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, preference: preference,
            selectedRouteID: selected, recommendedRouteID: recommended, calculationSeconds: calculationSeconds,
            samplingCount: samplingCount, samplingBudget: samplingBudget, gpsMatchQuality: gpsMatchQuality,
            candidates: candidates, failure: failure)
    }
}

@MainActor @Observable
final class RoutingDiagnostics {
    static let shared = RoutingDiagnostics()
    var recordingEnabled = UserDefaults.standard.bool(forKey: "routingDiagnosticsEnabled") {
        didSet { UserDefaults.standard.set(recordingEnabled, forKey: "routingDiagnosticsEnabled") }
    }
    private(set) var latest: RoutingDecisionRecord?
    private(set) var archiveError: String?
    func publish(_ record: RoutingDecisionRecord) {
        latest = record
        guard recordingEnabled else { return }
        Task {
            do { try await RoutingDiagnosticsArchive.shared.save(record); archiveError = nil }
            catch { archiveError = PolishUserErrorMessage.make(error, fallback: "Nie udało się zapisać diagnostyki routingu.") }
        }
    }
}

actor RoutingDiagnosticsArchive {
    static let shared = RoutingDiagnosticsArchive()
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoutingDiagnostics", isDirectory: true)
    }
    func save(_ record: RoutingDecisionRecord) throws {
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var root = directory; try root.setResourceValues(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let data = try encoder.encode(record)
        // Bound local retention, including exceptionally detailed long-distance routes.
        guard data.count <= 10_000_000 else { throw ValhallaFeatureError.message("Diagnostyka przekracza limit 10 MB.") }
        try data.write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var bytes = 0
        for (index, file) in files.enumerated() {
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if index >= 20 || bytes > 20_000_000 { try FileManager.default.removeItem(at: file) }
        }
    }
    func records() throws -> [RoutingDecisionRecord] {
        guard FileManager.default.fileExists(atPath: Self.directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try files.prefix(20).map { file in
            let record = try decoder.decode(RoutingDecisionRecord.self, from: Data(contentsOf: file))
            guard record.isReplayable else { throw ValhallaFeatureError.message("Nieprawidłowe dane zapisanej diagnostyki.") }
            return record
        }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: Self.directory.path) {
            try FileManager.default.removeItem(at: Self.directory)
        }
    }
}
