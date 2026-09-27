import Foundation

extension TransitRepository {
    func calculateRoutes(from: Coordinate, to: Coordinate, departingAt: Date,
                         walkingRoutingEndpoint: URL,
                         onProgress: TransitPlanningProgressHandler?,
                         onProvisionalRoutes: TransitProvisionalRoutesHandler?) async throws -> [NavigationRoute] {
        nextPlanningID &+= 1
        let planningID = nextPlanningID
        let regionID = region.id
        let trace = TransitPlanningTrace()
        trace.setCount("fallbackRequestCount", value: 0)
        let totalInterval = TransitSignposting.begin("TransitPlanning", planningID: planningID)
        defer {
            TransitSignposting.end("TransitPlanning", identifier: totalInterval, planningID: planningID)
            trace.emitSummary(planningID: planningID)
        }

        await onProgress?(.loadingSchedule)
        let database: GTFSDatabase
        do {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let databaseInterval = TransitSignposting.begin("GTFSLoad", planningID: planningID)
            defer {
                TransitSignposting.end("GTFSLoad", identifier: databaseInterval, planningID: planningID)
                trace.recordDuration("GTFSLoad", startedAt: startedAt)
            }
            database = try await loadDatabase(planningID: planningID, trace: trace)
        }
        loadedDatabaseFingerprint = database.feedFingerprint
        guard walkingRoutingEndpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        await loadPersistentPedestrianCacheIfNeeded()
        let flatTripServiceIndexURL = cacheDirectory.appendingPathComponent("active-trip-services-v1.flat")
        let tripServiceIndex: TransitFlatTripServiceIndex?
        if flatTripServiceFingerprint == database.feedFingerprint,
           let flatTripServiceIndex {
            tripServiceIndex = flatTripServiceIndex
        } else if let mappedIndex = Self.readFlatTripServiceIndex(
            database: database, at: flatTripServiceIndexURL) {
            tripServiceIndex = mappedIndex
            flatTripServiceIndex = mappedIndex
            flatTripServiceFingerprint = database.feedFingerprint
        } else {
            tripServiceIndex = nil
            flatTripServiceIndex = nil
            flatTripServiceFingerprint = database.feedFingerprint
            if flatTripServiceBuildTask == nil {
                flatTripServiceBuildTask = Task(priority: .utility) {
                    await Task.detached(priority: .utility) {
                        Self.createFlatTripServiceIndex(database: database, at: flatTripServiceIndexURL)
                    }.value
                    self.flatTripServiceBuildTask = nil
                }
            }
        }
        trace.setCount("flatTripServiceIndexHit", value: tripServiceIndex.map { _ in 1 } ?? 0)
        await onProgress?(.searchingConnections)

        // Coarse access estimates bound the stop set before any exact routing request is sent.
        async let realtimeRequest = loadRealtimeForRoutePlanning(planningID: planningID, trace: trace)
        let originWalks = coarseWalkingOptions(from: from, database: database, trace: trace)
        let destinationApproaches = coarseWalkingOptions(from: to, database: database, trace: trace)
        let destinationWalks = destinationApproaches.map { option in
            TransitWalkOption(stop: option.stop, distance: option.distance, duration: option.duration,
                              coordinates: Array(option.coordinates.reversed()),
                              hasResolvedGeometry: false, isApproximate: true)
        }
        let realtime = await realtimeRequest
        let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
        let snapshot = await Task.detached(priority: .userInitiated) {
            TransitSnapshot(database: database, realtime: realtime, departure: departingAt,
                            maximumDepartureWindow: Self.maximumDepartureSearchWindow,
                            flatTripServiceIndex: tripServiceIndex)
        }.value
        trace.recordDuration("TransitSnapshotBuild", startedAt: snapshotStartedAt)
        let usingCachedSchedule = databaseWasCached

        let searchInterval = TransitSignposting.begin("TransitSearch", planningID: planningID)
        let searchStartedAt = ProcessInfo.processInfo.systemUptime
        var routePool: [String: NavigationRoute] = [:]
        var lastPlanningError: Error = TransitRoutingError.noJourney
        do {
            for (stageIndex, departureWindow) in Self.stagedDepartureWindows.enumerated() {
                try Task.checkCancellation()
                trace.setCount("searchWindowStage", value: stageIndex + 1)
                let coarseRoutes: [NavigationRoute]
                do {
                    coarseRoutes = try await Task.detached(priority: .userInitiated) {
                        try Self.plan(snapshot: snapshot, from: from, to: to,
                                      departingAt: departingAt,
                                      departureSearchWindow: departureWindow,
                                      maximumJourneyDuration: Self.maximumJourneyDuration,
                                      originWalks: originWalks, destinationWalks: destinationWalks,
                                      usingCachedSchedule: usingCachedSchedule, resultLimit: 15,
                                      planningID: planningID, trace: trace, regionID: regionID)
                    }.value
                } catch TransitRoutingError.noJourney {
                    continue
                } catch {
                    lastPlanningError = error
                    throw error
                }

                let originStopIDs = Set(coarseRoutes.compactMap { $0.journey?.originAccessStopID })
                let destinationStopIDs = Set(coarseRoutes.compactMap { $0.journey?.destinationAccessStopID })
                let originCandidates = originStopIDs.compactMap { database.stopByID[$0] }
                    .map { ($0, from.distance(to: $0.coordinate)) }
                    .sorted { $0.1 < $1.1 }
                let destinationCandidates = destinationStopIDs.compactMap { database.stopByID[$0] }
                    .map { ($0, to.distance(to: $0.coordinate)) }
                    .sorted { $0.1 < $1.1 }
                guard !originCandidates.isEmpty, !destinationCandidates.isEmpty else { continue }
                async let exactOriginRequest = walkingOptions(from: from, candidates: originCandidates,
                                                              endpoint: walkingRoutingEndpoint,
                                                              planningID: planningID, trace: trace)
                async let exactDestinationRequest = walkingOptions(from: to, candidates: destinationCandidates,
                                                                   endpoint: walkingRoutingEndpoint,
                                                                   planningID: planningID, trace: trace)
                let (exactOriginWalks, exactDestinationApproaches) = try await (
                    exactOriginRequest, exactDestinationRequest)
                let exactDestinationWalks = exactDestinationApproaches.map { option in
                    TransitWalkOption(stop: option.stop, distance: option.distance,
                                      duration: option.duration,
                                      coordinates: Array(option.coordinates.reversed()),
                                      hasResolvedGeometry: option.hasResolvedGeometry,
                                      isApproximate: option.isApproximate)
                }
                let exactRoutes: [NavigationRoute]
                do {
                    exactRoutes = try await Task.detached(priority: .userInitiated) {
                        try Self.plan(snapshot: snapshot, from: from, to: to,
                                      departingAt: departingAt,
                                      departureSearchWindow: departureWindow,
                                      maximumJourneyDuration: Self.maximumJourneyDuration,
                                      originWalks: exactOriginWalks,
                                      destinationWalks: exactDestinationWalks,
                                      usingCachedSchedule: usingCachedSchedule, resultLimit: 15,
                                      planningID: planningID, trace: trace, regionID: regionID)
                    }.value
                } catch TransitRoutingError.noJourney {
                    continue
                } catch TransitRoutingError.outsideCoverage {
                    continue
                }
                for route in exactRoutes {
                    let signature = TransitCandidateRanker.transitSignature(route)
                    guard !signature.isEmpty else { continue }
                    if let old = routePool[signature],
                       TransitCandidateRanker.generalizedCost(old) <= TransitCandidateRanker.generalizedCost(route) { continue }
                    routePool[signature] = route
                }
                if stageIndex < Self.stagedDepartureWindows.count - 1 && routePool.count >= 3 { break }
            }
            guard !routePool.isEmpty else { throw lastPlanningError }
            let planned = routePool.values.sorted {
                TransitCandidateRanker.generalizedCost($0) < TransitCandidateRanker.generalizedCost($1)
            }.prefix(15).map { $0 }
            trace.recordElapsedDuration("TimeToStaticCandidates")
            TransitSignposting.end("TransitSearch", identifier: searchInterval, planningID: planningID)
            trace.recordDuration("TransitSearch", startedAt: searchStartedAt)
            trace.recordElapsedDuration("TimeToFirstRoute")
            await onProgress?(.enrichingGeometry)
            let geometryCandidates = Self.selectRouteVariants(
                planned, limit: Self.maximumWalkingGeometryCandidates)
            let routes = await resolveTransferWalks(in: geometryCandidates, endpoint: walkingRoutingEndpoint,
                                                    planningID: planningID, trace: trace)
            guard !routes.isEmpty else { throw TransitRoutingError.walkingUnavailable }
            trace.recordElapsedDuration("TimeToRouteReady")
            await onProvisionalRoutes?(routes)
            await onProgress?(nil)
            return routes
        } catch {
            TransitSignposting.end("TransitSearch", identifier: searchInterval, planningID: planningID)
            trace.recordDuration("TransitSearch", startedAt: searchStartedAt)
            throw error
        }
    }

