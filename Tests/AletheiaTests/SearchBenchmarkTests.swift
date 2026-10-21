import os
import XCTest
@testable import Aletheia

/// 500 generated sessions of about 10,000 words, with invented names. Slow, so
/// it only runs when ALETHEIA_BENCH is set (xcodebuild: TEST_RUNNER_ALETHEIA_BENCH=1).
/// Runs against a file-backed index. "cold" is the first run of each query
/// after `closeIndex()` (connection and SQLite page cache gone, as after a lock;
/// the OS file cache is still warm), "warm" the next run.
final class SearchBenchmarkTests: XCTestCase {
    func testFiveHundredSessionsOfTenThousandWords() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALETHEIA_BENCH"] != nil, "set ALETHEIA_BENCH to run")
        let common = ["weather", "errands", "sleep", "mother", "garden", "work", "walking", "dinner", "tired", "weekend", "friends",
                      "plans", "morning", "coffee", "worried", "music", "quiet", "kitchen", "train", "window", "letters", "river",
                      "market", "bread", "winter", "ladder", "paper", "summer", "story", "morning", "evening", "house"]
        let names = ["Orlen", "Vasha", "Pemberly", "Tarquin", "Isolde", "Brannock", "Quill", "Marenka"]
        var rng = SystemRandomNumberGenerator()
        let calendar = Calendar(identifier: .gregorian)
        var docs: [SessionSearch.Document] = []
        for s in 0..<500 {
            var lines: [String] = []
            var words = 0, n = 0
            while words < 10_000 {
                var sentence = (0..<14).map { _ in common[Int.random(in: 0..<common.count, using: &rng)] }
                if n % 97 == 0 { sentence[3] = names[Int.random(in: 0..<names.count, using: &rng)] }
                if s % 50 == 0, n == 40 { sentence[5] = "Vashya" }   // a misspelling
                lines.append("[\(n / 60):\(String(format: "%02d", n % 60))] \(n % 2 == 0 ? "Therapist" : "Patient"): " + sentence.joined(separator: " "))
                words += 14
                n += 1
            }
            let date = calendar.date(byAdding: .day, value: s, to: calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!)!
            docs.append(.init(date: date, tag: "S\(s + 1)", kind: .transcript, text: lines.joined(separator: "\n"),
                              session: UUID(), patient: UUID()))
        }
        func time(_ work: () -> Void) -> Double {
            let start = Date()
            work()
            return Date().timeIntervalSince(start) * 1000
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)/search.sqlite")
        let saved = SessionSearch.index
        SessionSearch.index = SearchIndex(url: file)
        defer {
            SessionSearch.index = saved
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        var result: SessionSearch.Result?
        let cold = time { result = SessionSearch.search(docs, question: "Vasha sleep") }
        var warm: [Double] = [], afterClose: [Double] = []
        let queries = ["Vasha sleep", "\"quiet kitchen\"", "Tarquin work", "Isolde", "worr*", "Marenka garden evening"]
        for q in queries { _ = SessionSearch.search(docs, question: q) }
        for q in queries { warm.append(time { _ = SessionSearch.search(docs, question: q) }) }
        for q in queries {
            SessionSearch.closeIndex()
            SessionSearch.openIndex()
            afterClose.append(time { _ = SessionSearch.search(docs, question: q) })
        }
        // Queries while another thread keeps indexing new sessions (the launch sweep, or saves).
        let writing = DispatchGroup()
        // Shared with the writer thread, so both fields live behind one lock.
        let progress = OSAllocatedUnfairLock(initialState: (stop: false, written: 0))
        writing.enter()
        DispatchQueue.global(qos: .utility).async {
            var n = 0
            while true {
                if progress.withLock({ $0.stop }) { break }
                let d = docs[n % docs.count]
                let id = UUID().uuidString
                let text = d.text + "\n[99:00] Patient: extra \(n)"
                SessionSearch.index.replace(
                    session: id, patient: id, kinds: [.transcript],
                    items: [SearchIndex.Item(session: id, patient: id, kind: "transcript", date: 0, fingerprint: SearchIndex.fingerprint(of: text), text: text)],
                    stamp: nil)
                n += 1
                progress.withLock { $0.written = n }
            }
            writing.leave()
        }
        var whileIndexing: [Double] = []
        for q in queries { whileIndexing.append(time { _ = SessionSearch.search(docs, question: q) }) }
        progress.withLock { $0.stop = true }
        writing.wait()
        let written = progress.withLock { $0.written }
        var large: [Double] = []   // a 200,000-character budget keeps up to 20,000 hits per kind
        for q in queries { large.append(time { result = SessionSearch.search(docs, question: q, characterBudget: 200_000) }) }
        func list(_ v: [Double]) -> String { v.map { String(format: "%.0f", $0) }.joined(separator: "/") }
        print(String(format: "BENCH sessions=500 words=%d build+first query=%.0f ms warm(ms)=%@ after close(ms)=%@ while indexing %d sessions(ms)=%@ large budget(ms)=%@ hits=%d of %d mentions=%d",
                     500 * 10_000, cold, list(warm), list(afterClose), written, list(whileIndexing), list(large),
                     result?.hits.count ?? 0, result?.transcriptHitCount ?? 0, result?.totalMentions ?? 0))
        XCTAssertEqual(result?.sessionsSearched, 500)
    }
}
