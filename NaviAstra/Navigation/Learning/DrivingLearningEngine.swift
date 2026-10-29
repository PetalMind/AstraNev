import Foundation
import Observation

@MainActor @Observable
final class DrivingLearningEngine {
    static let shared = DrivingLearningEngine()
    private(set) var settings = DrivingLearningSettings()
    private(set) var patterns: [DrivingRoutePattern] = []
    private(set) var approaches: [DrivingApproachPreference] = []
    private(set) var shortcuts: [DrivingShortcutPreference] = []
    private(set) var roads: [DrivingRoadPreference] = []
    private(set) var pendingCount = 0
    private(set) var learnedTripCount = 0
    private(set) var isProcessing = false
    private(set) var message: String?
    private(set) var lastProcessedTripID: UUID?
    @ObservationIgnored private var snapshot = DrivingProfileSnapshot()
    @ObservationIgnored private let store: DrivingProfileStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var roadEvidence: [String: RoadEvidence] = [:]
    var recordingGeneration: Int { revision }
    private(set) var evidence: [PreferenceEvidence] = []
    private(set) var databaseBytes: Int64?
    @ObservationIgnored private var lastAssessments: [UUID: DrivingRouteAssessment] = [:]
    var segmentCount: Int { snapshot.trips.reduce(0) { $0 + $1.segments.count } }
    var offeredVariantCount: Int { snapshot.trips.reduce(0) { $0 + $1.offeredVariants.count } }

    private struct RoadEvidence {
        var segment: LearnedRoadSegment
        var usage = 0
        var selfSelected = 0
        var avoided = 0
        var offered = 0
        var chosen = 0
        var confirmed = false
        var observations: [PreferenceEvidence] = []
    }

    init(store: DrivingProfileStore? = nil) {
        let store = store ?? DrivingProfileStore()
        self.store = store
        do { snapshot = try store.load() }
        catch { message = "Nie udało się odczytać preferencji tras na urządzeniu." }
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        snapshot.trips = Array(snapshot.trips.filter { $0.startedAt >= cutoff }.prefix(300))
        snapshot.pending = Array(snapshot.pending.filter { $0.startedAt >= cutoff }.suffix(10))
        // Enable automatic local learning for the existing installation once.
        // Remote matching remains a separate opt-in; subsequent disable is kept.
        let upgradedAutomaticLearning = snapshot.schemaVersion < 3
        if upgradedAutomaticLearning { snapshot.settings.enabled = true }
        settings = snapshot.settings
        let existing = Set(snapshot.evidence.compactMap(\.tripID))
        let migrated = snapshot.trips.filter { !existing.contains($0.id) }
        for trip in migrated { snapshot.evidence += DrivingEvidenceMath.observations(for: trip, migrated: true) }
        snapshot.schemaVersion = 3
        if !migrated.isEmpty || upgradedAutomaticLearning {
            do { try store.save(snapshot) }
            catch { message = "Nie udało się zapisać ustawień uczenia tras na urządzeniu." }
        }
        rebuild()
    }

    func updateSettings(_ value: DrivingLearningSettings) {
        var next = snapshot
        next.settings = value
        if !value.enabled { next.pending = [] }
        guard commit(next) else { return }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
        settings = value
    }

    func clear() {
        var next = DrivingProfileSnapshot()
        next.settings = settings
        guard commit(next) else { return }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
        lastProcessedTripID = nil
        message = nil
    }

    func remove(_ pattern: DrivingRoutePattern) {
        let ids = Set(pattern.trips.map(\.id))
        var next = snapshot
        next.trips.removeAll { ids.contains($0.id) }
        next.pending.removeAll { ids.contains($0.id) }
        next.evidence.removeAll { $0.tripID.map { ids.contains($0) } ?? false }
        next.evidence.append(removal(subject: "pattern:\(pattern.id)", confidence: pattern.confidence))
        guard commit(next) else { return }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
    }

    func removeTrip(_ id: UUID) {
        var next = snapshot
        next.trips.removeAll { $0.id == id }
        next.pending.removeAll { $0.id == id }
        next.ignoredTripIDs.remove(id)
        next.evidence.removeAll { $0.tripID == id }
        next.evidence.append(action(.tripRemoved, subject: "trip:\(id)", tripID: nil))
        guard commit(next) else { return }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
    }

    func removeRoad(_ id: String) {
        var next = snapshot; next.ignoredRoadIDs.insert(id)
        next.evidence.append(removal(subject: "road:" + id, confidence: roads.first { $0.id == id }?.metrics.confidence))
        _ = commit(next)
    }

