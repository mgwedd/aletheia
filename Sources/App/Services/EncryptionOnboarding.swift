import Foundation

/// Pure decision for the first-run "Protect your data" step.
///
/// At-rest encryption is Aletheia's recommended default, so onboarding surfaces
/// it as an opt-out step the therapist actively declines, rather than a buried
/// Settings toggle they have to discover. It stays passphrase-based (no silent
/// device key that could lock a therapist out of their own PHI if the keychain
/// is ever lost) — "default on" here means *recommended and set up during
/// onboarding*, with the recovery passphrase the safety net.
///
/// Kept free of any view or framework type so the recommendation is unit-tested
/// in isolation.
enum EncryptionOnboarding {
    /// Whether first-run should recommend turning on at-rest encryption. Only
    /// once a data folder is chosen (there's nothing to key or encrypt without
    /// one) and encryption isn't already on for it.
    static func isRecommended(dataFolderChosen: Bool, alreadyEnabled: Bool) -> Bool {
        dataFolderChosen && !alreadyEnabled
    }
}
