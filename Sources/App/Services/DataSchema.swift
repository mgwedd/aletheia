import Foundation

/// Versioning for the on-disk data format, so the client can evolve without
/// hard-breaking a therapist's existing data.
///
/// The data folder carries a small `.aletheia.json` stamp with the schema
/// version that wrote it. On open, `Store` reconciles that stamp with the
/// version this build understands:
///
///   - older stamp → run migrations (none yet), then re-stamp: `.upgraded`
///   - same stamp  → `.ok`
///   - newer stamp → `.needsNewerApp`: the data was written by a newer app,
///     so this (older) app must NOT silently rewrite it. The UI tells the
///     user to update rather than risk losing anything.
///
/// Adding a field to a stored model does not need a version bump — JSON
/// decoding ignores unknown keys and `decodeIfPresent`/defaults cover missing
/// ones. Bump `currentVersion` only for changes an older app couldn't safely
/// read or would corrupt.
enum DataSchema {
    static let currentVersion = 1
    static let metadataFileName = ".aletheia.json"
}

struct StoreMetadata: Codable, Equatable {
    var schemaVersion: Int
    var lastWrittenBy: String?
}

enum SchemaCompatibility: Equatable {
    case ok
    case upgraded(fromVersion: Int)
    case needsNewerApp(dataVersion: Int, appVersion: Int)
}