    func removeShortcut(_ id: String) {
        var next = snapshot; next.ignoredShortcutIDs.insert(id)
        next.evidence.append(removal(subject: "alternative:" + id, confidence: shortcuts.first { $0.id == id }?.confidence))
        _ = commit(next)
    }

    func removeApproach(_ id: UUID) {
        var next = snapshot; next.ignoredApproachIDs.insert(id)
        next.evidence.append(removal(subject: "approach:\(id)", confidence: approaches.first { $0.id == id }?.confidence))
        _ = commit(next)
    }

    func isRemembered(_ tripID: UUID) -> Bool {
        snapshot.trips.contains { $0.id == tripID && $0.confirmed }
            || snapshot.pending.contains { $0.id == tripID && $0.confirmed }
    }

    func rememberHistoricalTrip(_ trip: TripRecord, endpoint: URL) {
        guard settings.enabled, trip.transportMode == .car, trip.arrived, trip.waypoints.isEmpty,
              trip.trace.count >= 3, !trip.trace.dropFirst().contains(where: \.startsSegment),
              trip.trace.last.map({ $0.coordinate.distance(to: trip.destination.coordinate) <= 200 }) == true else { return }
        if canRemember(trip.id) { remember(trip.id, endpoint: endpoint); return }
        guard !isRemembered(trip.id) else { return }
        var next = snapshot
        next.pending.append(PendingDrivingTrip(id: trip.id, destinationName: trip.destination.name,
            destination: trip.destination.coordinate, startedAt: trip.startedAt, duration: trip.duration,
            context: DrivingPreferenceContext(date: trip.startedAt), trace: sampleTrace(trip.trace, limit: 2_000),
            proposedCoordinates: [], costing: "auto", confirmed: true, allowAutomaticDeviations: false))
        next.pending = Array(next.pending.suffix(10))
        next.evidence.append(action(.manualRouteSave, subject: "trip:\(trip.id)", tripID: trip.id))
        guard commit(next) else { return }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
        processPending(endpoint: endpoint)
    }

    func enqueue(_ trip: TripRecord, proposed: NavigationRoute?, costing: String,
                 context: DrivingPreferenceContext, allowAutomaticDeviations: Bool,
                 recordingGeneration: Int? = nil, offeredRoutes: [NavigationRoute] = [],
                 selectedRouteID: UUID? = nil, selectedAgainstAlternative: Bool = false) {
        guard settings.enabled, trip.transportMode == .car, trip.arrived,
              recordingGeneration.map({ $0 == revision }) ?? true,
              trip.waypoints.isEmpty, trip.duration >= 60, trip.distanceMeters >= 500,
              trip.trace.count >= 3, let proposed,
              let first = trip.trace.first, let last = trip.trace.last,
              last.coordinate.distance(to: trip.destination.coordinate) <= 200,
              first.coordinate.distance(to: proposed.coordinates.first ?? first.coordinate) <= 200,
              !trip.trace.dropFirst().contains(where: \.startsSegment),
              !snapshot.trips.contains(where: { $0.id == trip.id }),
              !snapshot.pending.contains(where: { $0.id == trip.id }) else { return }
        var next = snapshot
        let trace = sampleTrace(trip.trace, limit: 2_000)
        next.pending.append(PendingDrivingTrip(id: trip.id, destinationName: trip.destination.name,
            destination: trip.destination.coordinate, startedAt: trip.startedAt, duration: trip.duration,
            context: context, trace: trace,
            proposedCoordinates: ValhallaServices.sample(proposed.coordinates, limit: 2_000),
            costing: costing, confirmed: false, allowAutomaticDeviations: allowAutomaticDeviations,
            offeredVariants: Array(offeredRoutes.prefix(5)).map {
                DrivingOfferedVariant(id: $0.id.uuidString, coordinates: ValhallaServices.sample($0.coordinates, limit: 1_000))
            }, selectedVariantID: selectedRouteID?.uuidString, selectedAgainstAlternative: selectedAgainstAlternative,
            proposedVariantID: proposed.id.uuidString))
        next.pending = Array(next.pending.suffix(10))
        _ = commit(next)
    }

    private func sampleTrace(_ trace: [TripTracePoint], limit: Int) -> [TripTracePoint] {
        guard trace.count > limit else { return trace }
        return (0..<limit).map { trace[Int(Double($0) * Double(trace.count - 1) / Double(limit - 1))] }
    }

