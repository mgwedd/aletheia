import Foundation

/// AI-written digest of one session: a note per ~10-minute section plus a merged
/// digest of the whole. Stored encrypted beside the session's notes
/// (`Store.digestFileName`) and never shown as the record; it lets long sessions
/// and patient histories be covered without sending every word.
struct SessionDigest: Codable, Equatable {
    struct Section: Codable, Equatable {
        /// Seconds into the recording; nil for an untimed transcript.
        let start: Int?
        let end: Int?
        let digest: String
    }

    /// File-format version, for future changes to this struct.
    static let currentVersion = 1

    var version = SessionDigest.currentVersion
    let model: String
    let promptVersion: Int
    /// `NoteFreshness.fingerprint` of the transcript it was built from.
    let transcriptFingerprint: String
    let sections: [Section]
    let sessionDigest: String
    let createdAt: Date

    /// Whether this digest still matches the transcript, the model and the
    /// prompts. Anything else means it must be rebuilt.
    func isCurrent(transcript: String, model: String) -> Bool {
        version == Self.currentVersion
            && promptVersion == Prompts.digestVersion
            && self.model == model
            && transcriptFingerprint == NoteFreshness.fingerprint(of: transcript)
    }
}
