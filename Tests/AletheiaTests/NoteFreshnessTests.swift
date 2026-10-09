import XCTest
@testable import Aletheia

final class NoteFreshnessTests: XCTestCase {
    func testFingerprintIsStableLowercaseSHA256Hex() {
        let a = NoteFreshness.fingerprint(of: "Therapist: How was your week?")
        XCTAssertEqual(a, NoteFreshness.fingerprint(of: "Therapist: How was your week?"))
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a, a.lowercased())
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
        // Known vector: SHA-256 of "abc".
        XCTAssertEqual(
            NoteFreshness.fingerprint(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testFingerprintChangesWhenTheWordsChange() {
        let before = NoteFreshness.fingerprint(of: "I slept badly.")
        XCTAssertNotEqual(before, NoteFreshness.fingerprint(of: "I slept well."))
        XCTAssertNotEqual(before, NoteFreshness.fingerprint(of: ""))
    }

    func testSurroundingWhitespaceDoesNotChangeTheFingerprint() {
        XCTAssertEqual(
            NoteFreshness.fingerprint(of: "I slept badly."),
            NoteFreshness.fingerprint(of: "\n  I slept badly.\n\n")
        )
    }

    func testNoteWithoutARecordedFingerprintIsNotOutdated() {
        XCTAssertFalse(NoteFreshness.isOutdated(recorded: nil, transcript: "anything"))
        XCTAssertFalse(NoteFreshness.isOutdated(recorded: nil, transcript: ""))
    }

    func testMatchingFingerprintIsCurrentAndAnEditMakesItOutdated() {
        let recorded = NoteFreshness.fingerprint(of: "original")
        XCTAssertFalse(NoteFreshness.isOutdated(recorded: recorded, transcript: "original"))
        XCTAssertTrue(NoteFreshness.isOutdated(recorded: recorded, transcript: "original, cleaned up"))
        XCTAssertTrue(NoteFreshness.isOutdated(recorded: recorded, transcript: ""))
    }

    func testRecordRoundTrip() throws {
        let fingerprint = NoteFreshness.fingerprint(of: "text")
        let data = try NoteFreshness.encode(fingerprint: fingerprint)
        XCTAssertEqual(NoteFreshness.decodeFingerprint(from: data), fingerprint)
    }

    func testUnreadableRecordDecodesToNil() {
        XCTAssertNil(NoteFreshness.decodeFingerprint(from: Data("not json".utf8)))
        XCTAssertNil(NoteFreshness.decodeFingerprint(from: Data("{}".utf8)))
    }
}
