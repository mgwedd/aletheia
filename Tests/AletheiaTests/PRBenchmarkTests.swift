import XCTest
@testable import Aletheia

/// Fast benchmarks (well under a minute) that `.github/workflows/bench.yml` runs
/// on every PR and main push, and reports in a PR comment. They never fail on
/// timing: each prints a `BENCH-JSON` line that `scripts/bench-report.py`
/// compares against recent main runs. Skipped unless ALETHEIA_BENCH is set
/// (xcodebuild: TEST_RUNNER_ALETHEIA_BENCH=1).
final class PRBenchmarkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALETHEIA_BENCH"] != nil, "set ALETHEIA_BENCH to run")
    }

    /// 50 sessions of 60,000 characters each. "cold" builds a fresh index and
    /// answers one query; "warm" is the next query against that index.
    func testSessionSearch() {
        let words = ["weather", "errands", "sleep", "mother", "garden", "work", "walk", "dinner", "tired", "weekend", "friends", "plans"]
        var rng = SeededGenerator(state: 42)
        let calendar = Calendar(identifier: .gregorian)
        var docs: [SessionSearch.Document] = []
        for s in 0..<50 {
            var lines: [String] = []
            var length = 0, n = 0
            while length < 60_000 {
                let sentence = (0..<14).map { _ in words[Int.random(in: 0..<words.count, using: &rng)] }.joined(separator: " ")
                let line = "[\(n / 60):\(String(format: "%02d", n % 60))] Patient: \(sentence)"
                lines.append(line)
                length += line.count + 1
                n += 1
            }
            if s % 7 == 0 { lines[40] += " and Micheal rang" }
            let date = calendar.date(from: DateComponents(year: 2026, month: 1 + s / 28, day: 1 + s % 28))!
            docs.append(.init(date: date, tag: "S\(s + 1)", kind: .transcript, text: lines.joined(separator: "\n")))
        }
        let saved = SessionSearch.index
        defer { SessionSearch.index = saved }
        var cold: [Double] = [], warm: [Double] = []
        for _ in 0..<3 {
            SessionSearch.index = SearchIndex()
            cold.append(milliseconds { _ = SessionSearch.search(docs, question: "Michael sleep") })
            for q in ["Michael garden", "tired weekend", "\"dinner plans\""] {
                warm.append(milliseconds { _ = SessionSearch.search(docs, question: q) })
            }
        }
        report("search.cold_50x60k", cold)
        report("search.warm_query_50x60k", warm)
    }

    /// A two-hour mic-only session: one speaker, so the whole transcript is one turn.
    func testTranscriptCompactor() {
        let lines = (0..<1500).map { String(format: "[%02d:%02d] You: Segment %d um about the week, okay. Okay.", $0 * 5 / 60, $0 * 5 % 60, $0) }
        let raw = lines.joined(separator: "\n")
        report("compactor.two_hour_single_speaker", (0..<7).map { _ in milliseconds { _ = TranscriptCompactor.compact(raw) } })
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure(work)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private func report(_ name: String, _ samples: [Double]) {
        let list = samples.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("BENCH-JSON {\"name\":\"\(name)\",\"unit\":\"ms\",\"samples\":[\(list)]}")
    }
}

/// SplitMix64, so every run benchmarks the same text.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
