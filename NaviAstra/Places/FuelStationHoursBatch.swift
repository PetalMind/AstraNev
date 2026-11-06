import Foundation

/// Coalesces visible stations into one bounded OSM request. A disappearing row
/// releases only its own waiter; the download is cancelled when nobody needs it.
@MainActor
final class FuelStationHoursBatch {
    static let shared = FuelStationHoursBatch()
    private static let lookupOnly = FuelStationHoursBatch(resolver: { identities in
        try await OpenStreetMapPlaceDetailsProvider().fuelStationLookupDetails(for: identities)
    })
    typealias Resolver = @MainActor ([PlaceIdentity]) async throws -> [String: PlaceDetails]
    private let resolver: Resolver
    private let lookup: Resolver?

    init(resolver: @escaping Resolver = { identities in
        try await OpenStreetMapPlaceDetailsProvider().fuelStationHoursDetails(for: identities)
    }, lookup: Resolver? = nil) {
        self.resolver = resolver
        self.lookup = lookup
    }
    private struct Entry {
        let identity: PlaceIdentity
        var waiters: [UUID: CheckedContinuation<PlaceDetails?, Never>]
    }
    private struct Cached {
        let value: PlaceDetails?
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]
    private var queue: [String] = []
    private var activeKeys: Set<String> = []
    private var task: Task<Void, Never>?
    private var cache: [String: Cached] = [:]

    static func requestKey(_ identity: PlaceIdentity) -> String {
        [identity.cacheKey, String(identity.coordinate.latitude), String(identity.coordinate.longitude),
         identity.address ?? "", identity.name, identity.category ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// A slow area lookup must not hold the lane for subsequently visible typed
    /// OSM stations. Each lane still coalesces, caches and cancels its own work.
    static func resolvedDetails(for identity: PlaceIdentity, lookupBatch: FuelStationHoursBatch? = nil,
                                fallbackBatch: FuelStationHoursBatch? = nil) async -> PlaceDetails? {
        var lookedUp: PlaceDetails?
        if NominatimFuelStationLookup.object(for: identity) != nil {
            lookedUp = await (lookupBatch ?? lookupOnly).details(for: identity)
            guard !Task.isCancelled else { return nil }
            if let lookedUp, let hours = PlaceSearchOpeningHours.removingExpiredHours(from: lookedUp).openingHours,
               !hours.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return lookedUp }
        }
        guard !Task.isCancelled else { return nil }
        let fallback = await (fallbackBatch ?? shared).details(for: identity)
        guard !Task.isCancelled else { return nil }
        return fallback ?? lookedUp
    }

    func details(for identity: PlaceIdentity) async -> PlaceDetails? {
        guard !Task.isCancelled else { return nil }
        let key = Self.requestKey(identity)
        if let cached = cache[key], cached.expiresAt > Date() { return cached.value }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if var entry = entries[key] {
                    entry.waiters[waiter] = continuation
                    entries[key] = entry
                } else {
                    entries[key] = Entry(identity: identity, waiters: [waiter: continuation])
                    queue.append(key)
                }
                startIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(key: key, waiter: waiter) }
        }
    }

    private func release(key: String, waiter: UUID) {
        guard var entry = entries[key], let continuation = entry.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        if entry.waiters.isEmpty {
            entries[key] = nil
            queue.removeAll { $0 == key }
        } else { entries[key] = entry }
        if entries.isEmpty || (!activeKeys.isEmpty && activeKeys.allSatisfy({ entries[$0] == nil })) {
            task?.cancel()
        }
    }

    private func startIfNeeded() {
        guard task == nil, !queue.isEmpty else { return }
        task = Task { [self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { finishBatch(values: [:], failed: true); return }
            let keys = Array(queue.prefix(8))
            queue.removeFirst(keys.count)
            activeKeys = Set(keys)
            let identities = keys.compactMap { entries[$0]?.identity }
            var lookupValues: [String: PlaceDetails] = [:]
            do {
                if let lookup {
                    lookupValues = (try? await lookup(identities)) ?? [:]
                    try Task.checkCancellation()
                    publishMatches(lookupValues)
                }
                let remaining = activeKeys.compactMap { entries[$0]?.identity }
                guard !remaining.isEmpty else { finishBatch(values: [:], failed: false); return }
                let values = try await resolver(remaining)
                finishBatch(values: lookupValues.merging(values) { _, refreshed in refreshed }, failed: false)
            } catch {
                finishBatch(values: lookupValues, failed: true)
            }
        }
    }

    private func publishMatches(_ values: [String: PlaceDetails]) {
        for key in Array(activeKeys) {
            guard let entry = entries[key], let value = values[key],
                  let hours = PlaceSearchOpeningHours.removingExpiredHours(from: value).openingHours,
                  !hours.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            entries[key] = nil
            activeKeys.remove(key)
            cache[key] = Cached(value: value, expiresAt: Date().addingTimeInterval(600))
            for waiter in entry.waiters.values { waiter.resume(returning: value) }
        }
    }

    private func finishBatch(values: [String: PlaceDetails], failed: Bool) {
        let cancelled = Task.isCancelled
        for key in activeKeys {
            if cancelled, entries[key] != nil {
                // All old waiters had left when the request was cancelled. A new
                // row may have joined the same key before cancellation completed.
                if !queue.contains(key) { queue.append(key) }
                continue
            }
            guard let entry = entries.removeValue(forKey: key) else { continue }
            let value = cancelled ? nil : values[key]
            if !cancelled {
                // A confirmed match retains its original fetchedAt. Missing/error
                // entries are only a short throttle and never become hours facts.
                cache[key] = Cached(value: value, expiresAt: Date().addingTimeInterval(failed ? 30 : value == nil ? 120 : 600))
            }
            for waiter in entry.waiters.values { waiter.resume(returning: value) }
        }
        activeKeys = []
        task = nil
        if cache.count > 256 {
            cache = Dictionary(uniqueKeysWithValues: cache.filter { $0.value.expiresAt > Date() }
                .sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(256).map { ($0.key, $0.value) })
        }
        startIfNeeded()
    }
}
