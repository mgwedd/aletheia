import Foundation

/// Typed repository for the therapist's assistant conversations — a session's
/// own chat and a patient's multi-thread chat history — sitting on the
/// generic `PersistenceCore` (Arch v2 (2), #65/#74/#76) rather than owning any
/// SQL of its own.
///
///   sessionChat — kind "sessionChat", a singleton per session keyed by
///                 `sessionID.uuidString`, `itemID = sessionID`.
///   chatThread  — kind "chatThread", a collection scoped by
///                 `ownerID = patientID`; the core hands back oldest-created
///                 first, so this repository re-sorts most-recently-updated
///                 first for display.
///
/// Encoding/encryption is handled by `RecordPayloadCodec`, not this type.
final class ChatRepository {
    private static let sessionChatKind = "sessionChat"
    private static let chatThreadKind = "chatThread"

    private let core: PersistenceCore
    private let protector: FileProtector

    init(core: PersistenceCore, protector: FileProtector) {
        self.core = core
        self.protector = protector
    }

    // MARK: - Session chat

    func sessionChat(sessionID: UUID) -> [ChatMessage] {
        guard let record = core.record(kind: Self.sessionChatKind, id: sessionID.uuidString) else { return [] }
        return RecordPayloadCodec.decode([ChatMessage].self, from: record.payload, using: protector) ?? []
    }

    /// Upserts a session's chat by its session id. An empty conversation
    /// removes the record rather than storing an empty payload, so the store
    /// stays tidy for the many sessions that are never chatted about.
    @discardableResult
    func saveSessionChat(_ messages: [ChatMessage], sessionID: UUID, now: Date = Date()) -> Bool {
        guard !messages.isEmpty else {
            return core.remove(kind: Self.sessionChatKind, id: sessionID.uuidString)
        }
        guard let data = RecordPayloadCodec.encode(messages, using: protector) else { return false }
        let createdAt = core.record(kind: Self.sessionChatKind, id: sessionID.uuidString)?.createdAt ?? now
        let record = PersistedRecord(
            id: sessionID.uuidString, kind: Self.sessionChatKind, itemID: sessionID,
            payload: data, createdAt: createdAt, updatedAt: now
        )
        return core.put(record)
    }

    // MARK: - Chat threads

    private struct ChatThreadPayload: Codable {
        var title: String
        var messages: [ChatMessage]
    }

    /// A patient's chat threads, most-recently-active first.
    func chatThreads(patientID: UUID) -> [ChatThread] {
        core.records(kind: Self.chatThreadKind, ownerID: patientID)
            .compactMap(makeThread)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Inserts a thread or updates it in place (by id). `createdAt` and the
    /// owning patient are fixed at insert; edits carry title/messages/updatedAt
    /// — matching the original SQL's `ON CONFLICT DO UPDATE SET title = …,
    /// updated_at = …, messages = …` (which leaves `patient_id`/`created_at`
    /// alone on an update).
    @discardableResult
    func saveChatThread(_ thread: ChatThread, patientID: UUID) -> Bool {
        let payload = ChatThreadPayload(title: thread.title, messages: thread.messages)
        guard let data = RecordPayloadCodec.encode(payload, using: protector) else { return false }
        let existing = core.record(kind: Self.chatThreadKind, id: thread.id.uuidString)
        let record = PersistedRecord(
            id: thread.id.uuidString, kind: Self.chatThreadKind,
            ownerID: existing?.ownerID ?? patientID,
            payload: data,
            createdAt: existing?.createdAt ?? thread.createdAt,
            updatedAt: thread.updatedAt
        )
        return core.put(record)
    }

    /// Removes a thread, but only when it actually belongs to `patientID` —
    /// matching the original `DELETE ... WHERE id = ? AND patient_id = ?`,
    /// which is a no-op (not an error) for a mismatched or absent thread.
    @discardableResult
    func deleteChatThread(id: UUID, patientID: UUID) -> Bool {
        guard let existing = core.record(kind: Self.chatThreadKind, id: id.uuidString) else { return true }
        guard existing.ownerID == patientID else { return true }
        return core.remove(kind: Self.chatThreadKind, id: id.uuidString)
    }

    /// A record whose id isn't a UUID can't happen from this repository's own
    /// writes, so that's the one case that drops the row; a record that fails
    /// to *decode* (undecryptable under the current protector) still surfaces
    /// as a thread with best-effort text, same as `AnnotationRepository`'s
    /// comments — matching the old per-column SQL, where a garbled read never
    /// made a row disappear.
    private func makeThread(_ record: PersistedRecord) -> ChatThread? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        if let payload = RecordPayloadCodec.decode(ChatThreadPayload.self, from: record.payload, using: protector) {
            return ChatThread(
                id: id, title: payload.title, createdAt: record.createdAt,
                updatedAt: record.updatedAt, messages: payload.messages
            )
        }
        let garbled = RecordPayloadCodec.openedText(from: record.payload, using: protector)
        return ChatThread(id: id, title: garbled, createdAt: record.createdAt, updatedAt: record.updatedAt, messages: [])
    }
}
