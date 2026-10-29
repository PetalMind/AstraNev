#if os(iOS)
import Foundation
import CoreGraphics
import ImageIO
import MapLibre
import OSLog
import UniformTypeIdentifiers

/// Configure before either the first map or offline storage creates its session.
@MainActor
enum MapTileNetwork {
    private static var prepared = false

    static func prepare() {
        guard !prepared else { return }
        prepared = true
        let configuration = MLNNetworkConfiguration.sharedManager.sessionConfiguration ?? .default
        configuration.protocolClasses = [SatelliteTileURLProtocol.self] + (configuration.protocolClasses ?? [])
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
        // The SDK's 50 MB default held only about sixteen pairs of 1024 px PNGs.
        // This ambient limit does not resize, invalidate or remove offline packs.
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(256 * 1_024 * 1_024) { error in
            if let error {
                Logger(subsystem: "NaviAstra", category: "SatelliteTiles")
                    .error("Map cache configuration failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}

nonisolated struct SatelliteTileKey: Hashable, Sendable {
    // Reserved host is handled locally by URLProtocol, never by an external server.
    static let template = "https://satellite.naviastra.invalid/v1/{z}/{x}/{y}.png"
    let zoom: Int
    let x: Int
    let y: Int

    init?(url: URL) {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", url.host == "satellite.naviastra.invalid",
              url.query == nil, parts.count == 4, parts[0] == "v1",
              let z = Int(parts[1]), (12...20).contains(z), let x = Int(parts[2]),
              parts[3].hasSuffix(".png"), let y = Int(parts[3].dropLast(4)),
              (0..<(1 << z)).contains(x), (0..<(1 << z)).contains(y) else { return nil }
        zoom = z; self.x = x; self.y = y
    }

    func upstreamURL(resolution: String) -> URL {
        let extent = 20_037_508.342789244
        let side = extent * 2 / Double(1 << zoom)
        let bbox = [-extent + Double(x) * side, extent - Double(y + 1) * side,
                    -extent + Double(x + 1) * side, extent - Double(y) * side]
            .map(String.init(describing:)).joined(separator: ",")
        return URL(string: "https://mapy.geoportal.gov.pl/wss/service/PZGIK/ORTO/WMS/\(resolution)"
            + "?SERVICE=WMS&REQUEST=GetMap&VERSION=1.3.0&LAYERS=Raster&STYLES="
            + "&FORMAT=image/png&TRANSPARENT=TRUE&CRS=EPSG:3857"
            + "&WIDTH=1024&HEIGHT=1024&BBOX=\(bbox)")!
    }
}

nonisolated struct SatelliteTile: Sendable {
    let data: Data
    let expires: Date
    var preview = false
}

/// A high-resolution image that already covers a tile needs no second, hidden
/// image underneath. Only transparent holes require the standard-resolution WMS.
actor SatelliteTilePipeline {
    static let shared = SatelliteTilePipeline()
    private struct Flight {
        let id: UUID
        let task: Task<SatelliteTile, Error>
        var callers: Set<UUID>
    }
    private struct Cached {
        let tile: SatelliteTile
        var used: Date
    }
    private struct Upgrade {
        let id: UUID
        let task: Task<SatelliteTile, Error>
    }
    private enum Arrival: Sendable {
        case high(Result<SatelliteTile, Error>)
        case standard(Result<SatelliteTile, Error>)
    }
    private let session: URLSession
    private var pending: [SatelliteTileKey: Flight] = [:]
    private var cache: [SatelliteTileKey: Cached] = [:]
    private var upgrades: [SatelliteTileKey: Upgrade] = [:]
    private var active = 0
    private var networkActive = 0
    private var cooldown = Date.distantPast
    private let logger = Logger(subsystem: "NaviAstra", category: "SatelliteTiles")

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 15
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func tile(for key: SatelliteTileKey) async throws -> SatelliteTile {
        try Task.checkCancellation()
        if let cached = cache[key], cached.tile.expires > .now {
            cache[key]?.used = .now
            return cached.tile
        }
        let caller = UUID()
        let flight: Flight
        if var existing = pending[key] {
            existing.callers.insert(caller); pending[key] = existing; flight = existing
        } else {
            let work = upgrades[key]?.task ?? Task { try await self.load(key) }
            flight = Flight(id: UUID(), task: work, callers: [caller])
            pending[key] = flight
        }
        return try await withTaskCancellationHandler {
            do {
                let tile = try await flight.task.value
                try Task.checkCancellation()
                if pending[key]?.id == flight.id, tile.expires > .now {
                    // A late preview must not overwrite the completed full image.
                    if !tile.preview || cache[key]?.tile.preview != false {
                        cache[key] = Cached(tile: tile, used: .now)
                    }
                    trimCache()
                }
                release(key, caller: caller, flightID: flight.id)
                return tile
            } catch {
                release(key, caller: caller, flightID: flight.id)
                throw error
            }
        } onCancel: {
            Task { await self.release(key, caller: caller, flightID: flight.id) }
        }
    }

    private func release(_ key: SatelliteTileKey, caller: UUID, flightID: UUID) {
        guard var flight = pending[key], flight.id == flightID else { return }
        flight.callers.remove(caller)
        if flight.callers.isEmpty {
            pending[key] = nil
            flight.task.cancel()
        } else { pending[key] = flight }
    }

    private func trimCache() {
        cache = cache.filter { $0.value.tile.expires > .now }
        var bytes = cache.values.reduce(0) { $0 + $1.tile.data.count }
        for key in cache.keys.sorted(by: { cache[$0]!.used < cache[$1]!.used }) {
            guard bytes > 32 * 1_024 * 1_024 else { break }
            bytes -= cache.removeValue(forKey: key)?.tile.data.count ?? 0
        }
    }

    private func load(_ key: SatelliteTileKey) async throws -> SatelliteTile {
        // Bound complete tile jobs, including their possible fallback, on HTTP/2
        // as well as HTTP/1. Cancellation removes obsolete camera work from the queue.
        while active >= 4 { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        let started = Date()
        let channel = AsyncStream<Arrival>.makeStream()
        let highWork = Task {
            do {
                let tile = try await self.fetch(key.upstreamURL(resolution: "HighResolution"))
                _ = try SatelliteTileImage.isOpaque(tile.data)
                channel.continuation.yield(.high(.success(tile))); return tile
            } catch { channel.continuation.yield(.high(.failure(error))); throw error }
        }
        let standardWork = Task {
            do {
                // Normal tiles need only one request. A stalled high-resolution
                // endpoint must not hold up an otherwise available base image.
                try await Task.sleep(for: .seconds(3))
                let tile = try await self.fetch(key.upstreamURL(resolution: "StandardResolution"))
                _ = try SatelliteTileImage.isOpaque(tile.data)
                channel.continuation.yield(.standard(.success(tile))); return tile
            } catch { channel.continuation.yield(.standard(.failure(error))); throw error }
        }
        var keepHigh = false
        defer {
            channel.continuation.finish(); standardWork.cancel()
            if !keepHigh { highWork.cancel() }
        }
        return try await withTaskCancellationHandler {
            for await arrival in channel.stream {
                try Task.checkCancellation()
                switch arrival {
                case .high(.success(let high)):
                    if try SatelliteTileImage.isOpaque(high.data) { return high }
                    do {
                        let standard: SatelliteTile
                        if Date().timeIntervalSince(started) < 3 {
                            standardWork.cancel()
                            standard = try await fetch(key.upstreamURL(resolution: "StandardResolution"))
                        } else { standard = try await standardWork.value }
                        return try complete(high: high, standard: standard)
                    } catch {
                        try Task.checkCancellation()
                        return SatelliteTile(data: high.data, expires: min(high.expires, Date().addingTimeInterval(300)))
                    }
                case .high(.failure(let error)):
                    guard cooldown <= .now else { throw error }
                    let standard: SatelliteTile
                    if Date().timeIntervalSince(started) < 3 {
                        standardWork.cancel()
                        standard = try await fetch(key.upstreamURL(resolution: "StandardResolution"))
                    } else { standard = try await standardWork.value }
                    _ = try SatelliteTileImage.isOpaque(standard.data)
                    return SatelliteTile(data: standard.data, expires: min(standard.expires, Date().addingTimeInterval(300)))
                case .standard(.success(let standard)):
                    // Show a temporary base image while the original high request
                    // continues. Native expiry replaces it with the completed full
                    // image, without starting the high request over or lowering LOD.
                    if upgrades.count >= 4 {
                        do { return try complete(high: await highWork.value, standard: standard) }
                        catch {
                            try Task.checkCancellation()
                            return SatelliteTile(data: standard.data, expires: min(standard.expires, Date().addingTimeInterval(300)))
                        }
                    }
                    let id = UUID()
                    let upgrade = Task {
                        defer { if self.upgrades[key]?.id == id { self.upgrades[key] = nil } }
                        let tile = try await withTaskCancellationHandler {
                            do { return try self.complete(high: await highWork.value, standard: standard) }
                            catch {
                                try Task.checkCancellation()
                                return SatelliteTile(data: standard.data, expires: min(standard.expires, Date().addingTimeInterval(300)))
                            }
                        } onCancel: { highWork.cancel() }
                        try Task.checkCancellation()
                        self.cache[key] = Cached(tile: tile, used: .now); self.trimCache()
                        return tile
                    }
                    upgrades[key] = Upgrade(id: id, task: upgrade)
                    keepHigh = true
                    return SatelliteTile(data: standard.data, expires: min(standard.expires, Date().addingTimeInterval(3)), preview: true)
                case .standard(.failure): continue // Keep the still running high request.
                }
            }
            throw CancellationError()
        } onCancel: {
            highWork.cancel(); standardWork.cancel(); channel.continuation.finish()
        }
    }

    private func complete(high: SatelliteTile, standard: SatelliteTile) throws -> SatelliteTile {
        if try SatelliteTileImage.isOpaque(high.data) { return high }
        return SatelliteTile(data: try SatelliteTileImage.composite(standard: standard.data, high: high.data),
                             expires: min(high.expires, standard.expires))
    }

    private func fetch(_ url: URL) async throws -> SatelliteTile {
        // Six is Foundation's previous per-host default; even slow-image fallback
        // stays bounded on HTTP/2. Normally only four high-image jobs are active.
        while networkActive >= 6 { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        guard cooldown <= .now else { throw URLError(.resourceUnavailable) }
        networkActive += 1
        defer { networkActive -= 1 }
        let (data, response) = try await session.data(for: URLRequest(url: url))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if [429, 503].contains(http.statusCode) {
            cooldown = HTTPRetryDelay.date(from: http, minimum: 30)
        }
        guard http.statusCode == 200, http.mimeType == "image/png", !data.isEmpty,
              data.count <= 8 * 1_024 * 1_024 else { throw URLError(.badServerResponse) }
        var lifetime: TimeInterval = 86_400
        let policy = http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
        if policy.contains("no-store") || policy.contains("no-cache") { lifetime = 0 }
        else if let directive = policy.split(separator: ",").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("max-age=") }),
                let seconds = Double(directive.split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? "") {
            lifetime = max(0, min(lifetime, seconds))
        }
        if let header = http.value(forHTTPHeaderField: "Expires") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { lifetime = min(lifetime, max(0, date.timeIntervalSinceNow)) }
        }
        return SatelliteTile(data: data, expires: Date().addingTimeInterval(lifetime))
    }
}

nonisolated enum SatelliteTileImage {
    private static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 1024, image.height == 1024 else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    static func isOpaque(_ data: Data) throws -> Bool {
        let image = try decode(data)
        if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return true }
        var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1024, height: 1024,
                bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw URLError(.cannotDecodeContentData)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            let rgba = bytes.bindMemory(to: UInt8.self)
            return stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 }
        }
    }

    static func composite(standard: Data, high: Data) throws -> Data {
        let lower = try decode(standard), upper = try decode(high)
        // Preserve color space and lossless PNG, including transparent border gaps.
        let space = upper.colorSpace?.model == .rgb ? upper.colorSpace!
            : (lower.colorSpace?.model == .rgb ? lower.colorSpace! : CGColorSpaceCreateDeviceRGB())
        guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 4096, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw URLError(.cannotDecodeContentData)
        }
        context.draw(lower, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.draw(upper, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard let image = context.makeImage() else { throw URLError(.cannotDecodeContentData) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
        return output as Data
    }
}

nonisolated final class SatelliteTileURLProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var work: Task<Void, Never>?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "satellite.naviastra.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let key = SatelliteTileKey(url: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let task = Task { [weak self] in
            do {
                let tile = try await SatelliteTilePipeline.shared.tile(for: key)
                try Task.checkCancellation()
                guard let self, !self.stateLock.withLock({ self.stopped }),
                      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "image/png", "Cache-Control": tile.expires > .now
                            ? "private, max-age=\(max(0, Int(tile.expires.timeIntervalSinceNow)))" : "no-store, must-revalidate"]) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: tile.data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard let self, !self.stateLock.withLock({ self.stopped }) else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
            self?.stateLock.withLock { self?.work = nil }
        }
        stateLock.withLock {
            if stopped { task.cancel() } else { work = task }
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true; work?.cancel(); work = nil }
    }
}
#endif
