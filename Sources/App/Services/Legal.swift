import Foundation

/// The app's legal terms and the rule for whether the user has accepted the
/// current version. Kept as pure, framework-free values so the acceptance
/// logic is unit-tested in isolation and reused by both the first-run gate and
/// Settings.
///
/// Acceptance is recorded locally (see `AppSettings.recordLegalAcceptance`):
/// the accepted version and timestamp go to UserDefaults (the gate) and to an
/// append-only receipt file in the data folder (`LegalReceipt`). Both stay on
/// this Mac. This is a good-faith local record — not tamper-proof, and not tied
/// to a person's identity (no local store can prove either). What it does show:
/// the first-run flow will not let anyone continue without accepting, so the app
/// cannot be used without a recorded acceptance of the current terms.
enum Legal {
    /// The current terms version. This is the date the terms last changed, and
    /// it is exactly what gets stored as the accepted version. **Bump this
    /// whenever TERMS.md or PRIVACY.md change materially** — users are then
    /// required to re-accept, and the new version + timestamp are recorded.
    static let currentVersion = "2026-09-17"

    /// Canonical, human-readable copies in the repository. Shown as links in the
    /// first-run acceptance step and in Settings.
    static let termsURL = URL(string: "https://github.com/mgwedd/aletheia/blob/main/TERMS.md")!
    static let privacyURL = URL(string: "https://github.com/mgwedd/aletheia/blob/main/PRIVACY.md")!

    /// Whether a recorded acceptance satisfies the current terms version.
    /// An empty record (never accepted) or an older version (terms changed
    /// since) both count as not accepted, so the gate re-appears.
    static func isAccepted(_ acceptedVersion: String) -> Bool {
        !acceptedVersion.isEmpty && acceptedVersion == currentVersion
    }
}
