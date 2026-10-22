#if DEBUG
import XCTest
@testable import Aletheia

final class HarnessEvalTests: XCTestCase {
    func testParse() {
        let a = HarnessEvalArgs.parse(["app", "--harness-eval", "/t.txt", "--question", "Why?", "--model", "m:1b",
                                       "--budget", "16384", "--out", "/o"])
        XCTAssertEqual(a?.transcript.path, "/t.txt")
        XCTAssertEqual(a?.question, "Why?")
        XCTAssertEqual(a?.model, "m:1b")
        XCTAssertEqual(a?.budgetTokens, 16384)
        XCTAssertEqual(a?.out?.path, "/o")
        let d = HarnessEvalArgs.parse(["app", "--harness-eval", "/t.txt", "--budget", "-5"])
        XCTAssertEqual(d?.question, HarnessEvalArgs.defaultQuestion)
        XCTAssertNil(d?.budgetTokens)
        XCTAssertNil(d?.out)
        XCTAssertNil(HarnessEvalArgs.parse(["app"]))
    }

    func testCoverageLabel() {
        let t = "[00:05] Alex: hi\n[1:52:03] Alex: bye"
        XCTAssertEqual(EvalReport.coverage(transcript: t), "Read: full transcript (1h 52m)")
        XCTAssertEqual(EvalReport.coverage(transcript: t, sections: 12), "Read: 12 section digests, merged (1h 52m)")
        XCTAssertEqual(EvalReport.coverage(transcript: "no stamps"), "Read: full transcript")
    }

    func testStageAggregatesCallsAndFlagsTruncation() {
        let ok = AIRunStats(promptTokens: 900, promptNanos: 1_000_000_000, outputTokens: 100, outputNanos: 2_000_000_000,
                            expectedPromptTokens: 1000)
        let cut = AIRunStats(promptTokens: 100, promptNanos: 1_000_000_000, outputTokens: 100, outputNanos: 2_000_000_000,
                             expectedPromptTokens: 1000)
        let clear = EvalStage(name: "n", output: "o", wallSeconds: 3, calls: [.init(estimatedTokens: 1000, stats: ok)], coverage: "c")
        XCTAssertFalse(clear.truncated)
        XCTAssertEqual(clear.prefillTPS, 900)
        XCTAssertEqual(clear.decodeTPS, 50)
        XCTAssertTrue(clear.text().contains("prompt tokens: 900 (engine-reported) vs 1000 estimated"))
        XCTAssertTrue(clear.text().contains("tripwire clear"))
        let both = EvalStage(name: "n", output: "o", wallSeconds: 3,
                             calls: [.init(estimatedTokens: 1000, stats: ok), .init(estimatedTokens: 1000, stats: cut)], coverage: "c")
        XCTAssertTrue(both.truncated)
        XCTAssertEqual(both.promptTokens, 1000)
        XCTAssertTrue(both.text().contains("TRIPWIRE FIRED"))
        let failed = EvalStage(name: "n", output: "", error: "boom", wallSeconds: 0, calls: [], coverage: "Not read: boom")
        XCTAssertTrue(failed.text().contains("ERROR: boom"))
        XCTAssertTrue(failed.text().contains("prompt tokens: n/a"))
    }

    func testWarmPrefillIsLabelledNotCold() {
        var warm = AIRunStats(promptTokens: 900, promptNanos: 100_000_000, outputTokens: 10, outputNanos: 1_000_000_000)
        warm.reusedPrefix = true
        let cold = AIRunStats(promptTokens: 900, promptNanos: 1_000_000_000, outputTokens: 10, outputNanos: 1_000_000_000)
        let s = EvalStage(name: "n", output: "o", wallSeconds: 1,
                          calls: [.init(estimatedTokens: 900, stats: cold), .init(estimatedTokens: 900, stats: warm)], coverage: "c")
        XCTAssertEqual(s.prefillTPS, 900)
        XCTAssertEqual(s.warmPrefillTPS, 9000)
        XCTAssertTrue(s.text().contains("900.0 tok/s (cold)"))
        XCTAssertTrue(s.text().contains("9000.0 tok/s (cache-warm"))
    }

    func testHeaderShowsBudgetOverride() {
        XCTAssertFalse(EvalReport.header(model: "m", budget: 8192, numCtx: 8192, transcriptChars: 10).contains("override"))
        XCTAssertTrue(EvalReport.header(model: "m", budget: 2000, numCtx: 8192, transcriptChars: 10)
            .contains("--budget override; requests send num_ctx 8192"))
    }

    func testJSONReport() throws {
        let s = EvalStage(name: "n", output: "o", wallSeconds: 1, calls: [], coverage: "c")
        let data = try XCTUnwrap(EvalReport.json(header: "h", stages: [s]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((obj["stages"] as? [[String: Any]])?.first?["coverage"] as? String, "c")
    }
}
#endif
