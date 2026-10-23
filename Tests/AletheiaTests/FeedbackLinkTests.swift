import XCTest
@testable import Aletheia

final class FeedbackLinkTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testTheLinkOpensTheFormOnAstreaLabs() throws {
        let url = FeedbackLink.url(.bug, environment: "x")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "astrealabs.com")
        XCTAssertEqual(url.path, "/feedback")
        XCTAssertNil(url.fragment)
    }

    func testTheLinkCarriesOnlyTheAllowedKeys() {
        for kind in [FeedbackLink.Kind.bug, .feature] {
            let keys = Set(query(FeedbackLink.url(kind)).keys)
            XCTAssertEqual(keys, FeedbackLink.allowedQueryKeys)
        }
    }

    func testTheProjectAndTypeMatchTheForm() {
        XCTAssertEqual(query(FeedbackLink.url(.bug))["project"], "aletheia")
        XCTAssertEqual(query(FeedbackLink.url(.bug))["type"], "bug")
        XCTAssertEqual(query(FeedbackLink.url(.feature))["type"], "feature")
    }

    func testTheEnvironmentNamesVersionTierMacOSAndChip() {
        let text = FeedbackLink.environment(
            appVersion: "1.4.2", tier: .preview,
            macOS: OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 1),
            appleSilicon: true)
        XCTAssertEqual(text, "Aletheia 1.4.2 (preview), macOS 15.3.1, Apple silicon")

        let intel = FeedbackLink.environment(
            appVersion: "1.0", tier: .production,
            macOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            appleSilicon: false)
        XCTAssertEqual(intel, "Aletheia 1.0 (production), macOS 14.0.0, Intel")
    }

    func testTheEnvironmentSurvivesTheRoundTrip() {
        let env = "Aletheia 1.4.2 (dev), macOS 15.3.1, Apple silicon"
        XCTAssertEqual(query(FeedbackLink.url(.bug, environment: env))["environment"], env)
    }

    /// Nothing that identifies the user or the Mac goes in the link.
    func testTheLinkCarriesNothingAboutTheUserOrTheMac() {
        let text = FeedbackLink.url(.bug).absoluteString.removingPercentEncoding ?? ""
        let identifying = [
            NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName,
            Host.current().localizedName ?? "", NSHomeDirectory(),
        ].filter { $0.count >= 3 }
        for value in identifying {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(value), "link contains \(value)")
        }
    }
}
