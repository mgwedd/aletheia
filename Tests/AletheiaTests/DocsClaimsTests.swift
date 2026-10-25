import XCTest
@testable import Aletheia

/// Public documents must not claim anything the Release build does not do.
/// The rules are few and structural so ordinary rewording does not trip them.
final class DocsClaimsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func publicDocs() throws -> [(path: String, text: String)] {
        let docsDir = root.appendingPathComponent("docs")
        let extra = try FileManager.default.contentsOfDirectory(atPath: docsDir.path)
            .filter { $0.hasSuffix(".md") }.sorted().map { "docs/\($0)" }
        let paths = ["README.md", "PRIVACY.md", "SECURITY.md", "TERMS.md", "CONSENT.md"] + extra
        return try paths.map {
            ($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8))
        }
    }

    private func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
    }

    private func isNegated(_ paragraph: String) -> Bool {
        paragraph.contains(/(?i)\b(no|not|never|without|nor|none|neither|n't)\b/)
    }

    func testDocsDoNotMentionRemovedEnginesOrBackups() throws {
        for (path, text) in try publicDocs() {
            let lower = text.lowercased()
            XCTAssertFalse(lower.contains("ollama"), path)
            XCTAssertFalse(lower.contains("11434"), path)
            XCTAssertFalse(lower.contains("icloud backup"), path)
            for p in paragraphs(text) where p.localizedCaseInsensitiveContains("ai server") {
                XCTAssertTrue(isNegated(p), "\(path) mentions an AI server without saying there is none")
            }
        }
    }

    func testTelemetryAndAnalyticsAreOnlyEverDisclaimed() throws {
        for (path, text) in try publicDocs() {
            for p in paragraphs(text) where p.contains(/(?i)telemetry|analytics/) {
                XCTAssertTrue(isNegated(p), "\(path) mentions telemetry/analytics without a negation: \(p.prefix(80))")
            }
        }
    }

    /// While at-rest encryption is not in the Release tier, no document may
    /// present it as something every install has.
    func testEncryptionClaimsMatchTheShippingTier() throws {
        let tier = AtRestEncryptionFeatureModule().tier
        XCTAssertTrue(tier == .dev || tier == .preview || tier == .production)
        guard tier > .production else { return }
        let absolute = /(?i)encrypted at rest|always encrypted|encrypted by default/
        for (path, text) in try publicDocs() {
            for p in paragraphs(text) where p.contains(absolute) {
                XCTAssertTrue(
                    p.contains(/(?i)developer|dev tier|dev-tier|opt-in|if you turn on|production builds do not/),
                    "\(path) claims encryption at rest but it is not in the Release tier: \(p.prefix(80))")
            }
        }
    }

    func testSecurityDocHasSupportWithoutPatientData() throws {
        let text = try String(contentsOf: root.appendingPathComponent("SECURITY.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("## Support without patient data"))
        XCTAssertTrue(text.contains("Astrea Labs"))
        XCTAssertTrue(text.contains("support@astrealabs.com"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("never asks for patient data"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("redacts"))
    }
}
