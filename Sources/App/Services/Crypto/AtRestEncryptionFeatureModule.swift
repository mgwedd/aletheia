import Foundation

/// At-rest encryption (Tier 2, passphrase-based) as a `FeatureModule`: complete
/// and working, but this area has a history of being glitchy, so it stays
/// developer-build-only rather than surfaced to testers or the clinician.
///
/// This gates only whether encryption can be newly turned on and whether its
/// settings/management UI is offered — never whether an already-encrypted data
/// folder (created by an earlier build) can be unlocked and read. See the
/// gating call sites in `FirstRunView` and `SettingsView`.
struct AtRestEncryptionFeatureModule: FeatureModule {
    /// Also usable as `AtRestEncryptionFeatureModule.id` at call sites that only
    /// need the identifier to query the registry, without constructing an
    /// instance.
    static let id = "atRestEncryption"

    var id: String { Self.id }
    let title = "Extra Encryption"
    let tier: BuildTier = .dev
}