    func processPending(endpoint: URL) {
        guard settings.enabled, task == nil, !snapshot.pending.isEmpty else { return }
        let generation = revision
        let matchingSettings = settings
        isProcessing = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.revision == generation { self.isProcessing = false; self.task = nil }
            }
            let matcher = DrivingRouteMatcher(endpoint: endpoint, settings: matchingSettings)
            let waiting = self.snapshot.pending
            for pending in waiting {
                guard !Task.isCancelled, self.revision == generation, self.settings.enabled else { return }
                do {
                    var actual: [LearnedRoadSegment] = []
                    var proposed: [LearnedRoadSegment] = []
                    var localGeometry = false
                    do {
                        actual = try await matcher.match(pending.trace.map(\.coordinate), costing: pending.costing, recorded: true)
                        // Matching the proposed geometry is needed only for deviation evidence.
                        if !pending.proposedCoordinates.isEmpty && (pending.allowAutomaticDeviations || pending.confirmed) {
                            proposed = try await matcher.match(pending.proposedCoordinates, costing: pending.costing, recorded: false)
                        } else { proposed = [] }
                    } catch {
                        try Task.checkCancellation()
                        if let failure = error as? DrivingLearningFailure, case .incompleteTrace = failure {
                            throw failure
                        }
                        // Missing/out-of-coverage offline graph or an unavailable
                        // opted-in matcher must not prevent validated local learning.
                        actual = try DrivingTraceLearning.segments(trace: pending.trace)
                        proposed = pending.allowAutomaticDeviations || pending.confirmed
                            ? DrivingTraceLearning.segments(coordinates: pending.proposedCoordinates) : []
                        localGeometry = true
                    }
                    guard !actual.isEmpty else { throw DrivingLearningFailure.incompleteTrace }
                    try Task.checkCancellation()
                    guard self.revision == generation else { return }
                    var offered: [DrivingObservedVariant] = []
                    if pending.allowAutomaticDeviations {
                        for variant in pending.offeredVariants {
                            do {
                                let matched: [LearnedRoadSegment]
                                if localGeometry {
                                    matched = DrivingTraceLearning.segments(coordinates: variant.coordinates)
                                } else {
                                    matched = variant.id == pending.proposedVariantID ? proposed
                                        : try await matcher.match(variant.coordinates, costing: pending.costing, recorded: false)
                                }
                                if !matched.isEmpty { offered.append(DrivingObservedVariant(id: variant.id, segments: matched)) }
                            } catch { try Task.checkCancellation() } // Missing offer evidence is unknown, not zero.
                        }
                    }
                    try Task.checkCancellation()
                    guard self.revision == generation else { return }
                    let deviations = localGeometry
                        ? DrivingTraceLearning.deviations(actual: actual, proposed: proposed, trace: pending.trace)
                        : DrivingDeviationDetector.detect(actual: actual, proposed: proposed, trace: pending.trace)
                    let learned = LearnedDrivingTrip(id: pending.id, destinationName: pending.destinationName,
                        origin: pending.trace[0].coordinate, destination: pending.destination, startedAt: pending.startedAt,
                        duration: pending.duration, context: pending.context, segments: actual,
                        deviations: deviations, confirmed: pending.confirmed,
                        automaticPreferenceEligible: pending.allowAutomaticDeviations,
                        offeredVariants: offered, selectedVariantID: pending.selectedVariantID,
                        selectedAgainstAlternative: pending.selectedAgainstAlternative && pending.allowAutomaticDeviations
                            && offered.contains { $0.id == pending.selectedVariantID && DrivingLearningMath.similarity(actual, $0.segments) >= 0.85 })
                    var next = self.snapshot
                    next.pending.removeAll { $0.id == pending.id }
                    next.trips.append(learned)
                    next.evidence += DrivingEvidenceMath.observations(for: learned)
                    let cutoff = Date().addingTimeInterval(-365 * 86_400)
                    next.trips = Array(next.trips.filter { $0.startedAt >= cutoff }
                        .sorted { $0.startedAt > $1.startedAt }.prefix(300))
                    if self.commit(next) {
                        self.lastProcessedTripID = pending.id
                        self.message = nil
                    }
                } catch is CancellationError { return }
                catch {
                    guard self.revision == generation else { return }
                    self.message = (error as? DrivingLearningFailure)?.errorDescription
                        ?? "Nie udało się przeanalizować przejazdu. Spróbujemy ponownie później."
                    // One uncertain observation must not block subsequent valid journeys.
                    continue
                }
            }
        }
    }

    func canRemember(_ tripID: UUID) -> Bool {
        guard settings.enabled else { return false }
        return snapshot.pending.contains { $0.id == tripID && !$0.confirmed }
            || snapshot.trips.contains { $0.id == tripID && !$0.confirmed }
    }

    func hasDeviation(_ tripID: UUID) -> Bool {
        snapshot.trips.first { $0.id == tripID }.map { !$0.deviations.isEmpty && !$0.confirmed } ?? false
    }

    func remember(_ tripID: UUID, endpoint: URL) {
        var next = snapshot
        if let index = next.pending.firstIndex(where: { $0.id == tripID }) { next.pending[index].confirmed = true }
        else if let index = next.trips.firstIndex(where: { $0.id == tripID }) { next.trips[index].confirmed = true }
        else { return }
        next.evidence.append(action(.manualRouteSave, subject: "trip:\(tripID)", tripID: tripID))
        guard commit(next) else { return }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
        processPending(endpoint: endpoint)
    }

    func dismissSuggestion(_ tripID: UUID) {
        var next = snapshot
        next.ignoredTripIDs.insert(tripID)
        _ = commit(next)
    }

    func shouldSuggest(_ tripID: UUID) -> Bool {
        hasDeviation(tripID) && snapshot.trips.first(where: { $0.id == tripID })?.automaticPreferenceEligible == false
            && !snapshot.ignoredTripIDs.contains(tripID)
            && (patterns.first { $0.trips.contains { $0.id == tripID } }?.confidence ?? 0) < 0.7
    }

    private func action(_ source: LearningReason, subject: String, tripID: UUID?) -> PreferenceEvidence {
        PreferenceEvidence(source: source, tripID: tripID, timestamp: Date(), context: nil,
            subject: subject, userConfirmed: source == .manualRouteSave)
    }

    private func removal(subject: String, confidence: Double?) -> PreferenceEvidence {
        var item = action(.manualPreferenceRemoval, subject: subject, tripID: nil)
        item.confidenceBefore = confidence
        item.confidenceAfter = confidence.map { _ in 0 }
        return item
    }

    @discardableResult private func commit(_ input: DrivingProfileSnapshot) -> Bool {
        var next = input
        let retained = Set(next.trips.map(\.id) + next.pending.map(\.id))
        let liveEvidence = next.evidence.filter { $0.tripID.map { retained.contains($0) } ?? true }
        let observations = liveEvidence.filter { $0.tripID != nil }
        let actions = Array(liveEvidence.filter { $0.tripID == nil }.suffix(max(0, 2_000 - observations.count)))
        next.evidence = observations + actions
        // Capture real before/after confidence from the same deterministic reducer.
        let existing = Set(snapshot.evidence.map(\.id))
        for index in next.evidence.indices where !existing.contains(next.evidence[index].id) {
            if let id = next.evidence[index].tripID,
               let trip = next.trips.first(where: { $0.id == id }) {
                let peers = { (all: [LearnedDrivingTrip]) in all.filter {
                    DrivingLearningMath.sameJourney($0, trip) && DrivingLearningMath.similarity($0.segments, trip.segments) >= 0.85
                        && DrivingLearningMath.compatibleChoices($0, trip)
                } }
                next.evidence[index].confidenceBefore = DrivingEvidenceMath.metrics(trips: peers(snapshot.trips), at: Date()).confidence
                next.evidence[index].confidenceAfter = DrivingEvidenceMath.metrics(trips: peers(next.trips), at: Date()).confidence
            }
        }
        do {
            try store.save(next)
            snapshot = next
            rebuild()
            return true
        } catch {
            message = "Nie udało się zapisać preferencji tras na urządzeniu."
            return false
        }
    }

    private func profileTrips() -> [LearnedDrivingTrip] {
        let grouped = Dictionary(grouping: snapshot.evidence.compactMap { item -> PreferenceEvidence? in
            item.tripID == nil ? nil : item
        }, by: { $0.tripID! })
        return snapshot.trips.compactMap { stored in
            guard let events = grouped[stored.id], events.contains(where: {
                [.normalTraversal, .selectedAlternative, .repeatedDeviation, .legacyImport].contains($0.source)
            }) else { return nil }
            var trip = stored
            trip.confirmed = events.contains { $0.userConfirmed || $0.source == .manualRouteSave }
            return trip
        }
    }

    private func rebuild() {
        let trips = profileTrips()
        patterns = DrivingLearningMath.patterns(trips)
        learnedTripCount = trips.count
        pendingCount = snapshot.pending.count
        evidence = snapshot.evidence.sorted { $0.timestamp > $1.timestamp }
        databaseBytes = store.databaseBytes()
        roadEvidence = [:]
        for trip in trips {
            guard let observation = snapshot.evidence.first(where: {
                $0.tripID == trip.id && [.normalTraversal, .selectedAlternative, .repeatedDeviation, .legacyImport].contains($0.source)
            }) else { continue }
            let selected = Set(observation.chosenSegments)
            let deviated = Set(trip.deviations.flatMap { $0.preferred.map(\.id) })
            let primary = Set(trip.offeredVariants.first?.segments.map(\.id) ?? [])
            let strong = trip.automaticPreferenceEligible ? deviated.union(trip.selectedAgainstAlternative ? selected.subtracting(primary) : []) : []
            let offered = Set(observation.offeredSegments ?? [])
            let avoided = Set(observation.avoidedSegments)
            let allSegments = trip.segments + trip.offeredVariants.flatMap(\.segments) + trip.deviations.flatMap(\.avoided)
            var visited = Set<String>()
            for segment in allSegments where visited.insert(segment.id).inserted {
                var value = roadEvidence[segment.id] ?? RoadEvidence(segment: segment)
                if selected.contains(segment.id) { value.usage += 1 }
                if strong.contains(segment.id) { value.selfSelected += 1 }
                if offered.contains(segment.id) { value.offered += 1 }
                if offered.contains(segment.id) && selected.contains(segment.id) { value.chosen += 1 }
                if avoided.contains(segment.id) { value.avoided += 1 }
                value.confirmed = value.confirmed || (trip.confirmed && selected.contains(segment.id))
                value.observations.append(observation)
                roadEvidence[segment.id] = value
            }
        }
        roads = roadEvidence.values.filter {
            !snapshot.ignoredRoadIDs.contains($0.segment.id) && ($0.selfSelected >= 3 || $0.avoided >= 3 || $0.confirmed)
        }.map { value in
            DrivingRoadPreference(id: value.segment.id, names: value.segment.names, uses: value.usage,
                selfSelected: value.selfSelected, avoided: value.avoided,
                preference: Double(value.chosen) / Double(max(1, value.offered)),
                avoidance: min(1, Double(value.avoided) / Double(max(1, value.offered))),
                offeredCount: value.offered, chosenCount: value.chosen,
                metrics: roadMetrics(value, at: Date()), lastUsedAt: value.observations.map(\.timestamp).max(),
                offeredCountKnown: value.observations.contains { $0.offeredAlternative != nil || $0.offeredSegments?.contains(value.segment.id) == true })
        }.sorted { $0.uses + $0.avoided > $1.uses + $1.avoided }
        let deviations = Dictionary(grouping: trips.flatMap(\.deviations), by: \.id)
        shortcuts = deviations.compactMap { id, items in
            guard let deviation = items.first, !snapshot.ignoredShortcutIDs.contains(id),
                  !snapshot.ignoredShortcutIDs.contains(deviation.boundaryID) else { return nil }
            let users = trips.filter { $0.deviations.contains { $0.id == id } }
            let eligible = users.filter { $0.automaticPreferenceEligible || $0.confirmed }
            let offeredUsers = trips.filter { trip in
                trip.offeredVariants.contains { DrivingLearningMath.similarity(deviation.preferred, $0.segments) >= 0.85 }
            }
            let chosenOffered = offeredUsers.filter { DrivingLearningMath.similarity(deviation.preferred, $0.segments) >= 0.85 }
            let durations = items.compactMap(\.elapsed).filter { $0 > 0 }
            let metrics = DrivingEvidenceMath.metrics(trips: eligible, at: Date())
            return DrivingShortcutPreference(id: id, deviation: deviation, uses: users.count,
                acceptanceRate: Double(chosenOffered.count) / Double(max(1, offeredUsers.count)), confidence: metrics.confidence,
                averageObservedDuration: durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count),
                metrics: metrics, confirmed: metrics.userConfirmed,
                offeredCount: offeredUsers.isEmpty ? nil : offeredUsers.count,
                chosenCount: chosenOffered.count, avoidedCount: offeredUsers.count - chosenOffered.count)
        }.sorted { $0.uses > $1.uses }
        var arrivals: [DrivingApproachPreference] = []
        for trip in trips.sorted(by: { $0.startedAt < $1.startedAt }) {
            var final: [LearnedRoadSegment] = [], length = 0.0
            for segment in trip.segments.reversed() {
                final.insert(segment, at: 0); length += segment.length
                if length >= 800 { break }
            }
            let bearing = DrivingEvidenceMath.approachBearing(origin: trip.origin, destination: trip.destination)
            if let index = arrivals.firstIndex(where: {
                $0.destination.distance(to: trip.destination) <= 150
                    && DrivingEvidenceMath.bearingRelevance($0.approachBearing, bearing) >= 0.5
                    && DrivingLearningMath.similarity(final, $0.segments) >= 0.8
                    && DrivingLearningMath.similarity($0.segments, final) >= 0.8
            }) { arrivals[index].trips.append(trip) }
            else { arrivals.append(DrivingApproachPreference(id: trip.id, destination: trip.destination,
                name: trip.destinationName, segments: final, trips: [trip], approachBearing: bearing, entry: final.first?.coordinates.first)) }
        }
        approaches = arrivals.filter { !snapshot.ignoredApproachIDs.contains($0.id) }
    }

    private func roadMetrics(_ value: RoadEvidence, at date: Date,
                             context: DrivingPreferenceContext? = nil, avoiding: Bool = false) -> PreferenceMetrics {
        let signal = avoiding ? value.avoided : value.selfSelected
        let confirmed = value.confirmed && !avoiding
        let confidence = confirmed ? max(0.72, DrivingLearningMath.confidence(signal)) : DrivingLearningMath.confidence(signal)
        let strength = confirmed ? 0.95 : min(1, Double(signal) / Double(max(1, value.offered > 0 ? value.offered : signal)))
        let supporting = value.observations.filter { item in
            avoiding ? item.avoidedSegments.contains(value.segment.id) : item.chosenSegments.contains(value.segment.id)
        }
        var recency = supporting.isEmpty ? 0 : supporting.reduce(0) { $0 + DrivingEvidenceMath.recency($1.timestamp, at: date) } / Double(supporting.count)
        if confirmed {
            let ids = Set(supporting.compactMap(\.tripID))
            if let manual = snapshot.evidence.filter({ $0.source == .manualRouteSave && $0.tripID.map { ids.contains($0) } == true }).map(\.timestamp).max() {
                recency = max(recency, DrivingEvidenceMath.recency(manual, at: date))
            }
        }
        let relevance = context.map { current in value.observations.compactMap(\.context).map { current.affinity(to: $0) }.max() ?? 0 } ?? 1
        return PreferenceMetrics(confidence: confidence, strength: strength, relevance: relevance,
            recency: recency, userConfirmed: confirmed)
    }

    /// Shared by preview, rerouting, EV and traffic comparison. Costs are bounded
    /// and ETA/distance/maneuvers are returned unchanged.
    func ranked(_ routes: [NavigationRoute], preference: RoutePreference,
                from starts: [UUID: Double] = [:], traffic: [UUID: TrafficSnapshot] = [:],
                date: Date = Date()) -> [NavigationRoute] {
        lastAssessments = [:]
        let base = RouteScoringEngine.ranked(routes, preference: preference, from: starts, traffic: traffic)
        guard settings.enabled, !snapshot.trips.isEmpty, preference != .shortest, base.count > 1 else { return base }
        let safe = base.filter { route in
            guard let snapshot = traffic[route.id], abs(date.timeIntervalSince(snapshot.updatedAt)) <= 120 else { return true }
            return !snapshot.incidents.contains { incident in
                guard incident.isRoadClosure, incident.isActive(at: date),
                      let closure = try? RoadClosureAvoidance(geometry: incident.geometry) else { return false }
                return closure.intersects(route)
            }
        }
        if safe.count != base.count { return ranked(safe, preference: preference, from: starts, traffic: traffic, date: date) }
        let scores = base.map { RouteScoringEngine.score($0, from: starts[$0.id] ?? 0, traffic: traffic[$0.id]) }
        let values = RouteScoringEngine.rankingValues(scores, preference: preference)
        let finite = values.filter { $0.isFinite && $0 > 0 }.sorted()
        let scale = finite.isEmpty ? 1 : finite[finite.count / 2]
        let fastest = scores.map(\.travelTime).filter(\.isFinite).min() ?? .infinity
        let assessments = base.map { assessment($0, start: starts[$0.id] ?? 0,
            context: DrivingPreferenceContext(date: date, trafficLevel: DrivingPreferenceContext.measuredTrafficLevel(traffic[$0.id], at: date)), date: date) }
        lastAssessments = Dictionary(uniqueKeysWithValues: zip(base.map(\.id), assessments))
        let weight = DrivingLearningMath.weight(tripCount: learnedTripCount, confirmed: assessments.contains { $0.confirmed })
        for route in base { lastAssessments[route.id]?.appliedWeight = weight }
        guard weight > 0 else { return base }
        let costs = base.indices.map { index -> Double in
            guard values[index].isFinite else { return .infinity }
            let assessment = assessments[index]
            let normalized = preference == .fastest ? values[index] / (values[index] + scale) : values[index]
            // A familiar route must not win solely by history when materially slower.
            let acceptableTime = scores[index].travelTime <= fastest + max(180, fastest * 0.20)
            let personal = acceptableTime
                ? assessment.score : min(0.5, assessment.score)
            if !acceptableTime {
                lastAssessments[base[index].id]?.score = personal
                lastAssessments[base[index].id]?.contributions.removeAll { !$0.penalty }
            }
            return normalized * (1 - weight) + (1 - personal) * weight
        }
        return base.indices.sorted { costs[$0] == costs[$1] ? $0 < $1 : costs[$0] < costs[$1] }.map { base[$0] }
    }

    func isPreferred(_ route: NavigationRoute) -> Bool {
        guard settings.enabled else { return false }
        let assessment = assessment(route)
        return assessment.score >= 0.7 && (assessment.confirmed || learnedTripCount >= 3)
    }

    private func metrics(for trips: [LearnedDrivingTrip], at date: Date,
                         context: DrivingPreferenceContext? = nil) -> PreferenceMetrics {
        var result = DrivingEvidenceMath.metrics(trips: trips, at: date, context: context)
        let ids = Set(trips.map(\.id))
        if let manual = snapshot.evidence.filter({ $0.source == .manualRouteSave && $0.tripID.map { ids.contains($0) } == true }).map(\.timestamp).max() {
            result.recency = max(result.recency, DrivingEvidenceMath.recency(manual, at: date))
        }
        return result
    }

    func assessment(_ route: NavigationRoute, start: Double = 0,
                    context: DrivingPreferenceContext? = nil, date: Date = Date()) -> DrivingRouteAssessment {
        guard let origin = RouteProgressGeometry(route).coordinate(at: start) ?? route.coordinates.first,
              let destination = route.coordinates.last else { return DrivingRouteAssessment() }
        let context = context ?? DrivingPreferenceContext(date: date)
        let geometry = RouteProgressGeometry(route)
        var result = DrivingRouteAssessment()
        for pattern in patterns {
            let trip = pattern.representative
            guard trip.destination.distance(to: destination) <= 150,
                  trip.origin.distance(to: origin) <= 250 || start > 0 else { continue }
            let similarity = DrivingLearningMath.overlap(trip.segments, geometry: geometry, from: start)
            var value = metrics(for: pattern.trips, at: date, context: context)
            value.relevance *= similarity
            result.score = max(result.score, 0.5 + 0.5 * value.effective)
            result.confirmed = result.confirmed || (value.userConfirmed && similarity >= 0.8 && value.recency > 0 && value.relevance >= 0.5)
            if value.effective > 0 {
                result.contributions.append(PreferenceContribution(subject: "pattern:\(pattern.id)",
                    reason: value.userConfirmed ? .manualRouteSave : pattern.trips.contains(where: { $0.selectedAgainstAlternative || !$0.deviations.isEmpty }) ? .selectedAlternative : .normalTraversal, metrics: value))
            }
        }
        if settings.destinationApproach {
            let bearing = DrivingEvidenceMath.approachBearing(origin: origin, destination: destination)
            for approach in approaches where approach.destination.distance(to: destination) <= 150 {
                var value = metrics(for: approach.trips, at: date, context: context)
                let overlap = DrivingLearningMath.overlap(approach.segments, geometry: geometry, from: max(start, geometry.length - 1_200))
                value.relevance *= overlap * DrivingEvidenceMath.bearingRelevance(bearing, approach.approachBearing)
                result.score = max(result.score, 0.5 + 0.25 * value.effective)
                if value.effective > 0 { result.contributions.append(PreferenceContribution(subject: "approach:\(approach.id)", reason: .destinationApproach, metrics: value)) }
            }
        }
        if settings.shortcuts {
            for alternative in shortcuts {
                let users = patterns.flatMap(\.trips).filter { $0.deviations.contains { $0.id == alternative.id } }
                var value = metrics(for: users, at: date, context: context)
                value.relevance *= DrivingLearningMath.overlap(alternative.deviation.preferred, geometry: geometry, from: start)
                result.score = max(result.score, 0.5 + 0.25 * value.effective)
                if value.effective > 0 { result.contributions.append(PreferenceContribution(subject: "alternative:" + alternative.id, reason: .repeatedDeviation, metrics: value)) }
            }
        }
        if settings.roads {
            var reward = 0.0, penalty = 0.0
            for road in roadEvidence.values where !snapshot.ignoredRoadIDs.contains(road.segment.id) {
                guard road.selfSelected >= 3 || road.avoided >= 3 || road.confirmed,
                      let point = road.segment.coordinates.first, geometry.project(point, within: 30) != nil else { continue }
                let overlap = DrivingLearningMath.overlap([road.segment], geometry: geometry, from: start)
                let fraction = min(1, road.segment.length / max(500, geometry.length - start))
                var positive = roadMetrics(road, at: date, context: context)
                var negative = roadMetrics(road, at: date, context: context, avoiding: true)
                positive.relevance *= overlap * fraction
                negative.relevance *= overlap * fraction
                reward += positive.effective
                penalty += negative.effective
                if positive.effective > 0 { result.contributions.append(PreferenceContribution(subject: "road:" + road.segment.id, reason: road.confirmed ? .manualRouteSave : .repeatedSegmentChoice, metrics: positive)) }
                if negative.effective > 0 { result.contributions.append(PreferenceContribution(subject: "road:" + road.segment.id, reason: .repeatedDeviation, metrics: negative, penalty: true)) }
            }
            result.score = max(0, min(1, result.score + reward * 0.35 - penalty * 0.35))
        }
        return result
    }

    func diagnosticAssessments(_ routes: [NavigationRoute], preference: RoutePreference,
                               starts: [UUID: Double] = [:], traffic: [UUID: TrafficSnapshot] = [:]) -> [UUID: DrivingRouteAssessment]? {
        guard settings.enabled else { return nil }
        _ = ranked(routes, preference: preference, from: starts, traffic: traffic)
        return lastAssessments
    }

    /// Produce routing hints, never replay a historical polyline as a navigable
    /// route. The provider revalidates access, closures, costing and turn guidance.
    func candidateHints(from origin: Coordinate, to destination: Coordinate,
                        context: DrivingPreferenceContext, baseline: NavigationRoute? = nil) -> [[Coordinate]] {
        guard settings.enabled else { return [] }
        var hints: [[Coordinate]] = []
        let baselineGeometry = baseline.map { RouteProgressGeometry($0) }
        for pattern in patterns {
            let trip = pattern.representative
            let affinity = pattern.trips.map { context.affinity(to: $0.context) }.max() ?? 0
            let value = metrics(for: pattern.trips, at: Date(), context: context)
            guard affinity >= 0.5, value.effective >= 0.15 else { continue }
            if trip.origin.distance(to: origin) <= 250, trip.destination.distance(to: destination) <= 150 {
                // A short repeated alternative on a long journey can fall between
                // evenly sampled points. Put hints inside the actual deviation.
                if let deviation = trip.deviations.max(by: {
                    $0.preferred.reduce(0) { $0 + $1.length } < $1.preferred.reduce(0) { $0 + $1.length }
                }) {
                    let path = RouteProgressGeometry(coordinates: deviation.preferred.flatMap(\.coordinates))
                    let points = [0.33, 0.67].compactMap { path.coordinate(at: path.length * $0) }
                    if !points.isEmpty { hints.append(points) }
                } else {
                    let path = RouteProgressGeometry(coordinates: trip.coordinates)
                    let points = [0.25, 0.5, 0.75].compactMap { path.coordinate(at: path.length * $0) }
                    if !points.isEmpty { hints.append(points) }
                }
            }
            if hints.count >= 2 { break }
        }
        if settings.destinationApproach, hints.count < 2 {
            for approach in approaches where approach.destination.distance(to: destination) <= 150 {
                let value = metrics(for: approach.trips, at: Date(), context: context)
                let bearing = DrivingEvidenceMath.approachBearing(origin: origin, destination: destination)
                guard value.effective * DrivingEvidenceMath.bearingRelevance(bearing, approach.approachBearing) >= 0.15 else { continue }
                if let point = approach.entry,
                   point.distance(to: destination) >= 300 {
                    let detour = origin.distance(to: point) + point.distance(to: destination) - origin.distance(to: destination)
                    if detour <= max(300, (baselineGeometry?.length ?? origin.distance(to: destination)) * 0.1) { hints.append([point]) }
                }
                if hints.count >= 2 { break }
            }
        }
        if settings.shortcuts, hints.count < 2, let geometry = baselineGeometry {
            for shortcut in shortcuts {
                let users = patterns.flatMap(\.trips).filter { $0.deviations.contains { $0.id == shortcut.id } }
                guard metrics(for: users, at: Date(), context: context).effective >= 0.15 else { continue }
                let deviation = shortcut.deviation
                guard let entry = geometry.project(deviation.entry, within: 75),
                      let exit = geometry.project(deviation.exit, within: 75),
                      entry.distanceFromRoute <= 75, exit.distanceFromRoute <= 75,
                      exit.alongRoute > entry.alongRoute + 200,
                      let point = deviation.preferred[deviation.preferred.count / 2].coordinates.first else { continue }
                hints.append([point])
                if hints.count >= 2 { break }
            }
        }
        return Array(hints.prefix(2))
    }
}
