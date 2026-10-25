import CryptoKit
import Foundation
import XCTest
@testable import Aletheia

private final class CountingAssistant: Assistant, @unchecked Sendable {
    var prompts: [String] = []
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        return "digest text"
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

/// An expired or revoked license stops exactly two things: starting a new recording and
/// running AI. Each entry point asks the gate; nothing else does.
@MainActor
final class LicenseGateTests: XCTestCase {
    private let blocked = "License expired."

    // MARK: - Recording

    func testRecordingDoesNotStartWhenTheLicenseRefuses() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LicenseGate-\(UUID().uuidString)")
        let recorder = SessionRecorder(stagingDirectoryURL: dir.appendingPathComponent("staging"))
        recorder.licenseRefusal = { [blocked] in blocked }
        let context = SessionRecorder.ActiveRecording(
            sessionID: UUID(), patientID: UUID(), patientName: "P", patientSlug: "p", sessionFolder: "s")
        let refusal = await recorder.start(
            micURL: dir.appendingPathComponent("mic.caf"), callURL: dir.appendingPathComponent("call.caf"), context: context)
        XCTAssertEqual(refusal, blocked)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.hasOpenRecording)
        XCTAssertNil(recorder.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing was created for the refused recording")
    }

    func testRecordingStartsWhenTheLicenseAllows() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LicenseGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = SessionRecorder(stagingDirectoryURL: dir.appendingPathComponent("staging"))
        var asked = 0
        recorder.licenseRefusal = { asked += 1; return nil }
        recorder.audioCaptureStartOverride = { _, _ in }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let context = SessionRecorder.ActiveRecording(
            sessionID: UUID(), patientID: UUID(), patientName: "P", patientSlug: "p", sessionFolder: "s")
        let refusal = await recorder.start(
            micURL: dir.appendingPathComponent("mic.caf"), callURL: dir.appendingPathComponent("call.caf"), context: context)
        XCTAssertNil(refusal)
        XCTAssertEqual(asked, 1)
        await recorder.stop()
    }

    // MARK: - AI

    func testQueueAuthorizeFollowsTheGate() {
        let queue = InferenceQueue()
        XCTAssertNoThrow(try queue.authorize(), "no gate installed allows everything")
        queue.licenseRefusal = { [blocked] in blocked }
        XCTAssertThrowsError(try queue.authorize()) { XCTAssertEqual(($0 as? LicenseBlockedError)?.message, blocked) }
        queue.licenseRefusal = { nil }
        XCTAssertNoThrow(try queue.authorize())
    }

    func testChatAndNoteRunsNeverReachTheModelWhenBlocked() {
        let queue = InferenceQueue()
        queue.licenseRefusal = { [blocked] in blocked }
        let runner = ChatStreamRunner()
        var streamsMade = 0
        var errors: [Error] = []
        runner.start(
            queue: queue, kind: .note, label: "progress note",
            makeStream: { streamsMade += 1; return AsyncThrowingStream { $0.finish() } },
            onReveal: { _ in }, onError: { errors.append($0) }, onFinish: { _ in })
        XCTAssertEqual(streamsMade, 0)
        XCTAssertEqual((errors.first as? LicenseBlockedError)?.message, blocked)
        XCTAssertFalse(runner.isQueued)
        XCTAssertFalse(runner.isStreaming)
        XCTAssertNil(queue.running)
        XCTAssertTrue(queue.waiting.isEmpty)
    }

    func testBackgroundDigestsDoNotRunWhenBlocked() async {
        let queue = InferenceQueue()
        queue.licenseRefusal = { [blocked] in blocked }
        let fake = CountingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        do {
            _ = try await DigestBuilder(queue: queue).build(transcript: "[00:01] You: Hi.", service: service)
            XCTFail("a blocked license must stop the digest")
        } catch {
            XCTAssertEqual((error as? LicenseBlockedError)?.message, blocked)
        }
        XCTAssertTrue(fake.prompts.isEmpty, "nothing was sent to the model")
    }

    func testDigestsRunWhenTheLicenseAllows() async throws {
        let queue = InferenceQueue()
        queue.licenseRefusal = { nil }
        let fake = CountingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        _ = try await DigestBuilder(queue: queue).build(transcript: "[00:01] You: Hi.", service: service)
        XCTAssertFalse(fake.prompts.isEmpty)
    }
}
