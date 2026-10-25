import CryptoKit
import XCTest
@testable import Aletheia

private final class MemoryKeys: DeviceKeyStoring {
    var storage: [String: SymmetricKey] = [:]
    func save(_ key: SymmetricKey, for id: String) throws { storage[id] = key }
    func load(for id: String) -> SymmetricKey? { storage[id] }
    func delete(for id: String) { storage[id] = nil }
}

/// The lock must not hinge on a preference that `defaults write` can flip, and the
/// folder key must exist in memory only while the app is unlocked.
final class LockStateTests: XCTestCase {
    private let iterations = 100_000
    private var root: URL!
    private var keys: MemoryKeys!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LockStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        keys = MemoryKeys()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func defaults() -> UserDefaults {
        let name = "LockStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func manager(defaults: UserDefaults, autoUnlockAtLaunch: Bool = true) -> EncryptionManager {
        EncryptionManager(
            dataRootProvider: { [root] in root }, deviceKeys: keys, defaults: defaults,
            autoUnlockAtLaunch: autoUnlockAtLaunch)
    }

    // MARK: - Lock does not depend on a writable preference

    @MainActor
    func testStoredKeyKeepsTheLockOnEvenWhenThePreferenceIsOff() {
        let suite = defaults()
        let settings = AppSettings(defaults: suite)
        suite.set(false, forKey: "appLockEnabled")   // what `defaults write` would do
        let reloaded = AppSettings(defaults: suite)
        XCTAssertFalse(reloaded.appLockEnabled)

        let required = AppLock(settings: reloaded, canAuthenticate: { true }, lockRequired: { true })
        XCTAssertTrue(required.isLocked, "a remembered key must not open without authentication")
        XCTAssertTrue(required.isLockEnabled)
        required.simulateUnlockedForTesting()
        required.lockIfEnabled()
        XCTAssertTrue(required.isLocked, "relock triggers still work")

        let optional = AppLock(settings: reloaded, canAuthenticate: { true }, lockRequired: { false })
        XCTAssertFalse(optional.isLocked, "with no stored key the explicit choice to turn the lock off stands")
        _ = settings
    }

    func testLockIsRequiredOnlyWhenEncryptedAndKeyIsRemembered() throws {
        let m = manager(defaults: defaults())
        XCTAssertFalse(m.requiresAppLock, "no encryption")
        try m.enable(passphrase: "test-passphrase-1", iterations: iterations)
        XCTAssertFalse(m.requiresAppLock, "encrypted but the key is not kept on this Mac")
        try m.rememberOnDevice()
        XCTAssertTrue(m.requiresAppLock)
        m.forgetOnDevice()
        XCTAssertFalse(m.requiresAppLock)
    }

    func testLaunchSourceDecidesTheLockBeforeTheKeyComesOffTheKeychain() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/AletheiaApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("autoUnlockAtLaunch: false"))
        XCTAssertTrue(source.contains("lockRequired:"))
        let lockAt = try XCTUnwrap(source.range(of: "let appLock = AppLock(")).lowerBound
        let unlockAt = try XCTUnwrap(source.range(of: "if !appLock.isLocked { encryption.autoUnlockFromDevice() }")).lowerBound
        XCTAssertLessThan(lockAt, unlockAt)
    }

    // MARK: - Key lifecycle

    func testFreshManagerHoldsNoKeyWhenLaunchUnlockIsSkipped() throws {
        let suite = defaults()
        let first = manager(defaults: suite)
        try first.enable(passphrase: "test-passphrase-1", iterations: iterations)
        try first.rememberOnDevice()

        let locked = manager(defaults: suite, autoUnlockAtLaunch: false)
        XCTAssertEqual(locked.state, .lockedNeedsPassphrase)
        XCTAssertNil(locked.protector.heldKey)

        let open = manager(defaults: suite)
        XCTAssertEqual(open.state, .unlocked, "the default launch path still unlocks from the keychain")
        XCTAssertNotNil(open.protector.heldKey)
    }

    func testLockClearsTheKeyAndNothingBringsItBackUntilAnExplicitUnlock() throws {
        let m = manager(defaults: defaults())
        try m.enable(passphrase: "test-passphrase-1", iterations: iterations)
        try m.rememberOnDevice()
        let held = m.protector
        XCTAssertNotNil(held.heldKey)

        m.lock()
        XCTAssertNil(m.protector.heldKey)
        XCTAssertNil(held.heldKey, "a protector captured before the lock loses the key too")
        m.refreshState()
        XCTAssertEqual(m.state, .lockedNeedsPassphrase, "a state refresh must not re-unlock")
        XCTAssertNil(m.protector.heldKey)

        m.autoUnlockFromDevice()
        XCTAssertNotNil(m.protector.heldKey)
    }

    func testAppLockHookDropsTheKey() throws {
        let m = manager(defaults: defaults())
        try m.enable(passphrase: "test-passphrase-1", iterations: iterations)
        let appLock = MainActor.assumeIsolated {
            let lock = AppLock(settings: AppSettings(defaults: defaults()), canAuthenticate: { true }, lockRequired: { true })
            lock.simulateUnlockedForTesting()
            lock.onLock = { [weak m] in m?.lock() }
            lock.lockIfEnabled()
            return lock
        }
        XCTAssertTrue(MainActor.assumeIsolated { appLock.isLocked })
        XCTAssertNil(m.protector.heldKey)
        XCTAssertEqual(m.state, .lockedNeedsPassphrase)
    }

    // MARK: - Failures that used to be swallowed

    func testDisableRefusesAndKeepsTheKeystoreWhenTheMarkerCannotBeRemoved() throws {
        let m = manager(defaults: defaults())
        try m.enable(passphrase: "test-passphrase-1", iterations: iterations)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(EncryptionManager.markerFileName).path))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        XCTAssertThrowsError(try m.disable())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertTrue(Keystore.exists(at: root), "nothing is left unreadable")
        XCTAssertTrue(m.isUnlocked)
    }

    func testDeleteRecordingsReportsStagedAudioThatCannotBeRemoved() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let staging = Store.stagingDir(for: session.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: staging.appendingPathComponent("mic.caf"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staging.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            try? FileManager.default.removeItem(at: staging)
        }

        XCTAssertThrowsError(try store.deleteRecordings(for: patient, session: session)) { error in
            guard case StoreError.recordingNotDeleted = error else { return XCTFail("got \(error)") }
        }
    }

    func testDeleteRecordingsRemovesStagedAudio() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let staging = Store.stagingDir(for: session.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: staging.appendingPathComponent("mic.caf"))
        try store.deleteRecordings(for: patient, session: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testRegeneratingAWholeTranscriptNoteFailsWhenTheOldCoverageLineCannotBeRemoved() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveGeneratedNote("v1", for: patient, session: session, format: .soap, coverage: "first half only")
        let dir = root.appendingPathComponent("Patients", isDirectory: true)
        let sidecars = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == Store.noteSidecarFileName(for: .soap, .coverage) }
        let coverage = try XCTUnwrap(sidecars.first)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: coverage.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: coverage.path) }

        XCTAssertThrowsError(try store.saveGeneratedNote("v2", for: patient, session: session, format: .soap))
    }

    func testLockWhenHiddenDefaultsOnForFreshInstallsAndKeepsSavedChoice() {
        let suite = defaults()
        XCTAssertTrue(AppSettings(defaults: suite).lockWhenHidden)
        suite.set(false, forKey: "lockWhenHidden")
        XCTAssertFalse(AppSettings(defaults: suite).lockWhenHidden)
    }
}
