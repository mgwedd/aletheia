import CryptoKit
import XCTest
@testable import Aletheia

final class EncryptionManagerTests: XCTestCase {
    private let fastIterations = 100_000
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
        XCTAssertFalse(m.protector.isEncrypting)

        try m.unlock(passphrase: "open sesame")
        XCTAssertEqual(m.state, .unlocked)
        XCTAssertTrue(m.protector.isEncrypting)
    }

    func testProtectorUsedAfterLockThrowsLocked() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "pw", iterations: fastIterations)
        let captured = m.protector
        let file = tempRoot.appendingPathComponent("note.txt")
        try captured.write("private", to: file)
        m.lock()

        XCTAssertThrowsError(try captured.string(contentsOf: file)) {
            XCTAssertEqual($0 as? FileProtector.ProtectorError, .locked)
        }
        XCTAssertThrowsError(try captured.write("leak", to: file)) {
            XCTAssertEqual($0 as? FileProtector.ProtectorError, .locked)
        }
        XCTAssertThrowsError(try captured.seal(Data("leak".utf8))) {
            XCTAssertEqual($0 as? FileProtector.ProtectorError, .locked)
        }
        XCTAssertNil(RecordPayloadCodec.encode("leak", using: captured),
                     "a captured database store must fail the save instead of writing plaintext")
        try m.unlock(passphrase: "pw")
        XCTAssertThrowsError(try captured.string(contentsOf: file), "old handles stay revoked after a new unlock")
        XCTAssertEqual(try m.protector.string(contentsOf: file), "private")
    }

    func testChangingDataFolderRevokesCapturedProtector() throws {
        var selectedRoot: URL? = tempRoot
        let m = EncryptionManager(dataRootProvider: { selectedRoot })
        try m.enable(passphrase: "pw", iterations: fastIterations)
        let captured = m.protector

        selectedRoot = nil
        m.refreshState()
        XCTAssertEqual(m.state, .disabled)
        XCTAssertThrowsError(try captured.seal(Data("private".utf8))) {
            XCTAssertEqual($0 as? FileProtector.ProtectorError, .locked)
        }
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

    /// The non-negotiable constraint behind gating `AtRestEncryptionFeatureModule`
    /// to `.dev`: a folder encrypted by an earlier (preview/dev) build must still
    /// unlock and read on an MVP build. `EncryptionManager` takes no
    /// `FeatureRegistry`/`BuildTier` at all — nothing here could consult tier even
    /// if it wanted to — so this pins that independence against an explicit
    /// MVP-tier registry and exercises the full unlock-and-read round trip.
    func testUnlockPathIsIndependentOfBuildTier() throws {
        // A prior build already turned encryption on for this folder.
        try manager(root: tempRoot).enable(passphrase: "already encrypted", iterations: fastIterations)

        // This build's registry doesn't offer turning encryption on...
        let mvpRegistry = FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
        XCTAssertFalse(mvpRegistry.contains(id: AtRestEncryptionFeatureModule.id))

        // ...but a fresh manager over the same folder (simulating that MVP
        // build's launch) still reports the folder as locked, not gone or
        // disabled, and unlocks and reads normally.
        let relaunched = manager(root: tempRoot)
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)

        try relaunched.unlock(passphrase: "already encrypted")
        XCTAssertEqual(relaunched.state, .unlocked)

        let protector = relaunched.protector
        XCTAssertTrue(protector.isEncrypting)
        let note = Data("existing patient note".utf8)
        let sealed = try protector.seal(note)
        XCTAssertEqual(try protector.open(sealed), note)
    }
}
