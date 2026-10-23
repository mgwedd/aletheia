import CryptoKit
import Foundation

/// A signed list of revoked license ids: `ALETR1.<payload>.<signature>`, signed by
/// the same key family as license tokens. Verified offline; getting the bytes to
/// the app is a separate step. Payload: `{v, kid, iat, next, revoked: [lid]}`.
struct RevocationList: Equatable {
    let kid: String
    let issuedAt: Date
    /// When the issuer expects to publish the next list.
    let next: Date
    let revoked: Set<String>
}

enum RevocationError: Error, Equatable {
    case tooLong
    case malformed
    case unsupportedVersion
    case unknownKey
    case badSignature
    /// Older than the newest list already accepted: ignored, so an old list cannot be replayed.
    case stale
}

enum RevocationVerifier {
    static let prefix = "ALETR1"
    static let maxLength = 256 * 1024

    private struct Payload: Decodable {
        let v: Int
        let kid: String
        let iat: Int64
        let next: Int64
        let revoked: [String]
    }

    /// - Parameter lastAcceptedIssuedAt: `iat` of the newest list accepted so far
    ///   (Unix seconds); a list older than this is `.stale`. Equal is accepted.
    static func verify(_ text: String, keyring: LicenseKeyring, lastAcceptedIssuedAt: Int = 0) throws -> RevocationList {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxLength else { throw RevocationError.tooLong }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix,
              let payloadData = Base64URL.decode(String(parts[1])),
              let signature = Base64URL.decode(String(parts[2])),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else { throw RevocationError.malformed }
        guard payload.v == 1 else { throw RevocationError.unsupportedVersion }
        guard let key = keyring.keys[payload.kid] else { throw RevocationError.unknownKey }
        guard key.isValidSignature(signature, for: Data("\(prefix).\(parts[1])".utf8)) else {
            throw RevocationError.badSignature
        }
        guard payload.iat >= Int64(lastAcceptedIssuedAt) else { throw RevocationError.stale }
        return RevocationList(
            kid: payload.kid,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(payload.iat)),
            next: Date(timeIntervalSince1970: TimeInterval(payload.next)),
            revoked: Set(payload.revoked))
    }
}
