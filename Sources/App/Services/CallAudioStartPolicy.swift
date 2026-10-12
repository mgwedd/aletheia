import Foundation

/// Decides whether Record should try to start call-audio capture.
///
/// Starting capture goes through ScreenCaptureKit, which shows the system
/// "record this computer's screen and audio" dialog whenever access isn't
/// recognised. Record captures call audio whenever access is known good, and
/// otherwise tries once per launch: an ad-hoc-signed build is a new identity
/// to macOS on every update, so without that one attempt each update silently
/// dropped call audio until setup was redone. After a failed attempt Record
/// goes mic-only and says how to fix it instead of asking again.
///
/// "Known good" is any of: the (per-process cached) preflight says granted,
/// a capture already worked this launch, or a grant was confirmed for this
/// build in an earlier session (`CallAudioGrantStore`).
struct CallAudioStartPolicy: Equatable {
    private(set) var attempted = false
    private(set) var worked = false

    static let skippedMessage =
        "Call audio is off for this session: Screen & System Audio Recording isn't set up for this version of Aletheia. "
        + "Open Settings > Setup Assistant and choose Allow next to Call audio capture."

    func shouldAttempt(preflight: Bool, confirmedBefore: Bool) -> Bool {
        preflight || confirmedBefore || worked || !attempted
    }

    mutating func recordAttempt(succeeded: Bool) {
        attempted = true
        if succeeded { worked = true }
    }
}
