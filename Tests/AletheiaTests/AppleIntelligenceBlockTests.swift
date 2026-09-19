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

    func testAutomaticResolvesToLocalBackendsWhenAppleIntelligenceUnavailable() {
        let noLocal = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: false)
        XCTAssertEqual(noLocal.resolve(.automatic), .ollama)

        let withLocal = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: true)
        XCTAssertEqual(withLocal.resolve(.automatic), .localLlama)

        // Even an explicit Apple Intelligence preference falls back to local.
        XCTAssertEqual(noLocal.resolve(.appleIntelligence), .ollama)
    }
}
