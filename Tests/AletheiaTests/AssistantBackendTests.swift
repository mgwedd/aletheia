import XCTest
@testable import Aletheia

final class AssistantBackendResolverTests: XCTestCase {
    // MARK: Automatic prefers on-device, in order

    func testAutomaticPrefersAppleIntelligenceWhenAvailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true, localLlamaAvailable: true)
        XCTAssertEqual(r.resolve(.automatic), .appleIntelligence)
    }

    func testAutomaticFallsToLocalLlamaWhenNoAppleIntelligence() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: true)
        XCTAssertEqual(r.resolve(.automatic), .localLlama)
    }

    func testAutomaticFallsToOllamaWhenNothingOnDevice() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.automatic), .ollama)
    }

    // MARK: Explicit choices are honored when available, else fall back safely

    func testExplicitAppleIntelligenceHonoredWhenAvailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.appleIntelligence), .appleIntelligence)
    }

    func testExplicitAppleIntelligenceFallsBackWhenUnavailable() {
        // No on-device runtime → falls to Ollama rather than failing.
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.appleIntelligence), .ollama)

        // Embedded runtime present → prefer that over Ollama.
        let withLlama = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: true)
        XCTAssertEqual(withLlama.resolve(.appleIntelligence), .localLlama)
    }

    func testExplicitLocalLlamaFallsBackWhenUnavailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.localLlama), .ollama)
    }

    func testExplicitOllamaAlwaysResolvesToOllama() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true, localLlamaAvailable: true)
        XCTAssertEqual(r.resolve(.ollama), .ollama)
    }

    // MARK: Enum surface used by the settings picker

    func testAllBackendsAreSelectableAndDescribed() {
        for backend in AssistantBackend.allCases {
            XCTAssertFalse(backend.displayName.isEmpty)
            XCTAssertFalse(backend.summary.isEmpty)
        }
        // Round-trips through its raw value (how it's persisted).
        for backend in AssistantBackend.allCases {
            XCTAssertEqual(AssistantBackend(rawValue: backend.rawValue), backend)
        }
    }

    // MARK: selectableOptions — the picker's gating, pulled out so it's testable
    // without a view or a `FeatureRegistry` instance.

    /// A production build: the embedded llama.cpp module isn't in the
    /// registry, so "Built-in model" must not be offered — the leak this whole
    /// function exists to prevent (see `EmbeddedLlamaFeatureModule`).
    func testProductionLikeBuildHidesLocalLlama() {
        let options = AssistantBackend.selectableOptions(embeddedLlamaAvailable: false, appleIntelligenceBlocked: true)
        XCTAssertFalse(options.contains(.localLlama))
        XCTAssertTrue(options.contains(.automatic))
        XCTAssertTrue(options.contains(.ollama))
    }

    /// A dev build with the embedded runtime module present: "Built-in model"
    /// is offered.
    func testDevLikeBuildOffersLocalLlamaWhenModulePresent() {
        let options = AssistantBackend.selectableOptions(embeddedLlamaAvailable: true, appleIntelligenceBlocked: true)
        XCTAssertTrue(options.contains(.localLlama))
    }

    /// Apple Intelligence is withheld while `Integrations.appleIntelligenceBlocked`
    /// holds it off, independent of the embedded-runtime flag.
    func testAppleIntelligenceHiddenWhileBlockedRegardlessOfLocalLlama() {
        XCTAssertFalse(AssistantBackend.selectableOptions(embeddedLlamaAvailable: true, appleIntelligenceBlocked: true).contains(.appleIntelligence))
        XCTAssertFalse(AssistantBackend.selectableOptions(embeddedLlamaAvailable: false, appleIntelligenceBlocked: true).contains(.appleIntelligence))
    }

    func testAppleIntelligenceOfferedWhenNotBlocked() {
        XCTAssertTrue(AssistantBackend.selectableOptions(embeddedLlamaAvailable: false, appleIntelligenceBlocked: false).contains(.appleIntelligence))
    }

    /// `.automatic` and `.ollama` are always offered — every build has a safe
    /// default and Ollama is always installable.
    func testAutomaticAndOllamaAreAlwaysOffered() {
        for embeddedLlamaAvailable in [false, true] {
            for appleIntelligenceBlocked in [false, true] {
                let options = AssistantBackend.selectableOptions(embeddedLlamaAvailable: embeddedLlamaAvailable, appleIntelligenceBlocked: appleIntelligenceBlocked)
                XCTAssertTrue(options.contains(.automatic))
                XCTAssertTrue(options.contains(.ollama))
            }
        }
    }
}
