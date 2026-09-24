import XCTest
@testable import Aletheia

/// `BuildTier` is the composition axis: an ordered, nested set of build tiers.
/// These pin the ordering and the "a build includes everything at or below it"
/// rule the whole modular system rests on.
final class BuildTierTests: XCTestCase {
    func testOrderingIsProductionThroughDev() {
        XCTAssertLessThan(BuildTier.production, BuildTier.preview)
        XCTAssertLessThan(BuildTier.preview, BuildTier.dev)
        XCTAssertEqual(BuildTier.allCases.sorted(), [.production, .preview, .dev])
    }

    func testProductionBuildIncludesOnlyProductionModules() {
        XCTAssertTrue(BuildTier.production.includes(.production))
        XCTAssertFalse(BuildTier.production.includes(.preview))
        XCTAssertFalse(BuildTier.production.includes(.dev))
    }

    func testPreviewBuildIncludesProductionAndPreviewButNotDev() {
        XCTAssertTrue(BuildTier.preview.includes(.production))
        XCTAssertTrue(BuildTier.preview.includes(.preview))
        XCTAssertFalse(BuildTier.preview.includes(.dev))
    }

    func testDevBuildIncludesEverything() {
        XCTAssertTrue(BuildTier.dev.includes(.production))
        XCTAssertTrue(BuildTier.dev.includes(.preview))
        XCTAssertTrue(BuildTier.dev.includes(.dev))
    }

    func testRawValueRoundTrips() {
        for tier in BuildTier.allCases {
            XCTAssertEqual(BuildTier(rawValue: tier.rawValue), tier)
        }
        XCTAssertNil(BuildTier(rawValue: "nonsense"))
    }

    /// The test host sets no `AletheiaBuildTier`, so `current` must fall back to
    /// the thin product rather than the everything build — the safe default.
    func testCurrentDefaultsToProductionWhenUnset() {
        XCTAssertEqual(BuildTier.current, .production)
    }
}
