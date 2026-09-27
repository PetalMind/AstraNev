import Foundation

nonisolated enum TransitPlanningPhase: Equatable, Sendable {
    case searchingConnections
}

typealias TransitPlanningProgressHandler = @MainActor @Sendable (TransitPlanningPhase?) async -> Void
typealias TransitProvisionalRoutesHandler = @MainActor @Sendable ([NavigationRoute]) async -> Void
typealias TransitPlanningContinuation = @MainActor @Sendable () async -> Bool

nonisolated final class TransitPlanningCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    @discardableResult
    func addCancellationHandler(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { cancellationHandlers[id] = handler }
        lock.unlock()
        if alreadyCancelled { handler() }
        return id
    }

    func removeCancellationHandler(_ id: UUID) {
        lock.lock()
        cancellationHandlers[id] = nil
        lock.unlock()
    }

    func checkCancellation() throws {
        if Task.isCancelled || isCancelled { throw CancellationError() }
    }
}
