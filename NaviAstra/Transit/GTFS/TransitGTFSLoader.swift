import Foundation

nonisolated struct LoadedTransitDatabase: Sendable {
    let database: GTFSDatabase
    let wasCached: Bool
}

nonisolated struct PersistedTransitDatabase: Codable, Sendable {
    static let currentSchemaVersion = 4
    let schemaVersion: Int
    let database: GTFSDatabase
}

nonisolated struct PersistedTransferGraph: Codable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let fingerprint: String
    let storedAt: Date
    let footpathsByStopID: [String: [TransitFootpath]]
}

nonisolated struct LoadedGTFSArchive: Sendable {
    let data: Data
    let wasCached: Bool
    let retrievedAt: Date?
}

nonisolated struct GTFSArchiveValidators: Codable, Sendable {
    let sourceURL: String
    var etag: String?
    var lastModified: String?
}

nonisolated struct GTFSArchiveDownloadResult: Sendable {
    let data: Data?
    let notModified: Bool
    let validators: GTFSArchiveValidators
}

nonisolated enum TransitGTFSLoader {
    static func load(cacheDirectory: URL, feedURL: URL,
                     railwayFeedURL: URL, cityFeedFilename: String,
                     planningID: UInt64?,
                     trace: TransitPlanningTrace?,
                     existingDatabase: GTFSDatabase? = nil) async throws -> LoadedTransitDatabase {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        async let cityArchiveRequest = loadArchive(cacheDirectory: cacheDirectory,
                                                   filename: cityFeedFilename, feedURL: feedURL,
                                                   trace: trace, source: "City")
        async let railwayArchiveRequest = try? loadArchive(cacheDirectory: cacheDirectory,
                                                           filename: "polish-trains-gtfs.zip",
                                                           feedURL: railwayFeedURL,
                                                           trace: trace, source: "Railway")
        let cityArchive = try await cityArchiveRequest
        let railwayArchive = await railwayArchiveRequest
        trace?.setCount("cityArchiveBytes", value: cityArchive.data.count)
        trace?.setCount("railwayArchiveBytes", value: railwayArchive?.data.count ?? 0)
        trace?.setCount("cityArchiveCached", value: cityArchive.wasCached ? 1 : 0)
        trace?.setCount("railwayArchiveCached", value: railwayArchive?.wasCached == true ? 1 : 0)
        if Task.isCancelled { throw CancellationError() }
        var feeds = [GTFSInputFeed(data: cityArchive.data, prefix: "", retrievedAt: cityArchive.retrievedAt)]
        if let railwayArchive {
            feeds.append(GTFSInputFeed(data: railwayArchive.data, prefix: "rail/",
                                       retrievedAt: railwayArchive.retrievedAt))
        }
        let fingerprintStartedAt = ProcessInfo.processInfo.systemUptime
        let feedFingerprint = TransitFeedFingerprint.make(feeds)
        trace?.recordDuration("GTFSFingerprint", startedAt: fingerprintStartedAt)
        if let existingDatabase, existingDatabase.feedFingerprint == feedFingerprint {
            trace?.setCount("compiledScheduleFingerprintHit", value: 1)
            return LoadedTransitDatabase(database: existingDatabase, wasCached: true)
        }
        trace?.setCount("compiledScheduleFingerprintHit", value: 0)
        let transferCacheURL = cacheDirectory.appendingPathComponent("transit-transfer-graph-v1.plist")
        func makeDatabase(_ inputFeeds: [GTFSInputFeed], fingerprint: String? = nil) throws -> GTFSDatabase {
            let fingerprint = fingerprint ?? TransitFeedFingerprint.make(inputFeeds)
            let cachedFootpaths = readTransferGraph(at: transferCacheURL, fingerprint: fingerprint)
            trace?.setCount("transferGraphCacheHit", value: cachedFootpaths.map { _ in 1 } ?? 0)
            let database = try GTFSDatabase(feeds: inputFeeds,
                                            cachedFootpathsByStopID: cachedFootpaths?.footpathsByStopID,
                                            feedFingerprint: fingerprint,
                                            trace: trace)
            if cachedFootpaths == nil {
                persistTransferGraph(database.footpathsByStopID, fingerprint: fingerprint,
                                     to: transferCacheURL)
            }
            return database
        }
        let database: GTFSDatabase
        do {
            let indexStartedAt = ProcessInfo.processInfo.systemUptime
            let indexInterval = TransitSignposting.begin("ScheduleIndexBuild", planningID: planningID)
            defer {
                TransitSignposting.end("ScheduleIndexBuild", identifier: indexInterval,
                                       planningID: planningID)
                trace?.recordDuration("ScheduleIndexBuild", startedAt: indexStartedAt)
            }
            do {
                database = try makeDatabase(feeds, fingerprint: feedFingerprint)
            } catch {
                guard railwayArchive != nil else { throw error }
                database = try makeDatabase([feeds[0]])
            }
        }
        return LoadedTransitDatabase(database: database,
                                     wasCached: cityArchive.wasCached && (railwayArchive?.wasCached ?? true))
    }

    private static func readTransferGraph(at url: URL, fingerprint: String) -> PersistedTransferGraph? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let cache = try PropertyListDecoder().decode(PersistedTransferGraph.self, from: data)
            guard cache.schemaVersion == PersistedTransferGraph.currentSchemaVersion,
                  cache.fingerprint == fingerprint,
                  (0...30 * 24 * 60 * 60).contains(Date().timeIntervalSince(cache.storedAt)) else {
                return nil
            }
            return cache
        } catch {
            return nil
        }
    }

    private static func persistTransferGraph(_ footpaths: [String: [TransitFootpath]],
                                             fingerprint: String, to url: URL) {
        do {
            let cache = PersistedTransferGraph(
                schemaVersion: PersistedTransferGraph.currentSchemaVersion,
                fingerprint: fingerprint,
                storedAt: Date(),
                footpathsByStopID: footpaths
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(cache).write(to: url, options: .atomic)
        } catch {
            // A failed derived cache write must never prevent GTFS use.
        }
    }

    private static func loadArchive(cacheDirectory: URL, filename: String,
                                    feedURL: URL, trace: TransitPlanningTrace?, source: String) async throws -> LoadedGTFSArchive {
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer { trace?.recordDuration("\(source)ArchiveResolve", startedAt: startedAt) }
        let archiveURL = cacheDirectory.appendingPathComponent(filename)
        let cachedData = try? Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let isFresh = (try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate).map { Date().timeIntervalSince($0) < 86_400 } ?? false

        if let cachedData, isFresh, cachedData.count > 22 {
            let retrievedAt = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return LoadedGTFSArchive(data: cachedData, wasCached: true, retrievedAt: retrievedAt ?? nil)
        }

        let validatorsURL = archiveURL.appendingPathExtension("validators.plist")
        let storedValidators = readValidators(at: validatorsURL)
        let cachedValidators = cachedData != nil && storedValidators?.sourceURL == feedURL.absoluteString
            ? storedValidators : nil
        var downloadStartedAt: TimeInterval?
        do {
            let startedAt = ProcessInfo.processInfo.systemUptime
            downloadStartedAt = startedAt
            let result = try await download(feedURL, validators: cachedValidators)
            trace?.recordDuration("\(source)ArchiveDownload", startedAt: startedAt)
            if result.notModified {
                guard let cachedData, cachedData.count > 22 else {
                    throw TransitRoutingError.invalidResponse
                }
                try FileManager.default.setAttributes([.modificationDate: Date()],
                                                      ofItemAtPath: archiveURL.path)
                writeValidators(result.validators, to: validatorsURL)
                return LoadedGTFSArchive(data: cachedData, wasCached: true, retrievedAt: Date())
            }
            guard let data = result.data else { throw TransitRoutingError.invalidResponse }
            guard data.count > 22 else { throw TransitRoutingError.invalidResponse }
            try data.write(to: archiveURL, options: .atomic)
            writeValidators(result.validators, to: validatorsURL)
            return LoadedGTFSArchive(data: data, wasCached: false, retrievedAt: Date())
        } catch is CancellationError {
            if let downloadStartedAt {
                trace?.recordDuration("\(source)ArchiveDownload", startedAt: downloadStartedAt)
            }
            throw CancellationError()
        } catch {
            if let downloadStartedAt {
                trace?.recordDuration("\(source)ArchiveDownload", startedAt: downloadStartedAt)
            }
            if let cachedData, cachedData.count > 22 {
                let retrievedAt = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return LoadedGTFSArchive(data: cachedData, wasCached: true, retrievedAt: retrievedAt ?? nil)
            }
            throw TransitRoutingError.feedUnavailable
        }
    }

    private static func readValidators(at url: URL) -> GTFSArchiveValidators? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? PropertyListDecoder().decode(GTFSArchiveValidators.self, from: data)
    }

    private static func writeValidators(_ validators: GTFSArchiveValidators, to url: URL) {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(validators).write(to: url, options: .atomic)
        } catch {
            // Validator persistence is optional; the archive itself remains usable.
        }
    }

    private static func download(_ url: URL,
                                 validators: GTFSArchiveValidators?) async throws -> GTFSArchiveDownloadResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let etag = validators?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TransitRoutingError.invalidResponse }
        let responseValidators = GTFSArchiveValidators(
            sourceURL: url.absoluteString,
            etag: response.value(forHTTPHeaderField: "ETag") ?? validators?.etag,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? validators?.lastModified)
        if response.statusCode == 304 {
            return GTFSArchiveDownloadResult(data: nil, notModified: true, validators: responseValidators)
        }
        guard (200...299).contains(response.statusCode), !data.isEmpty else {
            throw TransitRoutingError.invalidResponse
        }
        return GTFSArchiveDownloadResult(data: data, notModified: false, validators: responseValidators)
    }
}
