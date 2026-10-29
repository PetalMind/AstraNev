import Foundation

nonisolated enum SatelliteRasterSource: String, CaseIterable, Sendable {
    case world
    case poland
}

nonisolated struct SatelliteTileAddress: Hashable, Sendable {
    let x: Int
    let y: Int
    let z: Int
}

/// MapLibre 6.29 stops a raster request after an error until its necessity changes.
/// Track actual tile errors rather than fullyRendered: failed rasters count as loaded.
nonisolated struct SatelliteTileRecovery {
    static let sourcePrefix = "naviastra-satellite-"

    struct Attempt: Sendable {
        let source: SatelliteRasterSource
        let previousIdentifier: String
    }

    private struct Failure {
        var tiles: Set<SatelliteTileAddress> = []
        var nextRetry: Date?
        var lastError: Date = .distantPast
        var attempts = 0
    }

    private let namespace: String
    private var generations: [SatelliteRasterSource: Int] = [:]
    private var failures: [SatelliteRasterSource: Failure] = [:]

    init(namespace: String = UUID().uuidString) { self.namespace = namespace }

    func identifier(for source: SatelliteRasterSource) -> String {
        Self.sourcePrefix + source.rawValue + "-" + namespace + "-\(generations[source, default: 0])"
    }

    var nextRetry: Date? { failures.values.compactMap(\.nextRetry).min() }

    mutating func failed(sourceID: String, tile: SatelliteTileAddress, now: Date) {
        guard let source = SatelliteRasterSource.allCases.first(where: { identifier(for: $0) == sourceID }) else { return }
        var failure = failures[source, default: Failure()]
        if now.timeIntervalSince(failure.lastError) > 120 { failure.attempts = 0 }
        failure.lastError = now
        failure.tiles.insert(tile)
        // A stream of errors during camera movement must not postpone recovery.
        if failure.nextRetry == nil {
            let delays: [TimeInterval] = [2, 5, 15, 30, 60, 120]
            failure.nextRetry = now.addingTimeInterval(delays[min(failure.attempts, delays.count - 1)])
        }
        failures[source] = failure
    }

    mutating func succeeded(sourceID: String, tile: SatelliteTileAddress) {
        guard let source = SatelliteRasterSource.allCases.first(where: { identifier(for: $0) == sourceID }),
              var failure = failures[source] else { return }
        failure.tiles.remove(tile)
        if failure.tiles.isEmpty { failure.nextRetry = nil }
        failures[source] = failure
    }

    mutating func retryPendingNow(_ now: Date) {
        for source in SatelliteRasterSource.allCases where failures[source]?.nextRetry != nil {
            failures[source]?.nextRetry = now
        }
    }

    mutating func takeDueAttempts(now: Date) -> [Attempt] {
        var result: [Attempt] = []
        for source in SatelliteRasterSource.allCases {
            guard var failure = failures[source], let nextRetry = failure.nextRetry,
                  nextRetry <= now, !failure.tiles.isEmpty else { continue }
            result.append(Attempt(source: source, previousIdentifier: identifier(for: source)))
            generations[source, default: 0] += 1
            failure.attempts += 1
            failure.tiles.removeAll()
            failure.nextRetry = nil
            failures[source] = failure
        }
        return result
    }

    mutating func resetFailures() { failures.removeAll() }
}
