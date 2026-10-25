import XCTest
import CryptoKit
@testable import Aletheia

/// "Remember on this Mac" starts off wherever a passphrase is first set or entered.
final class RememberKeyDefaultTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private final class RecordingDeviceKeys: DeviceKeyStoring {
        var saved: [String: SymmetricKey] = [:]
        func save(_ key: SymmetricKey, for id: String) throws { saved[id] = key }
        func load(for id: String) -> SymmetricKey? { saved[id] }
        func delete(for id: String) { saved[id] = nil }
    }

    func testDefaultIsOff() {
        XCTAssertFalse(EncryptionSettingsDefaults.rememberKeyOnDevice)
    }

    func testNoViewStartsARememberToggleOn() throws {
        let views = repo.appendingPathComponent("Sources/App/Views")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("rememberOnDevice") && line.contains("@State") {
                scanned += 1
                XCTAssertFalse(
                    line.range(of: "=\\s*true\\b", options: .regularExpression) != nil,
                    "\(url.lastPathComponent): remember toggle must not start on: \(line)")
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 3, "the enable, unlock and settings toggles are all covered")
    }

    func testEnablingEncryptionStoresNothingOnTheDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = RecordingDeviceKeys()
        let suite = "RememberKeyDefaultTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let m = EncryptionManager(dataRootProvider: { root }, deviceKeys: keys, defaults: defaults)
        try m.enable(passphrase: "test-passphrase-1", iterations: 100_000)
        XCTAssertTrue(keys.saved.isEmpty)
        XCTAssertFalse(m.isRememberedOnDevice)
    }
}
