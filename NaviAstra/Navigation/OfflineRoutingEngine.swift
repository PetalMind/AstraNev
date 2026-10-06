#if os(iOS)
import Foundation
import CryptoKit
import Valhalla
import ValhallaConfigModels

nonisolated struct OfflineRoutingPack: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let bytes: Int64
    let motorVehiclesOnly: Bool
    let installedAt: Date
}

/// Owns the native actor off the main thread. Installation, routing and deletion are serialized.
actor OfflineRoutingEngine {
    static let shared = OfflineRoutingEngine()
    private var engine: Valhalla?
    private var enginePackID: UUID?

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineRouting", isDirectory: true)
    }
    nonisolated static func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func route(request: Data, pack: OfflineRoutingPack?, mode: TransportMode) throws -> Data {
        try Task.checkCancellation()
        guard let pack else { throw OfflineRoutingFailure.missingPack }
        if pack.motorVehiclesOnly && mode != .car { throw OfflineRoutingFailure.unsupportedProfile }
        if enginePackID != pack.id {
            engine?.close()
            engine = nil
            enginePackID = nil
            let archive = Self.directory(for: pack.id).appendingPathComponent("tiles.tar")
            guard FileManager.default.fileExists(atPath: archive.path) else { throw OfflineRoutingFailure.missingPack }
            engine = try makeEngine(archive: archive, configName: "offline-routing.json")
            enginePackID = pack.id
        }
        guard let engine, let json = String(data: request, encoding: .utf8) else { throw RoutingError.invalidResponse }
        do {
            let response = try engine.route(rawRequest: json)
            try Task.checkCancellation()
            guard let data = response.data(using: .utf8) else { throw RoutingError.invalidResponse }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { throw OfflineRoutingFailure.incompleteCoverage(error.localizedDescription) }
    }

    func install(file: URL, name: String, motorVehiclesOnly: Bool, expectedSHA256: String? = nil) throws -> OfflineRoutingPack {
        try Task.checkCancellation()
        let id = UUID()
        let directory = Self.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var root = Self.root
        do {
            try root.setResourceValues(excluded)
            let archive = directory.appendingPathComponent("tiles.tar")
            try FileManager.default.copyItem(at: file, to: archive)
            if let expectedSHA256 {
                let file = try FileHandle(forReadingFrom: archive)
                defer { try? file.close() }
                var hash = SHA256()
                while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: chunk)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == expectedSHA256.lowercased() else { throw OfflineRoutingFailure.invalidArchive }
            }
            try OfflineRoutingArchive.validate(archive)
            let validationEngine = try makeEngine(archive: archive, configName: "offline-validation.json")
            validationEngine.close()
            let bytes = (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let pack = OfflineRoutingPack(id: id, name: name, bytes: Int64(bytes),
                                          motorVehiclesOnly: motorVehiclesOnly, installedAt: Date())
            try JSONEncoder().encode(pack).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
            return pack
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove(_ id: UUID) throws {
        if enginePackID == id {
            engine?.close()
            engine = nil
            enginePackID = nil
        }
        try FileManager.default.removeItem(at: Self.directory(for: id))
    }

    func discardInterruptedInstallations() throws {
        guard FileManager.default.fileExists(atPath: Self.root.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path) else { continue }
            // Metadata is committed last, after archive validation. These directories were never installed.
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func makeEngine(archive: URL, configName: String) throws -> Valhalla {
        var config = try ValhallaConfig(tileExtractTar: archive)
        // No remote tile fallback: a successful offline route must use data on this device.
        config.mjolnir?.tileUrl = nil
        config.mjolnir?.tileDir = archive.deletingLastPathComponent().appendingPathComponent("tiles").path
        config.mjolnir?.maxCacheSize = 64 * 1_024 * 1_024
        return try Valhalla(config, configName: configName)
    }
}
#endif
