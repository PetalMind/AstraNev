import Foundation

nonisolated struct LoadedTransitDatabase: Sendable {
    let database: GTFSDatabase
    let wasCached: Bool
}

nonisolated struct PersistedTransitDatabase: Codable, Sendable {
    static let currentSchemaVersion = 3
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

nonisolated enum TransitGTFSLoader {
    static func load(cacheDirectory: URL, feedURL: URL,
                     railwayFeedURL: URL, cityFeedFilename: String,
                     planningID: UInt64?,
                     trace: TransitPlanningTrace?) async throws -> LoadedTransitDatabase {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        async let cityArchiveRequest = loadArchive(cacheDirectory: cacheDirectory,
                                                   filename: cityFeedFilename, feedURL: feedURL)
        async let railwayArchiveRequest = try? loadArchive(cacheDirectory: cacheDirectory,
                                                           filename: "polish-trains-gtfs.zip",
                                                           feedURL: railwayFeedURL)
        let cityArchive = try await cityArchiveRequest
        let railwayArchive = await railwayArchiveRequest
        if Task.isCancelled { throw CancellationError() }
        var feeds = [GTFSInputFeed(data: cityArchive.data, prefix: "", retrievedAt: cityArchive.retrievedAt)]
        if let railwayArchive {
            feeds.append(GTFSInputFeed(data: railwayArchive.data, prefix: "rail/",
                                       retrievedAt: railwayArchive.retrievedAt))
        }
        let transferCacheURL = cacheDirectory.appendingPathComponent("transit-transfer-graph-v1.plist")
        func makeDatabase(_ inputFeeds: [GTFSInputFeed]) throws -> GTFSDatabase {
            let fingerprint = TransitFeedFingerprint.make(inputFeeds)
            let cachedFootpaths = readTransferGraph(at: transferCacheURL, fingerprint: fingerprint)
            trace?.setCount("transferGraphCacheHit", value: cachedFootpaths.map { _ in 1 } ?? 0)
            let database = try GTFSDatabase(feeds: inputFeeds,
                                            cachedFootpathsByStopID: cachedFootpaths?.footpathsByStopID,
                                            feedFingerprint: fingerprint)
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
                database = try makeDatabase(feeds)
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
                                    feedURL: URL) async throws -> LoadedGTFSArchive {
        let archiveURL = cacheDirectory.appendingPathComponent(filename)
        let cachedData = try? Data(contentsOf: archiveURL)
        let isFresh = (try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate).map { Date().timeIntervalSince($0) < 86_400 } ?? false

        if let cachedData, isFresh, cachedData.count > 22 {
            let retrievedAt = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return LoadedGTFSArchive(data: cachedData, wasCached: true, retrievedAt: retrievedAt ?? nil)
        }

        do {
            let data = try await download(feedURL)
            guard data.count > 22 else { throw TransitRoutingError.invalidResponse }
            try data.write(to: archiveURL, options: .atomic)
            return LoadedGTFSArchive(data: data, wasCached: false, retrievedAt: Date())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cachedData, cachedData.count > 22 {
                let retrievedAt = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return LoadedGTFSArchive(data: cachedData, wasCached: true, retrievedAt: retrievedAt ?? nil)
            }
            throw TransitRoutingError.feedUnavailable
        }
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode), !data.isEmpty else {
            throw TransitRoutingError.invalidResponse
        }
        return data
    }
}

