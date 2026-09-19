import Foundation

/// A `PersistenceCore` that keeps everything in memory. It exists so domain
/// repositories can be unit-tested without touching SQLite or the filesystem —
/// the point of depending on the protocol rather than a concrete store — and as
/// the reference for what the SQLite-backed core must do.
///
/// Not thread-safe by itself; the app's core is actor-isolated (Arch v2 (5)),
/// and tests drive this synchronously.
final class InMemoryPersistenceCore: PersistenceCore {
    /// Keyed by `"<kind>\u{1}<id>"` — the `\u{1}` separator can't occur in a
    /// kind or a UUID string, so the composite key is unambiguous.
    private var storage: [String: PersistedRecord] = [:]

    init() {}

    private func key(_ kind: String, _ id: String) -> String { "\(kind)\u{1}\(id)" }

    func record(kind: String, id: String) -> PersistedRecord? {
        storage[key(kind, id)]
    }

    func records(kind: String, itemID: UUID) -> [PersistedRecord] {
        storage.values
            .filter { $0.kind == kind && $0.itemID == itemID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func records(kind: String, ownerID: UUID) -> [PersistedRecord] {
        storage.values
            .filter { $0.kind == kind && $0.ownerID == ownerID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func put(_ record: PersistedRecord) -> Bool {
        storage[key(record.kind, record.id)] = record
        return true
    }

    @discardableResult
    func remove(kind: String, id: String) -> Bool {
        storage[key(kind, id)] = nil
        return true
    }
}
