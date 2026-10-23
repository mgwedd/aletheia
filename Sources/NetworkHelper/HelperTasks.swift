import Foundation

/// The work running for one app connection. When the app goes away (it
/// cancelled the request, quit or crashed, so the connection is invalidated)
/// everything still running for it is cancelled, so an abandoned download
/// stops instead of streaming to the end into a file nobody will read.
final class HelperTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [UUID: Task<Void, Never>] = [:]
    private var cancelled = false

    /// Starts `work`, unless `cancelAll` has already run (the app is gone, so
    /// nobody is waiting for the answer).
    func run(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        running[id] = Task { [weak self] in
            await work()
            self?.finished(id)
        }
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let tasks = Array(running.values)
        running.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    /// How many requests are still running (for tests).
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return running.count
    }

    private func finished(_ id: UUID) {
        lock.lock()
        running[id] = nil
        lock.unlock()
    }
}
