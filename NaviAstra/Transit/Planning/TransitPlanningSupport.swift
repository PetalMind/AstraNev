import Foundation
import os

nonisolated enum TransitPlanningPhase: Equatable, Sendable {
    case loadingSchedule
    case searchingConnections
    case enrichingGeometry
}

typealias TransitPlanningProgressHandler = @MainActor @Sendable (TransitPlanningPhase?) async -> Void
typealias TransitProvisionalRoutesHandler = @MainActor @Sendable ([NavigationRoute]) async -> Void

nonisolated enum TransitSignposting {
    static let log = OSLog(subsystem: "STDMSolution.NaviAstra", category: "TransitPlanning")

    static func begin(_ name: StaticString, planningID: UInt64? = nil) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        if let planningID {
            os_signpost(.begin, log: log, name: name, signpostID: identifier,
                        "planningID=%{public}llu", planningID)
        } else {
            os_signpost(.begin, log: log, name: name, signpostID: identifier)
        }
        return identifier
    }

    static func end(_ name: StaticString, identifier: OSSignpostID, planningID: UInt64? = nil) {
        if let planningID {
            os_signpost(.end, log: log, name: name, signpostID: identifier,
                        "planningID=%{public}llu", planningID)
        } else {
            os_signpost(.end, log: log, name: name, signpostID: identifier)
        }
    }

    static func event(_ name: StaticString, value: Int, planningID: UInt64? = nil) {
        if let planningID {
            os_signpost(.event, log: log, name: name,
                        "planningID=%{public}llu value=%{public}d", planningID, value)
        } else {
            os_signpost(.event, log: log, name: name, "value=%{public}d", value)
        }
    }

    static func summary(_ value: String, planningID: UInt64) {
        os_signpost(.event, log: log, name: "PlanningSummary",
                    "planningID=%{public}llu %{public}@", planningID, value as NSString)
    }
}

