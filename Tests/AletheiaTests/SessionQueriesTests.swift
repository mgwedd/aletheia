import XCTest
@testable import Aletheia

final class SessionQueriesTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testTodaysSessionsIncludesOnlyToday() throws {
        let jane = try store.createPatient(name: "Jane Doe")
        _ = try store.createSession(for: jane) // today
        let old = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        _ = try store.createSession(for: jane, on: old)

        let items = SessionQueries.todaysSessions(now: Date(), store: store)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.label.text, "J.D.")
    }

    func testTodaysSessionsSpansPatients() throws {
        let jane = try store.createPatient(name: "Jane")
        let john = try store.createPatient(name: "John")
        _ = try store.createSession(for: jane)
        _ = try store.createSession(for: john)

        let names = (SessionQueries.todaysSessions(now: Date(), store: store).map(\.label.text))
        XCTAssertEqual(names, ["J.", "J."])
    }

    func testNilStoreYieldsNothing() {
        XCTAssertTrue(SessionQueries.todaysSessions(now: Date(), store: nil).isEmpty)
    }
}
