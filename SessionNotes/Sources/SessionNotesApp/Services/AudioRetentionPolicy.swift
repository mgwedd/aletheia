import Foundation

/// Decides whether a session's raw audio (`mic.caf` / `call.caf`) is kept once
/// it has been transcribed. Audio is the most sensitive artifact a session
/// produces, so the default is **transcript-only**: the recording is discarded
/// the moment the transcript exists, leaving only the text as the document of
/// record.
///
/// Audio is retained only when the therapist opts in *and* at-rest encryption
/// is on — the two conditions together guarantee that any recording left on
/// disk is ciphertext (the recorder seals it at stop via
/// `SessionRecorder.sealRecordingsIfNeeded`), never plaintext PHI. If
/// encryption is later turned off, the opt-in stops taking effect and audio is
/// discarded on the next transcription rather than being left in the clear.
///
/// Pure and free of any I/O so the decision is unit-testable without a store,
/// a filesystem, or an `EncryptionManager`.
enum AudioRetentionPolicy {
    /// Whether audio should be kept after transcription. Requires both the
    /// opt-in and encryption, so kept audio is always encrypted at rest.
    static func keepsAudio(optedIn: Bool, encryptionEnabled: Bool) -> Bool {
        optedIn && encryptionEnabled
    }

    /// The complement: whether the audio should be discarded once the
    /// transcript has been written. True by default (transcript-only).
    static func discardsAudioAfterTranscription(optedIn: Bool, encryptionEnabled: Bool) -> Bool {
        !keepsAudio(optedIn: optedIn, encryptionEnabled: encryptionEnabled)
    }
}
