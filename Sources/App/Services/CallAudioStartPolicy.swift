import Foundation

/// Decides whether Record should try to start call-audio capture.
///
/// Starting capture goes through ScreenCaptureKit, which shows the system
/// "record this computer's screen and audio" dialog whenever access isn't
/// recognised. That dialog belongs to setup, where the user is asked once on
/// purpose. Record never asks: it captures call audio only when access is
/// known good, and otherwise records the mic alone and says how to fix it.
///
/// "Known good" is any of: the (per-process cached) preflight says granted,
/// a capture already worked this launch, or a grant was confirmed for this
/// build in an earlier session (`CallAudioGrantStore`).
struct CallAudioStartPolicy: Equatable {
    private(set) var worked = false

    static let skippedMessage =
        "Call audio is off for this session: Screen & System Audio Recording isn't set up for this version of Aletheia. "
        + "Open Settings > Setup Assistant and choose Allow next to Call audio capture. You will only be asked there."

    func shouldAttempt(preflight: Bool, confirmedBefore: Bool) -> Bool {
        preflight || confirmedBefore || worked
    }

    mutating func recordSuccess() {
        worked = true
    }
}
