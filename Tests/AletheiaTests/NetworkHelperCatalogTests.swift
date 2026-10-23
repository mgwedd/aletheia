import XCTest
@testable import Aletheia

/// The helper's compiled-in table of downloads and hosts.
final class NetworkHelperCatalogTests: XCTestCase {
    func testEveryFixedURLIsHTTPSOnAnAllowlistedHost() {
        for asset in HelperAsset.allCases {
            guard let url = asset.fixedURL else { continue }
            XCTAssertEqual(url.scheme, "https", "\(asset)")
            XCTAssertTrue(HelperAllowlist.allows(url), "\(asset) -> \(url)")
        }
    }

    /// Only the update archive has no fixed URL; the helper resolves it.
    func testOnlyTheUpdateArchiveHasNoFixedURL() {
        let unfixed = HelperAsset.allCases.filter { $0.fixedURL == nil }
        XCTAssertEqual(unfixed, [.updateArchive])
    }

    func testHelperAndAppAgreeOnEveryAssetID() {
        XCTAssertEqual(Set(HelperAsset.allCases.map(\.rawValue)), Set(AssetID.allCases.map(\.rawValue)))
    }

    func testEveryWhisperModelMapsToItsPinnedURL() throws {
        for model in WhisperModel.allCases {
            let helper = try XCTUnwrap(HelperAsset(rawValue: AssetID(model).rawValue))
            XCTAssertEqual(helper.fixedURL, model.downloadURL, "\(model)")
        }
    }

    func testEveryLlamaModelMapsToItsPinnedURL() throws {
        for model in LlamaModel.allCases {
            let helper = try XCTUnwrap(HelperAsset(rawValue: AssetID(model).rawValue))
            XCTAssertEqual(helper.fixedURL, model.downloadURL, "\(model)")
        }
    }

    func testAllowlistRejectsEverythingElse() throws {
        let rejected = [
            "http://huggingface.co/x",
            "https://example.com/x",
            "https://huggingface.co.evil.com/x",
            "https://evilhuggingface.co/x",
            "https://user:pw@huggingface.co/x",
            "https://huggingface.co:8443/x",
            "ftp://huggingface.co/x",
            "file:///etc/passwd",
            "https://127.0.0.1/x",
        ]
        for raw in rejected {
            XCTAssertFalse(HelperAllowlist.allows(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in ["https://huggingface.co/x", "https://cdn-lfs.hf.co/x", "https://objects.githubusercontent.com/x"] {
            XCTAssertTrue(HelperAllowlist.allows(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    /// Our own hosts match exactly: no lookalike, no other subdomain, no other port or scheme.
    func testAstreaLabsMatchesOnlyItsExactHosts() throws {
        let rejected = [
            "https://evilastrealabs.com/api/licenses/revocations",
            "https://astrealabs.com.evil.com/api/licenses/revocations",
            "https://www.astrealabs.com/api/licenses/revocations",
            "https://preview.astrealabs.com/api/licenses/revocations",
            "https://x.aletheia.astrealabs.com/api/licenses/revocations",
            "https://evilaletheia.astrealabs.com/api/licenses/revocations",
            "https://aletheia.astrealabs.com.evil.com/api/licenses/revocations",
            "https://aletheia.astrealabs.com:8443/api/licenses/revocations",
            "https://astrealabs.co/api/licenses/revocations",
            "https://astrealabs.com:8443/api/licenses/revocations",
            "http://astrealabs.com/api/licenses/revocations",
            "https://user@astrealabs.com/api/licenses/revocations",
        ]
        for raw in rejected {
            XCTAssertFalse(HelperAllowlist.allows(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in [
            "https://astrealabs.com/api/licenses/revocations",
            "https://ASTREALABS.com/x",
            "https://aletheia.astrealabs.com/api/licenses/revocations",
        ] {
            XCTAssertTrue(HelperAllowlist.allows(try XCTUnwrap(URL(string: raw))), raw)
        }
        XCTAssertTrue(HelperAllowlist.exactOnly.isSubset(of: Set(HelperAllowlist.hosts)))
    }

    func testUpdateArchiveMustBeThisRepositorysReleaseAsset() throws {
        XCTAssertTrue(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "https://github.com/mgwedd/aletheia/releases/download/v1.0.0/Aletheia.dmg"))))
        XCTAssertFalse(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "https://github.com/other/repo/releases/download/v1/x.dmg"))))
        XCTAssertFalse(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "https://huggingface.co/mgwedd/aletheia/releases/download/v1/x.dmg"))))
        XCTAssertFalse(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "http://github.com/mgwedd/aletheia/releases/download/v1/x.dmg"))))
        // Dot segments, plain or percent-encoded, can't climb out of this repo.
        for raw in [
            "https://github.com/mgwedd/aletheia/releases/download/../../../other/repo/releases/download/v1/x.dmg",
            "https://github.com/mgwedd/aletheia/releases/download/%2e%2e/%2E%2E/x.dmg",
            "https://github.com/mgwedd/aletheia/releases/download/./v1/x.dmg",
        ] {
            XCTAssertFalse(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testAppcastEndpointIsAllowed() {
        XCTAssertTrue(HelperAllowlist.allows(HelperEndpoints.appcast))
    }

    func testRevocationEndpointIsAFixedHTTPSURLWithNoQuery() {
        let url = HelperEndpoints.revocations
        XCTAssertTrue(HelperAllowlist.allows(url))
        XCTAssertEqual(url.absoluteString, "https://astrealabs.com/api/licenses/revocations")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }
}
