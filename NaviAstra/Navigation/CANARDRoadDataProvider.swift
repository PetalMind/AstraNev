import Foundation

/// Public CANARD map feed. No credentials or paid subscription are required.
/// The map embeds LZ-String encoded JSON; format changes must surface as unavailable data.
actor CANARDRoadDataProvider {
    static let shared = CANARDRoadDataProvider()
    static let mapURL = URL(string: "https://www.canard.gitd.gov.pl/cms/pl/o-nas/mapa-urzadzen")!
    static let attribution = "CANARD / GITD · CC BY 4.0"

    private var cached: RoadDataSnapshot?
    private var inFlight: Task<RoadDataSnapshot, Error>?
    private var retryAfter: Date?

    func load() async throws -> RoadDataSnapshot {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < 86_400 { return cached }
        if let inFlight { return try await inFlight.value }
        if let retryAfter, retryAfter > .now { throw RoadDataError.unavailable }
        if let saved = Self.readCache(), Date().timeIntervalSince(saved.fetchedAt) >= 0,
           Date().timeIntervalSince(saved.fetchedAt) < 86_400 {
            cached = saved
            return saved
        }
        let task = Task { try await Self.download() }
        inFlight = task
        do {
            let snapshot = try await task.value
            cached = snapshot
            inFlight = nil
            retryAfter = nil
            Self.writeCache(snapshot)
            return snapshot
        } catch {
            inFlight = nil
            retryAfter = Date().addingTimeInterval(60)
            throw error
        }
    }

    nonisolated static func covers(_ coordinates: [Coordinate]) -> Bool {
        coordinates.contains { (49...55).contains($0.latitude) && (14...24.3).contains($0.longitude) }
    }

    nonisolated static func intersects(_ query: MapRoadPOIQuery) -> Bool {
        query.north >= 49 && query.south <= 55 && query.east >= 14 && query.west <= 24.3
    }

    private static func download() async throws -> RoadDataSnapshot {
        var request = URLRequest(url: mapURL, timeoutInterval: 25)
        request.setValue("NaviAstra/1.0 (public CANARD safety data)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= 5_000_000, let html = String(data: data, encoding: .utf8) else {
            throw RoadDataError.invalidResponse
        }
        return try decode(html: html)
    }

    static func decode(html: String) throws -> RoadDataSnapshot {
        var alerts: [RoadSafetyAlert] = []
        for (field, kind) in [("fotoradaryPP", "PP"), ("fotoradaryOPP", "PO"), ("fotoradaryRL", "PC")] {
            let pattern = NSRegularExpression.escapedPattern(for: field) + #"\s*:\s*"([A-Za-z0-9+/=]+)""#
            let expression = try NSRegularExpression(pattern: pattern)
            guard let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let json = CANARDLZDecoder.decodeBase64(String(html[range]))?.data(using: .utf8) else {
                throw RoadDataError.invalidResponse
            }
            let devices = try JSONDecoder().decode([Device].self, from: json)
            for device in devices {
                guard device.rodzajPomiaru == kind,
                      let coordinate = device.coordinate else { throw RoadDataError.invalidResponse }
                let id = "canard-\(device.id)"
                if kind == "PO" {
                    guard let other = device.otherEnd, coordinate.distance(to: other) > 3 else {
                        throw RoadDataError.invalidResponse
                    }
                    // CANARD supplies two endpoints without a documented enforcement direction.
                    // Label their traversal order only after matching the selected route.
                    alerts.append(RoadSafetyAlert(id: id + "-a", type: .averageSpeedStart,
                                                  coordinate: coordinate, source: .canard,
                                                  sectionOtherEnd: other))
                    alerts.append(RoadSafetyAlert(id: id + "-b", type: .averageSpeedEnd,
                                                  coordinate: other, source: .canard,
                                                  sectionOtherEnd: coordinate))
                } else {
                    alerts.append(RoadSafetyAlert(id: id, type: kind == "PC" ? .redLightCamera : .speedCamera,
                                                  coordinate: coordinate, source: .canard))
                }
            }
        }
        guard !alerts.isEmpty else { throw RoadDataError.invalidResponse }
        return RoadDataSnapshot(speedSegments: [], alerts: alerts, fetchedAt: .now)
    }

    private struct Device: Decodable {
        let id: Int64
        let lon: Double
        let lat: Double
        let rodzajPomiaru: String
        let lok2PktDlugosc: Double?
        let lok2PktSzerokosc: Double?

        var coordinate: Coordinate? { Self.coordinate(lat: lat, lon: lon) }
        var otherEnd: Coordinate? {
            guard let lat = lok2PktSzerokosc, let lon = lok2PktDlugosc else { return nil }
            return Self.coordinate(lat: lat, lon: lon)
        }
        private static func coordinate(lat: Double, lon: Double) -> Coordinate? {
            guard lat.isFinite, lon.isFinite, (49...55).contains(lat), (14...24.3).contains(lon) else { return nil }
            return Coordinate(latitude: lat, longitude: lon)
        }
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NaviAstra/canard-v1.json")
    }
    private static func readCache() -> RoadDataSnapshot? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(RoadDataSnapshot.self, from: data)
    }
    private static func writeCache(_ snapshot: RoadDataSnapshot) {
        guard let cacheURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// Bounded LZ-String base64 decoder; operates on UTF-16 code units like the public map.
nonisolated enum CANARDLZDecoder {
    static func decodeBase64(_ text: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let table = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
        let values = text.compactMap { table[$0] }
        guard !values.isEmpty, values.count == text.count, values.count <= 2_000_000 else { return nil }
        var cursor = 0
        var bitPosition = 32
        func bits(_ count: Int) -> Int? {
            var value = 0
            for bit in 0..<count {
                guard cursor < values.count else { return nil }
                if values[cursor] & bitPosition != 0 { value |= 1 << bit }
                bitPosition >>= 1
                if bitPosition == 0 { bitPosition = 32; cursor += 1 }
            }
            return value
        }
        guard let initial = bits(2), initial < 2,
              let first = bits(initial == 0 ? 8 : 16) else { return nil }
        var dictionary: [[UInt16]] = [[], [], [], [UInt16(first)]]
        var previous = dictionary[3]
        var output = previous
        var width = 3
        var enlargeIn = 4
        while output.count <= 4_000_000, dictionary.count < 200_000, width <= 20 {
            guard var code = bits(width) else { return nil }
            if code == 2 { return String(decoding: output, as: UTF16.self) }
            if code == 0 || code == 1 {
                guard let literal = bits(code == 0 ? 8 : 16) else { return nil }
                code = dictionary.count
                dictionary.append([UInt16(literal)])
                enlargeIn -= 1
            }
            if enlargeIn == 0 { enlargeIn = 1 << width; width += 1 }
            let entry: [UInt16]
            if code < dictionary.count { entry = dictionary[code] }
            else if code == dictionary.count { entry = previous + [previous[0]] }
            else { return nil }
            guard let first = entry.first else { return nil }
            output.append(contentsOf: entry)
            dictionary.append(previous + [first])
            enlargeIn -= 1
            previous = entry
            if enlargeIn == 0 { enlargeIn = 1 << width; width += 1 }
        }
        return nil
    }
}

nonisolated enum RoadSafetyFetch {
    static func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}

struct CombinedRoadDataProvider: RoadDataProvider {
    let osm: RoadDataProvider = OpenStreetMapRoadDataProvider()

    func loadSpeedLimits(near coordinate: Coordinate) async throws -> RoadDataSnapshot? {
        try await osm.loadSpeedLimits(near: coordinate)
    }

    func loadSpeedLimits(near coordinate: Coordinate, along corridor: [Coordinate]) async throws -> RoadDataSnapshot? {
        try await osm.loadSpeedLimits(near: coordinate, along: corridor)
    }

    func load(for route: [Coordinate]) async throws -> RoadDataSnapshot {
        guard CANARDRoadDataProvider.covers(route) else { return try await osm.load(for: route) }
        async let osmResult = RoadSafetyFetch.capture { try await osm.load(for: route) }
        async let canardResult = RoadSafetyFetch.capture { try await CANARDRoadDataProvider.shared.load() }
        let (osmData, canardData) = await (osmResult, canardResult)
        try Task.checkCancellation()
        switch (osmData, canardData) {
        case (.success(let base), .success(let official)):
            return RoadDataSnapshot(speedSegments: base.speedSegments,
                                    alerts: Self.merge(base.alerts, official.alerts), fetchedAt: min(base.fetchedAt, official.fetchedAt))
        case (.success(let base), .failure):
            return RoadDataSnapshot(speedSegments: base.speedSegments, alerts: base.alerts,
                                    fetchedAt: base.fetchedAt, unavailableSources: ["CANARD"])
        case (.failure, .success(let official)):
            return RoadDataSnapshot(speedSegments: [], alerts: official.alerts,
                                    fetchedAt: official.fetchedAt, unavailableSources: ["OpenStreetMap"])
        case (.failure(let error), .failure): throw error
        }
    }

    nonisolated static func merge(_ osm: [RoadSafetyAlert], _ official: [RoadSafetyAlert]) -> [RoadSafetyAlert] {
        // Keep OSM relation direction and speed metadata when both sources describe the same device.
        osm + official.filter { device in
            !osm.contains { candidate in
                (candidate.type == device.type ||
                 ([RoadAlertType.averageSpeedStart, .averageSpeedEnd].contains(candidate.type) &&
                  [RoadAlertType.averageSpeedStart, .averageSpeedEnd].contains(device.type))) &&
                candidate.coordinate.distance(to: device.coordinate) < 40
            }
        }
    }
}
