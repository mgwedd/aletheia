import XCTest
@testable import Aletheia

/// The first-run encryption recommendation: shown only once there's a data
/// folder to key and encryption isn't already on.
final class EncryptionOnboardingTests: XCTestCase {
    func testRecommendedWhenFolderChosenAndNotYetEnabled() {
        XCTAssertTrue(EncryptionOnboarding.isRecommended(dataFolderChosen: true, alreadyEnabled: false))
    }

    func testNotRecommendedWithoutADataFolder() {
        XCTAssertFalse(EncryptionOnboarding.isRecommended(dataFolderChosen: false, alreadyEnabled: false))
    }

    func testNotRecommendedWhenAlreadyEnabled() {
        XCTAssertFalse(EncryptionOnboarding.isRecommended(dataFolderChosen: true, alreadyEnabled: true))
        // No folder + somehow enabled is still "nothing to recommend".
        XCTAssertFalse(EncryptionOnboarding.isRecommended(dataFolderChosen: false, alreadyEnabled: true))
    }
}
