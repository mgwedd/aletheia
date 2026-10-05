import Foundation

/// Typed repository for the therapist's own annotations — inline margin
/// comments and freeform per-session notes — sitting on the generic
/// `PersistenceCore` (Arch v2 (2), #65/#74/#76) rather than owning any SQL of
/// its own. That's what lets it be unit-tested against
/// `InMemoryPersistenceCore` and run unchanged on `SQLitePersistenceCore` in
/// the app.
///
///   comment — kind "comment", a collection scoped by `itemID = sessionID`,
///             a fresh UUID id per comment.
///   note    — kind "note", a singleton per session keyed by
///             `sessionID.uuidString`, `itemID = sessionID`.
///
/// Encoding/encryption is handled by `RecordPayloadCodec`, not this type: a
/// comment or note is JSON-encoded then field-sealed into the record's opaque
/// `payload`, and opened the same way on read.
final class AnnotationRepository {
    private static let commentKind = "comment"
    private static let noteKind = "note"

    private let core: PersistenceCore
    private let protector: FileProtector

    init(core: PersistenceCore, protector: FileProtector) {
        self.core = core
        self.protector = protector
    }

    // MARK: - Comments

    /// What's actually sealed into a comment's payload. Identity (`id`) and
    /// timestamps already live on the record envelope, so they aren't
    /// duplicated here.
    private struct CommentPayload: Codable {
        var quotedText: String
        var body: String
        var anchorSeconds: Double?
        /// Google-Docs-style resolution. Optional in the payload so comments
        /// written before this field existed decode cleanly (treated as
        /// unresolved); `makeComment` maps a missing/`nil` value to `false`.
        var resolved: Bool?
    }

    func comments(sessionID: UUID) -> [SessionComment] {
        core.records(kind: Self.commentKind, itemID: sessionID).map(makeComment)
    }

    @discardableResult
    func addComment(
        sessionID: UUID,
        quotedText: String,
        body: String,
        anchorSeconds: Double? = nil,
        now: Date = Date()
    ) -> SessionComment? {
        let payload = CommentPayload(quotedText: quotedText, body: body, anchorSeconds: anchorSeconds, resolved: false)
        guard let data = RecordPayloadCodec.encode(payload, using: protector) else { return nil }
        let record = PersistedRecord(
            id: UUID().uuidString, kind: Self.commentKind, itemID: sessionID,
            payload: data, createdAt: now, updatedAt: now
        )
        guard core.put(record) else { return nil }
        return makeComment(record)
    }

    /// Edits a comment's body only — `quotedText` and `anchorSeconds` are
    /// carried over unchanged, matching the original SQL's `UPDATE ... SET
    /// body = ?, updated_at = ?`.
    @discardableResult
    func updateComment(id: String, body: String, now: Date = Date()) -> Bool {
        guard
            var record = core.record(kind: Self.commentKind, id: id),
            var payload = RecordPayloadCodec.decode(CommentPayload.self, from: record.payload, using: protector)
        else { return false }
        payload.body = body
        guard let data = RecordPayloadCodec.encode(payload, using: protector) else { return false }
        record.payload = data
        record.updatedAt = now
        return core.put(record)
    }

    /// Flips a comment's resolved state, leaving `quotedText`, `body`, and
    /// `anchorSeconds` untouched — the Google-Docs "Resolve"/"Reopen" action.
    @discardableResult
    func setCommentResolved(id: String, resolved: Bool, now: Date = Date()) -> Bool {
        guard
            var record = core.record(kind: Self.commentKind, id: id),
            var payload = RecordPayloadCodec.decode(CommentPayload.self, from: record.payload, using: protector)
        else { return false }
        payload.resolved = resolved
        guard let data = RecordPayloadCodec.encode(payload, using: protector) else { return false }
        record.payload = data
        record.updatedAt = now
        return core.put(record)
    }

    @discardableResult
    func deleteComment(id: String) -> Bool {
        core.remove(kind: Self.commentKind, id: id)
    }

    /// A record that can't be decoded under the current protector (reading a
    /// sealed database with a passthrough/wrong key) still surfaces as a
    /// comment rather than silently vanishing — with best-effort text, the
    /// same "still there, just garbled" behavior the old per-column SQL had.
    private func makeComment(_ record: PersistedRecord) -> SessionComment {
        if let payload = RecordPayloadCodec.decode(CommentPayload.self, from: record.payload, using: protector) {
            return SessionComment(
                id: record.id, quotedText: payload.quotedText, body: payload.body,
                createdAt: record.createdAt, updatedAt: record.updatedAt,
                anchorSeconds: payload.anchorSeconds, resolved: payload.resolved ?? false
            )
        }
        let garbled = RecordPayloadCodec.openedText(from: record.payload, using: protector)
        return SessionComment(
            id: record.id, quotedText: "", body: garbled,
            createdAt: record.createdAt, updatedAt: record.updatedAt, anchorSeconds: nil
        )
    }

    // MARK: - Notes

    func note(sessionID: UUID) -> String {
        guard let record = core.record(kind: Self.noteKind, id: sessionID.uuidString) else { return "" }
        return RecordPayloadCodec.decode(String.self, from: record.payload, using: protector) ?? ""
    }

    @discardableResult
    func saveNote(sessionID: UUID, text: String, now: Date = Date()) -> Bool {
        guard let data = RecordPayloadCodec.encode(text, using: protector) else { return false }
        let createdAt = core.record(kind: Self.noteKind, id: sessionID.uuidString)?.createdAt ?? now
        let record = PersistedRecord(
            id: sessionID.uuidString, kind: Self.noteKind, itemID: sessionID,
            payload: data, createdAt: createdAt, updatedAt: now
        )
        return core.put(record)
    }
}
