import Foundation

extension TransitRepository {
    func loadDatabase(planningID: UInt64? = nil,
                              trace: TransitPlanningTrace? = nil) async throws -> GTFSDatabase {
        if let database, let databaseLoadedAt,
           Date().timeIntervalSince(databaseLoadedAt) < 86_400 {
            return database
        }
        database = nil
        let compiledIndexStartedAt = ProcessInfo.processInfo.systemUptime
        let compiledIndexInterval = TransitSignposting.begin("CompiledIndexLoad", planningID: planningID)
        let persistedCandidate = Self.readCompiledDatabase(
            at: compiledDatabaseURL,
            expectedSchemaVersion: PersistedTransitDatabase.currentSchemaVersion,
            maximumAge: 30 * 24 * 60 * 60)
            ?? Self.readCompiledDatabase(at: legacyCompiledDatabaseURL,
                                         expectedSchemaVersion: 3,
                                         maximumAge: 30 * 24 * 60 * 60)
        let persisted = persistedCandidate.flatMap { candidate in
            (0..<86_400).contains(Date().timeIntervalSince(candidate.modifiedAt)) ? candidate : nil
        }
        TransitSignposting.end("CompiledIndexLoad", identifier: compiledIndexInterval, planningID: planningID)
        trace?.recordDuration("CompiledIndexLoad", startedAt: compiledIndexStartedAt)
        trace?.setCount("compiledIndexHit", value: persisted.map { _ in 1 } ?? 0)
        trace?.setCount("compiledIndexCandidateHit", value: persistedCandidate.map { _ in 1 } ?? 0)
        if let persisted {
            let loadedDatabase: GTFSDatabase
            if persisted.database.requiresPatternServiceIndexUpgrade {
                let migrationStartedAt = ProcessInfo.processInfo.systemUptime
                loadedDatabase = await Task.detached(priority: .utility) {
                    persisted.database.upgradingPatternServiceIndexes()
                }.value
                trace?.recordDuration("CompiledIndexMigration", startedAt: migrationStartedAt)
                Self.persistCompiledDatabase(loadedDatabase, to: compiledDatabaseURL,
                                             planningID: planningID, trace: trace,
                                             preserveModifiedAt: persisted.modifiedAt)
            } else {
                loadedDatabase = persisted.database
            }
            database = loadedDatabase
            databaseWasCached = true
            databaseLoadedAt = persisted.modifiedAt
            TransitSignposting.event("CompiledIndexCacheHit", value: 1, planningID: planningID)
            return loadedDatabase
        }

        let loadTask: Task<LoadedTransitDatabase, Error>
        if let databaseLoadTask {
            loadTask = databaseLoadTask
        } else {
            let directory = cacheDirectory
            let feedURL = staticFeedURL
            let railwayURL = railwayFeedURL
            let cityFeedFilename = region.staticFeedFilename
            let previousDatabase = persistedCandidate?.database
            loadTask = Task.detached(priority: .utility) {
                try await TransitGTFSLoader.load(cacheDirectory: directory, feedURL: feedURL,
                                                 railwayFeedURL: railwayURL,
                                                 cityFeedFilename: cityFeedFilename,
                                                 planningID: planningID, trace: trace,
                                                 existingDatabase: previousDatabase)
            }
            databaseLoadTask = loadTask
        }
        do {
            let loaded = try await loadTask.value
            let loadedDatabase: GTFSDatabase
            if loaded.database.requiresPatternServiceIndexUpgrade {
                let migrationStartedAt = ProcessInfo.processInfo.systemUptime
                loadedDatabase = await Task.detached(priority: .utility) {
                    loaded.database.upgradingPatternServiceIndexes()
                }.value
                trace?.recordDuration("CompiledIndexMigration", startedAt: migrationStartedAt)
            } else {
                loadedDatabase = loaded.database
            }
            database = loadedDatabase
            databaseWasCached = loaded.wasCached
            databaseLoadedAt = Date()
            databaseLoadTask = nil
            Self.persistCompiledDatabase(loadedDatabase, to: compiledDatabaseURL,
                                         planningID: planningID, trace: trace)
            return loadedDatabase
        } catch {
            databaseLoadTask = nil
            throw error
        }
    }

