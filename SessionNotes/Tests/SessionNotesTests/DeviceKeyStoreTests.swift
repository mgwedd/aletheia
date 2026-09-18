import CryptoKit
import XCTest
@testable import SessionNotes

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
        _ = try first.enable(passphrase: "pw", iterations: fastIterations)
        XCTAssertFalse(first.isRememberedOnDevice)

        try first.rememberOnDevice()
        XCTAssertTrue(first.isRememberedOnDevice)
        XCTAssertEqual(device.storage.count, 1)

        // A fresh manager over the same folder + same device store = a relaunch.
        let relaunched = manager(device)
        XCTAssertEqual(relaunched.state, .unlocked, "a remembered folder unlocks without the passphrase")
        XCTAssertTrue(relaunched.protector.isEncrypting)
    }

    func testForgetOnDeviceRestoresPassphrasePromptNextLaunch() throws {
        let device = InMemoryDeviceKeyStore()
        let first = manager(device)
        _ = try first.enable(passphrase: "pw", iterations: fastIterations)
        try first.rememberOnDevice()
        first.forgetOnDevice()
        XCTAssertFalse(first.isRememberedOnDevice)

        let relaunched = manager(device)
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
    }

    func testRememberWhileLockedThrows() throws {
        let device = InMemoryDeviceKeyStore()
        let m = manager(device)
        _ = try m.enable(passphrase: "pw", iterations: fastIterations)
        m.lock()
        XCTAssertThrowsError(try m.rememberOnDevice())
        XCTAssertTrue(device.storage.isEmpty)
    }

    func testDisableClearsRememberedKey() throws {
        let device = InMemoryDeviceKeyStore()
        let m = manager(device)
        _ = try m.enable(passphrase: "pw", iterations: fastIterations)
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
        _ = try first.enable(passphrase: "pw", iterations: fastIterations)
        let relaunched = EncryptionManager(dataRootProvider: { [root] in root })
        XCTAssertEqual(relaunched.state, .lockedNeedsPassphrase)
    }
}
