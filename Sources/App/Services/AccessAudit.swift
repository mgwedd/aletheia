import Foundation

/// Records that a patient or session was opened, and that AI was used on patient
/// data. Opening is rate limited per record, so a view that appears again and
/// again (switching back and forth, re-rendering) is one entry per window.
/// Entries carry an opaque id and a fixed kind, never a name, text or prompt.
final class AccessAudit {
    /// An opened record is entered once per this many seconds.
    static let viewWindow: TimeInterval = 300
    /// Digests run as many small jobs; one entry covers the run.
    static let digestWindow: TimeInterval = 600

    typealias Sink = (AuditAction, String?, AuditDetail?) -> Void

    private let sink: Sink
    private let lock = NSLock()
    private var lastViewed: [UUID: Date] = [:]
    private var lastDigest: Date?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    /// A patient record was opened.
    func viewedPatient(_ id: UUID, now: Date = Date()) {
        viewed(id, detail: .patient, now: now)
    }

    /// A session record was opened.
    func viewedSession(_ id: UUID, now: Date = Date()) {
        viewed(id, detail: .session, now: now)
    }

    /// An AI job began on patient data.
    func aiUsed(_ kind: InferenceQueue.Kind, now: Date = Date()) {
        if kind == .digest {
            lock.lock()
            defer { lock.unlock() }
            if let last = lastDigest, now.timeIntervalSince(last) < Self.digestWindow { return }
            lastDigest = now
            sink(.aiInference, nil, .aiUse(kind))
            return
        }
        sink(.aiInference, nil, .aiUse(kind))
    }

    /// Forget what was opened, so the next opening after an unlock is recorded.
    func reset() {
        lock.lock()
        lastViewed.removeAll()
        lock.unlock()
    }

    private func viewed(_ id: UUID, detail: AuditDetail, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastViewed[id], now.timeIntervalSince(last) < Self.viewWindow { return }
        lastViewed[id] = now
        sink(.phiViewed, id.uuidString, detail)
    }
}
