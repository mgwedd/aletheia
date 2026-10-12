#if DEBUG
import XCTest
@testable import Aletheia

final class HarnessRunTests: XCTestCase {
    func testParse() {
        let a = HarnessArgs.parse(["app", "--harness-record", "12", "--out", "/tmp/x", "--harness-transcribe"])
        XCTAssertEqual(a?.seconds, 12)
        XCTAssertEqual(a?.out.path, "/tmp/x")
        XCTAssertEqual(a?.transcribe, true)
        XCTAssertNil(HarnessArgs.parse(["app"]))
        XCTAssertNil(HarnessArgs.parse(["app", "--harness-record", "12"]))
    }

    func testWerAndSharedWords() {
        XCTAssertEqual(HarnessScoring.wer(reference: "the quick brown fox", hypothesis: "The quick, brown fox!"), 0)
        XCTAssertEqual(HarnessScoring.wer(reference: "the quick brown fox", hypothesis: "the slow brown"), 0.5)
        XCTAssertEqual(HarnessScoring.spoken("[00:03] Call audio (overlapping): hello there"), " hello there")
        XCTAssertEqual(HarnessScoring.sharedWords(reference: "a b c", hypothesis: "b c d"), 2)
    }
}
#endif
