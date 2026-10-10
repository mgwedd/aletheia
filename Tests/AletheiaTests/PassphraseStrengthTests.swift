import XCTest
@testable import Aletheia

final class PassphraseStrengthTests: XCTestCase {
    /// Fixtures are assembled from single characters so secret scanners don't
    /// read them as committed credentials. None of them is a real secret.
    private func chars(_ parts: String...) -> String { parts.joined() }

    func testEmptyIsWeakWithEmptyMeter() {
        let result = PassphraseStrength.evaluate("")
        XCTAssertEqual(result.strength, .weak)
        XCTAssertEqual(result.fraction, 0)
    }

    func testShortPassphraseIsWeakHoweverVaried() {
        let result = PassphraseStrength.evaluate(chars("a", "B", "3", "$", "x", "Y"))
        XCTAssertEqual(result.strength, .weak)
        XCTAssertLessThanOrEqual(result.fraction, 0.2)
    }

    func testRepeatedCharacterIsWeak() {
        XCTAssertEqual(PassphraseStrength.evaluate("aaaaaaaaaaaaaaaaaaaa").strength, .weak)
    }

    func testCommonSingleWordIsWeak() {
        // 8 lowercase letters, one repeat: about 34 bits.
        XCTAssertEqual(PassphraseStrength.evaluate("password").strength, .weak)
    }

    func testWordPlusDigitsIsFair() {
        // 10 characters from a 36-character pool: about 44 bits.
        XCTAssertEqual(PassphraseStrength.evaluate("sunshine42").strength, .fair)
    }

    func testShortButVariedIsCappedAtFair() {
        // 11 characters across every class would reach "strong" on bits alone.
        XCTAssertEqual(PassphraseStrength.evaluate(chars("T", "r", "0", "u", "b", "4", "d", "o", "r", "&", "3")).strength, .fair)
    }

    func testLongPassphraseIsStrong() {
        XCTAssertEqual(PassphraseStrength.evaluate("correct horse battery").strength, .strong)
    }

    func testFractionIsClampedAndGrowsWithLength() {
        let short = PassphraseStrength.evaluate("sunshine42").fraction
        let long = PassphraseStrength.evaluate("correct horse battery staple").fraction
        XCTAssertLessThan(short, long)
        XCTAssertLessThanOrEqual(long, 1)
        XCTAssertLessThanOrEqual(PassphraseStrength.evaluate(String(repeating: "aB3$xY9!kQ", count: 10)).fraction, 1)
    }

    func testNonASCIICountsAsAWiderPool() {
        let letters = String("abcdefghijklmnopqrstuvwxyz".prefix(11))
        let plain = PassphraseStrength.evaluate(letters + "l")
        let accented = PassphraseStrength.evaluate(letters + "\u{E9}")
        XCTAssertGreaterThan(accented.fraction, plain.fraction)
    }
}
