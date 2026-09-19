import Foundation

/// One margin comment the therapist anchored to a piece of a transcript
/// (Google-Docs style). `quotedText` is the passage it's attached to; `body` is
/// what the therapist wrote.
struct SessionComment: Identifiable, Equatable {
    let id: String
    var quotedText: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    /// Seconds into the session that this comment's passage falls at, derived
    /// from the transcript's time codes when the comment is created. nil when the
    /// passage couldn't be located (e.g. no quote, or a hand-typed passage).
    var anchorSeconds: Double?
    /// Google-Docs-style resolution: a resolved comment drops its transcript
    /// highlight and collapses into the rail's "Resolved" section, but is kept
    /// (never silently deleted) so the therapist can reopen it. Defaults to
    /// false, and older payloads written before this field simply decode as
    /// unresolved.
    var resolved: Bool

    init(
        id: String,
        quotedText: String,
        body: String,
        createdAt: Date,
        updatedAt: Date,
        anchorSeconds: Double? = nil,
        resolved: Bool = false
    ) {
        self.id = id
        self.quotedText = quotedText
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.anchorSeconds = anchorSeconds
        self.resolved = resolved
    }
}

/// Local database for the therapist's own annotations — inline transcript
/// comments, freeform per-session notes, per-session assistant chat, and
/// per-patient chat threads. These are PHI, and the user asked for a real
/// local database, so this is SQLite living *inside the chosen data folder*
/// (`<dataRoot>/Aletheia.sqlite`) — it backs up with everything else and
/// never leaves the Mac.
///
/// As of Arch v2 (2) (#65/#74/#76) this class is a thin domain-named adapter,
/// not the storage itself: the actual reading and writing happens in
/// `AnnotationRepository` and `ChatRepository`, both built on the generic
/// `PersistenceCore` (`SQLitePersistenceCore` here). The bespoke `comments` /
/// `notes` / `chat_threads` / `session_chats` tables this class used to own
/// directly are gone — everything now lives in the core's one `records`
/// table — which is a clean cut rather than a migration, since there are no
/// existing installs to carry forward.
///
/// This type is kept, under its original name and with its original method
/// signatures, purely so its existing callers — `Store` (which shares one
/// instance with it for chat data) and views that reach
/// `AppModel.commentStore` directly for comments/notes — need no changes for
/// this slice. See the PR description for that coordination trade-off.
///
/// Session-scoped rows (comments, notes, session chat) are keyed by the
/// session's `UUID` — assigned once at creation and persisted in the session's
/// `session.json` — and patient-scoped rows (chat threads) by the patient's
/// `UUID`. Identity is never derived from a folder name or slug, so annotations
/// follow a session or patient even if the on-disk folder is renamed or moved.
final class CommentStore {
    private let core: SQLitePersistenceCore
    private let annotations: AnnotationRepository
    private let chats: ChatRepository
    /// Kept only for `reencrypt(to:)`, which needs to know the protector the
    /// store's current payloads are sealed under before re-sealing them.
    private let protector: FileProtector

    /// Every record kind this store's data lives under, for operations (only
    /// `reencrypt`, today) that must walk everything regardless of which
    /// repository owns it.
    private static let allKinds = ["comment", "note", "sessionChat", "chatThread"]

    /// The database file for a given data folder — the single SQLite store all
    /// annotations, notes, and chat threads live in.
    static func databaseURL(root: URL) -> URL {
        root.appendingPathComponent("Aletheia.sqlite")
    }

    init?(root: URL, protector: FileProtector = .passthrough) {
        guard let core = SQLitePersistenceCore(url: Self.databaseURL(root: root)) else { return nil }
        self.core = core
        self.protector = protector
        self.annotations = AnnotationRepository(core: core, protector: protector)
        self.chats = ChatRepository(core: core, protector: protector)
    }

    // MARK: - Comments

    func comments(sessionID: UUID) -> [SessionComment] {
        annotations.comments(sessionID: sessionID)
    }

    @discardableResult
    func addComment(sessionID: UUID, quotedText: String, body: String, anchorSeconds: Double? = nil, now: Date = Date()) -> SessionComment? {
        annotations.addComment(sessionID: sessionID, quotedText: quotedText, body: body, anchorSeconds: anchorSeconds, now: now)
    }

    @discardableResult
    func updateComment(id: String, body: String, now: Date = Date()) -> Bool {
        annotations.updateComment(id: id, body: body, now: now)
    }

    @discardableResult
    func setCommentResolved(id: String, resolved: Bool, now: Date = Date()) -> Bool {
        annotations.setCommentResolved(id: id, resolved: resolved, now: now)
    }

    @discardableResult
    func deleteComment(id: String) -> Bool {
        annotations.deleteComment(id: id)
    }

    // MARK: - Notes

    func note(sessionID: UUID) -> String {
        annotations.note(sessionID: sessionID)
    }

    @discardableResult
    func saveNote(sessionID: UUID, text: String, now: Date = Date()) -> Bool {
        annotations.saveNote(sessionID: sessionID, text: text, now: now)
    }

    // MARK: - Chat threads

    /// A patient's chat threads, most-recently-active first. Titles and the
    /// message payload are sealed at rest like every other PHI value.
    func chatThreads(patientID: UUID) -> [ChatThread] {
        chats.chatThreads(patientID: patientID)
    }

    @discardableResult
    func saveChatThread(_ thread: ChatThread, patientID: UUID) -> Bool {
        chats.saveChatThread(thread, patientID: patientID)
    }

    @discardableResult
    func deleteChatThread(id: UUID, patientID: UUID) -> Bool {
        chats.deleteChatThread(id: id, patientID: patientID)
    }

    // MARK: - Session chat

    /// The assistant conversation held on one session's transcript.
    func sessionChat(sessionID: UUID) -> [ChatMessage] {
        chats.sessionChat(sessionID: sessionID)
    }

    @discardableResult
    func saveSessionChat(_ messages: [ChatMessage], sessionID: UUID, now: Date = Date()) -> Bool {
        chats.saveSessionChat(messages, sessionID: sessionID, now: now)
    }

    // MARK: - Snapshot

    /// Writes a consistent, compact copy of the database to `destination` using
    /// SQLite's `VACUUM INTO`, delegated to the underlying core. Safe to call
    /// while the store is open. `destination` must not already exist and its
    /// parent directory must. Returns false on any SQLite error.
    @discardableResult
    func snapshot(to destination: URL) -> Bool {
        core.snapshot(to: destination)
    }

    // MARK: - Migration

    /// Re-seals every record's payload from this store's protector to
    /// `newProtector` (open with the current one, seal with the new one), so
    /// turning encryption on or off converts the whole database in place — the
    /// same contract this method had over the old bespoke tables, now
    /// implemented as one generic pass over every kind via `PersistenceCore`.
    /// Returns false on any storage error.
    @discardableResult
    func reencrypt(to newProtector: FileProtector) -> Bool {
        for kind in Self.allKinds {
            for record in core.allRecords(kind: kind) {
                var resealed = record
                resealed.payload = RecordPayloadCodec.reseal(record.payload, from: protector, to: newProtector)
                guard core.put(resealed) else { return false }
            }
        }
        return true
    }
}
