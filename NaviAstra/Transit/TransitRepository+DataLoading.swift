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
        let persisted = Self.readCompiledDatabase(at: compiledDatabaseURL)
        TransitSignposting.end("CompiledIndexLoad", identifier: compiledIndexInterval, planningID: planningID)
        trace?.recordDuration("CompiledIndexLoad", startedAt: compiledIndexStartedAt)
        trace?.setCount("compiledIndexHit", value: persisted.map { _ in 1 } ?? 0)
        if let persisted {
            database = persisted.database
            databaseWasCached = true
            databaseLoadedAt = persisted.modifiedAt
            TransitSignposting.event("CompiledIndexCacheHit", value: 1, planningID: planningID)
            return persisted.database
        }

        let loadTask: Task<LoadedTransitDatabase, Error>
        if let databaseLoadTask {
            loadTask = databaseLoadTask
        } else {
            let directory = cacheDirectory
            let feedURL = staticFeedURL
            let railwayURL = railwayFeedURL
            let cityFeedFilename = region.staticFeedFilename
            loadTask = Task.detached(priority: .utility) {
                try await TransitGTFSLoader.load(cacheDirectory: directory, feedURL: feedURL,
                                                 railwayFeedURL: railwayURL,
                                                 cityFeedFilename: cityFeedFilename,
                                                 planningID: planningID, trace: trace)
            }
            databaseLoadTask = loadTask
        }
        do {
            let loaded = try await loadTask.value
            database = loaded.database
            databaseWasCached = loaded.wasCached
            databaseLoadedAt = Date()
            databaseLoadTask = nil
            let compiledIndex = PersistedTransitDatabase(
                schemaVersion: PersistedTransitDatabase.currentSchemaVersion,
                database: loaded.database
            )
            let indexURL = compiledDatabaseURL
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
                    try data.write(to: indexURL, options: .atomic)
                    TransitSignposting.event("CompiledIndexPersisted", value: data.count, planningID: planningID)
                } catch {
                    TransitSignposting.event("CompiledIndexPersistFailed", value: 1, planningID: planningID)
                }
            }
            return loaded.database
        } catch {
            databaseLoadTask = nil
            throw error
        }
    }

    static func readCompiledDatabase(at url: URL) -> (database: GTFSDatabase, modifiedAt: Date)? {
        do {
            guard let modifiedAt = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return nil }
            let age = Date().timeIntervalSince(modifiedAt)
            guard (0..<86_400).contains(age) else { return nil }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let index = try PropertyListDecoder().decode(PersistedTransitDatabase.self, from: data)
            guard index.schemaVersion == PersistedTransitDatabase.currentSchemaVersion,
                  !index.database.stops.isEmpty, !index.database.trips.isEmpty else { return nil }
            return (index.database, modifiedAt)
        } catch {
            return nil
        }
    }

    static func readFlatTripServiceIndex(
        database: GTFSDatabase, at url: URL
    ) -> TransitFlatTripServiceIndex? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return TransitFlatTripServiceIndex(data: data, fingerprint: database.feedFingerprint,
                                           tripCount: database.trips.count)
    }

    static func createFlatTripServiceIndex(database: GTFSDatabase, at url: URL) {
        var data = TransitFlatTripServiceIndex.header(fingerprint: database.feedFingerprint,
                                                      tripCount: database.trips.count)
        data.reserveCapacity(TransitFlatTripServiceIndex.headerByteCount + database.trips.count * 4)
        let serviceIndexByID = Dictionary(uniqueKeysWithValues: database.serviceIDs.enumerated()
            .map { ($1, $0) })
        for trip in database.trips {
            let serviceIndex = serviceIndexByID[trip.serviceID] ?? -1
            let encodedServiceIndex = serviceIndex >= 0 ? UInt32(clamping: serviceIndex) : UInt32.max
            TransitFlatTripServiceIndex.append(encodedServiceIndex, to: &data)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // The planner uses the in-memory service map if the flat index cannot be persisted.
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