    func loadRealtimeForRoutePlanning(planningID: UInt64,
                                             trace: TransitPlanningTrace) async -> GTFSRealtimeSnapshot {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let now = Date()
        let snapshot: GTFSRealtimeSnapshot
        let shouldRefresh: Bool
        let cachedSnapshotAge = realtimeLoadedAt.map { max(0, now.timeIntervalSince($0)) }
        var usedCachedSnapshot = false
        if let realtimeSnapshot, let realtimeLoadedAt,
           now.timeIntervalSince(realtimeLoadedAt) < 45 {
            snapshot = realtimeSnapshot
            shouldRefresh = false
            usedCachedSnapshot = true
        } else if let realtimeSnapshot, let realtimeLoadedAt,
                  now.timeIntervalSince(realtimeLoadedAt) <= 180 {
            snapshot = realtimeSnapshot
            shouldRefresh = true
            usedCachedSnapshot = true
        } else {
            snapshot = .empty
            shouldRefresh = true
        }
        if let cachedSnapshotAge {
            trace.setCount("realtimeAgeSeconds", value: Int(cachedSnapshotAge.rounded()))
        }
        trace.setValue("realtimeUsed", value: usedCachedSnapshot && snapshot.isAvailable ? "yes" : "no")
        trace.setValue("realtimeFreshness", value: usedCachedSnapshot
                       ? snapshot.freshness.rawValue : "static_only")
        trace.recordDuration("RealtimeWait", startedAt: startedAt)
        if shouldRefresh {
            trace.setCount("realtimeRefreshDeferred", value: 1)
            TransitSignposting.event("RealtimeRefreshDeferred", value: 1, planningID: planningID)
            let fetchStartedAt = ProcessInfo.processInfo.systemUptime
            let interval = TransitSignposting.begin("RealtimeBackgroundFetch", planningID: planningID)
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = await self.loadRealtime()
                let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - fetchStartedAt) * 1_000).rounded())
                trace.recordDuration("RealtimeBackgroundFetch", startedAt: fetchStartedAt)
                TransitSignposting.end("RealtimeBackgroundFetch", identifier: interval, planningID: planningID)
                TransitSignposting.event("RealtimeFetchDurationMS", value: milliseconds,
                                         planningID: planningID)
            }
        }
        return snapshot
    }

    func coarseWalkingOptions(from coordinate: Coordinate, database: GTFSDatabase,
                                      trace: TransitPlanningTrace) -> [TransitWalkOption] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let interval = TransitSignposting.begin("NearbyStops")
        let candidates = Self.nearestStops(to: coordinate, stopByID: database.stopByID,
                                           spatialIndex: database.stopSpatialIndex,
                                           maximumDistance: Self.maximumAccessWalkDistance,
                                           localLimit: Self.maximumLocalWalkingCandidates,
                                           railwayLimit: Self.maximumRailWalkingCandidates)
        TransitSignposting.end("NearbyStops", identifier: interval)
        trace.recordDuration("NearbyStops", startedAt: startedAt)
        trace.addCount("nearbyStops", value: candidates.count)
        TransitSignposting.event("NearbyStopCount", value: candidates.count)
        trace.addCount("coarseAccessCandidates", value: candidates.count)
        let cached = candidates.compactMap { stop, distance -> TransitWalkOption? in
            let key = Self.accessCacheKey(from: coordinate, stop: stop,
                                          databaseFingerprint: loadedDatabaseFingerprint ?? "")
            guard let entry = persistentAccessEstimates[key],
                  Date().timeIntervalSince(entry.storedAt) >= 0,
                  Date().timeIntervalSince(entry.storedAt) < 6 * 60 * 60 else { return nil }
            let originAdjustment = coordinate.distance(to: entry.origin) / 0.9
            let adjustedDuration = entry.duration + originAdjustment
            guard adjustedDuration <= Self.maximumAccessWalkTime else { return nil }
            return TransitWalkOption(stop: stop,
                                     distance: max(distance, entry.distance + originAdjustment * 0.9),
                                     duration: adjustedDuration,
                                     coordinates: [coordinate, stop.coordinate],
                                     hasResolvedGeometry: false, isApproximate: true)
        }
        trace.addCount("persistentAccessCacheHits", value: cached.count)
        return approximateFallbackWalkingOptions(from: coordinate, candidates: candidates, existing: cached)
    }

    func walkingOptions(from coordinate: Coordinate,
                                candidates: [(GTFSStop, Double)],
                                endpoint: URL, planningID: UInt64,
                                trace: TransitPlanningTrace) async throws -> [TransitWalkOption] {
        let matrixStartedAt = ProcessInfo.processInfo.systemUptime
        let matrixInterval = TransitSignposting.begin("WalkingMatrix", planningID: planningID)
        defer {
            TransitSignposting.end("WalkingMatrix", identifier: matrixInterval, planningID: planningID)
            trace.recordDuration("WalkingMatrix", startedAt: matrixStartedAt)
        }

        trace.addCount("exactAccessCandidates", value: candidates.count)
        let provider = ValhallaRouteProvider(endpoint: endpoint)
        var cachedByStopID: [String: TransitWalkOption] = [:]
        for (stop, _) in candidates {
            if let option = cachedWalkingOption(from: coordinate, to: stop, endpoint: endpoint) {
                cachedByStopID[stop.id] = option
            }
        }
        var results = candidates.compactMap { cachedByStopID[$0.0.id] }
        let matrixCandidates = candidates.filter { cachedByStopID[$0.0.id] == nil }
        var start = 0
        var matrixUnavailable = false
        var matrixCalls = 0
        var matrixReachableTargets = 0
        var matrixUnreachableTargets = 0
        var matrixOverWalkLimit = 0
        var matrixShapesReturned = 0
        while start < matrixCandidates.count {
            let end = min(start + Self.walkingMatrixBatchSize, matrixCandidates.count)
            let batch = Array(matrixCandidates[start..<end])
            let costs: [WalkingRouteCost?]
            do {
                matrixCalls += 1
                trace.addCount("matrixTargetsSent", value: batch.count)
                costs = try await provider.walkingCosts(from: coordinate, to: batch.map { $0.0.coordinate })
            } catch is CancellationError {
                throw CancellationError()
            } catch RoutingError.server(let statusCode) {
                trace.addCount("matrixHTTPErrorCount", value: 1)
                trace.setCount("matrixHTTPErrorStatus", value: statusCode)
                TransitSignposting.event("WalkingMatrixHTTPErrorStatus", value: statusCode,
                                         planningID: planningID)
                matrixUnavailable = true
                break
            } catch {
                trace.addCount("matrixErrorCount", value: 1)
                matrixUnavailable = true
                break
            }
            for index in batch.indices {
                guard let cost = costs[index] else {
                    matrixUnreachableTargets += 1
                    continue
                }
                matrixReachableTargets += 1
                if (cost.coordinates?.count ?? 0) > 1 { matrixShapesReturned += 1 }
                guard cost.duration <= Self.maximumAccessWalkTime else {
                    matrixOverWalkLimit += 1
                    continue
                }
                let stop = batch[index].0
                let coordinates = cost.coordinates.flatMap { $0.count > 1 ? $0 : nil }
                    ?? [coordinate, stop.coordinate]
                if let resolvedCoordinates = cost.coordinates, resolvedCoordinates.count > 1 {
                    cacheWalkingGeometry(
                        TransitWalkingGeometry(coordinates: resolvedCoordinates, duration: cost.duration),
                        for: TransitWalkingGeometryKey(from: coordinate, to: stop.coordinate),
                        endpoint: endpoint
                    )
                }
                results.append(TransitWalkOption(stop: stop, distance: cost.distance,
                                                 duration: cost.duration,
                                                 coordinates: coordinates,
                                                 hasResolvedGeometry: (cost.coordinates?.count ?? 0) > 1))
                let accessKey = Self.accessCacheKey(from: coordinate, stop: stop,
                                                    databaseFingerprint: loadedDatabaseFingerprint ?? "")
                persistentAccessEstimates[accessKey] = TransitAccessEstimate(
                    key: accessKey, origin: coordinate, stopID: stop.id,
                    distance: cost.distance, duration: cost.duration, storedAt: Date())
            }
            start = end
        }
        trace.addCount("matrixCalls", value: matrixCalls)
        trace.addCount("matrixReachableTargets", value: matrixReachableTargets)
        trace.addCount("matrixUnreachableTargets", value: matrixUnreachableTargets)
        trace.addCount("matrixOverWalkLimit", value: matrixOverWalkLimit)
        trace.addCount("matrixShapesReturned", value: matrixShapesReturned)
        let matrixGeometries = results.filter(\.hasResolvedGeometry).count
        trace.addCount("matrixGeometries", value: matrixGeometries)
        TransitSignposting.event("WalkingMatrixBatchCount", value: matrixCalls, planningID: planningID)
        TransitSignposting.event("WalkingMatrixGeometryCount", value: matrixGeometries,
                                 planningID: planningID)
        trimPersistentAccessEstimates()
        persistPedestrianCache()
        if matrixUnavailable {
            trace.addCount("matrixFallbackCount", value: 1)
            trace.addCount("matrixFallbacks", value: 1)
            let fallbackOptions = approximateFallbackWalkingOptions(
                from: coordinate, candidates: candidates, existing: results,
                limitToPrioritizedCandidates: false
            )
            let approximateCount = fallbackOptions.filter(\.isApproximate).count
            trace.addCount("approximateFallbackStops", value: approximateCount)
            TransitSignposting.event("WalkingMatrixFallbackApproximateUsed", value: approximateCount,
                                     planningID: planningID)
            return fallbackOptions
        }
        return results
    }

    func cachedWalkingOption(from coordinate: Coordinate, to stop: GTFSStop,
                                     endpoint: URL) -> TransitWalkOption? {
        let endpointKey = endpoint.absoluteString
        let directKey = TransitWalkingGeometryKey(from: coordinate, to: stop.coordinate)
        if let geometry = cachedWalkingGeometry(for: directKey, endpointKey: endpointKey) {
            return TransitWalkOption(stop: stop,
                                     distance: Self.pathDistance(geometry.coordinates),
                                     duration: geometry.duration,
                                     coordinates: geometry.coordinates,
                                     hasResolvedGeometry: true)
        }
        let reverseKey = TransitWalkingGeometryKey(from: stop.coordinate, to: coordinate)
        guard let geometry = cachedWalkingGeometry(for: reverseKey, endpointKey: endpointKey) else {
            return nil
        }
        return TransitWalkOption(stop: stop,
                                 distance: Self.pathDistance(geometry.coordinates),
                                 duration: geometry.duration,
                                 coordinates: Array(geometry.coordinates.reversed()),
                                 hasResolvedGeometry: true)
    }

    func cachedWalkingGeometry(for key: TransitWalkingGeometryKey,
                                       endpointKey: String) -> TransitWalkingGeometry? {
        guard let geometry = walkingGeometryCache[endpointKey]?[key],
              let storedAt = walkingGeometryStoredAt[endpointKey]?[key],
              (0...30 * 24 * 60 * 60).contains(Date().timeIntervalSince(storedAt)) else {
            walkingGeometryCache[endpointKey]?.removeValue(forKey: key)
            walkingGeometryStoredAt[endpointKey]?.removeValue(forKey: key)
            walkingGeometryCacheOrder[endpointKey]?.removeAll { $0 == key }
            return nil
        }
        Self.touchWalkingGeometryCacheKey(key, in: &walkingGeometryCacheOrder[endpointKey, default: []])
        return geometry
    }

    func cacheWalkingGeometry(_ geometry: TransitWalkingGeometry,
                                     for key: TransitWalkingGeometryKey,
                                     endpoint: URL) {
        let endpointKey = endpoint.absoluteString
        var geometries = walkingGeometryCache[endpointKey] ?? [:]
        var order = walkingGeometryCacheOrder[endpointKey] ?? []
        geometries[key] = geometry
        Self.touchWalkingGeometryCacheKey(key, in: &order)
        var storedAt = walkingGeometryStoredAt[endpointKey] ?? [:]
        storedAt[key] = Date()
        while order.count > Self.maximumCachedWalkingGeometries {
            let removed = order.removeFirst()
            geometries.removeValue(forKey: removed)
            storedAt.removeValue(forKey: removed)
        }
        walkingGeometryCache[endpointKey] = geometries
        walkingGeometryCacheOrder[endpointKey] = order
        walkingGeometryStoredAt[endpointKey] = storedAt
    }

    func loadPersistentPedestrianCacheIfNeeded() async {
        guard !pedestrianCacheLoaded else { return }
        pedestrianCacheLoaded = true
        let url = cacheDirectory.appendingPathComponent("pedestrian-cache-v2.plist")
        let cacheTask = Task.detached(priority: .utility) { () -> PersistedPedestrianCache? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let cache = try? PropertyListDecoder().decode(PersistedPedestrianCache.self, from: data) else {
                return nil
            }
            return cache
        }
        let cache = await cacheTask.value
        guard let cache,
              cache.schemaVersion == PersistedPedestrianCache.currentSchemaVersion else { return }
        let now = Date()
        let geometries = cache.geometries.filter {
            let age = now.timeIntervalSince($0.storedAt)
            return (0...30 * 24 * 60 * 60).contains(age)
        }.sorted { $0.storedAt > $1.storedAt }
        for entry in geometries.prefix(Self.maximumCachedWalkingGeometries).reversed() {
            walkingGeometryCache[entry.endpoint, default: [:]][entry.key] = entry.geometry
            walkingGeometryStoredAt[entry.endpoint, default: [:]][entry.key] = entry.storedAt
            Self.touchWalkingGeometryCacheKey(entry.key,
                                             in: &walkingGeometryCacheOrder[entry.endpoint, default: []])
        }
        let access = cache.accessEstimates.filter {
            let age = now.timeIntervalSince($0.storedAt)
            return (0...6 * 60 * 60).contains(age)
        }.sorted { $0.storedAt > $1.storedAt }
        for entry in access.prefix(Self.maximumCachedAccessEstimates).reversed() {
            persistentAccessEstimates[entry.key] = entry
        }
    }

    func persistPedestrianCache() {
        let geometries = walkingGeometryCache.flatMap { endpoint, values in
            values.compactMap { key, geometry -> PersistedWalkingGeometry? in
                guard let storedAt = walkingGeometryStoredAt[endpoint]?[key] else { return nil }
                return PersistedWalkingGeometry(endpoint: endpoint, key: key,
                                                geometry: geometry, storedAt: storedAt)
            }
        }.sorted { $0.storedAt > $1.storedAt }
        let access = persistentAccessEstimates.values.sorted { $0.storedAt > $1.storedAt }
            .prefix(Self.maximumCachedAccessEstimates)
        let cache = PersistedPedestrianCache(
            schemaVersion: PersistedPedestrianCache.currentSchemaVersion,
            geometries: Array(geometries.prefix(Self.maximumCachedWalkingGeometries)),
            accessEstimates: Array(access)
        )
        let url = cacheDirectory.appendingPathComponent("pedestrian-cache-v2.plist")
        let previousWrite = pedestrianCacheWriteTask
        pedestrianCacheWriteTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(cache).write(to: url, options: .atomic)
            } catch {
                // Disk cache failures must not affect route planning.
            }
        }
    }

    func trimPersistentAccessEstimates() {
        let overflow = persistentAccessEstimates.count - Self.maximumCachedAccessEstimates
        guard overflow > 0 else { return }
        let oldestKeys = persistentAccessEstimates.values
            .sorted { $0.storedAt < $1.storedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys { persistentAccessEstimates.removeValue(forKey: key) }
    }

    static func accessCacheKey(from coordinate: Coordinate, stop: GTFSStop,
                                       databaseFingerprint: String) -> String {
        let latitudeCell = Int(floor(coordinate.latitude * 1_000))
        let longitudeCell = Int(floor(coordinate.longitude * 1_000))
        return "\(databaseFingerprint)|\(latitudeCell):\(longitudeCell)|\(stop.id)"
    }

    func approximateFallbackWalkingOptions(
        from coordinate: Coordinate,
        candidates: [(GTFSStop, Double)],
        existing: [TransitWalkOption],
        limitToPrioritizedCandidates: Bool = true
    ) -> [TransitWalkOption] {
        let localCandidates = candidates.filter { !$0.0.id.hasPrefix("rail/") }
        let railwayCandidates = candidates.filter { $0.0.id.hasPrefix("rail/") }
        let local = limitToPrioritizedCandidates
            ? Array(localCandidates.prefix(Self.maximumApproximateLocalWalkingCandidates)) : localCandidates
        let railway = limitToPrioritizedCandidates
            ? Array(railwayCandidates.prefix(Self.maximumApproximateRailWalkingCandidates)) : railwayCandidates
        let prioritized = (Array(local) + Array(railway)).sorted { $0.1 < $1.1 }
        var byStopID = Dictionary(existing.map { ($0.stop.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (stop, straightLineDistance) in prioritized where byStopID[stop.id] == nil {
            // Leave headroom for street detours and slower walking pace.
            let estimatedDistance = straightLineDistance * 1.5
            let estimatedDuration = estimatedDistance / 0.9
            guard estimatedDuration <= Self.maximumAccessWalkTime else { continue }
            byStopID[stop.id] = TransitWalkOption(stop: stop, distance: estimatedDistance,
                                                  duration: estimatedDuration,
                                                  coordinates: [coordinate, stop.coordinate],
                                                  hasResolvedGeometry: false,
                                                  isApproximate: true)
        }
        return prioritized.compactMap { byStopID[$0.0.id] }
    }

    func resolveTransferWalks(in routes: [NavigationRoute], endpoint: URL,
                                      planningID: UInt64,
                                      trace: TransitPlanningTrace) async -> [NavigationRoute] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let interval = TransitSignposting.begin("GeometryFetch", planningID: planningID)
        defer {
            TransitSignposting.end("GeometryFetch", identifier: interval, planningID: planningID)
            trace.recordDuration("GeometryFetch", startedAt: startedAt)
        }

        var requestsByKey: [TransitWalkingGeometryKey: TransitWalkingGeometryRequest] = [:]
        for route in routes {
            guard let journey = route.journey else { continue }
            for leg in journey.legs where leg.mode == "WALK" {
                if !leg.isTransfer && (leg.hasResolvedWalkingGeometry || leg.coordinates.count > 2) { continue }
                guard let from = leg.coordinates.first, let to = leg.coordinates.last,
                      from.distance(to: to) > 1 else { continue }
                let request = TransitWalkingGeometryRequest(from: from, to: to)
                requestsByKey[request.key] = request
            }
        }

        let endpointKey = endpoint.absoluteString
        var geometries = walkingGeometryCache[endpointKey] ?? [:]
        var cacheOrder = walkingGeometryCacheOrder[endpointKey] ?? []
        // Walking geometry requests currently use Valhalla's fixed pedestrian profile.
        // The endpoint is part of the outer cache key; coordinates and direction are in the inner key.
        for key in requestsByKey.keys where geometries[key] != nil {
            Self.touchWalkingGeometryCacheKey(key, in: &cacheOrder)
        }
        let cachedGeometries = geometries
        let cachedRequestKeys = Set(requestsByKey.keys.filter { geometries[$0] != nil })
        let missingRequests = requestsByKey.values.filter { cachedGeometries[$0.key] == nil }
        let fetchedGeometries = await loadWalkingGeometries(requests: Array(missingRequests), endpoint: endpoint)
        // The actor can process another planning request while network fetches are suspended.
        // Merge into its latest cache state so concurrent requests do not discard each other's entries.
        geometries = walkingGeometryCache[endpointKey] ?? geometries
        cacheOrder = walkingGeometryCacheOrder[endpointKey] ?? cacheOrder
        for key in cachedRequestKeys {
            Self.touchWalkingGeometryCacheKey(key, in: &cacheOrder)
        }
        for key in fetchedGeometries.keys {
            Self.touchWalkingGeometryCacheKey(key, in: &cacheOrder)
            walkingGeometryStoredAt[endpointKey, default: [:]][key] = Date()
        }
        geometries.merge(fetchedGeometries) { _, fetched in fetched }
        while cacheOrder.count > Self.maximumCachedWalkingGeometries {
            let leastRecentlyUsed = cacheOrder.removeFirst()
            geometries.removeValue(forKey: leastRecentlyUsed)
            walkingGeometryStoredAt[endpointKey]?.removeValue(forKey: leastRecentlyUsed)
        }
        walkingGeometryCache[endpointKey] = geometries
        walkingGeometryCacheOrder[endpointKey] = cacheOrder
        persistPedestrianCache()
        let cacheHits = requestsByKey.count - missingRequests.count
        trace.setCount("geometryCacheHits", value: cacheHits)
        trace.setCount("geometryRequests", value: missingRequests.count)
        trace.setCount("walkingSegments", value: requestsByKey.count)
        TransitSignposting.event("UniqueWalkingGeometryCount", value: requestsByKey.count,
                                 planningID: planningID)
        TransitSignposting.event("WalkingGeometryCacheHits", value: cacheHits, planningID: planningID)
        TransitSignposting.event("WalkingGeometryRequests", value: missingRequests.count, planningID: planningID)
        var resolved: [NavigationRoute] = []
        for route in routes {
            if let route = resolveTransferWalks(in: route, geometries: geometries) {
                resolved.append(route)
            }
        }

        return Self.selectRouteVariants(resolved, limit: 3)
    }

    static func selectRouteVariants(_ routes: [NavigationRoute], limit: Int) -> [NavigationRoute] {
        let ranked = routes.sorted { TransitCandidateRanker.generalizedCost($0) < TransitCandidateRanker.generalizedCost($1) }
        guard limit > 0, !ranked.isEmpty else { return [] }
        let fastest = ranked.min { $0.expectedTravelTime < $1.expectedTravelTime }
        let fewestTransfers = ranked.min {
            ($0.journey?.transferCount ?? Int.max, $0.expectedTravelTime)
                < ($1.journey?.transferCount ?? Int.max, $1.expectedTravelTime)
        }
        let leastWalking = ranked.min {
            ($0.journey?.walkingDuration ?? .infinity, $0.expectedTravelTime)
                < ($1.journey?.walkingDuration ?? .infinity, $1.expectedTravelTime)
        }
        var selected: [NavigationRoute] = []
        for candidate in [ranked.first, fastest, fewestTransfers, leastWalking].compactMap({ $0 }) + ranked {
            guard !selected.contains(where: { TransitCandidateRanker.transitSignature($0) == TransitCandidateRanker.transitSignature(candidate) }) else { continue }
            selected.append(candidate)
            if selected.count == limit { break }
        }
        return selected.sorted { TransitCandidateRanker.generalizedCost($0) < TransitCandidateRanker.generalizedCost($1) }
    }

    static func touchWalkingGeometryCacheKey(
        _ key: TransitWalkingGeometryKey,
        in order: inout [TransitWalkingGeometryKey]
    ) {
        if let existingIndex = order.firstIndex(of: key) {
            order.remove(at: existingIndex)
        }
        order.append(key)
    }

    func loadWalkingGeometries(
        requests: [TransitWalkingGeometryRequest], endpoint: URL
    ) async -> [TransitWalkingGeometryKey: TransitWalkingGeometry] {
        await withTaskGroup(
            of: (TransitWalkingGeometryKey, TransitWalkingGeometry?).self,
            returning: [TransitWalkingGeometryKey: TransitWalkingGeometry].self
        ) { group in
            var requestsIterator = requests.makeIterator()
            let concurrencyLimit = min(4, requests.count)
            for _ in 0..<concurrencyLimit {
                guard let request = requestsIterator.next() else { break }
                group.addTask { await WalkingConnectionProvider.fetchGeometry(request, endpoint: endpoint) }
            }

            var geometries: [TransitWalkingGeometryKey: TransitWalkingGeometry] = [:]
            while let (key, geometry) = await group.next() {
                if let geometry { geometries[key] = geometry }
                if let request = requestsIterator.next() {
                    group.addTask { await WalkingConnectionProvider.fetchGeometry(request, endpoint: endpoint) }
                }
            }
            return geometries
        }
    }

    func resolveTransferWalks(
        in route: NavigationRoute,
        geometries: [TransitWalkingGeometryKey: TransitWalkingGeometry]
    ) -> NavigationRoute? {
        guard var journey = route.journey else { return nil }
        var resolved = route
        var changed = false
        for index in journey.legs.indices where journey.legs[index].mode == "WALK" {
            let leg = journey.legs[index]
            if !leg.isTransfer && leg.coordinates.count > 2 { continue }
            guard let from = leg.coordinates.first, let to = leg.coordinates.last else { return nil }
            let walkingGeometry: TransitWalkingGeometry
            if from.distance(to: to) <= 1 {
                walkingGeometry = TransitWalkingGeometry(coordinates: [from, to], duration: 0)
            } else {
                let key = TransitWalkingGeometryKey(from: from, to: to)
                guard let geometry = geometries[key] else { return nil }
                walkingGeometry = geometry
            }
            if !leg.isTransfer && walkingGeometry.duration > Self.maximumAccessWalkTime {
                return nil
            }

            let transferDeparture: Date
            if leg.isTransfer, index > 0, journey.legs[index - 1].mode == "WALK" {
                transferDeparture = journey.legs[index - 1].arrival
            } else if leg.from == "Punkt początkowy" {
                transferDeparture = journey.departure
            } else if leg.to == "Cel", index > 0 {
                transferDeparture = journey.legs[index - 1].arrival
            } else {
                transferDeparture = leg.departure
            }
            let nextRide = journey.legs.suffix(from: index + 1).first(where: { $0.mode != "WALK" })
            journey.legs[index].coordinates = walkingGeometry.coordinates
            journey.legs[index].hasResolvedWalkingGeometry = true
            journey.legs[index].walkingTimeIsApproximate = false
            journey.legs[index].departure = transferDeparture
            journey.legs[index].arrival = transferDeparture.addingTimeInterval(
                walkingGeometry.duration + (leg.isTransfer ? leg.minimumTransferTime : 0))
            if nextRide == nil,
               journey.legs.indices.contains(index + 1),
               journey.legs[index + 1].mode == "WALK" {
                let egressDuration = journey.legs[index + 1].arrival.timeIntervalSince(
                    journey.legs[index + 1].departure)
                journey.legs[index + 1].departure = journey.legs[index].arrival
                journey.legs[index + 1].arrival = journey.legs[index].arrival
                    .addingTimeInterval(egressDuration)
                journey.arrival = journey.legs[index + 1].arrival
            } else if nextRide == nil {
                journey.arrival = journey.legs[index].arrival
            }
            changed = true
        }
        guard changed else {
            resolved.journey = journey
            return resolved
        }
        for nextRideIndex in journey.legs.indices where journey.legs[nextRideIndex].mode != "WALK" {
            let previousRideIndex = journey.legs[..<nextRideIndex].lastIndex(where: { $0.mode != "WALK" })
            let walkingStartIndex = (previousRideIndex.map { $0 + 1 } ?? 0)..<nextRideIndex
            let walkLegs = walkingStartIndex.map { journey.legs[$0] }.filter { $0.mode == "WALK" }
            guard !walkLegs.isEmpty else { continue }
            let startTime = previousRideIndex.map { journey.legs[$0].arrival } ?? journey.departure
            let required = walkLegs.reduce(0.0) {
                $0 + $1.arrival.timeIntervalSince($1.departure)
            }
            guard required <= journey.legs[nextRideIndex].departure.timeIntervalSince(startTime) else {
                return nil
            }
        }
        let rideDuration = journey.legs.filter { $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        journey.walkingDuration = journey.legs.filter { $0.mode == "WALK" }
            .reduce(0.0) {
                $0 + max(0, $1.arrival.timeIntervalSince($1.departure) - $1.minimumTransferTime)
            }
        journey.waitingDuration = max(0, journey.arrival.timeIntervalSince(journey.departure)
            - rideDuration - journey.walkingDuration)
        resolved.journey = journey
        resolved.expectedTravelTime = journey.arrival.timeIntervalSince(journey.departure)
        resolved.coordinates = journey.legs.flatMap { leg in
            leg.coordinates.isEmpty ? [] : Array(leg.coordinates.dropFirst())
        }
        if let first = journey.legs.first?.coordinates.first {
            resolved.coordinates.insert(first, at: 0)
        }
        resolved.distance = zip(resolved.coordinates, resolved.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        return resolved
    }
}
