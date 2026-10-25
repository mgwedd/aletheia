import XCTest
@testable import Aletheia

final class ReminderSchedulerTests: XCTestCase {
    private final class FakeStore: ReminderStore {
        var granted = true
        var addError: Error?
        var accessRequests = 0
        var added: [ReminderDraft] = []

        func requestAccess() async -> Bool {
            accessRequests += 1
            return granted
        }

        func add(_ draft: ReminderDraft) throws {
            if let addError { throw addError }
            added.append(draft)
        }
    }

    private let draft = ReminderDraft(
        title: "Follow up", notes: "Session notes", dueDate: Date(timeIntervalSince1970: 1_700_000_000))

    func testGrantedAccessAddsTheReminderExactlyOnce() async throws {
        let store = FakeStore()
        try await EventKitReminderScheduler(store: store).schedule(draft)
        XCTAssertEqual(store.added, [draft])
    }

    func testDeniedAccessThrowsAndAddsNothing() async {
        let store = FakeStore()
        store.granted = false
        do {
            try await EventKitReminderScheduler(store: store).schedule(draft)
            XCTFail("a denied permission must be reported, not swallowed")
        } catch let error as ReminderSchedulerError {
            guard case .accessDenied = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertEqual(store.accessRequests, 1)
        XCTAssertTrue(store.added.isEmpty)
    }

    func testAStoreFailureReachesTheCaller() async {
        let store = FakeStore()
        store.addError = ReminderSchedulerError.unavailable
        do {
            try await EventKitReminderScheduler(store: store).schedule(draft)
            XCTFail("a reminder that was not saved must not look saved")
        } catch let error as ReminderSchedulerError {
            guard case .unavailable = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testTheErrorsExplainWhatToDo() {
        XCTAssertTrue(ReminderSchedulerError.accessDenied.errorDescription?.contains("Privacy & Security › Reminders") == true)
        XCTAssertTrue(ReminderSchedulerError.unavailable.errorDescription?.contains("aren't available") == true)
    }
}
