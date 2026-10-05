import XCTest
@testable import Aletheia

final class ModelAdvisorTests: XCTestCase {
    private func hardware(appleSilicon: Bool, memGB: Int, cores: Int = 8) -> HardwareCapabilities {
        HardwareCapabilities(isAppleSilicon: appleSilicon, physicalMemoryGB: memGB, coreCount: cores, chipDescription: "Apple M-Test")
    }

    func testAppleSiliconHighMemoryGetsLargerModels() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 16))
        XCTAssertEqual(r.whisperModel, .mediumEn)
        XCTAssertEqual(r.ollamaModel, "llama3.1:8b")
    }

    func testAppleSilicon8GBGetsMidTier() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 8))
        XCTAssertEqual(r.whisperModel, .smallEn)
        XCTAssertEqual(r.ollamaModel, "llama3.2:3b")
    }

    func testIntel16GBKeepsTranscriptionLighter() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: false, memGB: 16))
        XCTAssertEqual(r.whisperModel, .smallEn)
        XCTAssertEqual(r.ollamaModel, "llama3.1:8b")
    }

    func testLowMemoryGetsSmallestModels() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 4))
        XCTAssertEqual(r.whisperModel, .baseEn)
        XCTAssertEqual(r.ollamaModel, "llama3.2:1b")
    }

    func testSummaryMentionsHardwareAndModel() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 16))
        XCTAssertTrue(r.summary.contains("Apple M-Test"))   // the detected chip
        XCTAssertTrue(r.summary.contains("16 GB"))
        XCTAssertTrue(r.summary.contains("Medium"))
    }

    func testCurrentHardwareProducesAValidRecommendation() {
        // Whatever the CI runner is, this must not crash and must pick a real model.
        let r = ModelAdvisor.current()
        XCTAssertTrue(WhisperModel.allCases.contains(r.whisperModel))
        XCTAssertFalse(r.ollamaModel.isEmpty)
    }
}
