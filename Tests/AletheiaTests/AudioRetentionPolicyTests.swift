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
}
