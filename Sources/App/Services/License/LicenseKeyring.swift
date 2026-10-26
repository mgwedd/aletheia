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
    // The current signing key and the next one, so the site can rotate to `prod-2` without
    // locking anyone out. Their private seeds are held by the owner, never in this repo.
    static let productionPublicKeys: [String: String] = [
        "prod-1": "OJ3lF6ssIkFSvc2sLNx6HYfo0l/bvWOg6iK42xV9K+w=",
        "prod-2": "VlzGFej0dahg8Z4BGGRMHgU+RN2Gd+qgYHLlS34yS5E=",
    ]
    // END PRODUCTION KEYS

    /// Production keys only. Never contains the dev key.
    static let production = LicenseKeyring(encoded: productionPublicKeys)

    #if ALETHEIA_DEV
    /// The dev tier also trusts a dev key for local Debug builds. Its private half is kept
    /// by the owner outside the repo, never committed. Compiled out of every other tier.
    static let devKeyID = "aletheia-dev-2"
    static let devPublicKey = "8KFp2hW7OwEzohfjyeq+7R4eZywqyDxNYBGU7YUzkSU="
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