nonisolated final class TransitPlanningTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var durations: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    private var values: [String: String] = [:]

    func recordDuration(_ name: String, startedAt: TimeInterval) {
        let milliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        lock.lock()
        durations[name] = max(durations[name] ?? 0, milliseconds)
        lock.unlock()
    }

    func setCount(_ name: String, value: Int) {
        lock.lock()
        counts[name] = value
        lock.unlock()
    }

    func setValue(_ name: String, value: String) {
        lock.lock()
        values[name] = value
        lock.unlock()
    }

    func recordElapsedDuration(_ name: String) {
        recordDuration(name, startedAt: startedAt)
    }

    func addCount(_ name: String, value: Int) {
        lock.lock()
        counts[name, default: 0] += value
        lock.unlock()
    }

    func emitSummary(planningID: UInt64) {
        lock.lock()
        let durations = self.durations
        let counts = self.counts
        let values = self.values
        lock.unlock()

        func duration(_ name: String) -> String {
            guard let value = durations[name] else { return "n/a" }
            return "\(Int(value.rounded()))ms"
        }
        func count(_ name: String) -> String {
            counts[name].map(String.init) ?? "n/a"
        }
        func value(_ name: String) -> String {
            values[name] ?? "n/a"
        }
        let shapeHitRate: String
        if let reachable = counts["matrixReachableTargets"], reachable > 0,
           let shapes = counts["matrixShapesReturned"] {
            shapeHitRate = "\(Int((Double(shapes) / Double(reachable) * 100).rounded()))%"
        } else {
            shapeHitRate = "n/a"
        }
        let total = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
        var summary = "total=\(total)ms gtfsLoad=\(duration("GTFSLoad")) indexBuild=\(duration("ScheduleIndexBuild")) "
            + "realtimeWait=\(duration("RealtimeWait")) realtimeFetch=\(duration("RealtimeBackgroundFetch")) "
            + "nearbyStopsMax=\(duration("NearbyStops")) "
            + "walkingMatrixMax=\(duration("WalkingMatrix")) transitSearch=\(duration("TransitSearch")) "
            + "candidateRanking=\(duration("CandidateRanking")) geometryFetch=\(duration("GeometryFetch")) "
            + "snapshotBuild=\(duration("TransitSnapshotBuild")) "
            + "timeToStaticCandidates=\(duration("TimeToStaticCandidates")) "
            + "timeToFirstRoute=\(duration("TimeToFirstRoute")) "
            + "timeToRouteReady=\(duration("TimeToRouteReady")) "
            + "counts[nearbyStops=\(count("nearbyStops")), tripDaysExamined=\(count("tripDaysExamined")), "
            + "activeTrips=\(count("activeTrips")), activeRoutes=\(count("activeRoutes")), "
            + "routesTouched=\(count("routesTouched")), activePatterns=\(count("activePatterns")), "
            + "markedStops=\(count("markedStops")), departureScans=\(count("departureTripsScanned")), "
            + "departureDominated=\(count("departureTripsDominated")), "
            + "stopsWithDepartures=\(count("stopsWithDepartures")), candidates=\(count("candidates")), "
            + "uniqueRoutes=\(count("uniqueRoutes")), walkingSegments=\(count("walkingSegments")), "
            + "rounds=\(count("roundsExecuted")), matrixCalls=\(count("matrixCalls")), "
            + "matrixTargets=\(count("matrixTargetsSent")), matrixHTTPErrorCount=\(count("matrixHTTPErrorCount")), "
            + "matrixErrorCount=\(count("matrixErrorCount")), "
            + "matrixHTTPErrorStatus=\(count("matrixHTTPErrorStatus")), "
            + "matrixFallbackCount=\(count("matrixFallbackCount")), fallbackRequestCount=\(count("fallbackRequestCount")), "
            + "approximateFallbackStops=\(count("approximateFallbackStops")), "
            + "matrixReachable=\(count("matrixReachableTargets")), matrixUnreachable=\(count("matrixUnreachableTargets")), "
            + "matrixOverWalkLimit=\(count("matrixOverWalkLimit")), matrixShapesReturned=\(count("matrixShapesReturned")), "
            + "matrixShapeHitRate=\(shapeHitRate), "
            + "geometryCacheHits=\(count("geometryCacheHits")), geometryRequests=\(count("geometryRequests")), "
            + "accessCacheHits=\(count("persistentAccessCacheHits")), "
            + "searchWindowStage=\(count("searchWindowStage")), "
            + "realtimeAgeSeconds=\(count("realtimeAgeSeconds")), realtimeFreshness=\(value("realtimeFreshness")), "
            + "realtimeUsed=\(value("realtimeUsed")), realtimeRefreshDeferred=\(count("realtimeRefreshDeferred"))]"
        summary += "compiledIndexLoad=\(duration("CompiledIndexLoad")) compiledIndexHit=\(count("compiledIndexHit")) "
            + "transferGraphCacheHit=\(count("transferGraphCacheHit")) "
            + "flatTripServiceIndexHit=\(count("flatTripServiceIndexHit")) "
        TransitSignposting.summary(summary, planningID: planningID)
    }
}

nonisolated enum TransitRoutingError: LocalizedError {
    case invalidResponse
    case noJourney
    case noJourneyBeforeArrivalDeadline
    case noParkRide
    case walkingUnavailable
    case walkingServerError(Int)
    case walkingRateLimited
    case feedUnavailable
    case railwayFeedUnavailable
    case outsideCoverage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Źródło rozkładów zwróciło nieprawidłowe dane."
        case .noJourney:
            "Nie znaleziono połączenia kolejowego ani komunikacji publicznej dla wybranej godziny."
        case .noJourneyBeforeArrivalDeadline:
            "Nie znaleziono połączenia, które dotrze przed wybraną godziną."
        case .noParkRide:
            "Nie udało się znaleźć działającego połączenia z parkingu P+R."
        case .walkingUnavailable:
            "Nie udało się wyznaczyć dojścia pieszo do przystanków przez serwer Valhalla."
        case .walkingServerError(let statusCode):
            "Serwer tras odrzucił wyznaczenie dojścia (HTTP \(statusCode))."
        case .walkingRateLimited:
            "Serwer tras ograniczył liczbę żądań. Poczekaj chwilę i spróbuj ponownie."
        case .feedUnavailable:
            "Nie udało się pobrać rozkładu jazdy komunikacji publicznej."
        case .railwayFeedUnavailable:
            "Krajowy rozkład kolejowy jest chwilowo niedostępny. Spróbuj ponownie za chwilę."
        case .outsideCoverage:
            "Wybierz początek i cel, z których można dojść do stacji lub przystanku w 30 minut pieszo."
        }
    }
}