    static func readCompiledDatabase(at url: URL,
                                     expectedSchemaVersion: Int,
                                     maximumAge: TimeInterval = 86_400) -> (database: GTFSDatabase, modifiedAt: Date)? {
        do {
            guard let modifiedAt = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return nil }
            let age = Date().timeIntervalSince(modifiedAt)
            guard (0..<maximumAge).contains(age) else { return nil }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let index = try PropertyListDecoder().decode(PersistedTransitDatabase.self, from: data)
            guard index.schemaVersion == expectedSchemaVersion,
                  !index.database.stops.isEmpty, !index.database.trips.isEmpty,
                  !index.database.routePatterns.contains(where: {
                      $0.tripsByService == nil && $0.tripIndices == nil
                  }) else { return nil }
            return (index.database, modifiedAt)
        } catch {
            return nil
        }
    }

    static func persistCompiledDatabase(_ database: GTFSDatabase, to url: URL,
                                        planningID: UInt64?, trace: TransitPlanningTrace?,
                                        preserveModifiedAt: Date? = nil) {
        let compiledIndex = PersistedTransitDatabase(
            schemaVersion: PersistedTransitDatabase.currentSchemaVersion,
            database: database
        )
        Task.detached(priority: .utility) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let interval = TransitSignposting.begin("CompiledIndexPersist", planningID: planningID)
            defer {
                TransitSignposting.end("CompiledIndexPersist", identifier: interval, planningID: planningID)
                trace?.recordDuration("CompiledIndexPersist", startedAt: startedAt)
            }
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(compiledIndex)
                try data.write(to: url, options: .atomic)
                if let preserveModifiedAt {
                    try? FileManager.default.setAttributes([.modificationDate: preserveModifiedAt],
                                                           ofItemAtPath: url.path)
                }
                TransitSignposting.event("CompiledIndexPersisted", value: data.count, planningID: planningID)
            } catch {
                TransitSignposting.event("CompiledIndexPersistFailed", value: 1, planningID: planningID)
            }
        }
    }

    func loadRealtime() async -> GTFSRealtimeSnapshot {
        if let realtimeSnapshot, let realtimeLoadedAt,
           Date().timeIntervalSince(realtimeLoadedAt) < 45 {
            return realtimeSnapshot
        }
        let loadTask: Task<GTFSRealtimeSnapshot, Never>
        if let realtimeLoadTask {
            loadTask = realtimeLoadTask
        } else {
            let updatesURL = tripUpdatesURL
            let alertsURL = alertsURL
            let railwayUpdatesURL = railwayTripUpdatesURL
            loadTask = Task {
                async let updates = try? Self.download(updatesURL)
                async let alerts = try? Self.download(alertsURL)
                async let railwayUpdates = try? Self.download(railwayUpdatesURL)
                let (updatesData, alertsData, railwayUpdatesData) = await (updates, alerts, railwayUpdates)
                let receivedAt = Date()
                let parsedUpdates = updatesData.flatMap { try? GTFSRealtimeSnapshot.tripUpdates(from: $0) }
                let parsedRailwayUpdates = railwayUpdatesData.flatMap {
                    try? GTFSRealtimeSnapshot.tripUpdates(from: $0, prefix: "rail/")
                }
                let parsedAlerts = alertsData.flatMap { try? GTFSRealtimeSnapshot.alerts(from: $0) }
                let cityFreshness = self.realtimeFreshness(parsedUpdates?.updatedAt, relativeTo: receivedAt)
                let railwayFreshness = self.realtimeFreshness(parsedRailwayUpdates?.updatedAt,
                                                               relativeTo: receivedAt)
                let cityUpdatesAreFresh = cityFreshness == .live || cityFreshness == .degraded
                let railwayUpdatesAreFresh = railwayFreshness == .live || railwayFreshness == .degraded
                let freshness = Self.combinedFreshness([
                    cityFreshness,
                    railwayFreshness
                ].filter { $0 != .unavailable })
                let updatesAreFresh = cityUpdatesAreFresh || railwayUpdatesAreFresh
                let alertsAreFresh = self.isFresh(parsedAlerts?.updatedAt, relativeTo: receivedAt)
                var mergedUpdates: [String: [String: [String: GTFSStopTimeUpdate]]] = [:]
                var canceledTrips: Set<String> = []
                if cityUpdatesAreFresh {
                    mergedUpdates.merge(parsedUpdates?.updates ?? [:], uniquingKeysWith: { _, newer in newer })
                    canceledTrips.formUnion(parsedUpdates?.canceledTrips ?? [])
                }
                if railwayUpdatesAreFresh {
                    mergedUpdates.merge(parsedRailwayUpdates?.updates ?? [:], uniquingKeysWith: { _, newer in newer })
                    canceledTrips.formUnion(parsedRailwayUpdates?.canceledTrips ?? [])
                }
                let sourceUpdatedAt = [
                    region.id: parsedUpdates?.updatedAt,
                    "rail": parsedRailwayUpdates?.updatedAt
                ].compactMapValues { $0 }
                return GTFSRealtimeSnapshot(
                    updates: mergedUpdates,
                    canceledTrips: canceledTrips,
                    updatedAt: sourceUpdatedAt.values.max(),
                    isAvailable: updatesAreFresh,
                    alertsAvailable: alertsAreFresh,
                    alerts: alertsAreFresh ? (parsedAlerts?.alerts ?? []) : [],
                    freshness: freshness,
                    sourceFreshness: [region.id: cityFreshness, "rail": railwayFreshness],
                    sourceUpdatedAt: sourceUpdatedAt
                )
            }
            realtimeLoadTask = loadTask
        }
        let snapshot = await loadTask.value
        realtimeSnapshot = snapshot
        realtimeLoadedAt = Date()
        realtimeLoadTask = nil
        return snapshot
    }

    func isFresh(_ updatedAt: Date?, relativeTo now: Date) -> Bool {
        guard let updatedAt else { return false }
        return (-60...180).contains(now.timeIntervalSince(updatedAt))
    }

    func realtimeFreshness(_ updatedAt: Date?, relativeTo now: Date) -> TransitRealtimeFreshness {
        guard let updatedAt else { return .unavailable }
        let age = now.timeIntervalSince(updatedAt)
        guard (-60...180).contains(age) else { return .stale }
        return age <= 90 ? .live : .degraded
    }

    static func combinedFreshness(_ values: [TransitRealtimeFreshness]) -> TransitRealtimeFreshness {
        guard !values.isEmpty else { return .unavailable }
        if values.contains(.stale) { return .stale }
        if values.contains(.unavailable) { return .unavailable }
        if values.contains(.degraded) { return .degraded }
        return .live
    }

    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
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
