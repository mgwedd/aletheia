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

    func testParseBench() {
        let a = HarnessBenchArgs.parse(["app", "--harness-bench", "/tmp/a.caf", "--out", "/tmp/o",
                                        "--models", "medium.en,bogus,small.en", "--start-min", "5", "--minutes", "2"])
        XCTAssertEqual(a?.audio.path, "/tmp/a.caf")
        XCTAssertEqual(a?.models, [.mediumEn, .smallEn])
        XCTAssertEqual(a?.sliceRange(count: 16000 * 600), 16000 * 300..<16000 * 420)
        XCTAssertEqual(a?.download, false)
        let defaults = HarnessBenchArgs.parse(["app", "--harness-bench", "/tmp/a.caf", "--out", "/tmp/o"])
        XCTAssertEqual(defaults?.models.first, .largeV3)
        XCTAssertEqual(defaults?.sliceRange(count: 100), 0..<100)
        XCTAssertNil(HarnessBenchArgs.parse(["app", "--harness-bench", "/tmp/a.caf"]))
        XCTAssertNil(HarnessBenchArgs.parse(["app", "--harness-bench", "/tmp/a.caf", "--out", "/o", "--models", "bogus"]))
        // A slice past the end is empty, not a crash.
        XCTAssertEqual(HarnessBenchArgs(audio: URL(fileURLWithPath: "/a"), out: URL(fileURLWithPath: "/o"), startMinutes: 10)
            .sliceRange(count: 100).count, 0)
    }

    func testWerAndSharedWords() {
        XCTAssertEqual(HarnessScoring.wer(reference: "the quick brown fox", hypothesis: "The quick, brown fox!"), 0)
        XCTAssertEqual(HarnessScoring.wer(reference: "the quick brown fox", hypothesis: "the slow brown"), 0.5)
        XCTAssertEqual(HarnessScoring.spoken("[00:03] Call audio (overlapping): hello there"), " hello there")
        XCTAssertEqual(HarnessScoring.sharedWords(reference: "a b c", hypothesis: "b c d"), 2)
    }
}
#endif
