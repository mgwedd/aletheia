import XCTest
@testable import Aletheia

/// The retention decision is the privacy hinge for the most sensitive artifact a
/// session produces, so pin the full truth table: audio is kept only when the
/// user opted in *and* at-rest encryption is on, and is discarded (transcript-
/// only) in every other combination — including the important one where the user
/// opted in but encryption is off, which must never leave audio in the clear.
final class AudioRetentionPolicyTests: XCTestCase {
    func testKeepsAudioOnlyWhenOptedInAndEncrypted() {
        XCTAssertTrue(AudioRetentionPolicy.keepsAudio(optedIn: true, encryptionEnabled: true))
    }

    func testDoesNotKeepAudioWhenOptedInButEncryptionOff() {
        // The safety-critical case: the opt-in alone must not retain plaintext PHI.
        XCTAssertFalse(AudioRetentionPolicy.keepsAudio(optedIn: true, encryptionEnabled: false))
    }

    func testDoesNotKeepAudioWhenNotOptedIn() {
        XCTAssertFalse(AudioRetentionPolicy.keepsAudio(optedIn: false, encryptionEnabled: true))
        XCTAssertFalse(AudioRetentionPolicy.keepsAudio(optedIn: false, encryptionEnabled: false))
    }

    func testDefaultIsTranscriptOnly() {
        // Out of the box: not opted in, no encryption → discard after transcription.
        XCTAssertTrue(AudioRetentionPolicy.discardsAudioAfterTranscription(optedIn: false, encryptionEnabled: false))
    }

    func testDiscardsIsTheComplementOfKeeps() {
        for optedIn in [true, false] {
            for encrypted in [true, false] {
                XCTAssertNotEqual(
                    AudioRetentionPolicy.keepsAudio(optedIn: optedIn, encryptionEnabled: encrypted),
                    AudioRetentionPolicy.discardsAudioAfterTranscription(optedIn: optedIn, encryptionEnabled: encrypted),
                    "keep and discard must be exact opposites for optedIn=\(optedIn), encrypted=\(encrypted)"
                )
            }
        }
    }

    // MARK: - Blank transcripts

    func testBlankTranscriptDetection() {
        XCTAssertTrue(AudioRetentionPolicy.isBlankTranscript(""))
        XCTAssertTrue(AudioRetentionPolicy.isBlankTranscript("   "))
        XCTAssertTrue(AudioRetentionPolicy.isBlankTranscript("\n\t \r\n"))
        XCTAssertFalse(AudioRetentionPolicy.isBlankTranscript("hello"))
        XCTAssertFalse(AudioRetentionPolicy.isBlankTranscript("  hello \n"))
        XCTAssertFalse(AudioRetentionPolicy.isBlankTranscript("[00:00] Therapist: hi"))
    }

    func testBlankTranscriptAlwaysKeepsAudio() {
        // Every opt-in / encryption combination, for empty and whitespace-only
        // transcripts: the only copy of the audio must never be deleted.
        for optedIn in [true, false] {
            for encrypted in [true, false] {
                for blank in ["", " ", "\n\n", " \t\n "] {
                    XCTAssertEqual(
                        AudioRetentionPolicy.decision(optedIn: optedIn, encryptionEnabled: encrypted, transcript: blank),
                        .keepBecauseTranscriptBlank,
                        "blank transcript \(blank.debugDescription) must keep audio (optedIn=\(optedIn), encrypted=\(encrypted))"
                    )
                }
            }
        }
    }

    func testNonBlankTranscriptFollowsExistingRule() {
        let text = "[00:01] Therapist: hello"
        XCTAssertEqual(AudioRetentionPolicy.decision(optedIn: true, encryptionEnabled: true, transcript: text), .keep)
        XCTAssertEqual(AudioRetentionPolicy.decision(optedIn: true, encryptionEnabled: false, transcript: text), .discard)
        XCTAssertEqual(AudioRetentionPolicy.decision(optedIn: false, encryptionEnabled: true, transcript: text), .discard)
        XCTAssertEqual(AudioRetentionPolicy.decision(optedIn: false, encryptionEnabled: false, transcript: text), .discard)
    }

    func testNonBlankDecisionAgreesWithTwoArgumentPolicy() {
        for optedIn in [true, false] {
            for encrypted in [true, false] {
                let discards = AudioRetentionPolicy.discardsAudioAfterTranscription(optedIn: optedIn, encryptionEnabled: encrypted)
                let decision = AudioRetentionPolicy.decision(optedIn: optedIn, encryptionEnabled: encrypted, transcript: "some words")
                XCTAssertEqual(decision == .discard, discards)
            }
        }
    }

    func testBlankTranscriptNoticeExplainsAndSuggestsNextSteps() {
        let encrypted = AudioRetentionPolicy.blankTranscriptNotice(encryptionEnabled: true)
        XCTAssertTrue(encrypted.contains("No speech was detected, so the recording was kept"))
        XCTAssertTrue(encrypted.contains("Transcribe"))
        XCTAssertTrue(encrypted.contains("delete"))
        XCTAssertFalse(encrypted.contains("not encrypted"))

        let plaintext = AudioRetentionPolicy.blankTranscriptNotice(encryptionEnabled: false)
        XCTAssertTrue(plaintext.contains("No speech was detected, so the recording was kept"))
        XCTAssertTrue(plaintext.contains("not encrypted"))
    }
}
