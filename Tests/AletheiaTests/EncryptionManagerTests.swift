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
        try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        XCTAssertThrowsError(try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)) { error in
            XCTAssertEqual(error as? EncryptionManager.ManagerError, .alreadyEnabled)
        }
    }

    func testEnableWithoutDataFolderThrows() {
        let m = manager(root: nil)
        XCTAssertThrowsError(try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)) { error in
            XCTAssertEqual(error as? EncryptionManager.ManagerError, .noDataFolder)
        }
    }

    func testLockThenUnlockRoundTrip() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "open sesame please", iterations: fastIterations)

        m.lock()
        XCTAssertEqual(m.state, .lockedNeedsPassphrase)
        XCTAssertFalse(m.protector.isEncrypting)

        try m.unlock(passphrase: "open sesame please")
        XCTAssertEqual(m.state, .unlocked)
        XCTAssertTrue(m.protector.isEncrypting)
    }

    func testProtectorUsedAfterLockThrowsLocked() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
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
        try m.unlock(passphrase: "test-passphrase-1")
        XCTAssertThrowsError(try captured.string(contentsOf: file), "old handles stay revoked after a new unlock")
        XCTAssertEqual(try m.protector.string(contentsOf: file), "private")
    }

    func testChangingDataFolderRevokesCapturedProtector() throws {
        var selectedRoot: URL? = tempRoot
        let m = EncryptionManager(dataRootProvider: { selectedRoot })
        try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
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
        try m.enable(passphrase: "right passphrase", iterations: fastIterations)
        m.lock()
        XCTAssertThrowsError(try m.unlock(passphrase: "wrong"))
        XCTAssertEqual(m.state, .lockedNeedsPassphrase)
    }

    func testFreshManagerOnEnabledFolderNeedsPassphrase() throws {
        try manager(root: tempRoot).enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        // Simulate a new launch: a new manager over the same folder.
        let relaunched = manager(root: tempRoot)
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertFalse(relaunched.protector.isEncrypting)
    }

    func testAddedRecoveryPassphraseAlsoUnlocks() throws {
        let m = manager(root: tempRoot)
        try m.enable(passphrase: "first passphrase", iterations: fastIterations)
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

    // MARK: - Lost keystore, damaged keystore, passphrase rules

    private func isolatedDefaults() -> UserDefaults {
        let name = "EncryptionManagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func deleteKeystore() throws {
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent(Keystore.fileName))
    }

    func testMissingKeystoreWithMarkerStaysLocked() throws {
        let defaults = isolatedDefaults()
        let first = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try deleteKeystore()

        let relaunched = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        XCTAssertEqual(relaunched.state, .keystoreMissing)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertTrue(relaunched.isKeystoreMissing)
        XCTAssertTrue(relaunched.protector.requiresProtection)
        XCTAssertFalse(relaunched.protector.isEncrypting)
        XCTAssertThrowsError(try relaunched.enable(passphrase: "another-passphrase-1", iterations: fastIterations)) {
            XCTAssertEqual($0 as? EncryptionManager.ManagerError, .keystoreMissing)
        }
        XCTAssertThrowsError(try relaunched.unlock(passphrase: "test-passphrase-1")) {
            XCTAssertEqual($0 as? EncryptionManager.ManagerError, .keystoreMissing)
        }
    }

    func testMarkerFileAloneKeepsAMissingKeystoreLocked() throws {
        let first = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: isolatedDefaults())
        try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try deleteKeystore()

        // Fresh defaults: only the file in the folder remembers.
        let relaunched = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: isolatedDefaults())
        XCTAssertEqual(relaunched.state, .keystoreMissing)
    }

    func testNewWriteAfterKeystoreDeletionThrowsLocked() throws {
        let defaults = isolatedDefaults()
        let first = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try deleteKeystore()

        let relaunched = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        let file = tempRoot.appendingPathComponent("note.txt")
        XCTAssertThrowsError(try relaunched.protector.write("new note", to: file)) {
            XCTAssertEqual($0 as? FileProtector.ProtectorError, .locked)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing was written in the clear")
    }

    func testDisableClearsTheMarker() throws {
        let defaults = isolatedDefaults()
        let m = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try m.disable()

        let relaunched = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        XCTAssertEqual(relaunched.state, .disabled)
        XCTAssertFalse(relaunched.protector.requiresProtection)
    }

    func testFolderEncryptedBeforeTheMarkerExistedGetsOne() throws {
        let (keystore, _) = try Keystore.create(passphrase: "test-passphrase-1", iterations: fastIterations)
        try keystore.write(to: tempRoot)
        let defaults = isolatedDefaults()
        _ = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        try deleteKeystore()

        let relaunched = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        XCTAssertEqual(relaunched.state, .keystoreMissing)
    }

    func testCorruptKeystoreSurfacesMalformed() throws {
        let defaults = isolatedDefaults()
        let first = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try Data("{ not json".utf8).write(to: tempRoot.appendingPathComponent(Keystore.fileName))

        let relaunched = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: defaults)
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
        XCTAssertThrowsError(try relaunched.unlock(passphrase: "test-passphrase-1")) {
            XCTAssertEqual($0 as? Keystore.KeystoreError, .malformed)
        }
    }

    func testEnableRejectsWeakPassphrase() {
        let m = manager(root: tempRoot)
        XCTAssertThrowsError(try m.enable(passphrase: "pw", iterations: fastIterations)) {
            XCTAssertEqual($0 as? EncryptionManager.ManagerError, .passphraseTooShort)
        }
        XCTAssertThrowsError(try m.enable(passphrase: "elevenchars", iterations: fastIterations)) {
            XCTAssertEqual($0 as? EncryptionManager.ManagerError, .passphraseTooShort)
        }
        XCTAssertFalse(Keystore.exists(at: tempRoot), "a rejected passphrase leaves no keystore")
        XCTAssertEqual(m.state, .disabled)
        XCTAssertNoThrow(try m.enable(passphrase: "twelve chars", iterations: fastIterations))
    }

    func testWrongPassphrasesBackOffThroughTheManager() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let throttle = UnlockThrottle(freeAttempts: 1, baseDelay: 10, maxDelay: 100, now: { now })
        let m = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, defaults: isolatedDefaults(), throttle: throttle)
        try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        m.lock()

        XCTAssertThrowsError(try m.unlock(passphrase: "wrong one"))   // free
        XCTAssertThrowsError(try m.unlock(passphrase: "wrong two"))   // starts a 10 s wait
        XCTAssertEqual(m.unlockRetryDelay, 10)
        XCTAssertThrowsError(try m.unlock(passphrase: "test-passphrase-1")) {
            XCTAssertEqual($0 as? EncryptionManager.ManagerError, .throttled(retryAfter: 10), "even the right passphrase waits")
        }
        now.addTimeInterval(11)
        try m.unlock(passphrase: "test-passphrase-1")
        XCTAssertEqual(m.state, .unlocked)
        XCTAssertEqual(m.unlockRetryDelay, 0)
    }

    private struct FailingDeviceKeys: DeviceKeyStoring {
        func save(_ key: SymmetricKey, for id: String) throws { throw KeychainDeviceKeyStore.KeychainError.unexpectedStatus(-25293) }
        func load(for id: String) -> SymmetricKey? { nil }
        func delete(for id: String) {}
    }

    func testRememberOnDeviceFailureIsSurfaced() throws {
        let m = EncryptionManager(dataRootProvider: { [tempRoot] in tempRoot }, deviceKeys: FailingDeviceKeys(), defaults: isolatedDefaults())
        try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        XCTAssertNil(m.rememberError)
        XCTAssertThrowsError(try m.rememberOnDevice())
        XCTAssertTrue(try XCTUnwrap(m.rememberError).contains("-25293"))
    }
}
