import Foundation

/// A patient or session record that is on disk but couldn't be read, so it's
/// left out of the normal lists. The store only *reports* these: it never
/// deletes, rewrites or re-identifies them.
///
/// Deliberately free of PHI: no patient names, note text or transcript content,
/// and the message never quotes a path. `folder` is a structured value for the
/// UI to show or reveal in Finder (a patient's folder name is derived from their
/// name, so treat it like any other on-screen PHI and don't log it).
struct UnreadableEntry: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case patientRecord   // `patient.json`
        case sessionRecord   // `session.json`
    }

    enum Reason: String, Equatable {
        /// The file exists but couldn't be opened or decrypted.
        case notReadable
        /// The file was read but isn't valid (corrupt or truncated JSON).
        case undecodable
        /// A session folder had no `session.json` and one couldn't be saved.
        case couldNotSaveIdentity
    }

    let kind: Kind
    let reason: Reason
    /// The patient folder (`.patientRecord`) or session folder (`.sessionRecord`).
    let folder: URL
    /// The owning patient's id, for `.sessionRecord` entries.
    let patientId: UUID?

    init(kind: Kind, reason: Reason, folder: URL, patientId: UUID? = nil) {
        self.kind = kind
        self.reason = reason
        self.folder = folder
        self.patientId = patientId
    }

    var id: String { "\(kind.rawValue)|\(folder.path)" }

    /// The file that couldn't be read.
    var fileName: String {
        switch kind {
        case .patientRecord: return "patient.json"
        case .sessionRecord: return "session.json"
        }
    }

    /// Where the file lives, for display and "Show in Finder".
    var fileURL: URL { folder.appendingPathComponent(fileName) }

    /// Plain-language, non-blocking explanation: what happened and what was (not)
    /// done to the file. The location is shown separately by the UI.
    var message: String {
        let subject = kind == .patientRecord ? "a patient's record" : "a session's record"
        switch reason {
        case .notReadable, .undecodable:
            let restore = kind == .patientRecord
                ? "Restoring that file from a backup (for example Time Machine) should bring the patient back."
                : "Restoring that file from a backup (for example Time Machine) should reattach the session to its notes."
            return "Aletheia couldn't read \(subject) (\(fileName)), so it isn't in the normal list. "
                + "The original file was left untouched, and nothing else was affected. \(restore)"
        case .couldNotSaveIdentity:
            return "Aletheia couldn't save an identity file (\(fileName)) for a session folder "
                + "(is it read-only?), so the session isn't in the normal list. Nothing was changed."
        }
    }
}

/// `Store.patientListing()`: healthy patients plus the records that didn't read.
struct PatientListing {
    let patients: [Patient]
    let unreadable: [UnreadableEntry]
}

/// `Store.sessionListing(for:)`: healthy sessions plus the folders whose
/// `session.json` didn't read.
struct SessionListing {
    let sessions: [SessionRecord]
    let unreadable: [UnreadableEntry]
}
