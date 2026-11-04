import Foundation

/// The tip, once per Mac before the first recording, to use headphones. On
/// speakers the call re-enters the microphone and is transcribed twice
/// (`SpeakerLeakageFilter` removes what it can); headphones avoid it.
enum HeadphonesTip {
    static let title = "Use headphones"
    static let message = """
    On speakers, your microphone also picks up your client's voice, so their \
    words can appear twice in the transcript, once as yours. Headphones keep \
    the two apart. This tip appears only once.
    """
    static let startButton = "Start Recording"

    /// True the first time it's asked on this Mac, and marks the tip shown,
    /// so it never appears again.
    static func takeIfDue(_ settings: AppSettings) -> Bool {
        guard !settings.hasSeenHeadphonesTip else { return false }
        settings.hasSeenHeadphonesTip = true
        return true
    }
}
