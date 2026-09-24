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

    /// The unit tests compile in the Debug config, which defines `ALETHEIA_DEV`,
    /// so this build's compiled tier is `.dev` — the full feature surface, which
    /// is exactly what lets the tests exercise every module.
    func testCompiledTierIsDevUnderTheTestConfig() {
        XCTAssertEqual(BuildTier.compiled, .dev)
    }

    /// With no `AletheiaBuildTier` Info.plist override in the test host,
    /// `current` falls back to the compiled tier (here, `.dev`). A plain Release
    /// build compiles at `.production` and so ships the thin product.
    func testCurrentFallsBackToCompiledTierWhenUnset() {
        XCTAssertEqual(BuildTier.current, .compiled)
        XCTAssertEqual(BuildTier.current, .dev)
    }
}
