import XCTest
@testable import Aletheia

final class NetworkAccessStatusTests: XCTestCase {
    private typealias E = NetworkAccessFacts.Entitlements
    private let goodHelper = E(sandboxed: true, networkClient: true)

    func testSandboxedWithoutNetworkReadsNoNetwork() {
        let status = NetworkAccessStatus(.init(app: E(sandboxed: true, networkClient: false), helper: goodHelper))
        XCTAssertEqual(status.state, .noNetwork)
        XCTAssertEqual(status.headline, "Aletheia can't connect to the internet")
        XCTAssertEqual(status.tone, .ok)
    }

    func testNetworkEntitlementInTheAppIsAWarning() {
        let status = NetworkAccessStatus(.init(app: E(sandboxed: true, networkClient: true), helper: goodHelper))
        XCTAssertEqual(status.state, .hasNetwork)
        XCTAssertEqual(status.tone, .warn)
        XCTAssertFalse(status.headline.contains("can't"))
    }

    /// Network wins over "not sandboxed": an unsandboxed app with the key is
    /// still reported as having network access.
    func testNetworkEntitlementWithoutSandboxIsStillAWarning() {
        let status = NetworkAccessStatus(.init(app: E(sandboxed: false, networkClient: true), helper: nil))
        XCTAssertEqual(status.state, .hasNetwork)
    }

    func testUnsandboxedDevelopmentRunSaysSoHonestly() {
        let status = NetworkAccessStatus(.init(app: E(sandboxed: false, networkClient: false), helper: nil))
        XCTAssertEqual(status.state, .notSandboxed)
        XCTAssertEqual(status.tone, .neutral)
        XCTAssertFalse(status.headline.contains("can't connect"), "must not claim a guarantee it can't show")
    }

    func testUnreadableSignatureIsReportedAsUnknown() {
        let status = NetworkAccessStatus(.init(app: nil, helper: nil))
        XCTAssertEqual(status.state, .unreadable)
        XCTAssertEqual(status.tone, .neutral)
    }

    func testHelperSummaries() {
        let app = E(sandboxed: true, networkClient: false)
        XCTAssertTrue(NetworkAccessStatus(.init(app: app, helper: goodHelper)).helperSummary.contains("Sandboxed"))
        XCTAssertTrue(NetworkAccessStatus(.init(app: app, helper: nil)).helperSummary.contains("wasn't found"))
        XCTAssertTrue(NetworkAccessStatus(.init(app: app, helper: E(sandboxed: true, networkClient: false)))
            .helperSummary.contains("no network"))
        XCTAssertTrue(NetworkAccessStatus(.init(app: app, helper: E(sandboxed: false, networkClient: true)))
            .helperSummary.contains("isn't sandboxed"))
    }

    func testDisclosureMatchesTheHelpersOwnAllowlist() {
        XCTAssertEqual(NetworkHelperDisclosure.hosts, HelperAllowlist.hosts)
    }

    func testDisclosureListsEveryDownload() {
        let lines = NetworkHelperDisclosure.downloads
        XCTAssertEqual(lines.count, 1 + WhisperModel.allCases.count + LlamaModel.allCases.count)
    }

    func testVerifyCommandNamesTheRunningBundle() {
        let command = NetworkHelperDisclosure.verifyCommand()
        XCTAssertTrue(command.hasPrefix("codesign -d --entitlements - \""))
        XCTAssertTrue(command.contains(Bundle.main.bundleURL.path))
    }

    /// The reader runs against real signatures: the test host has no helper
    /// bundle, so that reads as missing rather than crashing.
    func testReaderReturnsNilForMissingCode() {
        XCTAssertNil(EntitlementReader.entitlements(ofCodeAt: URL(fileURLWithPath: "/nonexistent/NetworkHelper.xpc")))
    }

    func testReaderReadsALiveSignedBinary() throws {
        // Apple-signed system binaries carry a signature; reading one must not fail.
        _ = EntitlementReader.entitlements(ofCodeAt: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertNotNil(EntitlementReader.ownEntitlements())
    }

    func testSettingsShowsTheCardInTheSecurityPane() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: repo.appendingPathComponent("Sources/App/Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("NetworkAccessView()"))
    }
}
