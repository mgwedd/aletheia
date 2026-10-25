import CryptoKit
import Foundation

/// The record kept beside a signed note (`note.<format>.signed.json`): who signed
/// it, when, and a hash of exactly the text that was signed.
struct SignedNote: Codable, Equatable {
    var signedAt: Date
    /// The signer's account on this Mac (the same identity the activity log uses).
    var signer: String
    /// SHA-256 of the signed text's UTF-8 bytes, lowercase hex.
    var sha256: String
    /// Whether the signed text started as AI output.
    var aiGenerated: Bool
}

/// Where a progress note stands: a draft the clinician can still change, or
/// signed and fixed. Pure, so it's unit-tested; the `Store` persists the record.
///
///     draft ──sign──▶ signed ──reopen (explicit, audited)──▶ draft
///                       │
///                       └─ file no longer matches its hash ──▶ altered
enum NoteLifecycle {
    enum Status: Equatable {
        /// Not signed. The clinician can edit and regenerate.
        case draft
        /// Signed, and the saved text is exactly what was signed.
        case signed(SignedNote)
        /// A signature exists but the saved text no longer matches it, so
        /// something changed the note outside the app's save paths.
        case altered(SignedNote)

        var isDraft: Bool { self == .draft }

        /// The signature record, for a signed or altered note.
        var record: SignedNote? {
            switch self {
            case .draft: return nil
            case .signed(let record), .altered(let record): return record
            }
        }
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sign(text: String, signer: String, at date: Date, aiGenerated: Bool) -> SignedNote {
        SignedNote(
            signedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)), signer: signer, sha256: sha256Hex(text), aiGenerated: aiGenerated)
    }

    /// `record` is the stored signature (nil when never signed), `currentText`
    /// the note as saved now.
    static func status(record: SignedNote?, currentText: String?) -> Status {
        guard let record else { return .draft }
        guard let currentText, sha256Hex(currentText) == record.sha256 else { return .altered(record) }
        return .signed(record)
    }

    /// Only a draft can be edited, regenerated, restored or have its text replaced.
    /// A signed or altered note is read-only until the clinician reopens it.
    static func allowsChanges(_ status: Status) -> Bool { status.isDraft }

    /// A progress note comes from the on-device model, with the clinician's edits
    /// on top. Every non-empty one counts as AI-generated; a note saved before the
    /// generated baseline was kept has no baseline but is still AI output.
    static func isAIGenerated(_ state: NoteEditState) -> Bool {
        state == .generated || state == .edited
    }

    /// Whether the note may leave the app (export, copy). An unsigned AI note
    /// may not; a signed one may. An altered one may not, since it's no longer
    /// what was signed.
    static func allowsLeaving(_ status: Status, aiGenerated: Bool) -> Bool {
        if case .signed = status { return true }
        return !aiGenerated && status.isDraft
    }

    /// Put above an unsigned AI note when it goes out inside a larger export
    /// (a session or a whole record), where the note can't simply be blocked.
    static let exportDraftStamp = "DRAFT - not clinician-verified"

    /// `text` with the draft stamp above it unless the note is signed.
    static func stamped(_ text: String, status: Status?) -> String {
        if case .signed = status { return text }
        return exportDraftStamp + "\n\n" + text
    }

    static let reviewToExport = "Review and sign to export"
    static let reviewToCopy = "Review and sign to copy"
    static let draftBadge = "Draft — needs clinician review"
    static let signButton = "Sign note…"

    static func signedLine(_ record: SignedNote) -> String {
        "Signed by \(record.signer) on \(record.signedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    static let alteredNotice =
        "This note's text no longer matches what was signed. Treat it as unverified."

    static let signTitle = "Sign this note?"
    static let signMessage =
        "Signing says you have read this note and it is accurate. A signed note is read-only. To change it later you reopen it as a new draft, which is recorded in the activity log."
    static let reopenTitle = "Reopen as a new draft?"
    static let reopenMessage =
        "The note becomes editable again and stops counting as signed until you sign it again. The signed text is kept as the previous version, and the activity log records this."

    /// Next raw transcript file name given the names already in the session
    /// folder: `transcript.raw.txt` first, then `transcript.raw.2.txt`, ...
    static func nextRawTranscriptName(existing: [String]) -> String {
        let taken = Set(existing)
        if !taken.contains(rawTranscriptName) { return rawTranscriptName }
        var n = 2
        while taken.contains("transcript.raw.\(n).txt") { n += 1 }
        return "transcript.raw.\(n).txt"
    }

    static let rawTranscriptName = "transcript.raw.txt"

    /// Matched by shape: `transcript.raw.txt` or `transcript.raw.<n>.txt`.
    static func isRawTranscriptName(_ name: String) -> Bool {
        if name == rawTranscriptName { return true }
        guard name.hasPrefix("transcript.raw."), name.hasSuffix(".txt") else { return false }
        let middle = name.dropFirst("transcript.raw.".count).dropLast(".txt".count)
        return !middle.isEmpty && middle.allSatisfy(\.isNumber)
    }
}
