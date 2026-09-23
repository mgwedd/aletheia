import XCTest
@testable import Aletheia

/// `BuildTier` is the composition axis: an ordered, nested set of build tiers.
/// These pin the ordering and the "a build includes everything at or below it"
/// rule the whole modular system rests on.
final class BuildTierTests: XCTestCase {
    func testOrderingIsMvpThroughDev() {
        XCTAssertLessThan(BuildTier.mvp, BuildTier.preview)
        XCTAssertLessThan(BuildTier.preview, BuildTier.dev)
        XCTAssertEqual(BuildTier.allCases.sorted(), [.mvp, .preview, .dev])
    }

    func testMvpBuildIncludesOnlyMvpModules() {
        XCTAssertTrue(BuildTier.mvp.includes(.mvp))
        XCTAssertFalse(BuildTier.mvp.includes(.preview))
        XCTAssertFalse(BuildTier.mvp.includes(.dev))
    }

    func testPreviewBuildIncludesMvpAndPreviewButNotDev() {
        XCTAssertTrue(BuildTier.preview.includes(.mvp))
        XCTAssertTrue(BuildTier.preview.includes(.preview))
        XCTAssertFalse(BuildTier.preview.includes(.dev))
    }

    func testDevBuildIncludesEverything() {
        XCTAssertTrue(BuildTier.dev.includes(.mvp))
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
    func testCurrentDefaultsToMvpWhenUnset() {
        XCTAssertEqual(BuildTier.current, .mvp)
    }
}
