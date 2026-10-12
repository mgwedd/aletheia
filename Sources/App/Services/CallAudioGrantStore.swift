import Foundation

/// Remembers, across launches, that call-audio access was confirmed working
/// for *this build* of the app.
///
/// `CGPreflightScreenCaptureAccess` is cached per process and reads false
/// after any grant the system doesn't tie to the running binary (a toggle
/// switched on while the app was open, or one made to an earlier ad-hoc-signed
/// build). Trusting it alone made Aletheia forget a granted permission and go
/// back to asking. A confirmation recorded when access last worked (setup
/// granted it, or a capture started) lets later launches skip the question.
///
/// Keyed by build: a different build is a different code identity to macOS,
/// so the old confirmation no longer applies and setup must grant again.
struct CallAudioGrantStore {
    private static let key = "callAudioConfirmedBuild"

    let defaults: UserDefaults
    let build: String

    init(defaults: UserDefaults = .standard, build: String = CallAudioGrantStore.currentBuild) {
        self.defaults = defaults
        self.build = build
    }

    static var standard: CallAudioGrantStore { CallAudioGrantStore() }

    /// Version plus build number, so each shipped build counts as its own identity.
    static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let number = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(number)"
    }

    /// The build access was last confirmed for, if any.
    var confirmedBuild: String? {
        defaults.string(forKey: Self.key)
    }

    var isConfirmed: Bool {
        confirmedBuild == build
    }

    func confirm() {
        defaults.set(build, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
