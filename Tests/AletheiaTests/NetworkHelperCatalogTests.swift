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

    func testUpdateArchiveMustBeThisRepositorysReleaseAsset() throws {
        XCTAssertTrue(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "https://github.com/mgwedd/aletheia/releases/download/v1.0.0/Aletheia.dmg"))))
        XCTAssertFalse(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "https://github.com/other/repo/releases/download/v1/x.dmg"))))
        XCTAssertFalse(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "https://huggingface.co/mgwedd/aletheia/releases/download/v1/x.dmg"))))
        XCTAssertFalse(HelperEndpoints.isUpdateArchive(try XCTUnwrap(URL(string: "http://github.com/mgwedd/aletheia/releases/download/v1/x.dmg"))))
    }

    func testAppcastEndpointIsAllowed() {
        XCTAssertTrue(HelperAllowlist.allows(HelperEndpoints.appcast))
    }
}
