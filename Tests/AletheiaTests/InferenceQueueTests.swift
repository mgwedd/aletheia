import XCTest
@testable import Aletheia

/// A one-shot latch a test job can park on until the test opens it.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct JobFailure: Error {}

@MainActor
final class InferenceQueueTests: XCTestCase {
    private var log: [String] = []

    /// Polls (a few ms at a time) until `condition` holds, failing on timeout.
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    /// Gives a job that wrongly started a chance to do so.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func testRunsJobsInFIFOOrder() async {
        let queue = InferenceQueue()
        for name in ["a", "b", "c"] {
            queue.enqueue(kind: .sessionChat, label: name) { [self] in log.append(name) }
        }
        await waitUntil { log.count == 3 && queue.running == nil }
        XCTAssertEqual(log, ["a", "b", "c"])
    }

    func testSecondJobWaitsUntilFirstCompletes() async {
        let queue = InferenceQueue()
        let gate = Gate()
        queue.enqueue(kind: .note, label: "note") { [self] in
            log.append("note start")
            await gate.wait()
            log.append("note end")
        }
        queue.enqueue(kind: .sessionChat, label: "chat") { [self] in log.append("chat") }

        await settle()
        XCTAssertFalse(log.contains("chat"))
        XCTAssertEqual(queue.waiting.count, 1)

        gate.open()
        await waitUntil { log.contains("chat") }
        XCTAssertEqual(log, ["note start", "note end", "chat"])
    }

    func testCancellingWaitingJobMeansItNeverRuns() async {
        let queue = InferenceQueue()
        let gate = Gate()
        queue.enqueue(kind: .note, label: "note") { await gate.wait() }
        let skipped = queue.enqueue(kind: .sessionChat, label: "skipped") { [self] in log.append("skipped") }
        queue.enqueue(kind: .patientChat, label: "last") { [self] in log.append("last") }

        queue.cancel(skipped.id)
        XCTAssertEqual(queue.waiting.map(\.label), ["last"])

        gate.open()
        await waitUntil { log.contains("last") && queue.running == nil }
        XCTAssertEqual(log, ["last"])
    }

    func testCancellingRunningJobLetsNextStart() async {
        let queue = InferenceQueue()
        // Sleeps "forever"; cancellation makes the sleep throw, ending the body.
        let first = queue.enqueue(kind: .note, label: "note") {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        queue.enqueue(kind: .sessionChat, label: "chat") { [self] in log.append("chat") }
        await settle()
        XCTAssertEqual(queue.running?.id, first.id)
        XCTAssertTrue(log.isEmpty)

        queue.cancel(first.id)
        await waitUntil { log == ["chat"] }
        XCTAssertEqual(log, ["chat"])
    }

    func testThrowingJobDoesNotStallQueue() async {
        let queue = InferenceQueue()
        queue.enqueue(kind: .note, label: "boom") { throw JobFailure() }
        queue.enqueue(kind: .sessionChat, label: "chat") { [self] in log.append("chat") }
        await waitUntil { log == ["chat"] && queue.running == nil }
        XCTAssertEqual(log, ["chat"])
    }

    func testPublishedStateTransitions() async {
        let queue = InferenceQueue()
        XCTAssertNil(queue.running)
        XCTAssertTrue(queue.waiting.isEmpty)

        let gate = Gate()
        let first = queue.enqueue(kind: .note, label: "note") { await gate.wait() }
        XCTAssertEqual(queue.running, first)
        XCTAssertTrue(queue.waiting.isEmpty)

        let second = queue.enqueue(kind: .patientChat, label: "chat") { [self] in log.append("chat") }
        XCTAssertEqual(queue.running, first)
        XCTAssertEqual(queue.waiting, [second])

        gate.open()
        await waitUntil { queue.running == nil && queue.waiting.isEmpty }
        XCTAssertEqual(log, ["chat"])
    }

    func testBlockingJobWhenNoteIsRunningAndChatWaits() async {
        let queue = InferenceQueue()
        let gate = Gate()
        let note = queue.enqueue(kind: .note, label: "note") { await gate.wait() }
        let chat = queue.enqueue(kind: .sessionChat, label: "chat") {}

        XCTAssertNil(queue.blockingJob(for: note.id))
        XCTAssertEqual(queue.blockingJob(for: chat.id), note)
        XCTAssertEqual(
            queue.waitingStatus(for: chat.id),
            "Still generating the note, your question will run next."
        )
        XCTAssertNil(queue.waitingStatus(for: note.id))

        gate.open()
        await waitUntil { queue.running == nil }
        XCTAssertNil(queue.blockingJob(for: chat.id))
        XCTAssertNil(queue.waitingStatus(for: chat.id))
    }

    func testBlockingJobWhenChatIsRunningAndNoteWaits() async {
        let queue = InferenceQueue()
        let gate = Gate()
        queue.enqueue(kind: .patientChat, label: "chat") { await gate.wait() }
        let note = queue.enqueue(kind: .note, label: "note") {}

        XCTAssertEqual(queue.waitingStatus(for: note.id), "Waiting for the chat answer to finish…")
        gate.open()
        await waitUntil { queue.running == nil }
    }

    func testStatusTextCoversEveryPairing() {
        XCTAssertEqual(
            InferenceQueue.statusText(requesting: .patientChat, behind: .note),
            "Still generating the note, your question will run next."
        )
        XCTAssertEqual(
            InferenceQueue.statusText(requesting: .sessionChat, behind: .patientChat),
            "Still answering another question, yours will run next."
        )
        XCTAssertEqual(
            InferenceQueue.statusText(requesting: .note, behind: .sessionChat),
            "Waiting for the chat answer to finish…"
        )
        XCTAssertEqual(
            InferenceQueue.statusText(requesting: .note, behind: .note),
            "Waiting for another note to finish…"
        )
    }
}
