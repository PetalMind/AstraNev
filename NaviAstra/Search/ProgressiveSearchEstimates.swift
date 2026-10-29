import Foundation

/// Start road estimates with the first useful provider reply. Late POI metadata
/// never holds the first matrix hostage and unchanged targets are not sent again.
@MainActor
final class ProgressiveSearchEstimates {
    struct Estimate: Sendable {
        let time: Double
        let distance: Double
        var isValid: Bool {
            time.isFinite && (0...31_536_000).contains(time)
                && distance.isFinite && (0...400_000_000).contains(distance)
        }
    }
    typealias Resolver = @MainActor ([SearchResult]) async throws -> [String: Estimate]
    private let intent: ClassifiedQuery
    private let context: SearchContext
    private let resolver: Resolver
    private let onUpdate: @MainActor ([SearchResult]) -> Void
    private var current: [SearchResult] = []
    private var values: [String: Estimate] = [:]
    private var attempted: Set<String> = []
    private var inFlight: Set<String> = []
    private var task: Task<Void, Never>?
    private var cancelled = false

    init(intent: ClassifiedQuery, context: SearchContext, resolver: @escaping Resolver,
         onUpdate: @escaping @MainActor ([SearchResult]) -> Void) {
        self.intent = intent; self.context = context; self.resolver = resolver; self.onUpdate = onUpdate
    }

    func publish(_ results: [SearchResult]) {
        guard !cancelled else { return }
        current = Array(results.prefix(16))
        emit()
        startIfNeeded()
    }

    func complete(_ results: [SearchResult]) async -> [SearchResult] {
        publish(results)
        return await withTaskCancellationHandler {
            while let running = task {
                await running.value
                if Task.isCancelled { cancel(); break }
            }
            return enriched()
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func cancel() {
        cancelled = true; task?.cancel(); task = nil
    }

    private func enriched() -> [SearchResult] {
        current.map { result in
            var result = result
            let key = result.placeIdentity.cacheKey
            if let value = values[key] {
                result.travelTime = value.time; result.travelDistance = value.distance
                result.travelEstimateStatus = .notRequested
            } else if attempted.contains(key), !inFlight.contains(key) {
                result.travelTime = nil; result.travelDistance = nil
                result.travelEstimateStatus = .unavailable
            }
            return result
        }.sorted { SearchRanking.precedes($0, $1, intent: intent, context: context, withTravelEstimates: true) }
    }

    private func emit() { onUpdate(Array(enriched().prefix(8))) }

    private func startIfNeeded() {
        guard task == nil, !cancelled,
              current.contains(where: { !attempted.contains($0.placeIdentity.cacheKey) }) else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !self.cancelled else { return }
            let targets = self.current.filter { !self.attempted.contains($0.placeIdentity.cacheKey) }
            let keys = Set(targets.map { $0.placeIdentity.cacheKey })
            self.attempted.formUnion(keys)
            self.inFlight.formUnion(keys)
            do {
                let estimates = try await self.resolver(targets)
                try Task.checkCancellation()
                guard !self.cancelled else { return }
                for (key, value) in estimates where keys.contains(key) && value.isValid { self.values[key] = value }
            } catch {
                guard !Task.isCancelled, !self.cancelled else { return }
            }
            self.inFlight.subtract(keys)
            self.task = nil
            self.emit()
            self.startIfNeeded()
        }
    }
}
