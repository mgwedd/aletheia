import CryptoKit
import XCTest
@testable import Aletheia

@MainActor
final class LicenseTermsTests: XCTestCase {
    private let now = LicenseTestMint.now
    private var key: Curve25519.Signing.PrivateKey!
    private var ring: LicenseKeyring!

    override func setUp() {
        (key, ring) = LicenseTestMint.freshKeyring()
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private let sampleHash = String(repeating: "ab", count: 32)
    private let otherHash = String(repeating: "cd", count: 32)

    private func entry(_ d: String, v: String = "2026-10-24", h: String? = nil, at: Any? = nil) -> [String: Any] {
        ["d": d, "v": v, "h": h ?? sampleHash, "at": at ?? Int(1_799_000_000)]
    }

    private func parse(_ extra: [String: Any]) throws -> LicenseToken {
        var payload = LicenseTestMint.payload()
        payload.merge(extra) { _, new in new }
        return try LicenseVerifier.verify(try LicenseTestMint.token(payload, key: key), keyring: ring, now: now)
    }

    // MARK: - Parsing

    func testTokenWithoutNewFieldsStaysValid() throws {
        let token = try parse([:])
        XCTAssertEqual(token.acceptances, [])
        XCTAssertEqual(token.clauses, [])
    }

    func testParsesAcceptancesAndClauses() throws {
        let token = try parse(["acc": [entry("terms"), entry("privacy", v: "2026-10-23")], "cl": ["no-baa", "beta-no-sla"]])
        XCTAssertEqual(token.acceptances.map(\.document), [.terms, .privacy])
        XCTAssertEqual(token.acceptances[0].version, "2026-10-24")
        XCTAssertEqual(token.acceptances[0].hash, sampleHash)
        XCTAssertEqual(token.acceptances[0].acceptedAt, Date(timeIntervalSince1970: 1_799_000_000))
        XCTAssertEqual(token.acceptances[1].version, "2026-10-23")
        XCTAssertEqual(token.clauses, [.noBAA, .betaNoSLA])
    }

    func testUnknownDocumentsAndClauseCodesAreIgnored() throws {
        let token = try parse(["acc": [entry("eula"), entry("terms")], "cl": ["something-new", "no-baa", "no-baa", 7]])
        XCTAssertEqual(token.acceptances.map(\.document), [.terms])
        XCTAssertEqual(token.clauses, [.noBAA])
    }

    func testMalformedFieldsAreIgnoredWithoutRejectingTheToken() throws {
        let notLists = try parse(["acc": "terms", "cl": "no-baa"])
        XCTAssertEqual(notLists.acceptances, [])
        XCTAssertEqual(notLists.clauses, [])
        XCTAssertEqual(try parse(["acc": 5, "cl": ["x": 1]]).acceptances, [])
        let bad: [[String: Any]] = [
            entry("terms", h: sampleHash.uppercased()),
            entry("terms", h: "abc"),
            entry("terms", v: ""),
            entry("terms", at: "yesterday"),
            entry("terms", at: -5),
            entry("terms", at: true),
            entry("terms", at: 1.5),
            ["d": "terms"],
        ]
        for e in bad {
            XCTAssertEqual(try parse(["acc": [e]]).acceptances, [], "\(e)")
        }
        // One bad entry does not hide a good one.
        XCTAssertEqual(try parse(["acc": [entry("terms", h: "zz"), entry("privacy")]]).acceptances.map(\.document), [.privacy])
    }

    func testLatestAcceptanceWinsForARepeatedDocument() throws {
        let token = try parse(["acc": [entry("terms", v: "old", at: 1_700_000_000), entry("terms", v: "new", at: 1_790_000_000)]])
        XCTAssertEqual(token.acceptances.map(\.version), ["new"])
    }

    func testNewFieldsAreCoveredBySignature() throws {
        var payload = LicenseTestMint.payload()
        payload["acc"] = [entry("terms")]
        let good = try LicenseTestMint.token(payload, key: key)
        payload["acc"] = [entry("terms", h: otherHash)]
        let forged = try LicenseTestMint.token(payload, key: key)
        let g = good.split(separator: "."), f = forged.split(separator: ".")
        let spliced = "\(g[0]).\(f[1]).\(g[2])"
        XCTAssertThrowsError(try LicenseVerifier.verify(spliced, keyring: ring, now: now)) {
            XCTAssertEqual($0 as? LicenseError, .badSignature)
        }
    }

    func testAFreshKeyMintsAcceptanceToo() throws {
        let (key, ring) = LicenseTestMint.freshKeyring()
        var payload = LicenseTestMint.payload(kid: "test-1")
        payload["acc"] = [entry("terms")]
        let token = try LicenseVerifier.verify(try LicenseTestMint.token(payload, key: key), keyring: ring, now: now)
        XCTAssertEqual(token.acceptances.count, 1)
    }

    // MARK: - Bundled documents

    func testBundledDocumentsEqualTheRepoFiles() throws {
        for (document, file) in [(LicenseDocument.terms, "TERMS.md"), (.privacy, "PRIVACY.md")] {
            let bundled = try XCTUnwrap(BundledLegalDocuments.data(document), "\(file) is not in the app bundle (project.yml)")
            XCTAssertEqual(bundled, try Data(contentsOf: repoRoot.appendingPathComponent(file)))
        }
    }

    func testHashIsLowercaseHexSHA256OfTheBytes() {
        XCTAssertEqual(
            BundledLegalDocuments.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let hashes = BundledLegalDocuments.hashes()
        XCTAssertEqual(Set(hashes.keys), Set(LicenseDocument.allCases))
        XCTAssertTrue(hashes.values.allSatisfy(LicenseAcceptance.isSHA256Hex))
    }

    func testProjectBundlesTheTermsFiles() throws {
        let yml = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        for name in ["TERMS.md", "PRIVACY.md"] {
            XCTAssertTrue(yml.contains("- path: \(name)\n        buildPhase: resources"), name)
        }
    }

    // MARK: - Matching and the in-app fallback

    private func tokenWith(hashes: [LicenseDocument: String], clauses: [String] = []) throws -> LicenseToken {
        try parse([
            "acc": LicenseDocument.allCases.compactMap { d in hashes[d].map { entry(d.rawValue, h: $0) } },
            "cl": clauses,
        ])
    }

    func testMatchingHashesCoverTheCurrentTerms() throws {
        let bundled: [LicenseDocument: String] = [.terms: sampleHash, .privacy: otherHash]
        let summary = LicenseTermsSummary(token: try tokenWith(hashes: bundled), bundledHashes: bundled)
        XCTAssertTrue(summary.licenseCoversCurrentTerms)
        XCTAssertEqual(summary.rows.map(\.matchesThisVersion), [true, true])
        XCTAssertEqual(summary.rows[0].text, "Terms v2026-10-24 accepted on \(Date(timeIntervalSince1970: 1_799_000_000).licenseText)")
        XCTAssertEqual(summary.rows[1].document, .privacy)
    }

    func testChangedDocumentRequiresInAppAcceptance() throws {
        let summary = LicenseTermsSummary(
            token: try tokenWith(hashes: [.terms: sampleHash, .privacy: sampleHash]),
            bundledHashes: [.terms: sampleHash, .privacy: otherHash])
        XCTAssertFalse(summary.licenseCoversCurrentTerms)
        XCTAssertEqual(summary.rows.map(\.matchesThisVersion), [true, false])
    }

    func testTokenWithoutAccRequiresInAppAcceptance() throws {
        let summary = LicenseTermsSummary(token: try parse([:]), bundledHashes: [.terms: sampleHash, .privacy: sampleHash])
        XCTAssertFalse(summary.licenseCoversCurrentTerms)
        XCTAssertTrue(summary.rows.isEmpty)
    }

    func testOnlyOneDocumentAcceptedIsNotEnough() throws {
        let summary = LicenseTermsSummary(
            token: try tokenWith(hashes: [.terms: sampleHash]), bundledHashes: [.terms: sampleHash, .privacy: sampleHash])
        XCTAssertFalse(summary.licenseCoversCurrentTerms)
    }

    func testMissingBundledDocumentNeverMatches() throws {
        let summary = LicenseTermsSummary(
            token: try tokenWith(hashes: [.terms: sampleHash, .privacy: sampleHash]), bundledHashes: [:])
        XCTAssertFalse(summary.licenseCoversCurrentTerms)
    }

    func testStateUsesTheRealBundledHashes() throws {
        let suite = "LicenseTermsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let state = LicenseState(settings: settings, keyring: ring, now: { self.now })
        let hashes = BundledLegalDocuments.hashes()
        var payload = LicenseTestMint.payload()
        payload["acc"] = LicenseDocument.allCases.map { entry($0.rawValue, h: hashes[$0]) }
        _ = state.install(try LicenseTestMint.token(payload, key: key))
        XCTAssertTrue(state.licenseCoversCurrentTerms)

        payload["acc"] = LicenseDocument.allCases.map { entry($0.rawValue) }
        _ = state.install(try LicenseTestMint.token(payload, key: key))
        XCTAssertFalse(state.licenseCoversCurrentTerms)
        XCTAssertFalse(settings.hasAcceptedCurrentLegal, "the in-app flow still applies")
    }

    // MARK: - Copy

    func testClauseAndInAppCopy() throws {
        let summary = LicenseTermsSummary(
            token: try tokenWith(hashes: [:], clauses: ["no-baa", "beta-no-sla"]), bundledHashes: [:])
        XCTAssertEqual(summary.clauseTexts, ["Business associate agreement not offered", "Beta: no service level"])
        XCTAssertEqual(LicenseTermsSummary.matchText, "Matches this version")
        let when = Date(timeIntervalSince1970: 1_799_000_000)
        XCTAssertEqual(
            LicenseTermsSummary.inAppText(acceptedVersion: Legal.currentVersion, acceptedAt: when),
            "Accepted in this app: v\(Legal.currentVersion) on \(when.licenseText)")
        XCTAssertTrue(LicenseTermsSummary.inAppText(acceptedVersion: "old", acceptedAt: when).contains("not been accepted"))
        XCTAssertTrue(LicenseTermsSummary.inAppText(acceptedVersion: "", acceptedAt: nil).contains("not been accepted"))
    }
}
