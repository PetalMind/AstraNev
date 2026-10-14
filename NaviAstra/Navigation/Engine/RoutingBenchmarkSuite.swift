import Foundation

nonisolated struct RoutingBenchmarkCase: Codable, Sendable {
    let id: String
    let category: String
    let passed: Bool
    let expected: String
    let measured: String
    let decision: RoutingDecisionRecord?
}

nonisolated struct RoutingBenchmarkReport: Codable, Sendable {
    let createdAt: Date
    let dataset: String
    let elapsedSeconds: Double
    let cases: [RoutingBenchmarkCase]
    var failures: Int { cases.filter { !$0.passed }.count }
}

/// Deterministic synthetic regression cases. Never labels them as observed real journeys.
nonisolated enum RoutingBenchmarkSuite {
    static func replay(_ records: [RoutingDecisionRecord]) -> RoutingBenchmarkReport {
        let started = ProcessInfo.processInfo.systemUptime
        let cases = records.map { record -> RoutingBenchmarkCase in
            let scores = record.candidates.map(\.rawScore)
            let values = RouteScoringEngine.rankingValues(scores, preference: record.preference)
            let personalizedWinner = record.candidates.filter { $0.personalRank != nil }
                .min { ($0.personalRank ?? .max) < ($1.personalRank ?? .max) }?.id
            let winner = personalizedWinner ?? scores.indices.sorted {
                if values[$0] != values[$1] { return values[$0] < values[$1] }
                if scores[$0].travelTime != scores[$1].travelTime { return scores[$0].travelTime < scores[$1].travelTime }
                if scores[$0].distance != scores[$1].distance { return scores[$0].distance < scores[$1].distance }
                return $0 < $1
            }.first.map { record.candidates[$0].id }
            return RoutingBenchmarkCase(id: record.id.uuidString, category: "recorded-ranking-replay",
                passed: winner == record.recommendedRouteID, expected: record.recommendedRouteID?.uuidString ?? "Brak wariantu",
                measured: winner?.uuidString ?? "Brak wariantu", decision: record)
        }
        return RoutingBenchmarkReport(createdAt: .now, dataset: "Odtworzenie rankingu z zapisanych pomiarów; bez ponownego zapytania do dostawców",
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, cases: cases)
    }

    static func run() -> RoutingBenchmarkReport {
        let started = ProcessInfo.processInfo.systemUptime
        var results: [RoutingBenchmarkCase] = []
        for variation in 0..<10 {
            let scale = 1 + Double(variation) * 0.1
            let start = Coordinate(latitude: 52 + Double(variation) * 0.01, longitude: 21)
            let end = Coordinate(latitude: start.latitude + 0.02 * scale, longitude: start.longitude)
            let points = [start, end]
            func route(distance: Double, time: Double, turns: Int = 0) -> NavigationRoute {
                let direct = start.distance(to: end), desired = max(direct, distance * scale)
                let offset = sqrt(max(0, pow(desired / 2, 2) - pow(direct / 2, 2)))
                let middleLatitude = (start.latitude + end.latitude) / 2
                let middle = Coordinate(latitude: middleLatitude,
                    longitude: start.longitude + offset / (111_320 * cos(middleLatitude * .pi / 180)))
                let shape = offset > 1 ? [start, middle, end] : points
                let actualDistance = zip(shape, shape.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                return NavigationRoute(coordinates: shape, distance: actualDistance, expectedTravelTime: time * scale,
                    maneuvers: (0..<turns).map { _ in Maneuver(shapeIndex: 0, instruction: "Skręt", type: 10) })
            }
            func check(_ category: String, passed: Bool, expected: String, measured: String,
                       routes: [NavigationRoute] = [], preference: RoutePreference = .fastest) {
                let selected = RouteScoringEngine.ranked(routes, preference: preference).first?.id
                results.append(RoutingBenchmarkCase(id: "\(category)-\(variation)", category: category,
                    passed: passed, expected: expected, measured: measured,
                    decision: routes.isEmpty ? nil : RoutingDecisionRecord.make(routes: routes, preference: preference,
                        selected: selected, source: "synthetic-benchmark", calculationSeconds: nil)))
            }
            for (category, distance, time) in [("miasto", 3_000.0, 600.0), ("aglomeracja", 20_000, 1_800),
                                               ("droga-krajowa", 80_000, 4_000), ("autostrada", 300_000, 10_000)] {
                let a = route(distance: distance, time: time), b = route(distance: distance * 0.9, time: time * 1.1)
                let fast = RouteScoringEngine.ranked([b, a], preference: .fastest).first?.id == a.id
                let short = RouteScoringEngine.ranked([a, b], preference: .shortest).first?.id == b.id
                check(category, passed: fast && short, expected: "Czas i dystans wybierają właściwe warianty",
                      measured: "fastest=\(fast), shortest=\(short)", routes: [a, b])
            }
            let busy = route(distance: 19_000, time: 1_860, turns: 41), easy = route(distance: 22_000, time: 1_980, turns: 8)
            let balanced = RouteScoringEngine.ranked([busy, easy], preference: .balanced).first?.id == easy.id
            check("mieszana", passed: balanced, expected: "Mniej złożonych manewrów przy małej różnicy czasu",
                  measured: "easy=\(balanced)", routes: [busy, easy], preference: .balanced)
            let active = route(distance: 2_000, time: 100)
            let geometry = RouteProgressGeometry(active)
            let segment = RouteTrafficSegment(id: "flow", routeID: active.id, startDistance: 0,
                endDistance: geometry.length / 2, coordinates: points, colorHex: 0, isRoadClosure: false,
                currentSpeedKph: 10, measuredAt: .now)
            let traffic = TrafficSnapshot(flow: nil, incidents: [], routeFlowSegments: [segment], updatedAt: .now,
                                          partialError: nil, incidentDataAvailable: true)
            let coverage = TrafficCoverage.measure(route: active, from: 0, traffic: traffic)
            check("korki", passed: abs(coverage.routeFraction - 0.5) < 0.001 &&
                RoadRouteETA.estimate(active, from: 0, traffic: traffic) > active.expectedTravelTime,
                expected: "50% pomiaru i wzrost ETA", measured: "coverage=\(coverage.routeFraction)")
            let closed = [Coordinate(latitude: start.latitude + 0.005, longitude: start.longitude),
                          Coordinate(latitude: start.latitude + 0.015, longitude: start.longitude)]
            let crossing = NavigationRoute(coordinates: [Coordinate(latitude: start.latitude + 0.01, longitude: 20.99),
                Coordinate(latitude: start.latitude + 0.01, longitude: 21.01)], distance: 1_000, expectedTravelTime: 100, maneuvers: [])
            let intersects = (try? RoadClosureAvoidance(geometry: closed).intersects(crossing)) == true
            check("zamkniecie", passed: intersects, expected: "Odrzucenie przejazdu przez środek blokady",
                  measured: "intersection=\(intersects)")
            let duplicate = route(distance: 2_000, time: 110)
            let kept = RouteSimilarity.diverse([active, duplicate]).count
            check("alternatywy", passed: kept == 1, expected: "Jeden wariant identycznej drogi", measured: "count=\(kept)")
            let denied = !DestinationIntelligenceEngine.motorAccessAllowed(["access": "no", "barrier": "bollard"])
            let allowed = DestinationIntelligenceEngine.motorAccessAllowed(["access": "private", "motor_vehicle": "yes"])
            check("poi", passed: denied && allowed, expected: "Hierarchia dostępu i blokująca bariera",
                  measured: "denied=\(denied), override=\(allowed)")
            let charging = EVStopPlanner.chargingTime(from: 0.2, to: 0.7, batteryKWh: 60, power: 150)
            check("ev", passed: charging.isFinite && charging > 300, expected: "Dodatni postój ładowania",
                  measured: "chargingSeconds=\(charging)")
            let fix = NavigationLocation(coordinate: start, speed: 10, course: 0, accuracy: 5, timestamp: .now)
            let match = MapMatchingEngine.match(route: active, geometry: geometry, location: fix,
                                                previous: nil, previousTimestamp: nil)
            check("gps", passed: (match?.match.confidence ?? 0) > 0.9, expected: "Pewne dopasowanie na drodze",
                  measured: "quality=\(match?.match.confidence ?? 0)")
            let turn = Maneuver(shapeIndex: 1, instruction: "Zjedź", type: 20, lanes: [
                TurnLaneGuidance(id: 0, indications: ["straight"], valid: false),
                TurnLaneGuidance(id: 1, indications: ["right"], valid: true, active: true)])
            let lanes = LaneGuidanceEngine.guidance(for: turn)
            let quality = GuidanceQualityEngine.evaluate(maneuver: turn, followingDistance: 50, speed: 25)
            check("pasy-i-komunikaty", passed: lanes?.selectedIndices == [1] && quality.preparationDistance > 600,
                  expected: "Pas dostawcy i wcześniejsze przygotowanie do złożonego węzła",
                  measured: "lanes=\(lanes?.selectedIndices ?? []), early=\(quality.preparationDistance)")
        }
        return RoutingBenchmarkReport(createdAt: .now, dataset: "120 syntetycznych scenariuszy krytycznych; brak zapytań sieciowych",
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, cases: results)
    }
}
