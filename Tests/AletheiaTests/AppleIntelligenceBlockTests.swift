import XCTest
@testable import Aletheia

@MainActor
final class AppleIntelligenceBlockTests: XCTestCase {
    func testAppleIntelligenceIsBlockedAndNeverAvailable() {
        // Guardrail: Apple Intelligence is intentionally disabled for now, so
        // patient data only ever reaches backends we can prove stay on-device.
        XCTAssertTrue(Integrations.appleIntelligenceBlocked)
        XCTAssertFalse(Integrations.appleIntelligenceAvailable)
    }

    func testAutomaticResolvesToTheBuiltInEngineWhenAppleIntelligenceUnavailable() {
        let resolver = AssistantBackendResolver(appleIntelligenceAvailable: false)
        XCTAssertEqual(resolver.resolve(.automatic), .localLlama)

        // Even an explicit Apple Intelligence preference falls back to the built-in engine.
        XCTAssertEqual(resolver.resolve(.appleIntelligence), .localLlama)
    }
}
