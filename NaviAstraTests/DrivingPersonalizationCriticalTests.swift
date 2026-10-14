import Foundation
import Testing
@testable import NaviAstra

/// Critical regressions for route selection, privacy and preference persistence.
@MainActor struct DrivingPersonalizationCriticalTests {
    private let origin = Coordinate(latitude: 52, longitude: 21)
    private let destination = Coordinate(latitude: 52.02, longitude: 21)

    private func segment(_ id: String, _ a: Coordinate, _ b: Coordinate) -> LearnedRoadSegment {
        LearnedRoadSegment(id: id, coordinates: [a, b], length: a.distance(to: b), names: [id])
    }

    private func fixture(confirmed: Bool = true, count: Int = 1) throws -> (DrivingLearningEngine, DrivingProfileStore, NavigationRoute) {
        let store = DrivingProfileStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("driving-critical-\(UUID().uuidString)/NavigationLearning.sqlite"))
        let via = Coordinate(latitude: 52.01, longitude: 21.003)
        let roads = [segment("a", origin, via), segment("b", via, destination)]
        var snapshot = DrivingProfileSnapshot()
        snapshot.settings.enabled = true
        for _ in 0..<count {
            snapshot.trips.append(LearnedDrivingTrip(id: UUID(), destinationName: "Cel", origin: origin,
                destination: destination, startedAt: Date(), duration: 310,
                context: DrivingPreferenceContext(date: Date()), segments: roads, deviations: [], confirmed: confirmed))
        }
        try store.save(snapshot)
        let route = NavigationRoute(coordinates: [origin, via, destination], distance: 2_300,
                                    expectedTravelTime: 310, maneuvers: [])
        return (DrivingLearningEngine(store: store), store, route)
    }

    @Test func confirmedHistoryReordersSimilarRoutesWithoutChangingETAOrStrictShortest() throws {
        let (engine, store, familiar) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let ordinary = NavigationRoute(coordinates: [origin, destination], distance: 2_224,
                                       expectedTravelTime: 300, maneuvers: [])
        let ranked = engine.ranked([ordinary, familiar], preference: .fastest)
        #expect(ranked.first?.id == familiar.id)
        #expect(ranked.first?.expectedTravelTime == 310)
        #expect(ranked.last?.expectedTravelTime == 300)
        #expect(ranked.first?.coordinates == familiar.coordinates)
        let decision = RoutingDecisionRecord.make(routes: [ordinary, familiar], preference: .fastest,
            selected: familiar.id, source: "personalization-fixture", calculationSeconds: nil,
            personalOrder: ranked.map(\.id))
        #expect(decision.recommendedRouteID == familiar.id)
        #expect(RoutingBenchmarkSuite.replay([decision]).failures == 0)
        #expect(engine.ranked([ordinary, familiar], preference: .shortest).first?.id == ordinary.id)
        var disabled = engine.settings; disabled.enabled = false
        engine.updateSettings(disabled)
        #expect(engine.ranked([ordinary, familiar], preference: .fastest).first?.id == ordinary.id)
        #expect(DrivingLearningEngine(store: store).settings.enabled == false)
    }

    @Test func singleObservationAndMateriallySlowerConfirmedRouteCannotTakeOverRouting() throws {
        let (unconfirmed, store, familiar) = try fixture(confirmed: false)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let ordinary = NavigationRoute(coordinates: [origin, destination], distance: 2_224,
                                       expectedTravelTime: 300, maneuvers: [])
        #expect(unconfirmed.ranked([ordinary, familiar], preference: .fastest).first?.id == ordinary.id)
        #expect(unconfirmed.patterns.first?.confidence == 0)
        unconfirmed.remember(unconfirmed.patterns[0].id, endpoint: URL(string: "https://example.invalid")!)
        var slow = familiar; slow.expectedTravelTime = 900
        #expect(unconfirmed.ranked([ordinary, slow], preference: .fastest).first?.id == ordinary.id)
        #expect(unconfirmed.ranked([ordinary, slow], preference: .balanced).first?.id == ordinary.id)
    }

    @Test func deletingPreferenceRemovesItsRoadEvidenceAndPersistsReset() throws {
        let (engine, store, familiar) = try fixture(count: 12)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        #expect(engine.isPreferred(familiar))
        engine.remove(engine.patterns[0])
        #expect(engine.learnedTripCount == 0)
        #expect(!engine.isPreferred(familiar))
        #expect(try store.load().trips.isEmpty)
        engine.clear()
        #expect(try store.load().pending.isEmpty)
        #expect(engine.settings.allowRemoteMatching == false)
    }

    @Test func repeatedDeviationRequiresRejoiningAndRejectsShortExcursionsAndStops() {
        let a = origin, b = Coordinate(latitude: 52.005, longitude: 21)
        let c = Coordinate(latitude: 52.015, longitude: 21)
        let d = destination, x = Coordinate(latitude: 52.01, longitude: 21.01)
        let entry = segment("entry", a, b), exit = segment("exit", c, d)
        let planned = [entry, segment("avoided", b, c), exit]
        let actual = [entry, segment("x", b, x), segment("y", x, c), exit]
        let time = Date()
        let moving = [TripTracePoint(coordinate: x, timestamp: time, speedKph: 30, startsSegment: false),
                      TripTracePoint(coordinate: c, timestamp: time.addingTimeInterval(20), speedKph: 30, startsSegment: false)]
        let detected = DrivingDeviationDetector.detect(actual: actual, proposed: planned, trace: moving)
        #expect(detected.count == 1)
        #expect(detected[0].avoided.map(\.id) == ["avoided"])
        #expect(DrivingLearningMath.confidence(1) == 0)
        #expect(DrivingLearningMath.confidence(2) == 0)
        #expect(DrivingLearningMath.confidence(10) > DrivingLearningMath.confidence(3))
        #expect(DrivingDeviationDetector.detect(actual: Array(actual.dropLast()), proposed: planned, trace: moving).isEmpty)
        let stopped = (0...5).map { TripTracePoint(coordinate: x,
            timestamp: time.addingTimeInterval(Double($0) * 20), speedKph: 0, startsSegment: false) }
        #expect(DrivingDeviationDetector.detect(actual: actual, proposed: planned, trace: stopped).isEmpty)
    }

    @Test func confirmedFamiliarityCannotOverrideFreshMeasuredClosure() throws {
        let (engine, store, familiar) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let ordinary = NavigationRoute(coordinates: [origin, destination], distance: 2_224,
                                       expectedTravelTime: 300, maneuvers: [])
        let closure = TrafficIncident(id: "closed", description: "Zamknięta droga",
            coordinate: Coordinate(latitude: 52.008, longitude: 21.0024), delaySeconds: nil,
            category: .roadClosed, severity: .major,
            geometry: [Coordinate(latitude: 52.007, longitude: 21.0021),
                       Coordinate(latitude: 52.009, longitude: 21.0027)])
        let measured = TrafficSnapshot(flow: nil, incidents: [closure], updatedAt: Date(),
            partialError: nil, incidentDataAvailable: true)
        #expect(engine.ranked([familiar, ordinary], preference: .fastest,
            traffic: [familiar.id: measured]).first?.id == ordinary.id)
    }

    @Test func approachLearnsAcrossDifferentOriginsAndRoadRemovalPersists() throws {
        let (_, store, _) = try fixture(confirmed: false, count: 2)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var snapshot = try store.load()
        let template = snapshot.trips[0]
        for index in 0..<2 {
            snapshot.trips.append(LearnedDrivingTrip(id: UUID(), destinationName: "Cel",
                origin: Coordinate(latitude: 51.9 + Double(index) * 0.01, longitude: 21),
                destination: destination, startedAt: Date(), duration: 800,
                context: template.context, segments: template.segments, deviations: [], confirmed: false))
        }
        try store.save(snapshot)
        let engine = DrivingLearningEngine(store: store)
        #expect(engine.patterns.count == 3)
        #expect(engine.approaches.count == 1)
        #expect(engine.approaches[0].trips.count == 4)
        #expect(engine.approaches[0].confidence > 0)
        engine.removeApproach(engine.approaches[0].id)
        #expect(DrivingLearningEngine(store: store).approaches.isEmpty)
        engine.removeRoad("a")
        #expect(try store.load().ignoredRoadIDs.contains("a"))
    }

    @Test func mapMatchingRejectsGapsAndUsesDirectedRoadIDsWithoutRemoteConsent() async throws {
        let shape = "_oydbB_w`ag@_pR?"
        let base: [String: Any] = ["units": "kilometers", "shape": shape,
            "edges": [["way_id": 1, "begin_osm_node_id": 10, "end_osm_node_id": 20,
                        "begin_shape_index": 0, "end_shape_index": 1, "length": 0.5]],
            "matched_points": [["type": "matched", "distance_from_trace_point": 2],
                               ["type": "matched", "distance_from_trace_point": 3]]]
        let matched = try DrivingRouteMatcher.decode(JSONSerialization.data(withJSONObject: base), scope: "fixture", validateGPS: true)
        #expect(matched.first?.id == "osm:1:10:20")
        var broken = base
        broken["matched_points"] = [["type": "unmatched"], ["type": "matched", "begin_route_discontinuity": true]]
        #expect(throws: DrivingLearningFailure.self) {
            try DrivingRouteMatcher.decode(JSONSerialization.data(withJSONObject: broken), scope: "fixture", validateGPS: true)
        }
        #if os(macOS)
        let matcher = DrivingRouteMatcher(endpoint: URL(string: "https://example.invalid")!, settings: DrivingLearningSettings())
        do {
            _ = try await matcher.match([origin, destination], costing: "auto", recorded: true)
            Issue.record("Remote matching ran without consent")
        } catch DrivingLearningFailure.needsLocalMap { }
        #endif
    }

    @Test func disablingLearningInvalidatesAnAlreadyRecordedTripEvenAfterReenabling() throws {
        let (engine, store, route) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let generation = engine.recordingGeneration
        var settings = engine.settings; settings.enabled = false
        engine.updateSettings(settings)
        settings.enabled = true; engine.updateSettings(settings)
        let start = Date().addingTimeInterval(-120)
        let trace = route.coordinates.enumerated().map { index, point in
            TripTracePoint(coordinate: point, timestamp: start.addingTimeInterval(Double(index) * 50),
                speedKph: 30, startsSegment: index == 0)
        }
        let trip = TripRecord(destination: Destination(name: "Cel", coordinate: destination),
            startedAt: start, endedAt: Date(), distanceMeters: route.distance,
            movingSeconds: 100, rerouteCount: 0, arrived: true, transportMode: .car, trace: trace)
        engine.enqueue(trip, proposed: route, costing: "auto", context: DrivingPreferenceContext(date: start),
            allowAutomaticDeviations: true, recordingGeneration: generation)
        #expect(engine.pendingCount == 0)
        #expect(try store.load().pending.isEmpty)
    }

    @Test func repeatedTemporaryDetoursRemainObservationsUntilExplicitConfirmation() throws {
        let (_, store, route) = try fixture(confirmed: false, count: 12)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var snapshot = try store.load()
        for index in snapshot.trips.indices { snapshot.trips[index].automaticPreferenceEligible = false }
        try store.save(snapshot)
        let engine = DrivingLearningEngine(store: store)
        #expect(engine.patterns[0].confidence == 0)
        #expect(engine.approaches[0].confidence == 0)
        #expect(!engine.isPreferred(route))
        engine.remember(engine.patterns[0].id, endpoint: URL(string: "https://example.invalid")!)
        #expect(engine.patterns[0].confidence == 0.72)
        #expect(engine.isPreferred(route))
    }
    @Test func oldEvidenceDecaysAndOrdinaryFrequencyIsWeakerThanDeliberateChoice() throws {
        let (_, store, route) = try fixture(confirmed: false, count: 12)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let ordinary = DrivingLearningEngine(store: store).assessment(route).score
        var profile = try store.load()
        for index in profile.trips.indices { profile.trips[index].selectedAgainstAlternative = true }
        profile.evidence = profile.trips.flatMap { DrivingEvidenceMath.observations(for: $0) }
        try store.save(profile)
        let strong = DrivingLearningEngine(store: store).assessment(route).score
        #expect(strong > ordinary)
        let future = Date().addingTimeInterval(240 * 86_400)
        let stale = DrivingLearningEngine(store: store).assessment(route, date: future).score
        #expect(stale < strong)
        #expect(DrivingEvidenceMath.recency(Date(), at: Date().addingTimeInterval(366 * 86_400)) == 0)
        let mixed = DrivingEvidenceMath.metrics(trips: profile.trips, at: future)
        #expect(mixed.confidence < 1)
        #expect(mixed.recency < 0.35)
    }

    @Test func realOfferedChosenAndAvoidedCountsRollbackWithDeletedTrip() throws {
        let (_, store, _) = try fixture(confirmed: false, count: 12)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var profile = try store.load()
        let detour = profile.trips[0].segments
        let direct = [segment("direct", origin, destination)]
        profile.trips = (0..<12).map { index in
            LearnedDrivingTrip(id: UUID(), destinationName: "Cel", origin: origin, destination: destination,
                startedAt: Date(), duration: 310, context: DrivingPreferenceContext(date: Date()),
                segments: index < 8 ? detour : direct, deviations: [], confirmed: false,
                offeredVariants: [DrivingObservedVariant(id: "A", segments: direct), DrivingObservedVariant(id: "B", segments: detour)],
                selectedVariantID: index < 8 ? "B" : "A", selectedAgainstAlternative: index < 8)
        }
        profile.evidence = profile.trips.flatMap { DrivingEvidenceMath.observations(for: $0) }
        try store.save(profile)
        let engine = DrivingLearningEngine(store: store)
        let road = try #require(engine.roads.first { $0.id == "a" })
        #expect(road.offeredCount == 12)
        #expect(road.chosenCount == 8)
        #expect(abs(road.metrics.strength - 8.0 / 12) < 0.001)
        #expect(engine.roads.first { $0.id == "direct" }?.avoided == 8)
        engine.removeTrip(profile.trips[0].id)
        let changed = try #require(engine.roads.first { $0.id == "a" })
        #expect(changed.offeredCount == 11)
        #expect(changed.chosenCount == 7)
        #expect(!engine.evidence.contains { $0.tripID == profile.trips[0].id })
        #expect(DrivingLearningEngine(store: store).roads.first { $0.id == "a" }?.chosenCount == 7)
    }

    @Test func longerAlternativeIsNotAShortcutAndDifferentPathsHaveDifferentFingerprints() {
        let alternative = [segment("long", origin, Coordinate(latitude: 52.01, longitude: 21.02)),
                           segment("return", Coordinate(latitude: 52.01, longitude: 21.02), destination)]
        let baseline = [segment("direct", origin, destination)]
        let longer = DrivingDeviation(id: "entry→exit", entry: origin, exit: destination,
            preferred: alternative, avoided: baseline, elapsed: 400)
        #expect(longer.kind == .unknownPreference)
        let shorter = DrivingDeviation(id: "entry→exit", entry: origin, exit: destination,
            preferred: baseline, avoided: alternative, elapsed: 400)
        #expect(shorter.kind == .distanceShortcut)
        #expect(DrivingLearningMath.alternativeID(boundary: "entry→exit", segments: alternative)
            != DrivingLearningMath.alternativeID(boundary: "entry→exit", segments: baseline))
    }

    @Test func oppositeDirectionDoesNotGeneratePreferredArrivalDetour() throws {
        let (engine, store, _) = try fixture(confirmed: true, count: 12)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let opposite = Coordinate(latitude: 52.05, longitude: 21)
        let direct = NavigationRoute(coordinates: [opposite, destination], distance: 3_300,
            expectedTravelTime: 300, maneuvers: [])
        #expect(engine.candidateHints(from: opposite, to: destination,
            context: DrivingPreferenceContext(date: Date()), baseline: direct).isEmpty)
        #expect(!engine.assessment(direct).contributions.contains { $0.reason == .destinationApproach })
        #expect(DrivingEvidenceMath.bearingRelevance(0, 180) == 0)
    }

    @Test func previousProfileMigratesWithoutInventingOffersAndUsesTwoHourContext() throws {
        let (_, store, _) = try fixture(confirmed: true)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let saved = try store.load()
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        legacy.removeValue(forKey: "schemaVersion"); legacy.removeValue(forKey: "evidence")
        var trips = try #require(legacy["trips"] as? [[String: Any]])
        var context = try #require(trips[0]["context"] as? [String: Any])
        context.removeValue(forKey: "bucketHours")
        context["hourBucket"] = Calendar.current.component(.hour, from: saved.trips[0].startedAt) / 4
        trips[0]["context"] = context
        for key in ["offeredVariants", "selectedVariantID", "selectedAgainstAlternative"] { trips[0].removeValue(forKey: key) }
        legacy["trips"] = trips
        let migrated = try JSONDecoder().decode(DrivingProfileSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        try store.save(migrated)
        let engine = DrivingLearningEngine(store: store)
        #expect(engine.patterns.count == 1)
        #expect(engine.patterns[0].confirmed)
        #expect(engine.patterns[0].confidence == 0.72)
        #expect(engine.patterns[0].representative.context.bucketHours == 2)
        #expect(engine.evidence.first { $0.source == .legacyImport }?.offeredAlternative == nil)
        #expect(engine.databaseBytes.map { $0 > 0 } == true)
        let first = DrivingPreferenceContext(date: Calendar.current.date(bySettingHour: 8, minute: 15, second: 0, of: Date())!)
        let second = DrivingPreferenceContext(date: Calendar.current.date(bySettingHour: 11, minute: 45, second: 0, of: Date())!)
        #expect(first.hourBucket != second.hourBucket)
    }

}
