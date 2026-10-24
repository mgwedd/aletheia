import CryptoKit
import Foundation

/// A verified license: the payload of an `ALET1.<payload>.<signature>` token.
/// The token is signed, not secret, and is checked entirely on this Mac.
struct LicenseToken: Equatable {
    let kid: String
    /// License id (UUID v4). Revocation lists name this.
    let lid: String
    /// The licensee's email, shown as "Licensed to …". Stays on this Mac.
    let sub: String
    let tier: String
    let issuedAt: Date
    let expiresAt: Date
    /// Terms documents the licensee accepted when the license was issued. Empty
    /// when the token has none or the field is unreadable.
    var acceptances: [LicenseAcceptance] = []
    /// Known plain-language notes about this license (see `LicenseClause`).
    var clauses: [LicenseClause] = []

    /// The expiry warning starts this long before `expiresAt`.
    static let warningWindow: TimeInterval = 14 * 86_400

    func isExpired(at now: Date) -> Bool { expiresAt <= now }

    /// Whole days left (rounded up), or nil once expired.
    func daysRemaining(at now: Date) -> Int? {
        guard !isExpired(at: now) else { return nil }
        return Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.up))
    }

    /// Within the warning window and not yet expired.
    func isExpiringSoon(at now: Date) -> Bool {
        !isExpired(at: now) && expiresAt.timeIntervalSince(now) <= Self.warningWindow
    }

    /// After `expiresAt`, recording and the AI keep working this long so a late
    /// renewal never interrupts a practice mid-week.
    static let gracePeriod: TimeInterval = 14 * 86_400

    /// When new work stops: `gracePeriod` after `expiresAt`.
    var graceEndsAt: Date { expiresAt.addingTimeInterval(Self.gracePeriod) }

    /// Expired, but still inside the grace period.
    func isInGracePeriod(at now: Date) -> Bool { isExpired(at: now) && now < graceEndsAt }

    /// Whole days of grace left (rounded up), or nil outside the grace period.
    func graceDaysRemaining(at now: Date) -> Int? {
        guard isInGracePeriod(at: now) else { return nil }
        return Int((graceEndsAt.timeIntervalSince(now) / 86_400).rounded(.up))
    }
}

/// Why a token was refused. The messages are shown to the user as they are.
enum LicenseError: Error, Equatable, LocalizedError {
    case empty
    case tooLong
    case malformed
    case unsupportedVersion
    case unknownKey
    case badSignature
    case expired(Date)
    case issuedInFuture
    case revoked

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste your license key to continue."
        case .tooLong:
            return "That is too long to be a license key. Paste only the key from your email, which starts with ALET1."
        case .malformed:
            return "That does not look like a license key. Paste the whole key from your email, which starts with ALET1."
        case .unsupportedVersion:
            return "This license key is from a newer format than this version of Aletheia understands. Update Aletheia and try again."
        case .unknownKey:
            return "This license key was not issued for this version of Aletheia. Check that you copied the whole key, or update Aletheia."
        case .badSignature:
            return "This license key could not be verified. Check that you copied the whole key from your email, with no characters missing."
        case .expired(let date):
            return "This license key expired on \(date.licenseText). Request a new key and paste it here."
        case .issuedInFuture:
            return "This license key is dated in the future. Check that this Mac's date and time are correct."
        case .revoked:
            return "This license key is no longer valid. Request a new key and paste it here."
        }
    }
}

extension Date {
    /// "12 March 2027", the way a license date is shown.
    var licenseText: String {
        formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "en_US")))
    }
}

/// Offline check of a license token. Pure: the keyring and the clock are passed in.
enum LicenseVerifier {
    static let prefix = "ALET1"
    static let maxLength = 1024
    /// A token dated further ahead than this is rejected (a wrong clock, or a forgery).
    static let allowedClockSkew: TimeInterval = 86_400

    private struct Payload: Decodable {
        let v: Int
        let kid: String
        let lid: String
        let sub: String
        let tier: String
        let iat: Int64
        let exp: Int64
    }

    /// Full check, including expiry. Throws a `LicenseError` naming the first problem.
    static func verify(_ text: String, keyring: LicenseKeyring, now: Date) throws -> LicenseToken {
        let token = try verifySignature(text, keyring: keyring)
        if token.isExpired(at: now) { throw LicenseError.expired(token.expiresAt) }
        if token.issuedAt.timeIntervalSince(now) > allowedClockSkew { throw LicenseError.issuedInFuture }
        return token
    }

    /// Everything except the time checks: shape, version, key id and signature. Lets
    /// the app still say who an expired license belonged to and when it ran out.
    static func verifySignature(_ text: String, keyring: LicenseKeyring) throws -> LicenseToken {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LicenseError.empty }
        guard trimmed.utf8.count <= maxLength else { throw LicenseError.tooLong }
        // One line, no stray spaces: a pasted key broken across lines is not the key.
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw LicenseError.malformed }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix,
              let payloadData = Base64URL.decode(String(parts[1])),
              let signature = Base64URL.decode(String(parts[2])),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else { throw LicenseError.malformed }
        guard payload.v == 1 else { throw LicenseError.unsupportedVersion }
        let extras = (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
        guard let key = keyring.keys[payload.kid] else { throw LicenseError.unknownKey }
        let signed = Data("\(prefix).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signed) else { throw LicenseError.badSignature }
        return LicenseToken(
            kid: payload.kid, lid: payload.lid, sub: payload.sub, tier: payload.tier,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(payload.iat)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(payload.exp)),
            acceptances: LicenseAcceptance.parse(extras["acc"]),
            clauses: LicenseClause.parse(extras["cl"]))
    }
}

/// Base64url without padding, as used by the token and revocation list.
enum Base64URL {
    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // No padding allowed on the wire; reject it rather than accept a variant.
        guard !base64.contains("="), base64.count % 4 != 1 else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
