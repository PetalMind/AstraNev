#if os(iOS)
import Foundation

nonisolated struct DetailedRoadSnapshot: Sendable {
    let roads: [DetailedRoad]
    let fetchedAt: Date
    let revision: String
    var coversQuery = true
    var isFresh: Bool {
        let age = Date().timeIntervalSince(fetchedAt)
        return coversQuery && age >= -300 && age < 24 * 60 * 60
    }
}

/// MVTs contain prepared geometry conforming to the same feature contract as the local normalizer.
nonisolated struct DetailedRoadTileConfiguration: Sendable {
    let tileJSONURL: URL
    let surfaceLayer: String
    let laneLayer: String
    let arrowLayer: String

    init?(tileJSONURL: URL, surfaceLayer: String = "road_surface",
          laneLayer: String = "road_lanes", arrowLayer: String = "road_arrows") {
        guard tileJSONURL.scheme == "https", tileJSONURL.host != nil,
              ![surfaceLayer, laneLayer, arrowLayer].contains(where: \.isEmpty) else { return nil }
        self.tileJSONURL = tileJSONURL
        self.surfaceLayer = surfaceLayer
        self.laneLayer = laneLayer
        self.arrowLayer = arrowLayer
    }
}
nonisolated enum DetailedRoadSourceConfiguration: Sendable {
    case shapes
    case vectorTiles(DetailedRoadTileConfiguration)
}
nonisolated enum DetailedRoadData: Sendable {
    case roads(DetailedRoadSnapshot)
    case vectorTiles(DetailedRoadTileConfiguration)
}

/// The map owns presentation; providers own data, transport and source-specific caching.
nonisolated protocol DetailedRoadDataProvider: Sendable {
    var sourceConfiguration: DetailedRoadSourceConfiguration { get }
    func cachedData(in query: DetailedRoadQuery) async -> DetailedRoadData?
    func data(in query: DetailedRoadQuery) async throws -> DetailedRoadData
}

nonisolated struct TileDetailedRoadProvider: DetailedRoadDataProvider {
    let configuration: DetailedRoadTileConfiguration
    var sourceConfiguration: DetailedRoadSourceConfiguration { .vectorTiles(configuration) }
    func cachedData(in query: DetailedRoadQuery) async -> DetailedRoadData? { .vectorTiles(configuration) }
    func data(in query: DetailedRoadQuery) async throws -> DetailedRoadData { .vectorTiles(configuration) }
}

@MainActor
enum DetailedRoadProviderFactory {
    static func make() -> any DetailedRoadDataProvider {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "DetailedRoadTileJSONURL") as? String,
           let url = URL(string: raw), let configuration = DetailedRoadTileConfiguration(tileJSONURL: url) {
            return TileDetailedRoadProvider(configuration: configuration)
        }
        return OverpassDetailedRoadProvider.shared
    }
}

/// L2 is independent of colors and stroke styling. Raw OSM remains in the provider's persistent L1.
actor DetailedRoadGeometryCache {
    static let shared = DetailedRoadGeometryCache()
    private struct Entry {
        let graphics: [DetailedRoadGraphic]
        var accessedAt: Date
        let vertices: Int
    }
    private var entries: [String: Entry] = [:]

    func graphics(for snapshot: DetailedRoadSnapshot, in query: DetailedRoadQuery) throws -> [DetailedRoadGraphic] {
        let key = "road-surface-union-v4|" + snapshot.revision + "|" + query.id
        if var cached = entries[key] {
            cached.accessedAt = .now
            entries[key] = cached
            return cached.graphics
        }
        try Task.checkCancellation()
        let normalized = snapshot.roads.compactMap(DetailedRoadNormalizer.normalize)
        let graphics = try DetailedRoadGeometry.build(normalized, in: query)
        try Task.checkCancellation()
        let vertices = graphics.reduce(0) { total, graphic in
            total + graphic.points.count + graphic.interiorRings.reduce(0) { $0 + $1.count }
        }
        entries[key] = Entry(graphics: graphics, accessedAt: .now, vertices: vertices)
        while entries.count > 8 || entries.values.reduce(0, { $0 + $1.vertices }) > 300_000 {
            guard let oldest = entries.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key else { break }
            entries[oldest] = nil
        }
        return graphics
    }
}
#endif
