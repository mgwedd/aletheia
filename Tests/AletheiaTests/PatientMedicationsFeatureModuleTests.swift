import XCTest
@testable import Aletheia

/// The patient medications table is carved to `.preview`: complete but non-core.
/// These pin the module out of the production build and into preview/dev —
/// against the real composition root's catalog. Gating hides only the UI; stored
/// medications are never touched.
final class PatientMedicationsFeatureModuleTests: XCTestCase {
    func testProductionBuildDoesNotIncludeMedications() {
        let registry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(registry.contains(id: PatientMedicationsFeatureModule.id))
    }

    func testPreviewBuildIncludesMedications() {
        let registry = FeatureRegistry.compose(tier: .preview, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: PatientMedicationsFeatureModule.id))
    }

    func testDevBuildIncludesMedications() {
        let registry = FeatureRegistry.compose(tier: .dev, from: FeatureRegistry.allModules)
        XCTAssertTrue(registry.contains(id: PatientMedicationsFeatureModule.id))
    }
}
