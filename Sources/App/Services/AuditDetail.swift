import Foundation

/// The note on an activity-log entry. It can only be fixed text written in the
/// code: a string literal (never a variable or an interpolation, because the
/// literal type is `StaticString`), or one of the builders below, which take
/// only numbers and closed enums. A name, a note or a prompt cannot be passed
/// in, so an entry can never carry patient data.
struct AuditDetail: Equatable, ExpressibleByStringLiteral {
    let text: String

    typealias StringLiteralType = StaticString

    init(stringLiteral value: StaticString) {
        text = value.description
    }

    /// For the builders in this file only.
    fileprivate init(built text: String) {
        self.text = text
    }

    // MARK: - Kinds of record

    static let patient: AuditDetail = "patient"
    static let session: AuditDetail = "session"
    static let transcript: AuditDetail = "transcript"
    static let note: AuditDetail = "note"
    static let therapistNote: AuditDetail = "therapist note"
    static let comment: AuditDetail = "comment"
    static let audioRecording: AuditDetail = "audio recording"
    static let chatThread: AuditDetail = "chat thread"

    /// What a record-changing entry may say.
    static let recordKinds: [AuditDetail] = [
        patient, session, transcript, note, therapistNote, comment, audioRecording, chatThread,
    ]

    // MARK: - Copying

    static let copiedChat: AuditDetail = "chat"
    static let copiedPatientText: AuditDetail = "patient text"

    // MARK: - AI use

    /// The kind of AI work only; never the prompt or the output.
    static func aiUse(_ kind: InferenceQueue.Kind) -> AuditDetail {
        switch kind {
        case .note: return "progress note"
        case .sessionChat: return "session chat"
        case .patientChat: return "patient chat"
        case .digest: return "digest"
        }
    }

    // MARK: - Settings

    static func setting<Value: Equatable>(_ setting: AuditedSetting<Value>, _ value: Value) -> AuditDetail {
        AuditDetail(built: setting.detail(for: value))
    }

    /// Custom note instructions changed. Says which format, never the text.
    static func noteInstructions(_ format: ProgressNoteFormat, customized: Bool) -> AuditDetail {
        AuditDetail(built: "Note instructions (\(format.shortName)): \(customized ? "customized" : "reset to default")")
    }

    // MARK: - Exports

    static func exportedSession(_ format: ExportFormat) -> AuditDetail {
        AuditDetail(built: "Session, \(format.title)")
    }

    static func exportedNote(_ note: ProgressNoteFormat, _ format: ExportFormat) -> AuditDetail {
        AuditDetail(built: "Note \(note.shortName), \(format.title)")
    }

    static func exportedAllRecords(patients: Int, sessions: Int) -> AuditDetail {
        AuditDetail(built: "All records, folder of \(patients) patients, \(sessions) sessions")
    }

    static func exportedPatientRecords(sessions: Int) -> AuditDetail {
        AuditDetail(built: "Patient records, zip of \(sessions) sessions")
    }

    // MARK: - Alerts

    static func failedUnlocks(attempts: Int, minutes: Int) -> AuditDetail {
        AuditDetail(built: "\(attempts) failed unlocks within \(minutes) minutes")
    }

    static func chainBroken(entry: Int64) -> AuditDetail {
        AuditDetail(built: "Chain broken at entry #\(entry)")
    }
}
