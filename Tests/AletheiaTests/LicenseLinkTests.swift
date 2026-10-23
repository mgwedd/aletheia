import CryptoKit
import XCTest
@testable import Aletheia

@MainActor
final class LicenseLinkTests: XCTestCase {
    private let key = "ALET1.eyJ2IjoxfQ.c2ln"
    private var suite: String?
    private var defaults: UserDefaults?

    override func tearDown() {
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        _ = AppNavigator.shared.takeOfferedLicenseKey()
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    func testALicenseLinkYieldsItsKey() {
        XCTAssertEqual(LicenseLink.keyText(from: url("aletheia://license?key=\(key)")), key)
        XCTAssertEqual(LicenseLink.keyText(from: url("aletheia://license/?key=\(key)")), key)
        XCTAssertEqual(LicenseLink.keyText(from: url("ALETHEIA://License?key=\(key)")), key)
    }

    func testAnyOtherLinkYieldsNothing() {
        let refused = [
            "https://license?key=\(key)",
            "aletheia://licence?key=\(key)",
            "aletheia://license/install?key=\(key)",
            "aletheia://license?token=\(key)",
            "aletheia://license?key=\(key)&key=\(key)",
            "aletheia://license?key=\(key)&from=mail",
            "aletheia://license?key=\(key)#x",
            "aletheia://user@license?key=\(key)",
            "aletheia://license:8080?key=\(key)",
            "aletheia://license?key=notakey",
            "aletheia://license?key=ALETR1.eyJ2IjoxfQ.c2ln",
            "aletheia://license",
            "aletheia://license?key=ALET1.\(String(repeating: "a", count: LicenseVerifier.maxLength))",
        ]
        for text in refused { XCTAssertNil(LicenseLink.keyText(from: url(text)), text) }
    }

    func testTheNavigatorHoldsAnOfferedKeyUntilTakenOnce() {
        let navigator = AppNavigator.shared
        XCTAssertFalse(navigator.offerLicenseKey(from: url("aletheia://other")))
        XCTAssertNil(navigator.offeredLicenseKey)

        XCTAssertTrue(navigator.offerLicenseKey(from: url("aletheia://license?key=\(key)")))
        XCTAssertEqual(navigator.takeOfferedLicenseKey(), key)
        XCTAssertNil(navigator.takeOfferedLicenseKey())
    }

    /// Opening a link only checks the key: the one in use stays until the user clicks.
    func testCheckingAKeyStoresNothing() throws {
        let (signer, ring) = LicenseTestMint.freshKeyring()
        let suite = "LicenseLinkTests-\(UUID().uuidString)"
        self.suite = suite
        defaults = UserDefaults(suiteName: suite)
        let settings = AppSettings(defaults: defaults!)
        let state = LicenseState(settings: settings, keyring: ring, now: { LicenseTestMint.now })
        let text = try LicenseTestMint.token(
            LicenseTestMint.payload(lid: LicenseTestMint.sampleLID, exp: LicenseTestMint.now.addingTimeInterval(80 * LicenseTestMint.day)),
            key: signer)

        guard case .success(let token) = state.check(text) else { return XCTFail("refused") }
        XCTAssertEqual(token.lid, LicenseTestMint.sampleLID)
        XCTAssertEqual(settings.licenseToken, "")
        guard case .unlicensed = state.status else { return XCTFail("status is \(state.status)") }

        guard case .failure(.badSignature) = state.check(String(text.dropLast(2)) + "AA") else { return XCTFail("accepted a bad key") }
    }

    func testTheOfferLineNamesTheLicenseeOrTheProblem() throws {
        let (signer, ring) = LicenseTestMint.freshKeyring()
        let text = try LicenseTestMint.token(
            LicenseTestMint.payload(lid: LicenseTestMint.sampleLID, exp: LicenseTestMint.now.addingTimeInterval(80 * LicenseTestMint.day)),
            key: signer)
        let token = try LicenseVerifier.verify(text, keyring: ring, now: LicenseTestMint.now)

        let good = LicenseEntryView.offerText(.success(token), buttonTitle: "Replace")
        XCTAssertTrue(good.contains(token.sub), good)
        XCTAssertTrue(good.contains("Replace"), good)
        let bad = LicenseEntryView.offerText(.failure(.unknownKey), buttonTitle: "Replace")
        XCTAssertTrue(bad.contains(LicenseError.unknownKey.errorDescription!), bad)
    }

    func testTheAppRegistersTheAletheiaScheme() {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [LicenseLink.scheme])
    }
}
