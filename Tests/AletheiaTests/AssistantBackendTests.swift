import XCTest
@testable import Aletheia

final class AssistantBackendResolverTests: XCTestCase {
    // MARK: Automatic prefers Apple Intelligence, else the built-in engine

    func testAutomaticPrefersAppleIntelligenceWhenAvailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true)
        XCTAssertEqual(r.resolve(.automatic), .appleIntelligence)
    }

    func testAutomaticFallsToTheBuiltInEngineWhenNoAppleIntelligence() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false)
        XCTAssertEqual(r.resolve(.automatic), .localLlama)
    }

    // MARK: Explicit choices are honored when available, else fall back to the built-in engine

    func testExplicitAppleIntelligenceHonoredWhenAvailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true)
        XCTAssertEqual(r.resolve(.appleIntelligence), .appleIntelligence)
    }

    func testExplicitAppleIntelligenceFallsBackToTheBuiltInEngineWhenUnavailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false)
        XCTAssertEqual(r.resolve(.appleIntelligence), .localLlama)
    }

    func testExplicitBuiltInEngineIsAlwaysTheBuiltInEngine() {
        for available in [false, true] {
            let r = AssistantBackendResolver(appleIntelligenceAvailable: available)
            XCTAssertEqual(r.resolve(.localLlama), .localLlama)
        }
    }

    // MARK: Stored preference (older versions stored other values)

    func testStoredPreferenceDecodesKnownValues() {
        for backend in AssistantBackend.allCases {
            XCTAssertEqual(AssistantBackendResolver.preference(fromStored: backend.rawValue), backend)
        }
    }

    func testRetiredOrUnknownStoredPreferenceMeansAutomatic() {
        // "ollama" is the value an older version stored for the server engine.
        XCTAssertEqual(AssistantBackendResolver.preference(fromStored: "ollama"), .automatic) // legacy-key
        XCTAssertEqual(AssistantBackendResolver.preference(fromStored: "somethingNew"), .automatic)
        XCTAssertEqual(AssistantBackendResolver.preference(fromStored: ""), .automatic)
        XCTAssertEqual(AssistantBackendResolver.preference(fromStored: nil), .automatic)
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

    /// A build without the embedded llama.cpp module in the registry must not
    /// offer "Built-in model" (see `EmbeddedLlamaFeatureModule`).
    func testProductionLikeBuildHidesLocalLlama() {
        let options = AssistantBackend.selectableOptions(embeddedLlamaAvailable: false, appleIntelligenceBlocked: true)
        XCTAssertFalse(options.contains(.localLlama))
        XCTAssertTrue(options.contains(.automatic))
    }

    /// With the embedded runtime module present (every shipping tier),
    /// "Built-in model" is offered.
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

    /// `.automatic` is always offered; every build has a safe default.
    func testAutomaticIsAlwaysOffered() {
        for embeddedLlamaAvailable in [false, true] {
            for appleIntelligenceBlocked in [false, true] {
                let options = AssistantBackend.selectableOptions(embeddedLlamaAvailable: embeddedLlamaAvailable, appleIntelligenceBlocked: appleIntelligenceBlocked)
                XCTAssertTrue(options.contains(.automatic))
            }
        }
    }
}
