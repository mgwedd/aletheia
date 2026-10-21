import XCTest
@testable import Aletheia

/// Global search at the size of a long history: 100 sessions of about 60,000
/// characters each (about 6M characters, an hour-long session each), through a
/// real Store and a file-backed index. Slow, so it only runs when
/// ALETHEIA_BENCH is set (xcodebuild: TEST_RUNNER_ALETHEIA_BENCH=1).
/// "cold" is a query right after the index's connection was closed (SQLite's
/// page cache gone, as after a lock); "warm" the same query again. The old
/// file-by-file scan is timed alongside for comparison.
final class GlobalSearchBenchmarkTests: XCTestCase {
    func testHundredHourLongSessions() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALETHEIA_BENCH"] != nil, "set ALETHEIA_BENCH to run")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gsbench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = SearchIndex(url: root.appendingPathComponent("search.sqlite"))
        let store = Store(root: root, searchIndex: index)
        let plain = Store(root: root)
        let patient = try store.createPatient(name: "Jane Doe")
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 12))!
        var characters = 0
        for s in 0..<100 {
            let session = try store.createSession(for: patient, on: calendar.date(byAdding: .day, value: 7 * s, to: start)!)
            var lines = (0..<900).map { i in
                "[\(i * 4 / 60):\(String(format: "%02d", i * 4 % 60))] \(i % 2 == 0 ? "You" : "Call audio"): "
                    + "Session \(s) line \(i) about work, sleep and how the week went."
            }
            if s == 17 { lines[450] = "[30:00] Call audio: A weekend of kayaking helped more than anything." }
            let text = lines.joined(separator: "\n")
            characters += text.count
            try plain.saveTranscript(text, for: patient, session: session)
        }
        func time(_ work: () -> Void) -> Double {
            let began = Date()
            work()
            return Date().timeIntervalSince(began) * 1000
        }
        let build = time { store.syncSearchIndex() }
        let queries = ["kayaking", "sleep", "work week", "kay", "jane sleep"]
        var cold: [Double] = [], warm: [Double] = [], scan: [Double] = []
        var found: [String: Int] = [:]
        for q in queries {
            index.close()
            index.reopen()
            cold.append(time { _ = store.globalSearch(query: q) })
            warm.append(time { found[q] = store.globalSearch(query: q).section(.transcript)?.total ?? 0 })
            scan.append(time { _ = store.searchHits(query: q) })
        }
        func list(_ v: [Double]) -> String { v.map { String(format: "%.0f", $0) }.joined(separator: "/") }
        print(String(
            format: "BENCH global search sessions=100 characters=%d index build=%.0f ms cold(ms)=%@ warm(ms)=%@ old scan(ms)=%@ queries=%@",
            characters, build, list(cold), list(warm), list(scan), queries.joined(separator: "/")))
        XCTAssertGreaterThan(characters, 5_500_000)
        XCTAssertEqual(found["kayaking"], 1)
        XCTAssertEqual(found["sleep"], 100)
    }
}
