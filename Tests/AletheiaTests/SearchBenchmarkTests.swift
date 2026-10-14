import XCTest
@testable import Aletheia

/// 500 generated sessions of about 10,000 words, with invented names. Slow, so
/// it only runs when ALETHEIA_BENCH is set (xcodebuild: TEST_RUNNER_ALETHEIA_BENCH=1).
/// Uses only `SessionSearch.search`, so the same file measures the previous
/// in-memory implementation on an older commit.
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
        var result: SessionSearch.Result?
        let cold = time { result = SessionSearch.search(docs, question: "Vasha sleep") }
        var warm: [Double] = []
        for q in ["Vasha sleep", "\"quiet kitchen\"", "Tarquin work", "Isolde", "worr*", "Marenka garden evening"] {
            warm.append(time { _ = SessionSearch.search(docs, question: q) })
        }
        print(String(format: "BENCH sessions=500 words=%d cold(index build + first query)=%.0f ms warm queries(ms)=%@ hits=%d mentions=%d",
                     500 * 10_000, cold, warm.map { String(format: "%.0f", $0) }.joined(separator: "/"),
                     result?.hits.count ?? 0, result?.totalMentions ?? 0))
        XCTAssertEqual(result?.sessionsSearched, 500)
    }
}
