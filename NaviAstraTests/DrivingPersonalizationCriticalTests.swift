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

    @Test func personalProfileReordersSimilarRoutesWithoutChangingETAOrExplicitPreferences() throws {
        let (engine, store, familiar) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let ordinary = NavigationRoute(coordinates: [origin, destination], distance: 2_224,
                                       expectedTravelTime: 300, maneuvers: [])
        let ranked = engine.ranked([ordinary, familiar], preference: .personalized)
        #expect(ranked.first?.id == familiar.id)
        #expect(ranked.first?.expectedTravelTime == 310)
        #expect(ranked.last?.expectedTravelTime == 300)
        #expect(ranked.first?.coordinates == familiar.coordinates)
        let decision = RoutingDecisionRecord.make(routes: [ordinary, familiar], preference: .personalized,
            selected: familiar.id, source: "personalization-fixture", calculationSeconds: nil,
            personalOrder: ranked.map(\.id))
        #expect(decision.recommendedRouteID == familiar.id)
        #expect(RoutingBenchmarkSuite.replay([decision]).failures == 0)
        for preference in [RoutePreference.fastest, .shortest, .balanced, .comfortable] {
            #expect(engine.ranked([familiar, ordinary], preference: preference).first?.id == ordinary.id)
        }
        var disabled = engine.settings; disabled.enabled = false
        engine.updateSettings(disabled)
        #expect(engine.ranked([ordinary, familiar], preference: .personalized).first?.id == ordinary.id)
        #expect(DrivingLearningEngine(store: store).settings.enabled == false)
    }

    @Test func singleObservationAndMateriallySlowerConfirmedRouteCannotTakeOverRouting() throws {
        let (unconfirmed, store, familiar) = try fixture(confirmed: false)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let ordinary = NavigationRoute(coordinates: [origin, destination], distance: 2_224,
                                       expectedTravelTime: 300, maneuvers: [])
        #expect(unconfirmed.ranked([ordinary, familiar], preference: .personalized).first?.id == ordinary.id)
        #expect(unconfirmed.patterns.first?.confidence == 0)
        unconfirmed.remember(unconfirmed.patterns[0].id, endpoint: URL(string: "https://example.invalid")!)
        var slow = familiar; slow.expectedTravelTime = 900
        #expect(unconfirmed.ranked([ordinary, slow], preference: .personalized).first?.id == ordinary.id)
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
        #expect(engine.ranked([familiar, ordinary], preference: .personalized,
            traffic: [familiar.id: measured]).first?.id == ordinary.id)
    }

    @Test func closureRankingUsesObservationFreshnessAvailabilityAndRemainingRoute() throws {
        let (engine, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let now = Date()
        let route = NavigationRoute(coordinates: [origin, destination], distance: 2_224,
                                    expectedTravelTime: 300, maneuvers: [])
        let closureRoad = [Coordinate(latitude: 52.006, longitude: 21),
                           Coordinate(latitude: 52.009, longitude: 21)]
        func snapshot(observedAt: Date, available: Bool = true) -> TrafficSnapshot {
            let incident = TrafficIncident(id: "closure", description: "Zamknięcie",
                coordinate: closureRoad[0], delaySeconds: nil, category: .roadClosed,
                severity: .major, geometry: closureRoad, observedAt: observedAt)
            return TrafficSnapshot(flow: nil, incidents: [incident], updatedAt: now,
                partialError: nil, incidentDataAvailable: available)
        }
        let staleIncident = snapshot(observedAt: now.addingTimeInterval(-121))
        let freshIncident = snapshot(observedAt: now)
        for preference in [RoutePreference.fastest, .personalized] {
            // A fresh envelope does not refresh the underlying observation.
            #expect(engine.ranked([route], preference: preference,
                traffic: [route.id: staleIncident], date: now).map(\.id) == [route.id])
            #expect(engine.ranked([route], preference: preference, from: [route.id: 1_500],
                traffic: [route.id: freshIncident], date: now).map(\.id) == [route.id])
            #expect(engine.ranked([route], preference: preference, from: [route.id: 100],
                traffic: [route.id: freshIncident], date: now).isEmpty)
            #expect(engine.ranked([route], preference: preference,
                traffic: [route.id: snapshot(observedAt: now, available: false)], date: now).map(\.id) == [route.id])
        }
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

    private func localLearningFixture() -> (DrivingLearningEngine, DrivingProfileStore, NavigationRoute, NavigationRoute) {
        let store = DrivingProfileStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("driving-local-critical-\(UUID().uuidString)/NavigationLearning.sqlite"))
        let ordinary = NavigationRoute(coordinates: [origin, destination], distance: 2_224,
            expectedTravelTime: 300, maneuvers: [])
        let coordinates = [origin,
            Coordinate(latitude: 52.004, longitude: 21),
            Coordinate(latitude: 52.008, longitude: 21.005),
            Coordinate(latitude: 52.014, longitude: 21.005),
            Coordinate(latitude: 52.018, longitude: 21), destination]
        let familiar = NavigationRoute(coordinates: coordinates,
            distance: RouteProgressGeometry(coordinates: coordinates).length,
            expectedTravelTime: 301, maneuvers: [])
        return (DrivingLearningEngine(store: store), store, ordinary, familiar)
    }

    private func continuousTrace(_ route: NavigationRoute, start: Date) -> [TripTracePoint] {
        let geometry = RouteProgressGeometry(route)
        let count = max(2, Int(ceil(geometry.length / 35)))
        return (0...count).compactMap { index in
            let distance = geometry.length * Double(index) / Double(count)
            return geometry.coordinate(at: distance).map {
                TripTracePoint(coordinate: $0, timestamp: start.addingTimeInterval(distance / 9),
                    speedKph: 32.4, startsSegment: index == 0)
            }
        }
    }

    private func waitForLocalLearning(_ engine: DrivingLearningEngine) async throws {
        for _ in 0..<300 {
            if !engine.isProcessing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Local learning did not finish within three seconds")
    }

    @Test func completedGPSLearnsLocallyAndChangesNextProposalAfterRepeatedChoice() async throws {
        let (engine, store, ordinary, familiar) = localLearningFixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        #expect(engine.settings.enabled)
        #expect(!engine.settings.allowRemoteMatching)
        let endpoint = URL(string: "https://example.invalid")!
        let recentStart = Date().addingTimeInterval(-600)
        let context = DrivingPreferenceContext(date: recentStart)
        for index in 0..<3 {
            // Separate days at the same weekday/hour model three independent visits.
            let start = recentStart.addingTimeInterval(Double(index - 2) * 7 * 86_400)
            let trace = continuousTrace(familiar, start: start)
            let trip = TripRecord(destination: Destination(name: "Cel", coordinate: destination),
                startedAt: start, endedAt: try #require(trace.last?.timestamp),
                distanceMeters: familiar.distance, movingSeconds: familiar.distance / 9,
                rerouteCount: 1, arrived: true, transportMode: .car, trace: trace)
            engine.enqueue(trip, proposed: ordinary, costing: "auto", context: context,
                allowAutomaticDeviations: true, recordingGeneration: engine.recordingGeneration,
                offeredRoutes: [ordinary], selectedRouteID: ordinary.id)
            engine.processPending(endpoint: endpoint)
            try await waitForLocalLearning(engine)
            #expect(engine.pendingCount == 0)
            #expect(engine.learnedTripCount == index + 1)
            #expect(engine.patterns.first?.representative.segments.allSatisfy { $0.id.hasPrefix("trace:") } == true)
            #expect(engine.patterns.first?.representative.deviations.isEmpty == false)
            if index < 2 {
                #expect(engine.candidateHints(from: origin, to: destination,
                    context: context, baseline: ordinary).isEmpty)
                #expect(engine.ranked([ordinary, familiar], preference: .personalized, date: recentStart).first?.id == ordinary.id)
            }
        }
        let restored = DrivingLearningEngine(store: store)
        #expect(restored.learnedTripCount == 3)
        #expect(restored.patterns.count == 1)
        #expect(!restored.settings.allowRemoteMatching)
        let hints = restored.candidateHints(from: origin, to: destination, context: context, baseline: ordinary)
        #expect(!hints.isEmpty)
        #expect(hints.flatMap { $0 }.contains { abs($0.longitude - 21.005) < 0.001 })
        #expect(restored.ranked([ordinary, familiar], preference: .personalized, date: recentStart).first?.id == familiar.id)
        #expect(restored.ranked([familiar, ordinary], preference: .fastest, date: recentStart).first?.id == ordinary.id)
        #expect(restored.ranked([ordinary, familiar], preference: .shortest, date: recentStart).first?.id == ordinary.id)
        #expect(familiar.expectedTravelTime == 301)
    }

    @Test func localLearningPreservesGapsAndRejectsNoiseWithoutPromotingTemporaryDetours() async throws {
        let (engine, store, ordinary, familiar) = localLearningFixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let start = Date().addingTimeInterval(-600)
        var broken = continuousTrace(familiar, start: start)
        let middle = broken.count / 2
        broken[middle] = TripTracePoint(coordinate: broken[middle].coordinate,
            timestamp: broken[middle].timestamp, speedKph: broken[middle].speedKph, startsSegment: true)
        let brokenSegments = try DrivingTraceLearning.segments(trace: broken)
        #expect(brokenSegments.filter(\.startsObservation).count == 2)
        let left = broken[middle - 1].coordinate, right = broken[middle].coordinate
        let gapMiddle = Coordinate(latitude: (left.latitude + right.latitude) / 2,
            longitude: (left.longitude + right.longitude) / 2)
        #expect(!brokenSegments.contains {
            (RouteProgressGeometry(coordinates: $0.coordinates).project(gapMiddle, within: 3)?.distanceFromRoute ?? .infinity) <= 3
        })
        let noiseCoordinates = ordinary.coordinates.enumerated().map { index, coordinate in
            Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude + (index == 0 ? 0.0001 : -0.0001))
        }
        let noise = DrivingTraceLearning.segments(coordinates: noiseCoordinates)
        let proposed = DrivingTraceLearning.segments(coordinates: ordinary.coordinates)
        #expect(DrivingTraceLearning.deviations(actual: noise, proposed: proposed,
            trace: continuousTrace(ordinary, start: start)).isEmpty)
        let valid = continuousTrace(familiar, start: start)
        let cutoff = valid.count / 2
        let unfinished = Array(valid.prefix(cutoff))
        #expect(DrivingTraceLearning.deviations(
            actual: DrivingTraceLearning.segments(coordinates: unfinished.map(\.coordinate)),
            proposed: proposed, trace: unfinished).isEmpty)
        var stopped: [TripTracePoint] = []
        for (index, point) in valid.enumerated() {
            stopped.append(TripTracePoint(coordinate: point.coordinate,
                timestamp: point.timestamp.addingTimeInterval(index > cutoff ? 100 : 0),
                speedKph: point.speedKph, startsSegment: point.startsSegment))
            if index == cutoff {
                for offset in 1...5 {
                    stopped.append(TripTracePoint(coordinate: point.coordinate,
                        timestamp: point.timestamp.addingTimeInterval(Double(offset) * 20),
                        speedKph: 0, startsSegment: false))
                }
            }
        }
        let stoppedSegments = try DrivingTraceLearning.segments(trace: stopped)
        #expect(DrivingTraceLearning.deviations(actual: stoppedSegments, proposed: proposed, trace: stopped).isEmpty)
        var jumping = valid
        jumping[cutoff] = TripTracePoint(coordinate: Coordinate(latitude: 52.5, longitude: 21.5),
            timestamp: valid[cutoff].timestamp, speedKph: 32.4, startsSegment: false)
        let invalidTrip = TripRecord(destination: Destination(name: "Cel", coordinate: destination),
            startedAt: start, endedAt: try #require(valid.last?.timestamp),
            distanceMeters: familiar.distance, movingSeconds: familiar.distance / 9,
            rerouteCount: 1, arrived: true, transportMode: .car, trace: jumping)
        engine.enqueue(invalidTrip, proposed: ordinary, costing: "auto", context: DrivingPreferenceContext(date: start),
            allowAutomaticDeviations: true)
        for index in 0..<4 {
            let trace = continuousTrace(familiar, start: start.addingTimeInterval(Double(index) * -7 * 86_400))
            let trip = TripRecord(destination: Destination(name: "Cel", coordinate: destination),
                startedAt: try #require(trace.first?.timestamp), endedAt: try #require(trace.last?.timestamp),
                distanceMeters: familiar.distance, movingSeconds: familiar.distance / 9,
                rerouteCount: 1, arrived: true, transportMode: .car, trace: trace)
            engine.enqueue(trip, proposed: ordinary, costing: "auto", context: DrivingPreferenceContext(date: start),
                allowAutomaticDeviations: false)
            engine.processPending(endpoint: URL(string: "https://example.invalid")!)
            try await waitForLocalLearning(engine)
        }
        #expect(engine.learnedTripCount == 4)
        #expect(engine.pendingCount == 1) // One invalid observation did not block the valid queue.
        #expect(engine.patterns.first?.confidence == 0)
        #expect(engine.candidateHints(from: origin, to: destination,
            context: DrivingPreferenceContext(date: start), baseline: ordinary).isEmpty)
        #expect(engine.ranked([ordinary, familiar], preference: .personalized).first?.id == ordinary.id)
    }

    @Test func automaticLocalLearningMigrationPreservesRemotePrivacyAndLaterDisable() throws {
        let (_, store, _, _) = localLearningFixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var legacy = DrivingProfileSnapshot()
        legacy.schemaVersion = 2
        legacy.settings.enabled = false
        legacy.settings.allowRemoteMatching = false
        try store.save(legacy)
        let engine = DrivingLearningEngine(store: store)
        #expect(engine.settings.enabled)
        #expect(!engine.settings.allowRemoteMatching)
        #expect(try store.load().schemaVersion == 3)
        var settings = engine.settings
        settings.enabled = false
        engine.updateSettings(settings)
        #expect(!DrivingLearningEngine(store: store).settings.enabled)
    }

    @Test func differentOneOffDeviationsOnLongJourneyDoNotBecomeOneRepeatedChoice() async throws {
        let store = DrivingProfileStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("driving-distinct-critical-\(UUID().uuidString)/NavigationLearning.sqlite"))
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let engine = DrivingLearningEngine(store: store)
        let farDestination = Coordinate(latitude: 52.4, longitude: 21)
        let ordinary = NavigationRoute(coordinates: [origin, farDestination], distance: 44_478,
            expectedTravelTime: 4_950, maneuvers: [])
        let recent = Date().addingTimeInterval(-7_000)
        let context = DrivingPreferenceContext(date: recent)
        for index in 0..<3 {
            let latitude = 52.08 + Double(index) * 0.10
            let points = [origin,
                Coordinate(latitude: latitude - 0.012, longitude: 21),
                Coordinate(latitude: latitude - 0.006, longitude: 21.005),
                Coordinate(latitude: latitude + 0.006, longitude: 21.005),
                Coordinate(latitude: latitude + 0.012, longitude: 21), farDestination]
            let route = NavigationRoute(coordinates: points,
                distance: RouteProgressGeometry(coordinates: points).length,
                expectedTravelTime: 4_951, maneuvers: [])
            let start = recent.addingTimeInterval(Double(index - 2) * 7 * 86_400)
            let trace = continuousTrace(route, start: start)
            let trip = TripRecord(destination: Destination(name: "Daleki cel", coordinate: farDestination),
                startedAt: start, endedAt: try #require(trace.last?.timestamp),
                distanceMeters: route.distance, movingSeconds: route.distance / 9,
                rerouteCount: 1, arrived: true, transportMode: .car, trace: trace)
            engine.enqueue(trip, proposed: ordinary, costing: "auto", context: context,
                allowAutomaticDeviations: true)
            engine.processPending(endpoint: URL(string: "https://example.invalid")!)
            try await waitForLocalLearning(engine)
        }
        #expect(engine.learnedTripCount == 3)
        // A common final approach may be learned, but no one-off side road is repeated.
        let hints = engine.candidateHints(from: origin, to: farDestination, context: context, baseline: ordinary)
        #expect(!hints.flatMap { $0 }.contains { $0.longitude > 21.003 })
    }


    private func traceWithStationaryGap(_ route: NavigationRoute, start: Date,
                                        pause: TimeInterval) -> [TripTracePoint] {
        let original = continuousTrace(route, start: start)
        let midpoint = original.count / 2
        var result: [TripTracePoint] = []
        for (index, point) in original.enumerated() {
            result.append(TripTracePoint(coordinate: point.coordinate,
                timestamp: point.timestamp.addingTimeInterval(index > midpoint ? pause : 0),
                speedKph: index == midpoint ? 0 : point.speedKph, startsSegment: point.startsSegment))
            if index == midpoint {
                result.append(TripTracePoint(coordinate: point.coordinate,
                    timestamp: point.timestamp.addingTimeInterval(pause), speedKph: 0, startsSegment: true))
            }
        }
        return result
    }

    private func historicalGapTrip(_ route: NavigationRoute, start: Date,
                                   pause: TimeInterval = 60) -> TripRecord {
        let trace = traceWithStationaryGap(route, start: start, pause: pause)
        return TripRecord(destination: Destination(name: "Cel", coordinate: destination),
            startedAt: start, endedAt: trace.last!.timestamp, distanceMeters: route.distance,
            movingSeconds: route.distance / 9, rerouteCount: 4, arrived: true, transportMode: .car, trace: trace)
    }

    @Test func repeatedStationaryGapsPreserveLearnedRoutesAcrossReload() async throws {
        let (engine, store, ordinary, familiar) = localLearningFixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let endpoint = URL(string: "https://example.invalid")!
        for (index, pause) in [40.0, 60.0, 90.0].enumerated() {
            let start = Date().addingTimeInterval(-600 - Double(index) * 86_400)
            let trip = historicalGapTrip(familiar, start: start, pause: pause)
            let chunks = try DrivingTraceLearning.observationChunks(trace: trip.trace)
            #expect(chunks.count == 2)
            #expect(!DrivingTraceLearning.hasUncertainGaps(trace: trip.trace))
            let boundary = try #require(trip.trace.indices.dropFirst().first { trip.trace[$0].startsSegment })
            #expect(DrivingTraceLearning.isStationaryGap(from: trip.trace[boundary - 1], to: trip.trace[boundary]))
            engine.enqueue(trip, proposed: ordinary, costing: "auto",
                context: DrivingPreferenceContext(date: start), allowAutomaticDeviations: true,
                recordingGeneration: engine.recordingGeneration, offeredRoutes: [ordinary], selectedRouteID: ordinary.id)
            engine.processPending(endpoint: endpoint)
            try await waitForLocalLearning(engine)
            #expect(engine.learnedTripCount == index + 1)
            #expect(engine.pendingCount == 0)
        }
        let saved = try store.load()
        #expect(saved.trips.count == 3)
        #expect(saved.trips.allSatisfy { $0.segments.filter(\.startsObservation).count == 2 })
        #expect(saved.trips.allSatisfy { $0.automaticPreferenceEligible && !$0.confirmed })
        let referenceTrace = continuousTrace(familiar, start: Date())
        let observedLength = zip(referenceTrace, referenceTrace.dropFirst()).reduce(0.0) {
            $0 + $1.0.coordinate.distance(to: $1.1.coordinate)
        }
        #expect(saved.trips.allSatisfy { abs($0.segments.reduce(0) { $0 + $1.length } - observedLength) < 2 })
        let restored = DrivingLearningEngine(store: store)
        #expect(restored.learnedTripCount == 3)
        #expect(restored.patterns.flatMap(\.trips).allSatisfy {
            $0.segments.filter(\.startsObservation).count == 2
        })
        #expect(!restored.settings.allowRemoteMatching)
    }

    @Test func missingMovingSectionNeverCreatesRoadOrDeviationAcrossGap() throws {
        let (_, store, ordinary, familiar) = localLearningFixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let complete = continuousTrace(familiar, start: Date().addingTimeInterval(-600))
        let lower = complete.count / 3, upper = complete.count * 2 / 3
        var broken = Array(complete.prefix(lower)) + Array(complete.suffix(from: upper))
        let resumed = broken[lower]
        broken[lower] = TripTracePoint(coordinate: resumed.coordinate, timestamp: resumed.timestamp,
            speedKph: resumed.speedKph, startsSegment: true)
        let chunks = try DrivingTraceLearning.observationChunks(trace: broken)
        let segments = try DrivingTraceLearning.segments(trace: broken)
        #expect(chunks.count == 2)
        #expect(DrivingTraceLearning.hasUncertainGaps(trace: broken))
        #expect(segments.filter(\.startsObservation).count == 2)
        let observedLength = chunks.reduce(0.0) { total, chunk in
            total + zip(chunk, chunk.dropFirst()).reduce(0) { $0 + $1.0.coordinate.distance(to: $1.1.coordinate) }
        }
        #expect(abs(segments.reduce(0) { $0 + $1.length } - observedLength) < 2)
        #expect(familiar.distance - observedLength > 500)
        let missingPoint = complete[(lower + upper) / 2].coordinate
        #expect(!segments.contains {
            (RouteProgressGeometry(coordinates: $0.coordinates).project(missingPoint, within: 25)?.distanceFromRoute ?? .infinity) <= 25
        })
        #expect(DrivingTraceLearning.deviations(actual: segments,
            proposed: DrivingTraceLearning.segments(coordinates: ordinary.coordinates), trace: broken).isEmpty)

        // A boundary flag does not make an unmarked impossible jump inside a
        // retained observation trustworthy.
        var jumping = complete
        let midpoint = jumping.count / 2
        jumping[midpoint] = TripTracePoint(coordinate: Coordinate(latitude: 52.5, longitude: 21.5),
            timestamp: jumping[midpoint].timestamp, speedKph: 32.4, startsSegment: false)
        #expect(throws: DrivingLearningFailure.self) {
            try DrivingTraceLearning.observationChunks(trace: jumping)
        }
    }

    @Test func historyRecoveryImportsAllQualifiedGapTripsOnceWithoutInventingChoices() throws {
        let (_, store, familiar) = try fixture(confirmed: false)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var old = try store.load()
        old.historyRecoveryVersion = 0
        try store.save(old)
        let engine = DrivingLearningEngine(store: store)
        let records = (0..<11).map { index in
            historicalGapTrip(familiar, start: Date().addingTimeInterval(-600 - Double(index) * 86_400))
        }
        engine.recoverHistoricalTrips(records)
        let recovered = try store.load()
        let imported = recovered.trips.filter(\.recoveredFromHistory)
        #expect(imported.count == 11)
        #expect(engine.learnedTripCount == 12)
        #expect(recovered.pending.isEmpty)
        #expect(recovered.historyRecoveryVersion == 1)
        #expect(Set(imported.map(\.id)) == Set(records.map(\.id)))
        #expect(imported.allSatisfy {
            !$0.confirmed && $0.deviations.isEmpty && $0.offeredVariants.isEmpty
                && !$0.selectedAgainstAlternative && $0.selectedVariantID == nil
                && $0.segments.filter(\.startsObservation).count == 2
        })
        let importedIDs = Set(imported.map(\.id))
        let observations = recovered.evidence.filter { $0.tripID.map { importedIDs.contains($0) } ?? false }
        #expect(observations.contains { $0.source == .historyRecovery })
        #expect(observations.allSatisfy {
            !$0.userConfirmed && $0.offeredAlternative == nil && $0.offeredSegments == nil
                && $0.selectedVariant == nil && $0.avoidedSegments.isEmpty
        })
        let restored = DrivingLearningEngine(store: store)
        restored.recoverHistoricalTrips(records)
        let repeated = try store.load()
        #expect(repeated.trips.count == recovered.trips.count)
        #expect(repeated.evidence.count == recovered.evidence.count)
        #expect(!restored.settings.allowRemoteMatching)

        restored.removeTrip(records[0].id)
        DrivingLearningEngine(store: store).recoverHistoricalTrips(records)
        #expect(!((try store.load()).trips.contains { $0.id == records[0].id }))
        restored.clear()
        DrivingLearningEngine(store: store).recoverHistoricalTrips(records)
        #expect(try store.load().trips.isEmpty)
    }

    @Test func historyRecoveryRespectsDisabledEmptyAndPreviouslyRemovedProfiles() throws {
        let (_, store, familiar) = try fixture(confirmed: false)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let trip = historicalGapTrip(familiar, start: Date().addingTimeInterval(-600))
        var old = try store.load()
        old.historyRecoveryVersion = 0
        old.settings.enabled = false
        try store.save(old)
        let disabled = DrivingLearningEngine(store: store)
        disabled.recoverHistoricalTrips([trip])
        #expect(try store.load().trips.count == 1)
        #expect(try store.load().historyRecoveryVersion == 1)
        var settings = disabled.settings
        settings.enabled = true
        disabled.updateSettings(settings)
        disabled.recoverHistoricalTrips([trip])
        #expect(!((try store.load()).trips.contains { $0.id == trip.id }))

        var empty = DrivingProfileSnapshot()
        empty.historyRecoveryVersion = 0
        try store.save(empty)
        DrivingLearningEngine(store: store).recoverHistoricalTrips([trip])
        #expect(try store.load().trips.isEmpty)
        #expect(try store.load().historyRecoveryVersion == 1)

        // Removing an old preference before migration cannot bring that history
        // back while another, unrelated learned trip remains in the profile.
        old.settings.enabled = true
        old.historyRecoveryVersion = 0
        var related = old.trips[0]
        related = LearnedDrivingTrip(id: trip.id, destinationName: trip.destination.name,
            origin: familiar.coordinates[0], destination: destination, startedAt: trip.startedAt,
            duration: trip.duration, context: DrivingPreferenceContext(date: trip.startedAt),
            segments: related.segments, deviations: [], confirmed: false)
        old.trips.append(related)
        try store.save(old)
        let removed = DrivingLearningEngine(store: store)
        removed.removeTrip(trip.id)
        removed.recoverHistoricalTrips([trip])
        #expect(!((try store.load()).trips.contains { $0.id == trip.id }))
    }


    @Test func recoveredRepeatedGeometryChangesNextProposalWithoutInventingHistoricalAlternatives() throws {
        let (_, store, ordinary, familiar) = localLearningFixture()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let recent = Date().addingTimeInterval(-600)
        var old = DrivingProfileSnapshot()
        old.historyRecoveryVersion = 0
        old.trips = [LearnedDrivingTrip(id: UUID(), destinationName: "Inny cel",
            origin: origin, destination: destination, startedAt: recent, duration: 300,
            context: DrivingPreferenceContext(date: recent),
            segments: DrivingTraceLearning.segments(coordinates: ordinary.coordinates), deviations: [], confirmed: false)]
        try store.save(old)
        let engine = DrivingLearningEngine(store: store)
        let records = (0..<3).map { index in
            // A habit remains useful when visits happen at different hours.
            historicalGapTrip(familiar, start: recent.addingTimeInterval(-Double(index) * 7 * 86_400 - Double(index) * 3 * 3_600))
        }
        engine.recoverHistoricalTrips(records)
        let restored = DrivingLearningEngine(store: store)
        let context = DrivingPreferenceContext(date: recent)
        let hints = restored.candidateHints(from: origin, to: destination, context: context, baseline: ordinary)
        #expect(!hints.isEmpty)
        #expect(hints.flatMap { $0 }.contains { $0.longitude > 21.003 })
        #expect(restored.ranked([ordinary, familiar], preference: .personalized, date: recent).first?.id == familiar.id)
        #expect(restored.ranked([familiar, ordinary], preference: .fastest, date: recent).first?.id == ordinary.id)
        #expect(restored.ranked([ordinary, familiar], preference: .shortest, date: recent).first?.id == ordinary.id)
        #expect(familiar.expectedTravelTime == 301)
        let recovered = try store.load().trips.filter(\.recoveredFromHistory)
        #expect(recovered.allSatisfy { !$0.confirmed && $0.offeredVariants.isEmpty && $0.deviations.isEmpty })

        // Three records of one day's drive must not impersonate three independent
        // days of observed behaviour.
        let oneDay = recovered.map { trip in
            LearnedDrivingTrip(id: UUID(), destinationName: trip.destinationName,
                origin: trip.origin, destination: trip.destination, startedAt: recent,
                duration: trip.duration, context: context, segments: trip.segments, deviations: [], confirmed: false)
        }
        #expect(DrivingHabitPreference.candidates(trips: oneDay, origin: origin,
            destination: destination, context: context, baseline: ordinary, date: Date()).isEmpty)
    }


    @Test func shortPersonalSectionOnLongRouteSurvivesDiversityButExactCopyDoesNot() {
        let farDestination = Coordinate(latitude: 52.4, longitude: 21)
        let baseline = NavigationRoute(coordinates: [origin, farDestination], distance: 44_478,
            expectedTravelTime: 3_600, maneuvers: [])
        let points = [origin,
            Coordinate(latitude: 52.18, longitude: 21),
            Coordinate(latitude: 52.1804, longitude: 21.002),
            Coordinate(latitude: 52.181, longitude: 21.002),
            Coordinate(latitude: 52.1814, longitude: 21), farDestination]
        let personal = NavigationRoute(coordinates: points,
            distance: RouteProgressGeometry(coordinates: points).length,
            expectedTravelTime: 3_620, maneuvers: [])
        let exactCopy = NavigationRoute(coordinates: points, distance: personal.distance,
            expectedTravelTime: personal.expectedTravelTime, maneuvers: [])
        #expect(RouteSimilarity.overlap(baseline, personal) > 0.98)
        #expect(RouteSimilarity.diverse([baseline, personal]).count == 1)
        let kept = RouteSimilarity.diverse([baseline, personal, exactCopy],
            preserving: [personal.id, exactCopy.id])
        #expect(kept.map(\.id) == [baseline.id, personal.id])
    }


    @Test func asyncHistoryRecoveryRespectsResetAndParentCancellation() async throws {
        let (_, store, familiar) = try fixture(confirmed: false)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var old = try store.load()
        old.historyRecoveryVersion = 0
        try store.save(old)
        let historical = historicalGapTrip(familiar, start: Date().addingTimeInterval(-600))
        let resetEngine = DrivingLearningEngine(store: store)
        var resetReads = 0
        await resetEngine.recoverHistoricalTripsAfterLaunch(records: {
            resetReads += 1
            if resetReads == 1 { resetEngine.clear() }
            return [historical]
        }, historyRevision: { 0 })
        #expect(resetReads == 1)
        #expect(try store.load().trips.isEmpty)
        #expect(try store.load().historyRecoveryVersion == 1)

        try store.save(old)
        let cancelledEngine = DrivingLearningEngine(store: store)
        var recovery: Task<Void, Never>?
        var cancellationReads = 0
        recovery = Task { @MainActor in
            await cancelledEngine.recoverHistoricalTripsAfterLaunch(records: {
                cancellationReads += 1
                recovery?.cancel()
                return [historical]
            }, historyRevision: { 0 })
        }
        await recovery?.value
        let cancelled = try store.load()
        #expect(cancellationReads == 1)
        #expect(cancelled.trips.count == old.trips.count)
        #expect(cancelled.historyRecoveryVersion == 0)
        #expect(!cancelled.trips.contains { $0.id == historical.id })

        // Cancellation must release the operation so a later visible view can retry.
        await cancelledEngine.recoverHistoricalTripsAfterLaunch(records: { [historical] }, historyRevision: { 0 })
        #expect(try store.load().trips.contains { $0.id == historical.id })
        #expect(try store.load().historyRecoveryVersion == 1)
    }

    @Test func asyncHistoryRecoveryRetriesWithoutOverwritingNewPendingTrip() async throws {
        let (_, store, familiar) = try fixture(confirmed: false)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var old = try store.load()
        old.historyRecoveryVersion = 0
        try store.save(old)
        let historical = historicalGapTrip(familiar, start: Date().addingTimeInterval(-86_400))
        let newlyCompleted = historicalGapTrip(familiar, start: Date().addingTimeInterval(-600))
        let engine = DrivingLearningEngine(store: store)
        var reads = 0
        await engine.recoverHistoricalTripsAfterLaunch(records: {
            reads += 1
            if reads == 1 {
                engine.enqueue(newlyCompleted, proposed: familiar, costing: "auto",
                    context: DrivingPreferenceContext(date: newlyCompleted.startedAt),
                    allowAutomaticDeviations: true, recordingGeneration: engine.recordingGeneration)
            }
            return [historical]
        }, historyRevision: { 0 })
        let saved = try store.load()
        #expect(reads == 2)
        #expect(saved.trips.contains { $0.id == historical.id && $0.recoveredFromHistory })
        #expect(saved.pending.contains { $0.id == newlyCompleted.id })
        #expect(!saved.trips.contains { $0.id == newlyCompleted.id })
        #expect(saved.historyRecoveryVersion == 1)
    }

    @Test func asyncHistoryRecoveryRereadsHistoryAfterDeletionDuringPreparation() async throws {
        let (_, store, familiar) = try fixture(confirmed: false)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var old = try store.load()
        old.historyRecoveryVersion = 0
        try store.save(old)
        let deleted = historicalGapTrip(familiar, start: Date().addingTimeInterval(-86_400))
        let retained = historicalGapTrip(familiar, start: Date().addingTimeInterval(-600))
        let engine = DrivingLearningEngine(store: store)
        var revision: UInt64 = 0
        var reads = 0
        await engine.recoverHistoricalTripsAfterLaunch(records: {
            reads += 1
            if reads == 1 {
                revision &+= 1
                return [deleted, retained]
            }
            return [retained]
        }, historyRevision: { revision })
        let saved = try store.load()
        #expect(reads == 2)
        #expect(!saved.trips.contains { $0.id == deleted.id })
        #expect(saved.trips.contains { $0.id == retained.id && $0.recoveredFromHistory })
        #expect(saved.historyRecoveryVersion == 1)
    }

}
