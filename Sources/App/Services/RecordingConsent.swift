import Foundation

/// The recording-consent rules: what the clinician affirms, which policy
/// applies, and whether a session must ask before it records. Pure, so it is
/// unit-tested.
enum RecordingConsent {
    static let attestationText = "I obtained this patient's consent to record the session and to process the recording with AI."

    static let sheetTitle = "Record consent"
    static let startRecordingTitle = "Start recording"
    static let chooseAudioTitle = "Choose Audio File…"
    static let saveConsentTitle = "Save"
    static let changeTitle = "Change…"
    static let notConfirmedMessage = "Confirm you have this patient's consent before recording."
    static let noConsentRecorded = "No consent recorded."
    static let unreadableRecord = "The consent record can't be read."
    /// The heading of the consent section in exports, and the archive's file name.
    static let exportHeading = "Recording consent"
    static let lockedBySignedNote = "Consent can't be changed once the session's note is signed."

    /// The patient's own policy, or the Settings default.
    static func effectivePolicy(for patient: Patient?, default fallback: ConsentPolicy) -> ConsentPolicy {
        patient?.recordingConsentPolicy ?? fallback
    }

    /// Whether a session must ask for consent before it records. A session
    /// that already has its own record never asks again.
    static func needsCapture(patient: Patient?, policy: ConsentPolicy, sessionHasRecord: Bool) -> Bool {
        if sessionHasRecord { return false }
        switch policy {
        case .firstSession: return patient?.recordingConsentAttestedAt == nil
        case .everySession: return true
        }
    }

    /// The sheet's explanation, by policy.
    static func sheetExplanation(_ policy: ConsentPolicy) -> String {
        switch policy {
        case .firstSession:
            return "Record who agreed to this recording, and how. You are asked once for each patient."
        case .everySession:
            return "Record who agreed to this recording, and how. You are asked before every session."
        }
    }

    /// The menu bar's refusal when Start recording is pressed before consent is complete.
    static func menuBarProblem(needsConsent: Bool, capture: ConsentCapture) -> String? {
        needsConsent && !capture.isComplete ? notConfirmedMessage : nil
    }

    static func status(record: ConsentRecord?, patient: Patient?) -> ConsentStatus {
        if let record { return .recorded(record) }
        if let since = patient?.recordingConsentAttestedAt { return .onFile(since: since) }
        return .none
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The one line the session screen shows.
    static func sessionLine(_ status: ConsentStatus) -> String {
        switch status {
        case .recorded(let record): return "\(record.summary) · \(dateTime(record.consentedAt))"
        case .onFile(let since): return "Consent on file since \(since.formatted(date: .abbreviated, time: .omitted))"
        case .none: return noConsentRecorded
        }
    }

    /// The body of the "Recording consent" section in exports, one fact per line.
    static func exportLines(_ status: ConsentStatus) -> [String] {
        switch status {
        case .recorded(let record):
            var lines = [
                "Who: \(record.party.title)",
                "Method: \(record.method.title)",
                "Given: \(dateTime(record.consentedAt))",
                "Recorded: \(dateTime(record.recordedAt))",
                "Confirmed: \(record.statement)",
            ]
            if let name = record.consenterName, !name.isEmpty { lines.insert("Name: \(name)", at: 1) }
            return lines
        case .onFile(let since):
            return ["Consent on file for this patient since \(since.formatted(date: .abbreviated, time: .omitted))."]
        case .none:
            return [noConsentRecorded]
        }
    }
}
