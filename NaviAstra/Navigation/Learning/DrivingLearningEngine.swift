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
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var historyRecoveryWorker: Task<HistoryRecoveryPlan, Error>?
    @ObservationIgnored private var historyRecoveryOperation: UUID?
    private var historyPresentationRevision = 0
    @ObservationIgnored private var canWriteProfile = true
    @ObservationIgnored private var roadEvidence: [String: RoadEvidence] = [:]
    @ObservationIgnored private var excludedHabitTripIDs: Set<UUID> = []
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

    private nonisolated struct HistoryRecoveryRecord: Sendable {
        let id: UUID
        let destinationName: String
        let destination: Coordinate
        let startedAt: Date
        let duration: TimeInterval
        let trace: [TripTracePoint]
    }

    private nonisolated struct HistoryRecoveryPlan: Sendable {
        let snapshot: DrivingProfileSnapshot
        let patterns: [DrivingRoutePattern]
    }

    init(store: DrivingProfileStore? = nil) {
        let store = store ?? DrivingProfileStore()
        self.store = store
        do { snapshot = try store.load() }
        catch {
            canWriteProfile = false
            message = "Nie udało się odczytać preferencji tras na urządzeniu. Zachowaliśmy dotychczasowy zapis."
            NSLog("DrivingLearningEngine load: %@", String(describing: error))
        }
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        snapshot.trips = Array(snapshot.trips.filter { $0.startedAt >= cutoff }.prefix(300))
        snapshot.pending = Array(snapshot.pending.filter { $0.startedAt >= cutoff }.suffix(10))
        let closedRecovery = !snapshot.settings.enabled && snapshot.historyRecoveryVersion < 1
        if closedRecovery { snapshot.historyRecoveryVersion = 1 }
        // Enable automatic local learning for the existing installation once.
        // Remote matching remains a separate opt-in; subsequent disable is kept.
        let upgradedAutomaticLearning = snapshot.schemaVersion < 3
        if upgradedAutomaticLearning { snapshot.settings.enabled = true }
        settings = snapshot.settings
        let existing = Set(snapshot.evidence.compactMap(\.tripID))
        let migrated = snapshot.trips.filter { !existing.contains($0.id) }
        for trip in migrated { snapshot.evidence += DrivingEvidenceMath.observations(for: trip, migrated: true) }
        snapshot.schemaVersion = 3
        if canWriteProfile && (!migrated.isEmpty || upgradedAutomaticLearning || closedRecovery) {
            do { try store.save(snapshot) }
            catch { message = "Nie udało się zapisać ustawień uczenia tras na urządzeniu." }
        }
        rebuild()
    }

    func updateSettings(_ value: DrivingLearningSettings) {
        var next = snapshot
        next.settings = value
        next.historyRecoveryVersion = 1
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
        next.historyRecoveryVersion = 1
        next.trips.removeAll { ids.contains($0.id) }
        next.pending.removeAll { ids.contains($0.id) }
        next.evidence.removeAll { $0.tripID.map { ids.contains($0) } ?? false }
        next.evidence.append(removal(subject: "pattern:\(pattern.id)", confidence: pattern.confidence))
        guard commit(next) else { return }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
    }

    @discardableResult
    func removeTrip(_ id: UUID) -> Bool {
        guard canWriteProfile else {
            message = "Nie udało się usunąć danych uczenia. Najpierw trzeba odzyskać zapis preferencji tras."
            return false
        }
        // Retrying a durable deletion must not append the same action repeatedly.
        guard snapshot.trips.contains(where: { $0.id == id })
            || snapshot.pending.contains(where: { $0.id == id })
            || snapshot.ignoredTripIDs.contains(id)
            || snapshot.evidence.contains(where: { $0.tripID == id }) else { return true }
        var next = snapshot
        next.historyRecoveryVersion = 1
        next.trips.removeAll { $0.id == id }
        next.pending.removeAll { $0.id == id }
        next.ignoredTripIDs.remove(id)
        next.evidence.removeAll { $0.tripID == id }
        next.evidence.append(action(.tripRemoved, subject: "trip:\(id)", tripID: nil))
        guard commit(next) else { return false }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
        return true
    }

    func removeRoad(_ id: String) {
        var next = snapshot; next.ignoredRoadIDs.insert(id)
        next.historyRecoveryVersion = 1
        next.evidence.append(removal(subject: "road:" + id, confidence: roads.first { $0.id == id }?.metrics.confidence))
        _ = commit(next)
    }

    func removeShortcut(_ id: String) {
        var next = snapshot; next.ignoredShortcutIDs.insert(id)
        next.historyRecoveryVersion = 1
        next.evidence.append(removal(subject: "alternative:" + id, confidence: shortcuts.first { $0.id == id }?.confidence))
        _ = commit(next)
    }

    func removeApproach(_ id: UUID) {
        var next = snapshot; next.ignoredApproachIDs.insert(id)
        next.historyRecoveryVersion = 1
        next.evidence.append(removal(subject: "approach:\(id)", confidence: approaches.first { $0.id == id }?.confidence))
        _ = commit(next)
    }

    func isRemembered(_ tripID: UUID) -> Bool {
        _ = historyPresentationRevision
        return snapshot.trips.contains { $0.id == tripID && $0.confirmed }
            || snapshot.pending.contains { $0.id == tripID && $0.confirmed }
    }

    func historyRememberUnavailableReason(_ trip: TripRecord) -> String? {
        guard settings.enabled else { return "Włącz uczenie tras w ustawieniach, aby zapamiętać przejazd." }
        guard canWriteProfile else { return "Zapis preferencji tras wymaga odzyskania. Nie można teraz zapamiętać przejazdu." }
        guard trip.transportMode == .car else { return "Zapamiętywanie tras jest dostępne dla przejazdów samochodem." }
        guard trip.arrived else { return "Można zapamiętać trasę po dotarciu do celu." }
        guard trip.waypoints.isEmpty else { return "Zapamiętywanie tras z przystankami pośrednimi nie jest jeszcze dostępne." }
        if isRemembered(trip.id) { return nil }
        guard (try? DrivingTraceLearning.observationChunks(trace: trip.trace)) != nil else {
            return "Ślad GPS jest zbyt krótki lub nie zawiera wystarczająco wielu wiarygodnych pomiarów, aby zapamiętać trasę."
        }
        guard trip.trace.last.map({ $0.coordinate.distance(to: trip.destination.coordinate) <= 200 }) == true else {
            return "Ślad GPS kończy się zbyt daleko od celu, aby zapamiętać tę trasę."
        }
        return nil
    }

    @discardableResult
    func rememberHistoricalTrip(_ trip: TripRecord, endpoint: URL) -> Bool {
        if let reason = historyRememberUnavailableReason(trip) {
            message = reason
            return false
        }
        if isRemembered(trip.id) { return true }
        if canRemember(trip.id) {
            remember(trip.id, endpoint: endpoint)
            return isRemembered(trip.id)
        }
        let trace = sampleTrace(trip.trace, limit: 2_000)
        guard !trace.isEmpty else {
            message = "Ślad ma zbyt wiele oddzielnych fragmentów, aby bezpiecznie zapamiętać tę trasę."
            return false
        }
        var next = snapshot
        next.pending.append(PendingDrivingTrip(id: trip.id, destinationName: trip.destination.name,
            destination: trip.destination.coordinate, startedAt: trip.startedAt, duration: trip.duration,
            context: DrivingPreferenceContext(date: trip.startedAt), trace: trace,
            proposedCoordinates: [], costing: "auto", confirmed: true, allowAutomaticDeviations: false))
        next.pending = Array(next.pending.suffix(10))
        next.evidence.append(action(.manualRouteSave, subject: "trip:\(trip.id)", tripID: trip.id))
        guard commit(next) else { return false }
        revision &+= 1
        task?.cancel(); task = nil; isProcessing = false
        processPending(endpoint: endpoint)
        return true
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
              !snapshot.trips.contains(where: { $0.id == trip.id }),
              !snapshot.pending.contains(where: { $0.id == trip.id }) else { return }
        var next = snapshot
        let trace = sampleTrace(trip.trace, limit: 2_000)
        guard !trace.isEmpty else { return }
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
        // Preserve both sides of every gap. Sampling must not turn separate
        // observations into a made-up continuous road.
        var indexes: Set<Int> = [0, trace.count - 1]
        for index in trace.indices.dropFirst() where trace[index].startsSegment
            || trace[index].timestamp.timeIntervalSince(trace[index - 1].timestamp) > 30 {
            indexes.insert(index - 1)
            indexes.insert(index)
        }
        guard indexes.count < limit - 1 else { return [] }
        let remaining = limit - indexes.count
        indexes.formUnion((0..<remaining).map { Int(Double($0) * Double(trace.count - 1) / Double(remaining - 1)) })
        return indexes.sorted().map { trace[$0] }
    }

    /// Recover facts already present in the local history, not imagined choices
    /// against a route that was never archived. Runs once for an existing profile.
    func recoverHistoricalTrips(_ records: [TripRecord]) {
        guard canWriteProfile, snapshot.historyRecoveryVersion < 1,
              let plan = try? Self.planHistoryRecovery(snapshot: snapshot,
                  records: historyRecoveryRecords(records), date: Date()) else { return }
        _ = commit(plan.snapshot, preparedPatterns: plan.patterns)
    }

    /// The view starts this after appearing. Only immutable values cross into
    /// the worker; SQLite and observable state remain owned by the main actor.
    func recoverHistoricalTripsAfterLaunch(records: @MainActor () -> [TripRecord],
                                           historyRevision: @MainActor () -> UInt64) async {
        guard canWriteProfile, snapshot.historyRecoveryVersion < 1,
              historyRecoveryOperation == nil, !Task.isCancelled else { return }
        let operation = UUID()
        historyRecoveryOperation = operation
        defer {
            if historyRecoveryOperation == operation {
                historyRecoveryWorker?.cancel()
                historyRecoveryWorker = nil
                historyRecoveryOperation = nil
            }
        }
        while !Task.isCancelled, canWriteProfile, snapshot.historyRecoveryVersion < 1 {
            let generation = revision
            let stateRevision = snapshotRevision
            let sourceRevision = historyRevision()
            let input = snapshot
            let history = historyRecoveryRecords(records())
            let date = Date()
            let worker = Task.detached(priority: .utility) {
                try Self.planHistoryRecovery(snapshot: input, records: history, date: date)
            }
            historyRecoveryWorker = worker
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            historyRecoveryWorker = nil
            guard !Task.isCancelled, canWriteProfile, snapshot.historyRecoveryVersion < 1 else { return }
            // A completed trip, pending match, manual action, or history deletion
            // must not be overwritten by a result prepared from an older snapshot.
            guard revision == generation, snapshotRevision == stateRevision,
                  historyRevision() == sourceRevision else {
                await Task.yield()
                continue
            }
            guard case let .success(plan) = result else { return }
            _ = commit(plan.snapshot, preparedPatterns: plan.patterns)
            return
        }
    }

    private func historyRecoveryRecords(_ records: [TripRecord]) -> [HistoryRecoveryRecord] {
        records.sorted { $0.startedAt > $1.startedAt }.prefix(300).compactMap { trip in
            guard trip.transportMode == .car, trip.arrived, trip.waypoints.isEmpty,
                  trip.duration >= 60, trip.distanceMeters >= 500 else { return nil }
            return HistoryRecoveryRecord(id: trip.id, destinationName: trip.destination.name,
                destination: trip.destination.coordinate, startedAt: trip.startedAt,
                duration: trip.duration, trace: trip.trace)
        }
    }

    private nonisolated static func planHistoryRecovery(snapshot: DrivingProfileSnapshot,
                                                        records: [HistoryRecoveryRecord],
                                                        date: Date) throws -> HistoryRecoveryPlan {
        try Task.checkCancellation()
        var next = snapshot
        next.historyRecoveryVersion = 1
        // A legacy empty profile could be a deliberate reset. A disabled profile
        // must not import drives made while learning was switched off.
        guard snapshot.settings.enabled, !snapshot.trips.isEmpty else {
            return HistoryRecoveryPlan(snapshot: next, patterns: DrivingLearningMath.patterns(profileTrips(in: next)))
        }
        let removalCutoff = snapshot.evidence.filter {
            $0.source == .manualPreferenceRemoval || $0.source == .tripRemoved
        }.map(\.timestamp).max() ?? .distantPast
        let cutoff = max(removalCutoff, date.addingTimeInterval(-365 * 86_400))
        var existing = Set(snapshot.trips.map(\.id) + snapshot.pending.map(\.id))
        for trip in records {
            try Task.checkCancellation()
            guard !existing.contains(trip.id), trip.startedAt > cutoff,
                  zip(trip.trace, trip.trace.dropFirst()).contains(where: {
                      $0.1.startsSegment || $0.1.timestamp.timeIntervalSince($0.0.timestamp) > 30
                  }),
                  let first = trip.trace.first, let last = trip.trace.last,
                  last.coordinate.distance(to: trip.destination) <= 200,
                  let segments = try? DrivingTraceLearning.segments(trace: trip.trace) else { continue }
            var learned = LearnedDrivingTrip(id: trip.id, destinationName: trip.destinationName,
                origin: first.coordinate, destination: trip.destination, startedAt: trip.startedAt,
                duration: trip.duration, context: DrivingPreferenceContext(date: trip.startedAt),
                segments: segments, deviations: [], confirmed: false)
            learned.recoveredFromHistory = true
            existing.insert(trip.id)
            next.trips.append(learned)
            next.evidence += DrivingEvidenceMath.observations(for: learned)
        }
        next.trips = Array(next.trips.sorted { $0.startedAt > $1.startedAt }.prefix(300))
        try Task.checkCancellation()
        let patterns = DrivingLearningMath.patterns(profileTrips(in: next))
        try Task.checkCancellation()
        return HistoryRecoveryPlan(snapshot: next, patterns: patterns)
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
                    let chunks = try DrivingTraceLearning.observationChunks(trace: pending.trace)
                    var actual: [LearnedRoadSegment] = []
                    var proposed: [LearnedRoadSegment] = []
                    var localGeometry = chunks.count > 1
                    do {
                        if localGeometry {
                            // Matching one concatenated trace would let the router invent
                            // connections across GPS gaps. Keep local observed sections.
                            actual = DrivingTraceLearning.segments(chunks: chunks)
                        } else {
                            actual = try await matcher.match(chunks[0].map(\.coordinate), costing: pending.costing, recorded: true)
                        }
                        // Matching the proposed geometry is needed only for deviation evidence.
                        if !pending.proposedCoordinates.isEmpty && (pending.allowAutomaticDeviations || pending.confirmed) {
                            proposed = localGeometry ? DrivingTraceLearning.segments(coordinates: pending.proposedCoordinates)
                                : try await matcher.match(pending.proposedCoordinates, costing: pending.costing, recorded: false)
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
                            && !DrivingTraceLearning.hasUncertainGaps(trace: pending.trace)
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

    @discardableResult private func commit(_ input: DrivingProfileSnapshot,
                                          preparedPatterns: [DrivingRoutePattern]? = nil) -> Bool {
        guard canWriteProfile else {
            message = "Zapis preferencji tras jest wstrzymany, aby zachować dane wymagające odzyskania."
            return false
        }
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
                // A batch recovery is not a sequence of fresh driver choices.
                // Leave unknown per-event confidence unset instead of doing a
                // quadratic replay of every historical event on app launch.
                if trip.recoveredFromHistory { continue }
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
            snapshotRevision &+= 1
            historyRecoveryWorker?.cancel()
            historyPresentationRevision &+= 1
            rebuild(preparedPatterns: preparedPatterns)
            return true
        } catch {
            message = "Nie udało się zapisać preferencji tras na urządzeniu."
            return false
        }
    }

    private func profileTrips() -> [LearnedDrivingTrip] {
        Self.profileTrips(in: snapshot)
    }

    private nonisolated static func profileTrips(in snapshot: DrivingProfileSnapshot) -> [LearnedDrivingTrip] {
        let grouped = Dictionary(grouping: snapshot.evidence.compactMap { item -> PreferenceEvidence? in
            item.tripID == nil ? nil : item
        }, by: { $0.tripID! })
        return snapshot.trips.compactMap { stored in
            guard let events = grouped[stored.id], events.contains(where: {
                [.normalTraversal, .selectedAlternative, .repeatedDeviation, .legacyImport, .historyRecovery].contains($0.source)
            }) else { return nil }
            var trip = stored
            trip.confirmed = events.contains { $0.userConfirmed || $0.source == .manualRouteSave }
            return trip
        }
    }

    private func rebuild(preparedPatterns: [DrivingRoutePattern]? = nil) {
        let trips = profileTrips()
        patterns = preparedPatterns ?? DrivingLearningMath.patterns(trips)
        learnedTripCount = trips.count
        pendingCount = snapshot.pending.count
        evidence = snapshot.evidence.sorted { $0.timestamp > $1.timestamp }
        databaseBytes = store.databaseBytes()
        roadEvidence = [:]
        for trip in trips {
            guard let observation = snapshot.evidence.first(where: {
                $0.tripID == trip.id && [.normalTraversal, .selectedAlternative, .repeatedDeviation, .legacyImport, .historyRecovery].contains($0.source)
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
                if length >= 800 || segment.startsObservation { break }
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
        excludedHabitTripIDs = Set(arrivals.filter { snapshot.ignoredApproachIDs.contains($0.id) }.flatMap { $0.trips.map(\.id) })
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
        if RoadRoutingContext.publishesAssessments { lastAssessments = [:] }
        let safe = routes.filter { route in
            guard let snapshot = traffic[route.id] else { return true }
            let start = starts[route.id] ?? 0
            let end = RouteProgressGeometry(route).length
            return !ConfirmedRoadClosure.evidence(in: snapshot, route: route, now: date).contains { closure in
                closure.distanceAhead(on: route, after: start, through: end, now: date) != nil
            }
        }
        let base = RouteScoringEngine.ranked(safe, preference: preference, from: starts, traffic: traffic)
        // Explicit fastest/shortest/comfort choices keep their stated meaning.
        // History affects ordering only in the dedicated personal profile.
        guard settings.enabled, !snapshot.trips.isEmpty, preference == .personalized, base.count > 1 else { return base }
        let scores = base.map { RouteScoringEngine.score($0, from: starts[$0.id] ?? 0, traffic: traffic[$0.id]) }
        let values = RouteScoringEngine.rankingValues(scores, preference: preference)
        let fastest = scores.map(\.travelTime).filter(\.isFinite).min() ?? .infinity
        let habits = base.first.flatMap { baseline in
            baseline.coordinates.first.flatMap { origin in baseline.coordinates.last.map { destination in
                DrivingHabitPreference.candidates(trips: habitTrips(), origin: origin,
                    destination: destination, context: DrivingPreferenceContext(date: date), baseline: baseline, date: date)
            } }
        } ?? []
        let assessments = base.map { route in
            var value = assessment(route, start: starts[route.id] ?? 0,
                context: DrivingPreferenceContext(date: date, trafficLevel: DrivingPreferenceContext.measuredTrafficLevel(traffic[route.id], at: date)), date: date)
            let familiar = DrivingHabitPreference.assessment(route: route, habits: habits, from: starts[route.id] ?? 0)
            if familiar > 0 {
                value.score = max(value.score, 0.5 + 0.35 * familiar)
                value.contributions.append(PreferenceContribution(subject: "Powtarzany odcinek",
                    reason: .normalTraversal, metrics: PreferenceMetrics(confidence: familiar, strength: 0.7)))
            }
            return value
        }
        if RoadRoutingContext.publishesAssessments {
            lastAssessments = Dictionary(uniqueKeysWithValues: zip(base.map(\.id), assessments))
        }
        let weight = DrivingLearningMath.weight(tripCount: learnedTripCount, confirmed: assessments.contains { $0.confirmed })
        if RoadRoutingContext.publishesAssessments {
            for route in base { lastAssessments[route.id]?.appliedWeight = weight }
        }
        guard weight > 0 else { return base }
        // A bounded number of seconds gives the same personal influence when an
        // unrelated candidate is added. The shared detour limits still apply.
        let maximumInfluence = min(300, fastest * 0.30) * (weight / 0.25)
        let costs = base.indices.map { index -> Double in
            guard values[index].isFinite else {
                if RoadRoutingContext.publishesAssessments {
                    lastAssessments[base[index].id]?.score = min(0.5, assessments[index].score)
                    lastAssessments[base[index].id]?.contributions.removeAll { !$0.penalty }
                }
                return .infinity
            }
            return values[index] + (0.5 - assessments[index].score) * 2 * maximumInfluence
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
        if settings.roads, let baseline {
            hints = DrivingHabitPreference.candidates(trips: habitTrips(), origin: origin,
                destination: destination, context: context, baseline: baseline).map(\.points)
        }
        for pattern in patterns {
            if hints.count >= 2 { break }
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
                    let points = DrivingLearningMath.sampledCoordinates(segments: trip.segments, fractions: [0.25, 0.5, 0.75])
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

    private func habitTrips() -> [LearnedDrivingTrip] {
        guard settings.roads else { return [] }
        return patterns.flatMap(\.trips).filter { trip in
            !excludedHabitTripIDs.contains(trip.id)
                && !trip.segments.contains { snapshot.ignoredRoadIDs.contains($0.id) }
                && !trip.deviations.contains {
                    snapshot.ignoredShortcutIDs.contains($0.id) || snapshot.ignoredShortcutIDs.contains($0.boundaryID)
                }
        }
    }
}
