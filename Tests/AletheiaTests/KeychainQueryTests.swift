import XCTest
@testable import Aletheia

final class KeychainQueryTests: XCTestCase {
    private let data = Data(repeating: 1, count: 32)

    func testSaveQueryAttributes() {
        let q = KeychainQuery.save(service: "com.aletheia.datakey", account: "id", data: data)
        XCTAssertEqual(q.count, 6)
        XCTAssertEqual(q[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(q[kSecAttrService as String] as? String, "com.aletheia.datakey")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "id")
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(q[kSecValueData as String] as? Data, data)
        XCTAssertEqual(q[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testMatchQueryAttributes() {
        let q = KeychainQuery.match(service: "s", account: "a")
        XCTAssertEqual(q.count, 4)
        XCTAssertEqual(q[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(q[kSecAttrService as String] as? String, "s")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "a")
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testLookupQueryAttributes() {
        let q = KeychainQuery.lookup(service: "s", account: "a")
        XCTAssertEqual(q.count, 6)
        XCTAssertEqual(q[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(q[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testUpdateAttributesCarryOnlyTheData() {
        let q = KeychainQuery.updateAttributes(data: data)
        XCTAssertEqual(Array(q.keys), [kSecValueData as String])
        XCTAssertEqual(q[kSecValueData as String] as? Data, data)
    }

    func testDeviceKeyStoreBuildsNoInlineKeychainDictionaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/App/Services/Crypto/DeviceKeyStore.swift"),
            encoding: .utf8
        )
        let marker = "enum KeychainQuery"
        let range = try XCTUnwrap(source.range(of: marker))
        let outsideBuilder = String(source[..<range.lowerBound])
        XCTAssertFalse(outsideBuilder.contains("kSecClass"), "build queries through KeychainQuery")
        XCTAssertFalse(outsideBuilder.contains("kSecAttrAccessible"), "build queries through KeychainQuery")
    }
}
