import CryptoKit
import Foundation

/// The public keys a license token (or revocation list) may be signed with, by `kid`.
struct LicenseKeyring {
    let keys: [String: Curve25519.Signing.PublicKey]

    /// Builds a keyring from `kid` -> base64 raw 32-byte Ed25519 public key.
    /// An entry that is not a valid key is skipped, so it can never verify anything.
    init(encoded: [String: String]) {
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for (kid, base64) in encoded {
            guard let raw = Data(base64Encoded: base64),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { continue }
            keys[kid] = key
        }
        self.keys = keys
    }

    // BEGIN PRODUCTION KEYS (scripts/check-license-keys.sh reads this block)
    // TODO(owner): production public keys. Replace `[:]` with a dictionary literal holding
    // one `"<kid>": "<base64 raw Ed25519 public key>",` line per key (the current key and
    // the next one). Until then a production build rejects every license, so a tagged
    // release is blocked (see scripts/check-license-keys.sh).
    static let productionPublicKeys: [String: String] = [:]
    // END PRODUCTION KEYS

    /// Production keys only. Never contains the dev key.
    static let production = LicenseKeyring(encoded: productionPublicKeys)

    #if ALETHEIA_DEV
    /// The dev tier also trusts a dev key whose private half lives only under `Tests/`
    /// (and in `scripts/mint-dev-license.swift`). Compiled out of every other tier.
    static let devKeyID = "aletheia-dev-1"
    static let devPublicKey = "l5KEG0cBMvhtV+s4ZO14Q7eFg172/V29cw1MehAF2lI="
    #endif

    /// The keyring this build trusts: production keys, plus the dev key in the dev tier.
    static let active: LicenseKeyring = {
        #if ALETHEIA_DEV
        return LicenseKeyring(encoded: productionPublicKeys.merging([devKeyID: devPublicKey]) { prod, _ in prod })
        #else
        return production
        #endif
    }()
}
