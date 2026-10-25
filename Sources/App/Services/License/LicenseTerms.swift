import CryptoKit
import Foundation

/// The two documents a license can record acceptance of.
enum LicenseDocument: String, CaseIterable {
    case terms
    case privacy

    var title: String {
        switch self {
        case .terms: return "Terms"
        case .privacy: return "Privacy Policy"
        }
    }

    /// The bundled copy's resource name (the repo-root file, copied in by project.yml).
    var resourceName: String {
        switch self {
        case .terms: return "TERMS"
        case .privacy: return "PRIVACY"
        }
    }
}

/// One accepted document in a token's `acc` list.
struct LicenseAcceptance: Equatable {
    let document: LicenseDocument
    /// The document's version label (its "last updated" date), shown as written.
    let version: String
    /// Lowercase hex SHA-256 of the document's UTF-8 bytes.
    let hash: String
    let acceptedAt: Date

    /// Reads the optional `acc` value. This is a convenience record on top of a
    /// signature that has already verified, so anything unreadable is skipped
    /// rather than refusing the license: a bad entry (or a non-list field) simply
    /// leaves that document unconfirmed, and the app asks for acceptance itself.
    /// Skipping can only withhold a confirmation, never grant one. Unknown
    /// documents are ignored so a newer site can add some. When a document is
    /// listed more than once, the latest acceptance wins.
    static func parse(_ value: Any?) -> [LicenseAcceptance] {
        guard let entries = value as? [Any] else { return [] }
        var latest: [LicenseDocument: LicenseAcceptance] = [:]
        for case let entry as [String: Any] in entries {
            guard let name = entry["d"] as? String, let document = LicenseDocument(rawValue: name),
                  let version = entry["v"] as? String, !version.isEmpty, version.count <= 32,
                  let hash = entry["h"] as? String, isSHA256Hex(hash),
                  let at = (entry["at"] as? NSNumber).flatMap({ number -> Int64? in
                      // Whole seconds only: no booleans, no fractions.
                      CFGetTypeID(number) == CFBooleanGetTypeID() || number.doubleValue != Double(number.int64Value) ? nil : number.int64Value
                  }), at > 0, at < 32_503_680_000
            else { continue }
            let item = LicenseAcceptance(
                document: document, version: version, hash: hash,
                acceptedAt: Date(timeIntervalSince1970: TimeInterval(at)))
            if let existing = latest[document], existing.acceptedAt >= item.acceptedAt { continue }
            latest[document] = item
        }
        return LicenseDocument.allCases.compactMap { latest[$0] }
    }

    static func isSHA256Hex(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// Short notes a license can carry in its `cl` list. Unknown codes are ignored.
enum LicenseClause: String, CaseIterable {
    case noBAA = "no-baa"
    case betaNoSLA = "beta-no-sla"

    var text: String {
        switch self {
        case .noBAA: return "Business associate agreement not offered"
        case .betaNoSLA: return "Beta: no service level"
        }
    }

    /// Reads the optional `cl` value: known codes only, in order, without repeats.
    /// A value that is not a list is ignored, as is any entry that is not a known string.
    static func parse(_ value: Any?) -> [LicenseClause] {
        guard let codes = value as? [Any] else { return [] }
        var seen: [LicenseClause] = []
        for case let code as String in codes {
            if let clause = LicenseClause(rawValue: code), !seen.contains(clause) { seen.append(clause) }
        }
        return seen
    }
}

/// The documents shipped inside this build, hashed from the bundled bytes.
enum BundledLegalDocuments {
    private final class BundleToken {}

    static func data(_ document: LicenseDocument, bundle: Bundle = Bundle(for: BundleToken.self)) -> Data? {
        guard let url = bundle.url(forResource: document.resourceName, withExtension: "md") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of each bundled document that is present.
    static func hashes(bundle: Bundle = Bundle(for: BundleToken.self)) -> [LicenseDocument: String] {
        var result: [LicenseDocument: String] = [:]
        for document in LicenseDocument.allCases {
            if let bytes = data(document, bundle: bundle) { result[document] = sha256Hex(bytes) }
        }
        return result
    }
}

/// What Settings › License says about the accepted terms, and whether the app
/// still has to ask. Pure: the bundled hashes and the in-app record are passed in.
struct LicenseTermsSummary: Equatable {
    struct Row: Equatable {
        let document: LicenseDocument
        /// "Terms v2026-10-24 accepted on 24 October 2026"
        let text: String
        /// The token's hash equals the bundled document's hash.
        let matchesThisVersion: Bool
    }

    let rows: [Row]
    let clauseTexts: [String]
    /// Every document is confirmed by the license at the version in this build.
    /// When false, the in-app acceptance (`Legal`, `LegalReceipt`) applies.
    let licenseCoversCurrentTerms: Bool

    static let matchText = "Matches this version"

    init(token: LicenseToken, bundledHashes: [LicenseDocument: String]) {
        var rows: [Row] = []
        var covered = true
        for document in LicenseDocument.allCases {
            let accepted = token.acceptances.first { $0.document == document }
            let matches = accepted != nil && accepted?.hash == bundledHashes[document]
            if let accepted {
                rows.append(Row(
                    document: document,
                    text: "\(document.title) v\(accepted.version) accepted on \(accepted.acceptedAt.licenseText)",
                    matchesThisVersion: matches))
            }
            if !matches { covered = false }
        }
        self.rows = rows
        self.clauseTexts = token.clauses.map(\.text)
        self.licenseCoversCurrentTerms = covered
    }

    /// The line for the in-app acceptance, shown when the license does not cover
    /// the current terms.
    static func inAppText(acceptedVersion: String, acceptedAt: Date?) -> String {
        guard Legal.isAccepted(acceptedVersion), let acceptedAt else {
            return "The current terms have not been accepted in the app yet. Aletheia asks for this before you continue."
        }
        return "Accepted in this app: v\(acceptedVersion) on \(acceptedAt.licenseText)"
    }
}
