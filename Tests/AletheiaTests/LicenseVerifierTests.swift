import CryptoKit
import XCTest
@testable import Aletheia

final class LicenseVerifierTests: XCTestCase {
    private let now = LicenseTestMint.now
    private let day = LicenseTestMint.day
    private var key: Curve25519.Signing.PrivateKey!
    private var ring: LicenseKeyring!

    override func setUp() {
        (key, ring) = LicenseTestMint.freshKeyring()
    }

    private func verify(_ text: String) throws -> LicenseToken {
        try LicenseVerifier.verify(text, keyring: ring, now: now)
    }

    private func assertRejects(_ text: String, _ expected: LicenseError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try verify(text), file: file, line: line) {
            XCTAssertEqual($0 as? LicenseError, expected, file: file, line: line)
        }
    }

    func testAcceptsAValidToken() throws {
        let text = try LicenseTestMint.token(LicenseTestMint.payload(), key: key)
        let token = try verify(text)
        XCTAssertEqual(token.sub, "clinician@example.com")
        XCTAssertEqual(token.tier, "beta")
        XCTAssertEqual(token.lid, LicenseTestMint.sampleLID)
        XCTAssertEqual(token.kid, "test-1")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(80 * day))
    }

    func testAKeyWithoutAnExpiryIsAcceptedAndNeverExpires() throws {
        var payload = LicenseTestMint.payload()
        payload.removeValue(forKey: "exp")
        let token = try verify(LicenseTestMint.token(payload, key: key))
        XCTAssertNil(token.expiresAt)
        XCTAssertFalse(token.isExpired(at: now.addingTimeInterval(1000 * day)))
        XCTAssertNil(token.graceEndsAt)
    }

    func testAnExpiryThatIsNotANumberIsMalformed() throws {
        for bad: Any in ["soon", NSNull()] {
            var payload = LicenseTestMint.payload()
            payload["exp"] = bad
            assertRejects(try LicenseTestMint.token(payload, key: key), .malformed)
        }
    }

    func testTrimsSurroundingWhitespaceAndNewlines() throws {
        let text = try LicenseTestMint.token(LicenseTestMint.payload(), key: key)
        XCTAssertNoThrow(try verify("  \n\(text)\n "))
    }

    func testIgnoresUnknownPayloadFields() throws {
        var payload = LicenseTestMint.payload()
        payload["seats"] = 3
        payload["nested"] = ["a": 1]
        XCTAssertNoThrow(try verify(LicenseTestMint.token(payload, key: key)))
    }

    func testRejectsBadSignature() throws {
        let other = Curve25519.Signing.PrivateKey()
        assertRejects(try LicenseTestMint.token(LicenseTestMint.payload(), key: other), .badSignature)
    }

    func testRejectsTamperedPayload() throws {
        let text = try LicenseTestMint.token(LicenseTestMint.payload(), key: key)
        let parts = text.split(separator: ".").map(String.init)
        var forged = LicenseTestMint.payload(sub: "someone.else@example.com")
        forged["exp"] = Int(now.addingTimeInterval(900 * day).timeIntervalSince1970)
        let forgedPayload = Base64URL.encode(try JSONSerialization.data(withJSONObject: forged, options: [.sortedKeys]))
        assertRejects("ALET1.\(forgedPayload).\(parts[2])", .badSignature)
    }

    func testRejectsUnknownKeyID() throws {
        assertRejects(try LicenseTestMint.token(LicenseTestMint.payload(kid: "nope"), key: key), .unknownKey)
    }

    func testRejectsUnsupportedVersion() throws {
        assertRejects(try LicenseTestMint.token(LicenseTestMint.payload(v: 2), key: key), .unsupportedVersion)
    }

    func testRejectsExpired() throws {
        let exp = now.addingTimeInterval(-1)
        assertRejects(try LicenseTestMint.token(LicenseTestMint.payload(exp: exp), key: key), .expired(exp))
        // Exactly at expiry counts as expired.
        assertRejects(try LicenseTestMint.token(LicenseTestMint.payload(exp: now), key: key), .expired(now))
    }

    func testRejectsIssuedMoreThanADayAhead() throws {
        let ahead = LicenseTestMint.payload(iat: now.addingTimeInterval(day + 60))
        assertRejects(try LicenseTestMint.token(ahead, key: key), .issuedInFuture)
        let withinSkew = LicenseTestMint.payload(iat: now.addingTimeInterval(day - 60))
        XCTAssertNoThrow(try verify(LicenseTestMint.token(withinSkew, key: key)))
    }

    func testRejectsMissingRequiredField() throws {
        for field in ["v", "kid", "lid", "sub", "tier", "iat"] {
            var payload = LicenseTestMint.payload()
            payload.removeValue(forKey: field)
            assertRejects(try LicenseTestMint.token(payload, key: key), .malformed)
        }
    }

    func testRejectsWrongFieldType() throws {
        var payload = LicenseTestMint.payload()
        payload["exp"] = "soon"
        assertRejects(try LicenseTestMint.token(payload, key: key), .malformed)
    }

    func testRejectsMalformedShapes() throws {
        let good = try LicenseTestMint.token(LicenseTestMint.payload(), key: key)
        let parts = good.split(separator: ".").map(String.init)
        assertRejects("", .empty)
        assertRejects("   \n", .empty)
        assertRejects("hello", .malformed)
        assertRejects("ALET1.\(parts[1])", .malformed)
        assertRejects("ALET1.\(parts[1]).\(parts[2]).extra", .malformed)
        assertRejects("ALET2.\(parts[1]).\(parts[2])", .malformed)
        assertRejects("ALETR1.\(parts[1]).\(parts[2])", .malformed)
        assertRejects("ALET1.!!!.\(parts[2])", .malformed)
        assertRejects("ALET1.\(parts[1]).!!!", .malformed)
        assertRejects("ALET1.\(parts[1]).\(parts[2])=", .malformed)
        assertRejects("ALET1.\(Base64URL.encode(Data("not json".utf8))).\(parts[2])", .malformed)
        // Not one line.
        assertRejects("ALET1.\(parts[1])\n.\(parts[2])", .malformed)
        assertRejects("ALET1. \(parts[1]).\(parts[2])", .malformed)
    }

    func testRejectsOversizeToken() throws {
        let big = LicenseTestMint.payload(sub: String(repeating: "a", count: 2000))
        assertRejects(try LicenseTestMint.token(big, key: key), .tooLong)
        // The 1 KB limit is on the whole token.
        assertRejects(String(repeating: "A", count: 1025), .tooLong)
    }

    func testAcceptsATokenJustUnderTheLimit() throws {
        // Grow the subject until the token is just under 1 KB.
        var length = 400
        var text = try LicenseTestMint.token(LicenseTestMint.payload(sub: String(repeating: "a", count: length)), key: key)
        while text.utf8.count < 1000 {
            length += 10
            text = try LicenseTestMint.token(LicenseTestMint.payload(sub: String(repeating: "a", count: length)), key: key)
        }
        XCTAssertLessThanOrEqual(text.utf8.count, 1024)
        XCTAssertNoThrow(try verify(text))
    }

    func testSignatureOnlyCheckStillDescribesAnExpiredLicense() throws {
        let exp = now.addingTimeInterval(-5 * day)
        let text = try LicenseTestMint.token(LicenseTestMint.payload(exp: exp), key: key)
        let token = try LicenseVerifier.verifySignature(text, keyring: ring)
        XCTAssertTrue(token.isExpired(at: now))
        XCTAssertEqual(token.sub, "clinician@example.com")
    }

    func testEmptyKeyringRejectsEveryToken() throws {
        let text = try LicenseTestMint.token(LicenseTestMint.payload(), key: key)
        XCTAssertThrowsError(try LicenseVerifier.verify(text, keyring: LicenseKeyring(encoded: [:]), now: now)) {
            XCTAssertEqual($0 as? LicenseError, .unknownKey)
        }
    }

    func testEveryErrorHasAReadableMessage() {
        let all: [LicenseError] = [.empty, .tooLong, .malformed, .unsupportedVersion, .unknownKey, .badSignature,
                                   .expired(now), .issuedInFuture, .revoked]
        for error in all {
            let message = error.errorDescription ?? ""
            XCTAssertGreaterThan(message.count, 20, "\(error)")
            XCTAssertTrue(message.hasSuffix("."), "\(error)")
        }
        XCTAssertTrue(LicenseError.expired(Date(timeIntervalSince1970: 1_800_000_000)).errorDescription!.contains("2027"))
    }

    func testExpiryWarningWindowIsFourteenDays() throws {
        let token = try verify(LicenseTestMint.token(LicenseTestMint.payload(exp: now.addingTimeInterval(14 * day)), key: key))
        XCTAssertTrue(token.isExpiringSoon(at: now))
        XCTAssertEqual(token.daysRemaining(at: now), 14)
        let later = try verify(LicenseTestMint.token(LicenseTestMint.payload(exp: now.addingTimeInterval(14 * day + 1)), key: key))
        XCTAssertFalse(later.isExpiringSoon(at: now))
        XCTAssertNil(token.daysRemaining(at: now.addingTimeInterval(15 * day)))
    }
}
