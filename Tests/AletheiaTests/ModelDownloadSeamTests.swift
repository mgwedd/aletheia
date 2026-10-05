import XCTest
@testable import Aletheia

/// The model-download seam lets the distribution mechanism change (direct
/// download now; Background Assets / CDN / App Store later) without touching the
/// callers that ask for a model. The HTTP implementation needs the network, so
/// what's pinned here is the source-agnostic contract: `LlamaModel → ModelAsset`
/// mapping, and that a consumer coded against `ModelDownloadProvider` works with
/// any conforming provider.
final class ModelDownloadSeamTests: XCTestCase {

    func testLlamaModelMapsToAsset() {
        for model in LlamaModel.allCases {
            let asset = model.asset
            XCTAssertEqual(asset.id, model.rawValue)
            XCTAssertEqual(asset.fileName, model.fileName)
            XCTAssertEqual(asset.remoteURL, model.downloadURL)
            XCTAssertEqual(asset.expectedSHA256, model.expectedSHA256)
            XCTAssertEqual(asset.approximateSizeMB, model.approximateSizeMB)
        }
    }

    @MainActor
    func testConsumerDrivesAnyProviderThroughTheProtocol() async throws {
        let fake = FakeModelDownloadProvider()
        // Use it only through the protocol — the point of the seam.
        let provider: ModelDownloadProvider = fake

        var progress: [Double] = []
        let dest = URL(fileURLWithPath: "/tmp/aletheia-test/model.gguf")
        try await provider.fetch(LlamaModel.llama32_3b.asset, to: dest) { progress.append($0) }

        XCTAssertEqual(fake.fetchedAssets.map(\.id), [LlamaModel.llama32_3b.rawValue])
        XCTAssertEqual(fake.destinations, [dest])
        XCTAssertEqual(progress.last, 1.0, "a completed fetch must report full progress")
        XCTAssertEqual(progress, progress.sorted(), "progress must be monotonically non-decreasing")
    }

    @MainActor
    func testIntegrityMismatchIsSurfacedToTheCaller() async {
        let provider = FakeModelDownloadProvider()
        provider.simulateIntegrityMismatch = true

        // A pinned asset (non-nil digest) that the provider will reject.
        let pinned = ModelAsset(
            id: "pinned", fileName: "pinned.gguf",
            remoteURL: URL(string: "https://example.invalid/pinned.gguf")!,
            expectedSHA256: "deadbeef", approximateSizeMB: 1)

        do {
            try await provider.fetch(pinned, to: URL(fileURLWithPath: "/tmp/pinned.gguf")) { _ in }
            XCTFail("a digest mismatch must throw so a corrupt model is never accepted")
        } catch {
            XCTAssertTrue(error is FakeModelDownloadProvider.Failure)
        }
    }
}

/// A no-network `ModelDownloadProvider` used to exercise the seam's contract.
@MainActor
private final class FakeModelDownloadProvider: ModelDownloadProvider {
    enum Failure: Error { case integrityMismatch }

    var simulateIntegrityMismatch = false
    private(set) var fetchedAssets: [ModelAsset] = []
    private(set) var destinations: [URL] = []

    func fetch(
        _ asset: ModelAsset,
        to destinationURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        fetchedAssets.append(asset)
        destinations.append(destinationURL)
        for step in stride(from: 0.0, through: 1.0, by: 0.25) { onProgress(step) }
        if simulateIntegrityMismatch, asset.expectedSHA256 != nil {
            throw Failure.integrityMismatch
        }
    }
}
