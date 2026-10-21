import XCTest
@testable import Aletheia

/// The fine-tuned / LoRA seam: a downloadable adapter reuses the model-download
/// seam (`ModelAsset`), and a `ModelLoadPlan` can only be built when the adapter
/// matches its base — so a mismatched adapter fails closed with a clear error
/// before any weights load. On-device application of the adapter is the Mac step;
/// what's pinned here is the source-agnostic, runtime-free contract.
final class FineTunedModelTests: XCTestCase {

    /// A therapy adapter trained against the recommended base (Llama 3.1 8B).
    private func therapyAdapter(
        base: LlamaModel = .llama31_8b,
        sha: String = "abc123"
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
        XCTAssertEqual(therapyAdapter(base: .llama31_8b).baseModel, .llama31_8b)
        // An adapter naming a base the app doesn't know about resolves to nil
        // rather than crashing — the compatibility check still fails it closed.
        let unknown = LoRAAdapter(
            id: "x", displayName: "X", fileName: "x.gguf",
            remoteURL: URL(string: "https://example.invalid/x.gguf")!,
            expectedSHA256: "abc123", approximateSizeMB: 1, baseModelID: "not-a-real-model")
        XCTAssertNil(unknown.baseModel)
    }

    // MARK: - Compatibility (fail closed)

    func testCompatibleAdapterMatchesItsBase() {
        let adapter = therapyAdapter(base: .llama31_8b)
        XCTAssertTrue(adapter.isCompatible(with: .llama31_8b))
        XCTAssertNoThrow(try adapter.validate(against: .llama31_8b))
    }

    func testMismatchedAdapterFailsClosedWithClearError() {
        let adapter = therapyAdapter(base: .llama31_8b)
        XCTAssertFalse(adapter.isCompatible(with: .gemma4_e2b))
        XCTAssertThrowsError(try adapter.validate(against: .gemma4_e2b)) { error in
            guard case let LoRACompatibilityError.baseMismatch(name, expected, actual) = error else {
                return XCTFail("expected a baseMismatch, got \(error)")
            }
            XCTAssertEqual(name, adapter.displayName)
            XCTAssertEqual(expected, LlamaModel.llama31_8b.shortName)
            XCTAssertEqual(actual, LlamaModel.gemma4_e2b.shortName)
            // The message names both sides so the user can fix the pairing.
            let message = (error as? LoRACompatibilityError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains(LlamaModel.llama31_8b.shortName))
            XCTAssertTrue(message.contains(LlamaModel.gemma4_e2b.shortName))
        }
    }

    // MARK: - ModelLoadPlan

    func testPlanWithoutAdapterUsesBaseOnly() {
        let plan = ModelLoadPlan(base: .llama31_8b)
        XCTAssertFalse(plan.usesAdapter)
        XCTAssertNil(plan.adapter)
        XCTAssertNil(plan.adapterURL)
        XCTAssertEqual(plan.baseURL, LlamaRuntime.modelURL(for: .llama31_8b))
    }

    func testPlanWithCompatibleAdapterResolvesBothURLs() throws {
        let adapter = therapyAdapter(base: .llama31_8b)
        let plan = try ModelLoadPlan(base: .llama31_8b, adapter: adapter)
        XCTAssertTrue(plan.usesAdapter)
        XCTAssertEqual(plan.adapter, adapter)
        XCTAssertEqual(plan.baseURL, LlamaRuntime.modelURL(for: .llama31_8b))
        XCTAssertEqual(plan.adapterURL, LlamaRuntime.adapterURL(for: adapter))
    }

    func testPlanRejectsMismatchedAdapter() {
        let adapter = therapyAdapter(base: .llama31_8b)
        XCTAssertThrowsError(try ModelLoadPlan(base: .gemma4_e2b, adapter: adapter)) { error in
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
        // The plan routes through the same seam, proving adapter selection needs
        // no call-site change. With the runtime linked the engine is the real one
        // (weights absent here, so it must fail to load rather than answer).
        let plan = ModelLoadPlan(base: .llama31_8b)
        let engine = LocalLLMEngineFactory.make(plan: plan)
        if case .unavailable = engine.state {
            XCTAssertFalse(LlamaRuntime.isBuilt, "an unavailable engine means the runtime isn't linked")
        }
        do {
            _ = try await engine.generate(LocalLLMRequest(prompt: "hi"))
            XCTFail("an engine without weights must throw rather than answer")
        } catch {
            XCTAssertTrue(error is LocalLLMEngineError)
        }
    }
}
