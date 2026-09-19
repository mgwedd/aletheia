import Foundation

/// A domain-neutral unit of persisted state: an opaque `payload` identified by
/// `(kind, id)`, scoped to an owner and optionally an item within that owner.
///
/// The persistence core stores and returns these without knowing what they
/// mean. The *domain adapter* decides that `kind == "comment"` is a therapist's
/// margin comment, that `ownerID` is a patient and `itemID` a session, and how
/// to encode/decode `payload`. Nothing clinical — not even the words
/// "patient"/"session" — appears at this layer, so the same core can back a
/// different single-user, on-device domain by swapping only the adapter above it.
///
/// Identity is always the opaque `UUID`s from Arch v2 (1) (#64), never a path.
struct PersistedRecord: Equatable {
    /// Stable and unique within `kind`. For a *collection* record (many per
    /// item, e.g. comments) this is a fresh UUID string; for a *singleton*
    /// (one per item, e.g. a session's note or chat) the adapter uses the
    /// item's id, so the upsert is keyed naturally.
    let id: String
    /// The adapter-defined record type, e.g. "comment", "note", "sessionChat",
    /// "chatThread". The core treats it as an opaque bucket name.
    let kind: String
    /// The owning aggregate root (a patient, in the therapist domain), if any.
    let ownerID: UUID?
    /// The item within the owner (a session) this record hangs off, if any.
    let itemID: UUID?
    /// Opaque bytes the adapter encodes/decodes. The core never inspects them,
    /// so at-rest field encryption stays an adapter concern.
    var payload: Data
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        kind: String,
        ownerID: UUID? = nil,
        itemID: UUID? = nil,
        payload: Data,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.itemID = itemID
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Domain-neutral storage for `PersistedRecord`s — the generic core of the
/// persistence layer (Arch v2 (2), #65). Implementations own *where* the bytes
/// live (SQLite in the app, an in-memory fake in tests); callers — the typed
/// domain repositories — depend only on this protocol, never on a concrete
/// store, which is what makes both the core reusable and the domain testable.
///
/// Query results are ordered oldest-first (`createdAt` ascending) for a stable,
/// predictable base ordering; a repository that wants another order (e.g. chat
/// threads most-recently-updated first) re-sorts the returned slice itself.
protocol PersistenceCore: AnyObject {
    /// One record by its identity, or nil when absent.
    func record(kind: String, id: String) -> PersistedRecord?

    /// Every record of `kind` hanging off `itemID`, oldest first.
    func records(kind: String, itemID: UUID) -> [PersistedRecord]

    /// Every record of `kind` owned by `ownerID`, oldest first.
    func records(kind: String, ownerID: UUID) -> [PersistedRecord]

    /// Inserts a record or replaces the existing one with the same `(kind, id)`.
    /// Returns false only on a storage error.
    @discardableResult
    func put(_ record: PersistedRecord) -> Bool

    /// Removes the record with `(kind, id)`. Returns true when the store ends up
    /// without it — including when it was already absent — and false only on a
    /// storage error.
    @discardableResult
    func remove(kind: String, id: String) -> Bool
}
