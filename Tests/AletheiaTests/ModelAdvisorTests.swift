import XCTest
@testable import Aletheia

final class ModelAdvisorTests: XCTestCase {
    private func hardware(appleSilicon: Bool, memGB: Int, cores: Int = 8) -> HardwareCapabilities {
        HardwareCapabilities(isAppleSilicon: appleSilicon, physicalMemoryGB: memGB, coreCount: cores, chipDescription: "Apple M-Test")
    }

    func testAppleSiliconHighMemoryGetsLargerModels() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 16))
        XCTAssertEqual(r.whisperModel, .mediumEn)
        XCTAssertEqual(r.medGemmaModel, .medgemma15_4b)
    }

    func testAppleSilicon32GBKeepsResponsiveDefault() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 32))
        XCTAssertEqual(r.whisperModel, .mediumEn)
        XCTAssertEqual(r.medGemmaModel, .medgemma15_4b)
    }

    func testAppleSilicon8GBGetsMidTier() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 8))
        XCTAssertEqual(r.whisperModel, .smallEn)
        XCTAssertEqual(r.medGemmaModel, .medgemma15_4b)
    }

    func testContextBudgetCapsAtModelContextWindow() {
        let mac32 = hardware(appleSilicon: true, memGB: 32)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac32, model: .medgemma_27b), 32_768)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac32, model: .medgemma15_4b), 65_536)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: hardware(appleSilicon: true, memGB: 48), model: .medgemma_27b), 65_536)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: hardware(appleSilicon: true, memGB: 32), model: .apertus8b_meditronFO), 65_536)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: hardware(appleSilicon: true, memGB: 16), model: .apertus8b_meditronFO), 32_768)
    }

    func testIntelGetsBaseTranscriptionAndFastEffort() {
        for memGB in [8, 16, 32] {
            let r = ModelAdvisor.recommend(for: hardware(appleSilicon: false, memGB: memGB))
            XCTAssertEqual(r.whisperModel, .baseEn, "\(memGB) GB")
            XCTAssertEqual(r.effort, .fast, "\(memGB) GB")
            XCTAssertEqual(r.medGemmaModel, .medgemma15_4b, "\(memGB) GB")
        }
    }

    func testAppleSiliconStartsAtDefaultEffort() {
        XCTAssertEqual(ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 8)).effort, .default)
    }

    func testIntelRunsInferenceOnTheCPU() {
        XCTAssertFalse(InferenceCompute.usesGPU(on: hardware(appleSilicon: false, memGB: 16)))
        XCTAssertTrue(InferenceCompute.usesGPU(on: hardware(appleSilicon: true, memGB: 16)))
    }

    func testCPUPathUsesOneThreadPerPhysicalCore() {
        XCTAssertEqual(InferenceCompute.cpuThreads(physicalCores: 4, activeCores: 8), 4)
        XCTAssertEqual(InferenceCompute.cpuThreads(physicalCores: 4, activeCores: 4), 4)
        XCTAssertEqual(InferenceCompute.cpuThreads(physicalCores: 8, activeCores: 2), 2)
        XCTAssertEqual(InferenceCompute.cpuThreads(physicalCores: 0, activeCores: 0), 1)
        XCTAssertGreaterThanOrEqual(InferenceCompute.cpuThreads, 1)
    }

    func testOnlyIntelWithoutAVX2IsRefused() {
        var oldIntel = hardware(appleSilicon: false, memGB: 8)
        oldIntel.hasAVX2 = false
        XCTAssertEqual(InferenceCompute.unsupportedReason(on: oldIntel), InferenceCompute.unsupportedCPUMessage)
        XCTAssertNil(InferenceCompute.unsupportedReason(on: hardware(appleSilicon: false, memGB: 8)))
        XCTAssertNil(InferenceCompute.unsupportedReason(on: hardware(appleSilicon: true, memGB: 8)))
    }

    func testStoredEffortWinsOverIntelDefault() {
        let suite = "ModelAdvisorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let intel = hardware(appleSilicon: false, memGB: 8)
        AppSettings(defaults: defaults, hardware: intel) { _ in false }.noteEffort = .focus
        let reopened = AppSettings(defaults: defaults, hardware: intel) { _ in false }
        XCTAssertEqual(reopened.noteEffort, .focus)
        XCTAssertEqual(reopened.sessionChatEffort, .fast)
    }

    func testLowMemoryGetsSmallestModels() {
        let r = ModelAdvisor.recommend(for: hardware(appleSilicon: true, memGB: 4))
        XCTAssertEqual(r.whisperModel, .baseEn)
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
        XCTAssertFalse(r.summary.isEmpty)
    }
}
