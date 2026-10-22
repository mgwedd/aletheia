import XCTest

/// The entitlements files as checked in: the app cannot reach the network, and
/// the helper holds exactly the sandbox and network access.
final class EntitlementsPlistTests: XCTestCase {
    private let network = "com.apple.security.network.client"
    private let sandbox = "com.apple.security.app-sandbox"

    private func plist(_ path: String) throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testProductionAppHasNoNetworkEntitlement() throws {
        let entitlements = try plist("Sources/App/Resources/Aletheia.entitlements")
        XCTAssertNil(entitlements[network])
        XCTAssertEqual(entitlements[sandbox] as? Bool, true)
    }

    func testDevAppHasNoNetworkEntitlement() throws {
        let entitlements = try plist("Sources/App/Resources/AletheiaDev.entitlements")
        XCTAssertNil(entitlements[network])
        XCTAssertEqual(entitlements[sandbox] as? Bool, true)
    }

    func testHelperHasExactlySandboxAndNetwork() throws {
        let entitlements = try plist("Sources/NetworkHelper/NetworkHelper.entitlements")
        XCTAssertEqual(Set(entitlements.keys), [sandbox, network])
        XCTAssertEqual(entitlements[sandbox] as? Bool, true)
        XCTAssertEqual(entitlements[network] as? Bool, true)
    }

    func testHelperIsAnXPCServiceNamedForItsBundleIdentifier() throws {
        let info = try plist("Sources/NetworkHelper/Info.plist")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "XPC!")
        let service = try XCTUnwrap(info["XPCService"] as? [String: Any])
        XCTAssertEqual(service["ServiceType"] as? String, "Application")
    }
}
