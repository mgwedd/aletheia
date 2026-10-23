import XCTest
@testable import Aletheia

/// The helper stops an abandoned request when the app's connection goes away.
final class HelperTasksTests: XCTestCase {
    func testCancelAllCancelsRunningWork() async throws {
        let tasks = HelperTasks()
        let started = expectation(description: "started")
        let stopped = expectation(description: "stopped by cancellation")
        tasks.run {
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch is CancellationError {
                stopped.fulfill()
            } catch {}
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(tasks.count, 1)
        tasks.cancelAll()
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(tasks.count, 0)
    }

    func testWorkAfterCancelAllNeverRuns() async {
        let tasks = HelperTasks()
        tasks.cancelAll()
        let ran = expectation(description: "ran")
        ran.isInverted = true
        tasks.run { ran.fulfill() }
        await fulfillment(of: [ran], timeout: 0.5)
        XCTAssertEqual(tasks.count, 0)
    }

    func testFinishedWorkIsForgotten() async {
        let tasks = HelperTasks()
        let done = expectation(description: "done")
        tasks.run { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        for _ in 0..<50 where tasks.count != 0 { await Task.yield() }
        XCTAssertEqual(tasks.count, 0)
    }
}
