import XCTest
@testable import Aletheia

/// `OllamaAppLocator` takes its lookups as injected closures specifically so
/// this can run without `NSWorkspace` or a real `/Applications` — no Mac,
/// filesystem, or app install required.
final class OllamaAppLocatorTests: XCTestCase {
    func testFindsAppByFirstMatchingBundleIdentifier() {
        let expected = URL(fileURLWithPath: "/Applications/Ollama.app")
        let url = OllamaAppLocator.locate(
            urlForBundleIdentifier: { $0 == OllamaAppLocator.knownBundleIdentifiers.first ? expected : nil },
            fileExists: { _ in XCTFail("shouldn't fall back to the path check when a bundle id matched"); return false }
        )
        XCTAssertEqual(url, expected)
    }

    func testTriesEveryKnownBundleIdentifierBeforeGivingUpOnThatRoute() {
        var queried: [String] = []
        _ = OllamaAppLocator.locate(
            urlForBundleIdentifier: { queried.append($0); return nil },
            fileExists: { _ in false }
        )
        XCTAssertEqual(queried, OllamaAppLocator.knownBundleIdentifiers)
    }

    func testFallsBackToApplicationsPathWhenNoBundleIdentifierMatches() {
        let url = OllamaAppLocator.locate(
            urlForBundleIdentifier: { _ in nil },
            fileExists: { $0 == OllamaAppLocator.fallbackApplicationPath }
        )
        XCTAssertEqual(url?.path, OllamaAppLocator.fallbackApplicationPath)
    }

    func testNotInstalledWhenNothingMatches() {
        let url = OllamaAppLocator.locate(
            urlForBundleIdentifier: { _ in nil },
            fileExists: { _ in false }
        )
        XCTAssertNil(url)
        XCTAssertFalse(OllamaAppLocator.isInstalled(
            urlForBundleIdentifier: { _ in nil },
            fileExists: { _ in false }
        ))
    }

    func testIsInstalledTrueWhenLocateSucceeds() {
        XCTAssertTrue(OllamaAppLocator.isInstalled(
            urlForBundleIdentifier: { _ in URL(fileURLWithPath: "/Applications/Ollama.app") },
            fileExists: { _ in false }
        ))
    }
}
