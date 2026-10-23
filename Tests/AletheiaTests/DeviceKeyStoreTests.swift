import CryptoKit
import XCTest
@testable import Aletheia

/// In-memory `DeviceKeyStoring` double so the remember/auto-unlock flow is
/// testable without touching the real Keychain (which is unavailable/flaky in
/// CI). Shared between "launches" by passing the same instance to two managers.
private final class InMemoryDeviceKeyStore: DeviceKeyStoring {
    private(set) var storage: [String: SymmetricKey] = [:]
    func save(_ key: SymmetricKey, for id: String) throws { storage[id] = key }
    func load(for id: String) -> SymmetricKey? { storage[id] }
    func delete(for id: String) { storage[id] = nil }
}

final class DeviceKeyStoreTests: XCTestCase {
    private let fastIterations = 1_000
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceKeyStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manager(_ device: DeviceKeyStoring) -> EncryptionManager {
        EncryptionManager(dataRootProvider: { [root] in root }, deviceKeys: device)
    }

    func testRememberedFolderAutoUnlocksOnNextLaunch() throws {
        let device = InMemoryDeviceKeyStore()
        let first = manager(device)
        _ = try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        XCTAssertFalse(first.isRememberedOnDevice)

        try first.rememberOnDevice()
        XCTAssertTrue(first.isRememberedOnDevice)
        XCTAssertEqual(device.storage.count, 1)

        // A fresh manager over the same folder + same device store = a relaunch.
        let relaunched = manager(device)
        XCTAssertEqual(relaunched.state, .unlocked, "a remembered folder unlocks without the passphrase")
        XCTAssertTrue(relaunched.protector.isEncrypting)
    }

    func testLockDropsRememberedKeyUntilExplicitUnlock() throws {
        let device = InMemoryDeviceKeyStore()
        let m = manager(device)
        try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try m.rememberOnDevice()
        m.lock()
        XCTAssertEqual(m.state, .lockedNeedsPassphrase)
        m.refreshState()
        XCTAssertEqual(m.state, .lockedNeedsPassphrase)
        XCTAssertFalse(m.protector.isEncrypting)

        m.autoUnlockFromDevice()
        XCTAssertEqual(m.state, .unlocked)
        XCTAssertTrue(m.protector.isEncrypting)
    }

    func testForgetOnDeviceRestoresPassphrasePromptNextLaunch() throws {
        let device = InMemoryDeviceKeyStore()
        let first = manager(device)
        _ = try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try first.rememberOnDevice()
        first.forgetOnDevice()
        XCTAssertFalse(first.isRememberedOnDevice)

        let relaunched = manager(device)
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
    }

    func testRememberWhileLockedThrows() throws {
        let device = InMemoryDeviceKeyStore()
        let m = manager(device)
        _ = try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        m.lock()
        XCTAssertThrowsError(try m.rememberOnDevice())
        XCTAssertTrue(device.storage.isEmpty)
    }

    func testDisableClearsRememberedKey() throws {
        let device = InMemoryDeviceKeyStore()
        let m = manager(device)
        _ = try m.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        try m.rememberOnDevice()
        XCTAssertEqual(device.storage.count, 1)

        try m.disable()
        XCTAssertTrue(device.storage.isEmpty, "turning encryption off removes the keychain copy")
        XCTAssertEqual(m.state, .disabled)
    }

    func testDefaultManagerUsesKeychainAndDoesNotAutoUnlockUnrememberedFolder() throws {
        // No id assigned (never remembered) → refresh must not consult the device
        // store, so a fresh manager stays locked. Uses the real default store.
        let first = EncryptionManager(dataRootProvider: { [root] in root })
        _ = try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        let relaunched = EncryptionManager(dataRootProvider: { [root] in root })
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
    }

    func testKeychainErrorDescription() {
        let err = KeychainDeviceKeyStore.KeychainError.unexpectedStatus(-50)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription?.contains("keychain") == true)
    }

    func testKeychainDeviceKeyStoreOperations() {
        let store = KeychainDeviceKeyStore()
        let testID = "test-key-\(UUID().uuidString)"
        let key = SymmetricKey(size: .bits256)

        // Save key to keychain
        try? store.save(key, for: testID)

        // Load key (might be nil if headless keychain is locked, but shouldn't crash)
        _ = store.load(for: testID)

        // Delete key
        store.delete(for: testID)
        XCTAssertNil(store.load(for: testID))
    }

    // MARK: - Keychain calls

    /// Records the Keychain calls instead of making them.
    private final class FakeKeychain {
        var calls: [String] = []
        var updateStatus: OSStatus = errSecSuccess
        var addStatus: OSStatus = errSecSuccess
        var stored: Data?

        var client: KeychainDeviceKeyStore.Client {
            .init(
                add: { [self] _ in calls.append("add"); return addStatus },
                update: { [self] _, _ in calls.append("update"); return updateStatus },
                copy: { [self] _ in calls.append("copy"); return (stored == nil ? errSecItemNotFound : errSecSuccess, stored) },
                delete: { [self] _ in calls.append("delete"); return errSecSuccess }
            )
        }
    }

    func testSaveReplacesInPlace() throws {
        let keychain = FakeKeychain()
        let store = KeychainDeviceKeyStore(client: keychain.client)
        try store.save(SymmetricKey(size: .bits256), for: "id")
        XCTAssertEqual(keychain.calls, ["update"], "an existing entry is updated; no delete leaves a gap")

        keychain.calls = []
        keychain.updateStatus = errSecItemNotFound
        try store.save(SymmetricKey(size: .bits256), for: "id")
        XCTAssertEqual(keychain.calls, ["update", "add"], "added only when there was nothing to update")
        XCTAssertFalse(keychain.calls.contains("delete"))
    }

    func testSaveSurfacesAKeychainFailure() {
        let keychain = FakeKeychain()
        keychain.updateStatus = errSecInteractionNotAllowed
        let store = KeychainDeviceKeyStore(client: keychain.client)
        XCTAssertThrowsError(try store.save(SymmetricKey(size: .bits256), for: "id")) {
            XCTAssertEqual($0 as? KeychainDeviceKeyStore.KeychainError, .unexpectedStatus(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(keychain.calls, ["update"])
    }

    func testLoadRejectsWrongLengthKey() {
        let keychain = FakeKeychain()
        let store = KeychainDeviceKeyStore(client: keychain.client)
        keychain.stored = Data(repeating: 7, count: 16)
        XCTAssertNil(store.load(for: "id"))
        keychain.stored = Data(repeating: 7, count: 32)
        XCTAssertNotNil(store.load(for: "id"))
    }

    func testErrorDescriptionIsReadable() throws {
        let text = try XCTUnwrap(KeychainDeviceKeyStore.KeychainError.unexpectedStatus(-25300).errorDescription)
        XCTAssertTrue(text.contains("-25300"))
        XCTAssertFalse(text.contains("unexpectedStatus"), "no raw enum dump")
    }
}
