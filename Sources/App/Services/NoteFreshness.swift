import CryptoKit
import Foundation

/// Tells whether a generated progress note still matches the transcript it was
/// written from. When a note is generated, the fingerprint of the transcript it
/// was generated from is stored beside it (`Store.saveNote`); later, a different
/// fingerprint for the current transcript means the transcript was edited and
/// the note is outdated.
///
/// Only *generated* per-format notes carry a fingerprint. The therapist's own
/// session notes are never fingerprinted and so can never be reported outdated.
///
/// Pure logic, no I/O, so it is unit-tested in isolation.
enum NoteFreshness {
    /// SHA-256 (lowercase hex) of the transcript text. Leading and trailing
    /// whitespace is ignored so a stray trailing newline from editing doesn't
    /// flag every note; any change to the words does.
    static func fingerprint(of transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// True only when a fingerprint was recorded for the note and it differs from
    /// the current transcript's. A note with no recorded fingerprint is not
    /// outdated.
    static func isOutdated(recorded: String?, transcript: String) -> Bool {
        guard let recorded else { return false }
        return recorded != fingerprint(of: transcript)
    }

    /// The small record stored beside a generated note (`note.<format>.meta.json`).
    struct Record: Codable, Equatable {
        let transcriptFingerprint: String
    }

    static func encode(fingerprint: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Record(transcriptFingerprint: fingerprint))
    }

    /// The fingerprint in `data`, or nil if it isn't a readable record.
    static func decodeFingerprint(from data: Data) -> String? {
        (try? JSONDecoder().decode(Record.self, from: data))?.transcriptFingerprint
    }
}
