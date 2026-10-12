import Foundation

/// Decides whether Record should try to start call-audio capture.
///
/// Starting capture goes through ScreenCaptureKit, which re-shows the system
/// "record this computer's screen and audio" dialog whenever it isn't
/// recognised as granted. On a build macOS doesn't carry the grant for
/// (ad-hoc signed, see #256) that was every Record click. This allows one
/// attempt per launch while access isn't confirmed; after that Record goes
/// mic-only with a visible note instead of prompting again.
///
/// `CGPreflightScreenCaptureAccess` is cached per process, so a grant made
/// while the app runs still preflights as false. A successful attempt is
/// remembered here so it isn't mistaken for a denial afterwards.
struct CallAudioStartPolicy: Equatable {
    private(set) var attempted = false
    private(set) var worked = false

    static let skippedMessage =
        "Call audio is off for this session: Screen & System Audio Recording isn't granted to Aletheia. "
        + "Turn it on in System Settings > Privacy & Security, then quit and reopen Aletheia."

    func shouldAttempt(preflight: Bool) -> Bool {
        preflight || worked || !attempted
    }

    mutating func recordAttempt(succeeded: Bool) {
        attempted = true
        if succeeded { worked = true }
    }
}
