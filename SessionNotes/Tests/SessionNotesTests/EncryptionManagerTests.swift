import CryptoKit
import XCTest
@testable import SessionNotes

final class EncryptionManagerTests: XCTestCase {
    private let fastIterations = 1_000
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptionManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func manager(root: URL?) -> EncryptionManager {
        EncryptionManager(dataRootProvider: { root })
    }

    func testStartsDisabledWithNoKeystore() {
        let m = manager(root: tempRoot)
        XCTAssertEqual(m.state, .disabled)
        XCTAssertFalse(m.isEnabled)
        XCTAssertFalse(m.protector.isEncrypting)
    }

    func testEnableCreatesKeystoreAndUnlocks() throws {
        let m = manager(root: tempRoot)
        var changed = 0
        m.onProtectionChanged = { changed += 1 }

        try m.enable(passphrase: "recovery phrase", iterations: fastIterations)

        XCTAssertEqual(m.state, .unlocked)
        XCTAssertTrue(m.isEnabled)
        XCTAssertTrue(m.protector.isEncrypting)
        XCTAssertTrue(Keystore.exists(at: tempRoot))
        XCTAssertEqual(changed, 1)
    }

    func testEnableTwiceThrows() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "pw", iterations: fastIterations)
        XCTAssertThrowsError(try m.enable(passphrase: "pw", iterations: fastIterations)) { error in
            XCTAssertEqual(error as? EncryptionManager.ManagerError, .alreadyEnabled)
        }
    }

    func testEnableWithoutDataFolderThrows() {
        let m = manager(root: nil)
        XCTAssertThrowsError(try m.enable(passphrase: "pw", iterations: fastIterations)) { error in
            XCTAssertEqual(error as? EncryptionManager.ManagerError, .noDataFolder)
        }
    }

    func testLockThenUnlockRoundTrip() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "open sesame", iterations: fastIterations)

        m.lock()
        XCTAssertEqual(m.state, .lockedNeedsPassphrase)
        XCTAssertFalse(m.protector.isEncrypting, "locked → passthrough, so encrypted files surface as .locked")

        try m.unlock(passphrase: "open sesame")
        XCTAssertEqual(m.state, .unlocked)
        XCTAssertTrue(m.protector.isEncrypting)
    }

    func testUnlockWithWrongPassphraseThrows() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "right", iterations: fastIterations)
        m.lock()
        XCTAssertThrowsError(try m.unlock(passphrase: "wrong"))
        XCTAssertEqual(m.state, .lockedNeedsPassphrase)
    }

    func testFreshManagerOnEnabledFolderNeedsPassphrase() throws {
        try manager(root: tempRoot).enable(passphrase: "pw", iterations: fastIterations)
        // Simulate a new launch: a new manager over the same folder.
        let relaunched = manager(root: tempRoot)
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertFalse(relaunched.protector.isEncrypting)
    }

    func testAddedRecoveryPassphraseAlsoUnlocks() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "first", iterations: fastIterations)
        try m.addRecoveryPassphrase("second", iterations: fastIterations)

        let relaunched = manager(root: tempRoot)
        try relaunched.unlock(passphrase: "second")
        XCTAssertEqual(relaunched.state, .unlocked)
    }
}
