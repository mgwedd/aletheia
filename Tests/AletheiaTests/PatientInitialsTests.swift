import XCTest
@testable import Aletheia

final class PatientInitialsTests: XCTestCase {
    func testTwoWordsGiveFirstAndLastInitial() {
        XCTAssertEqual(PatientInitials.from("Jane Doe"), "JD")
    }

    func testMoreThanTwoWordsUseFirstAndLast() {
        XCTAssertEqual(PatientInitials.from("Mary Ann Smith"), "MS")
    }

    func testOneWordGivesOneLetter() {
        XCTAssertEqual(PatientInitials.from("madonna"), "M")
    }

    func testHyphenatedWordIsOneWord() {
        XCTAssertEqual(PatientInitials.from("Mary-Jane"), "M")
    }

    func testExtraWhitespaceIsIgnored() {
        XCTAssertEqual(PatientInitials.from("  jane    doe  "), "JD")
        XCTAssertEqual(PatientInitials.from("\tjane\n"), "J")
    }

    func testEmptyOrBlankGivesQuestionMark() {
        XCTAssertEqual(PatientInitials.from(""), "?")
        XCTAssertEqual(PatientInitials.from("   "), "?")
    }

    func testLowercaseIsUppercased() {
        XCTAssertEqual(PatientInitials.from("ada lovelace"), "AL")
    }

    func testAccentedLettersKeepTheirAccent() {
        XCTAssertEqual(PatientInitials.from("émile zola"), "ÉZ")
    }

    func testNonLatinNames() {
        XCTAssertEqual(PatientInitials.from("李 小龍"), "李小")
        XCTAssertEqual(PatientInitials.from("Александр Пушкин"), "АП")
        XCTAssertEqual(PatientInitials.from("山田"), "山")
    }

    func testExpandingUppercaseStillGivesOneLetterPerWord() {
        // "ß" uppercases to "SS"; the monogram keeps a single letter.
        XCTAssertEqual(PatientInitials.from("ßeta ßigma"), "SS")
    }
}
