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
/// One exception overrides all of the above: a **blank transcript** (empty or
/// whitespace-only — e.g. Whisper returned nothing) keeps the audio, since the
/// recording may be the only copy of the session. See `decision(...)`.
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

// MARK: - Blank transcripts

/// What to do with a session's audio once transcription has finished.
enum AudioRetentionDecision: Equatable {
    /// Transcript-only default: delete the recordings.
    case discard
    /// The user opted in (and encryption is on): keep the recordings.
    case keep
    /// The transcript came back blank, so the recording may be the only copy of
    /// what was said: keep it regardless of the opt-in.
    case keepBecauseTranscriptBlank
}

extension AudioRetentionPolicy {
    /// Whether a transcript contains no text at all (empty or whitespace-only).
    /// Whisper returns `""` for empty samples, and deleting the only copy of the
    /// audio in that case would lose the session for good.
    static func isBlankTranscript(_ transcript: String) -> Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The full post-transcription decision. A blank transcript always keeps the
    /// audio (even when the user hasn't opted in and even when encryption is
    /// off — plaintext audio may then remain on disk, the deliberate trade-off
    /// against silently destroying the only copy). Otherwise the existing
    /// opt-in + encryption rule applies unchanged.
    static func decision(optedIn: Bool, encryptionEnabled: Bool, transcript: String) -> AudioRetentionDecision {
        if isBlankTranscript(transcript) { return .keepBecauseTranscriptBlank }
        return keepsAudio(optedIn: optedIn, encryptionEnabled: encryptionEnabled) ? .keep : .discard
    }

    /// The non-blocking message shown when a blank transcript kept the audio:
    /// what happened and what to do next, plus a plaintext caveat when at-rest
    /// encryption is off.
    static func blankTranscriptNotice(encryptionEnabled: Bool) -> String {
        var message = "No speech was detected, so the recording was kept. "
            + "Tap Transcribe to try again, or delete the recording files (mic.caf / call.caf in this session's folder) if you don't need them."
        if !encryptionEnabled {
            message += " At-rest encryption is off, so the kept recording is not encrypted."
        }
        return message
    }
}
