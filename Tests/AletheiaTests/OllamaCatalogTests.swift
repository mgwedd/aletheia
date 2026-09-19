import XCTest
@testable import Aletheia

final class OllamaCatalogTests: XCTestCase {
    func testContainsKnownTagsAndRejectsUnknown() {
        XCTAssertTrue(OllamaCatalog.contains("llama3.2:3b"))
        XCTAssertFalse(OllamaCatalog.contains("qwen2.5:7b"))
        XCTAssertFalse(OllamaCatalog.contains(""))
        XCTAssertFalse(OllamaCatalog.contains(OllamaCatalog.customTag))
    }

    func testOptionsAreOrderedLightestToHeaviest() {
        let sizes = OllamaCatalog.options.map(\.approxSizeGB)
        XCTAssertEqual(sizes, sizes.sorted(), "catalog should read lightest → heaviest")
        XCTAssertFalse(OllamaCatalog.options.isEmpty)
    }

    func testOptionLookupMatchesTag() {
        XCTAssertEqual(OllamaCatalog.option(for: "llama3.1:8b")?.label, "Llama 3.1 8B")
        XCTAssertNil(OllamaCatalog.option(for: "nope"))
    }

    func testRecommendedDefaultsAreInTheCatalog() {
        // The hardware recommendation should map onto a pickable rung so the
        // "Recommended for your Mac" hint always points at a real option.
        for gb in [6, 8, 16, 32] {
            let hw = HardwareCapabilities(isAppleSilicon: true, physicalMemoryGB: gb, coreCount: 8, chipDescription: "Test")
            let rec = ModelAdvisor.recommend(for: hw)
            XCTAssertTrue(OllamaCatalog.contains(rec.ollamaModel), "\(rec.ollamaModel) should be a catalog option")
        }
    }
}
