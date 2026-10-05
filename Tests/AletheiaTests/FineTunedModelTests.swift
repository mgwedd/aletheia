import XCTest
@testable import Aletheia

/// The fine-tuned / LoRA seam: a downloadable adapter reuses the model-download
/// seam (`ModelAsset`), and a `ModelLoadPlan` can only be built when the adapter
/// matches its base — so a mismatched adapter fails closed with a clear error
/// before any weights load. On-device application of the adapter is the Mac step;
/// what's pinned here is the source-agnostic, runtime-free contract.
final class FineTunedModelTests: XCTestCase {

    /// A therapy adapter trained against the recommended 3B base.
    private func therapyAdapter(
        base: LlamaModel = .llama32_3b,
        sha: String? = "abc123"
    ) -> LoRAAdapter {
        LoRAAdapter(
            id: "therapy-soap-v1",
            displayName: "Therapy notes (SOAP) v1",
            fileName: "therapy-soap-v1.gguf",
            remoteURL: URL(string: "https://huggingface.co/example/therapy-lora/resolve/main/therapy-soap-v1.gguf")!,
            expectedSHA256: sha,
            approximateSizeMB: 48,
            baseModelID: base.rawValue
        )
    }

    // MARK: - Adapter → download seam

    func testAdapterMapsToDownloadableAsset() {
        let adapter = therapyAdapter()
        let asset = adapter.asset
        XCTAssertEqual(asset.id, adapter.id)
        XCTAssertEqual(asset.fileName, adapter.fileName)
        XCTAssertEqual(asset.remoteURL, adapter.remoteURL)
        XCTAssertEqual(asset.expectedSHA256, adapter.expectedSHA256)
        XCTAssertEqual(asset.approximateSizeMB, adapter.approximateSizeMB)
    }

    func testAdapterResolvesItsBaseModel() {
        XCTAssertEqual(therapyAdapter(base: .llama32_3b).baseModel, .llama32_3b)
        // An adapter naming a base the app doesn't know about resolves to nil
        // rather than crashing — the compatibility check still fails it closed.
        let unknown = LoRAAdapter(
            id: "x", displayName: "X", fileName: "x.gguf",
            remoteURL: URL(string: "https://example.invalid/x.gguf")!,
            expectedSHA256: nil, approximateSizeMB: 1, baseModelID: "not-a-real-model")
        XCTAssertNil(unknown.baseModel)
    }

    // MARK: - Compatibility (fail closed)

    func testCompatibleAdapterMatchesItsBase() {
        let adapter = therapyAdapter(base: .llama32_3b)
        XCTAssertTrue(adapter.isCompatible(with: .llama32_3b))
        XCTAssertNoThrow(try adapter.validate(against: .llama32_3b))
    }

    func testMismatchedAdapterFailsClosedWithClearError() {
        let adapter = therapyAdapter(base: .llama32_3b)
        XCTAssertFalse(adapter.isCompatible(with: .llama32_1b))
        XCTAssertThrowsError(try adapter.validate(against: .llama32_1b)) { error in
            guard case let LoRACompatibilityError.baseMismatch(name, expected, actual) = error else {
                return XCTFail("expected a baseMismatch, got \(error)")
            }
            XCTAssertEqual(name, adapter.displayName)
            XCTAssertEqual(expected, LlamaModel.llama32_3b.shortName)
            XCTAssertEqual(actual, LlamaModel.llama32_1b.shortName)
            // The message names both sides so the user can fix the pairing.
            let message = (error as? LoRACompatibilityError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains(LlamaModel.llama32_3b.shortName))
            XCTAssertTrue(message.contains(LlamaModel.llama32_1b.shortName))
        }
    }

    // MARK: - ModelLoadPlan

    func testPlanWithoutAdapterUsesBaseOnly() {
        let plan = ModelLoadPlan(base: .llama32_3b)
        XCTAssertFalse(plan.usesAdapter)
        XCTAssertNil(plan.adapter)
        XCTAssertNil(plan.adapterURL)
        XCTAssertEqual(plan.baseURL, LlamaRuntime.modelURL(for: .llama32_3b))
    }

    func testPlanWithCompatibleAdapterResolvesBothURLs() throws {
        let adapter = therapyAdapter(base: .llama32_3b)
        let plan = try ModelLoadPlan(base: .llama32_3b, adapter: adapter)
        XCTAssertTrue(plan.usesAdapter)
        XCTAssertEqual(plan.adapter, adapter)
        XCTAssertEqual(plan.baseURL, LlamaRuntime.modelURL(for: .llama32_3b))
        XCTAssertEqual(plan.adapterURL, LlamaRuntime.adapterURL(for: adapter))
    }

    func testPlanRejectsMismatchedAdapter() {
        let adapter = therapyAdapter(base: .llama32_3b)
        XCTAssertThrowsError(try ModelLoadPlan(base: .llama32_1b, adapter: adapter)) { error in
            XCTAssertTrue(error is LoRACompatibilityError)
        }
    }

    // MARK: - Storage layout

    func testAdapterURLIsUnderAdaptersSubfolder() {
        let adapter = therapyAdapter()
        let url = LlamaRuntime.adapterURL(for: adapter)
        XCTAssertEqual(url.lastPathComponent, adapter.fileName)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Adapters")
        // Adapters live beside base weights, not tangled with them.
        XCTAssertEqual(
            url.deletingLastPathComponent().deletingLastPathComponent(),
            LlamaRuntime.modelsDirectory)
    }

    // MARK: - Engine factory routes a plan without changing call sites

    func testFactoryAcceptsAPlanAndDegradesGracefully() async {
        // No runtime linked in CI, so the engine is Unavailable — but the plan
        // routes through the same seam, proving adapter selection needs no
        // call-site change. (On-device this returns the real engine.)
        let plan = ModelLoadPlan(base: .llama32_3b)
        let engine = LocalLLMEngineFactory.make(plan: plan)
        if case .unavailable = engine.state {} else {
            XCTFail("without the runtime linked the engine must be unavailable")
        }
        do {
            _ = try await engine.generate(LocalLLMRequest(prompt: "hi"))
            XCTFail("an unavailable engine must throw rather than answer")
        } catch {
            XCTAssertTrue(error is LocalLLMEngineError)
        }
    }
}
