import Foundation

/// The recording-consent attestation: what the clinician affirms, and whether
/// a recording may start for a patient. Pure, so it is unit-tested.
enum RecordingConsent {
    static let attestationText = "I obtained this patient's consent to record the session and to process the recording with AI."

    /// A recording may start only once the patient has an attestation.
    static func allowsRecording(_ patient: Patient?) -> Bool {
        patient?.recordingConsentAttestedAt != nil
    }
}
