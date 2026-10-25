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
    private let fastIterations = 100_000
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
        // store, so a fresh manager stays locked. Uses the default store.
        let first = EncryptionManager(dataRootProvider: { [root] in root })
        _ = try first.enable(passphrase: "test-passphrase-1", iterations: fastIterations)
        let relaunched = EncryptionManager(dataRootProvider: { [root] in root })
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
    }

    func testTestsDoNotUseTheRealKeychainByDefault() throws {
        XCTAssertFalse(TestHost.usesLiveKeychain())
        XCTAssertTrue(KeychainDeviceKeyStore.makeDefault() is ProcessMemoryDeviceKeyStore)
        let a = AuditKeyManager.loadOrCreateKeychainKey()
        let b = AuditKeyManager.loadOrCreateKeychainKey()
        XCTAssertNotNil(a)
        XCTAssertEqual(a.map { $0.withUnsafeBytes { Data($0) } }, b.map { $0.withUnsafeBytes { Data($0) } })
    }

    func testProcessMemoryStoreRoundTrips() throws {
        let store = ProcessMemoryDeviceKeyStore()
        let key = SymmetricKey(size: .bits256)
        try store.save(key, for: "x")
        XCTAssertNotNil(store.load(for: "x"))
        store.delete(for: "x")
        XCTAssertNil(store.load(for: "x"))
    }

    func testKeychainErrorDescription() {
        let err = KeychainDeviceKeyStore.KeychainError.unexpectedStatus(-50)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription?.contains("keychain") == true)
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

    func testEveryKeychainCallIsNonSynchronizable() {
        var queries: [[String: Any]] = []
        let client = KeychainDeviceKeyStore.Client(
            add: { queries.append($0 as! [String: Any]); return errSecSuccess },
            update: { q, _ in queries.append(q as! [String: Any]); return errSecItemNotFound },
            copy: { queries.append($0 as! [String: Any]); return (errSecItemNotFound, nil) },
            delete: { queries.append($0 as! [String: Any]); return errSecSuccess }
        )
        let store = KeychainDeviceKeyStore(client: client)
        try? store.save(SymmetricKey(size: .bits256), for: "id")
        _ = store.load(for: "id")
        store.delete(for: "id")
        XCTAssertEqual(queries.count, 4, "update, add, copy, delete")
        for query in queries {
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        }
    }

    func testAuditKeyQueryIsNonSynchronizable() {
        XCTAssertEqual(AuditKeyManager.keyQuery[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(AuditKeyManager.keyQuery[kSecAttrAccount as String] as? String, "com.aletheia.audit-hmac-key")
    }

    func testCommonStatusesGetPlainReasons() throws {
        let locked = try XCTUnwrap(KeychainDeviceKeyStore.KeychainError.unexpectedStatus(errSecInteractionNotAllowed).errorDescription)
        XCTAssertTrue(locked.contains("locked"))
        let refused = try XCTUnwrap(KeychainDeviceKeyStore.KeychainError.unexpectedStatus(errSecAuthFailed).errorDescription)
        XCTAssertTrue(refused.contains("refused"))
    }
}
