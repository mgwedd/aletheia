import Foundation

/// Per-model read/write speeds measured on this Mac, in the generic persistence
/// core: kind "modelSpeed", one record per model tag. The payload is plain JSON
/// of `ModelSpeed` (numbers and a model name, no session text), so it isn't
/// field-sealed; the record's `updatedAt` is the time of the last sample.
final class ModelSpeedRepository {
    static let kind = "modelSpeed"
    private let core: PersistenceCore

    init(core: PersistenceCore) { self.core = core }

    func speed(for model: String) -> ModelSpeed {
        core.record(kind: Self.kind, id: model)
            .flatMap { try? JSONDecoder().decode(ModelSpeed.self, from: $0.payload) } ?? ModelSpeed()
    }

    /// Folds a finished run into the model's speeds; a run with nothing usable changes nothing.
    func record(model: String, from stats: AIRunStats, now: Date = Date()) {
        let old = speed(for: model)
        let updated = old.folding(stats)
        guard updated != old, let payload = try? JSONEncoder().encode(updated) else { return }
        let created = core.record(kind: Self.kind, id: model)?.createdAt ?? now
        core.put(PersistedRecord(id: model, kind: Self.kind, payload: payload, createdAt: created, updatedAt: now))
    }
}
