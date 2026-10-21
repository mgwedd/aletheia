import Foundation

/// What the search index is known to be missing, so global search can say
/// "results may be incomplete" instead of passing off a partial answer as
/// the whole one. Thread-safe.
///
/// Two sources of pending work:
///   - the sweep: sessions whose transcript changed, or that were never
///     indexed, found when the sweep lists the data folder;
///   - saves: a transcript, note or comment saved since, queued for the index.
/// Until a sweep has listed the folder (after launch, unlock, or the index
/// starting over), nothing is known, which is `checked == false`.
final class SearchIndexProgress {
    struct Snapshot: Equatable {
        /// Whether a sweep has compared the index with the data folder since it last started over.
        var checked: Bool
        /// Sessions whose text is known not to be in the index yet.
        var pendingSessions: Int
    }

    private let lock = NSLock()
    private var checked = false
    private var sweepPending = Set<String>()
    private var writes: [String: Int] = [:]
    private var changeHandler: (() -> Void)?

    /// Called (on whatever thread made the change) after every change.
    func onChange(_ handler: (() -> Void)?) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(checked: checked, pendingSessions: sweepPending.union(writes.keys).count)
    }

    /// A sweep is listing the data folder; until it has, coverage is unknown.
    func beginChecking() { change { $0.checked = false; $0.sweepPending = [] } }

    /// The sweep listed the folder; `stale` still has to be indexed.
    func checked(stale: Set<String>) { change { $0.checked = true; $0.sweepPending = stale } }

    /// The sweep finished one session.
    func indexed(session: String) { change { $0.sweepPending.remove(session) } }

    /// A save queued text of `session` for the index.
    func beginWrite(session: String) { change { $0.writes[session, default: 0] += 1 } }

    /// That save is in the index now.
    func endWrite(session: String) {
        change { state in
            guard let count = state.writes[session] else { return }
            if count <= 1 { state.writes[session] = nil } else { state.writes[session] = count - 1 }
        }
    }

    /// The sessions are gone (their patient was deleted): nothing left to wait for.
    func forget(sessions: [String]) {
        change { state in
            for session in sessions {
                state.sweepPending.remove(session)
                state.writes[session] = nil
            }
        }
    }

    /// The index started over empty, or was deleted: unknown until the next sweep.
    func invalidate() { change { $0.checked = false; $0.sweepPending = [] } }

    private struct Mutable {
        var checked: Bool
        var sweepPending: Set<String>
        var writes: [String: Int]
    }

    private func change(_ body: (inout Mutable) -> Void) {
        lock.lock()
        var state = Mutable(checked: checked, sweepPending: sweepPending, writes: writes)
        body(&state)
        checked = state.checked
        sweepPending = state.sweepPending
        writes = state.writes
        let handler = changeHandler
        lock.unlock()
        handler?()
    }
}

/// When a session's transcript has to be (re)indexed. Pure.
enum SearchIndexStaleness {
    /// The stamp recorded for a session that has no transcript, so a notes-only
    /// session counts as indexed once it has been, like any other.
    static let noTranscript = "none"

    /// A transcript's stamp: modification time and size. `noTranscript` when
    /// there is no file; nil when there is one but it can't be stamped (then
    /// it is always indexed, never assumed current).
    static func stamp(exists: Bool, modified: Date?, size: Int?) -> String? {
        guard exists else { return noTranscript }
        guard let modified, let size else { return nil }
        return "\(modified.timeIntervalSinceReferenceDate)-\(size)"
    }

    /// Whether the transcript must be read and indexed: its stamp is unknown,
    /// it was never indexed, or it changed since.
    static func needsIndexing(current: String?, stored: String?) -> Bool {
        guard let current else { return true }
        return current != stored
    }

    /// The order to index sessions in: those whose transcript is stale first
    /// (they are what global search is missing), newest first in each group so
    /// recent sessions are searchable soonest; ties by session id.
    static func order(_ targets: [Store.SearchIndexTarget]) -> [Store.SearchIndexTarget] {
        targets.sorted { a, b in
            if a.transcriptStale != b.transcriptStale { return a.transcriptStale }
            if a.session.date != b.session.date { return a.session.date > b.session.date }
            return a.session.id.uuidString < b.session.id.uuidString
        }
    }
}

/// Whether the Mac is busy with something the background sweep must not slow
/// down: a recording, a transcription, or the AI model generating. The views
/// that own those states report them here; the sweep waits while any is on.
/// Thread-safe.
final class SearchIndexActivity {
    enum Reason: Hashable {
        case recording
        case transcription
        case model
    }

    private let lock = NSLock()
    private var active = Set<Reason>()

    func set(_ reason: Reason, active isActive: Bool) {
        lock.lock()
        if isActive { active.insert(reason) } else { active.remove(reason) }
        lock.unlock()
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !active.isEmpty
    }
}

/// Publishes, on the main thread, that the search index changed, so an open
/// search runs again: its results fill in as sessions are indexed, and its
/// coverage line counts down. Changes reported from any thread in a burst
/// become one update.
final class SearchIndexMonitor: ObservableObject {
    @Published private(set) var revision = 0

    private let lock = NSLock()
    private var scheduled = false

    /// Callable from any thread.
    func noteChange() {
        lock.lock()
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.scheduled = false
            self.lock.unlock()
            self.revision &+= 1
        }
    }
}

/// The background sweep that brings the index in line with the data folder
/// (launch, unlock, folder change, or the index starting over). Off the main
/// actor, one session at a time on the index's serial queue, stopping as soon
/// as `shouldContinue` is false and pausing while `isBusy` is true.
enum SearchIndexSweep {
    static func run(
        store: Store,
        index: SearchIndex,
        isBusy: @escaping () -> Bool,
        pollNanoseconds: UInt64 = 1_000_000_000,
        shouldContinue: @escaping () -> Bool
    ) async {
        index.progress.beginChecking()
        guard let plan = store.searchIndexPlan() else { return }
        index.progress.checked(stale: plan.staleSessions)
        var everyTargetRead = true
        for target in plan.targets {
            while shouldContinue() && isBusy() {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
            guard shouldContinue() else { return }
            let read = await index.perform { store.indexSearchTarget(target) }
            if !read { everyTargetRead = false }
            index.progress.indexed(session: target.session.id.uuidString)
        }
        // Dropping deleted sessions trusts the listing, so only after a clean one.
        if plan.complete, everyTargetRead, shouldContinue() {
            let live = plan.live
            await index.perform { index.drop(sessionsNotIn: live) }
        }
    }
}
