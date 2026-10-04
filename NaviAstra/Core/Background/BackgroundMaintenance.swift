import Foundation
#if os(iOS)
import BackgroundTasks
import OSLog
#endif

/// Opportunistic maintenance only. Active navigation is driven by Core Location.
@MainActor
final class BackgroundMaintenance {
#if os(iOS)
    private static let refreshID = "Blackmaks.NaviAstra.cache-refresh"
    private static let processingID = "Blackmaks.NaviAstra.data-maintenance"
    private static var registered = false
    nonisolated private static let logger = Logger(subsystem: "NaviAstra", category: "BackgroundMaintenance")

    static func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            let work = Task {
                await OpenStreetMapPlaceDetailsProvider.maintainCache()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: .main) { task in
            let repository = TransitRepository()
            let work = Task {
                do {
                    // Maintain a feed only if the user has previously downloaded it.
                    let directory = await repository.cacheDirectory
                    if FileManager.default.fileExists(atPath: directory.path) {
                        _ = try await repository.loadDatabase()
                    }
                    await OpenStreetMapPlaceDetailsProvider.maintainCache()
                    task.setTaskCompleted(success: !Task.isCancelled)
                } catch {
                    logger.error("Background data maintenance failed: \(error.localizedDescription)")
                    task.setTaskCompleted(success: false)
                }
            }
            task.expirationHandler = {
                work.cancel()
                Task { await repository.cancelMaintenance() }
            }
        }
    }

    static func schedule() {
        guard registered else { return }
        // Replace pending requests rather than accumulating one per scene transition.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingID)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date().addingTimeInterval(6 * 3_600)
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.earliestBeginDate = Date().addingTimeInterval(24 * 3_600)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = true
        if #available(iOS 27.0, *) {
            for request in [refresh, processing] as [BGTaskRequest] {
                BGTaskScheduler.shared.submitTaskRequest(request) { error in
                    if let error {
                        logger.info("Maintenance scheduling unavailable: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(refresh)
                try BGTaskScheduler.shared.submit(processing)
            } catch { logger.info("Maintenance scheduling unavailable: \(error.localizedDescription)") }
        }
    }
#else
    static func register() {}
    static func schedule() {}
#endif
}
