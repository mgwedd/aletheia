import XCTest
@testable import Aletheia

final class PHIEntryGateTests: XCTestCase {
    func testKnownUnencryptedDiskBlocksNewPHI() {
        XCTAssertFalse(PHIEntryGate.allowsNewPHI(diskEncrypted: false))
    }

    func testEncryptedDiskAllowsNewPHI() {
        XCTAssertTrue(PHIEntryGate.allowsNewPHI(diskEncrypted: true))
        XCTAssertFalse(PHIEntryGate.warnsUnknown(diskEncrypted: true))
    }

    func testUnknownStateAllowsEntryWithAWarning() {
        XCTAssertTrue(PHIEntryGate.allowsNewPHI(diskEncrypted: nil))
        XCTAssertTrue(PHIEntryGate.warnsUnknown(diskEncrypted: nil))
    }

    func testBlockedMessageNamesFileVault() {
        XCTAssertEqual(PHIEntryGate.blockedTitle, "Turn on FileVault")
        XCTAssertTrue(PHIEntryGate.blockedMessage.contains("System Settings"))
    }

    /// FileVault only covers the internal disk, so a data folder on an
    /// unencrypted external drive needs its own way out of the block.
    func testBlockedMessageCoversADataFolderOnAnExternalDrive() {
        XCTAssertTrue(PHIEntryGate.blockedMessage.contains("external drive"))
        XCTAssertTrue(PHIEntryGate.blockedMessage.contains("data folder"))
    }
}
