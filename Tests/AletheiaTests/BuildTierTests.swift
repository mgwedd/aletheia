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

    /// `compiled` reflects the build configuration's tier flags. CI builds and
    /// tests all three tiers, so pin `compiled` against the flags actually set
    /// for this run rather than assuming one tier.
    func testCompiledTierMatchesTheBuildConfiguration() {
        #if ALETHEIA_DEV
        XCTAssertEqual(BuildTier.compiled, .dev)
        #elseif ALETHEIA_PREVIEW
        XCTAssertEqual(BuildTier.compiled, .preview)
        #else
        XCTAssertEqual(BuildTier.compiled, .production)
        #endif
    }

    /// With no `AletheiaBuildTier` Info.plist override in the test host,
    /// `current` falls back to the compiled tier — whichever tier this run was
    /// built at. A plain Release build compiles at `.production`, so it ships the
    /// thin product.
    func testCurrentFallsBackToCompiledTierWhenUnset() {
        XCTAssertEqual(BuildTier.current, .compiled)
    }
}
